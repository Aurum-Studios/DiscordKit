#!/usr/bin/env python3
# File: Tools/DiscordKitLoadTests/scripts/run_integration_timing_suites.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Capture reporting-only integrated load/recovery and a genuine bounded 30-minute soak.

Release receipts and the shared driver bind inputs and own process-group teardown,
RSS samples, deadlines and bounded artifacts. Every accepted cycle must contain
all four independently scheduled arrival bands and joined recovery receipts.
Standard uses five alternating baseline/candidate pairs; supplying the same
release-bound executable for both arms captures a separate no-change series.
Soak always requests at least 1800 measured seconds. A cap, interruption, missing
cycle, aggregate loss or retained owner remains failure evidence on disk.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import signal
import sys
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "DiscordBenchmarkSupport" / "scripts"))
import run_benchmarks as driver


FORMAT = "DiscordKitLoadTests.integration-matrix"
BANDS = ("below", "near", "above", "recovery")
OUTCOMES = {"success", "failure", "cancelled", "timedOut", "rejected", "uncertain"}
SCENARIO = "integration.mixed-v1"
SCHEDULER = "independent-scheduled-four-band-v1"
MAX_CYCLES = 256


def read_json(path: Path, cap: int = driver.MAX_REPORT_BYTES) -> dict:
    """Read a bounded complete object, rejecting duplicate keys and nonfinite numbers."""
    def unique_pairs(pairs: list[tuple[str, Any]]) -> dict:
        result: dict = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON key")
            result[key] = value
        return result

    with path.open("rb") as source:
        payload = source.read(cap + 1)
    if len(payload) > cap:
        raise ValueError("report exceeds byte ceiling")
    # The common parser rejects exponents that overflow and excessive recursion.
    driver.strict_json(payload)
    try:
        result = json.loads(payload, object_pairs_hook=unique_pairs)
    except RecursionError as error:
        raise ValueError("JSON nesting exceeds decoder bounds") from error
    if type(result) is not dict:
        raise ValueError("report must be a JSON object")
    return result


def integer(value: Any, label: str, minimum: int = 0, maximum: int | None = None) -> int:
    """Never let bool or a fractional count masquerade as a bounded population."""
    if type(value) is not int or value < minimum or maximum is not None and value > maximum:
        raise ValueError(f"invalid {label}")
    return value


def finite(value: Any, label: str, minimum: float = 0) -> float:
    """Require an actual finite numeric resource observation."""
    if type(value) not in (int, float) or not math.isfinite(value) or value < minimum:
        raise ValueError(f"invalid {label}")
    return value


def choose_cycle(duration: int, requested: int | None) -> int:
    """Keep every complete recovery receipt inside the fixed 256-cycle array."""
    choices = [value for value in range(4, 61, 4)
               if duration % value == 0 and 1 <= duration // value <= MAX_CYCLES]
    selected = requested if requested is not None else (8 if 8 in choices else next(iter(choices), None))
    if selected not in choices:
        raise ValueError("cycle seconds must be 4...60 in multiples of four, divide duration and require at most 256 cycles")
    return selected


def participant_command(executable: Path, row: dict) -> list[str]:
    """Pass explicit wall targets, fixed ceilings and observer policy without shell parsing."""
    return [str(executable.resolve()), "integration-timing", "--profile", "{profile}",
            "--seed", "{seed}", "--duration-seconds", "{duration_seconds}",
            "--cycle-seconds", str(row["cycle_seconds"]), "--output", "{output}",
            "--maximum-rss-bytes", "{rss_cap_bytes}",
            "--maximum-cpu-seconds", str(row["maximum_cpu_seconds"]),
            "--observer-mode", row["observer_mode"]]


def band_receipt(value: dict, name: str) -> dict:
    """Validate a complete fixed-band terminal population and resource extrema."""
    if type(value) is not dict or value.get("name") != name:
        raise ValueError("missing or relabeled load/recovery band")
    for key in ("offered", "submitted", "completed", "successful", "rejected", "cancelled",
                "peakPendingAgeNanoseconds", "recoveryNanoseconds", "schedulerMaximumLatenessNanoseconds",
                "controlProgress", "generatorCensored", "elapsedNanoseconds"):
        integer(value.get(key), f"band {key}")
    integer(value.get("peakActive"), "band peak active", maximum=8)
    integer(value.get("peakPending"), "band peak pending", maximum=8)
    if (value["offered"] == 0 or value["completed"] != value["offered"] or
            value["submitted"] > value["offered"] or value["successful"] > value["submitted"] or
            value["controlProgress"] == 0 or value["elapsedNanoseconds"] == 0 or
            value["generatorCensored"] > value["offered"]):
        raise ValueError("incomplete band population or control progress")
    outcomes = value.get("outcomes")
    if type(outcomes) is not dict or set(outcomes) != OUTCOMES:
        raise ValueError("missing band terminal outcome")
    for outcome, count in outcomes.items():
        integer(count, f"band {outcome}")
    if (sum(outcomes.values()) != value["completed"] or outcomes["success"] != value["successful"] or
            outcomes["rejected"] != value["rejected"] or outcomes["cancelled"] != value["cancelled"]):
        raise ValueError("band outcomes disagree with terminal counts")
    for key, count in (("successfulPerSecond", value["successful"]), ("completedPerSecond", value["completed"]),
                       ("offeredPerSecond", value["offered"])):
        if not math.isclose(finite(value.get(key), key), count * 1_000_000_000 / value["elapsedNanoseconds"], rel_tol=1e-12, abs_tol=1e-12):
            raise ValueError("band throughput disagrees with measured population")
    return value


def compact(native: dict, row: dict) -> dict:
    """Reject capped, partial, relabeled or unjoined integration captures before summary."""
    if (native.get("format") != "DiscordKitLoadTests.integration-timing" or
            type(native.get("schemaVersion")) is not int or native["schemaVersion"] != 1):
        raise ValueError("unsupported native integration report")
    configuration, measurement, common = native["configuration"], native["measurement"], native["common"]
    if measurement.get("cancelled") is not False or measurement.get("controlFailure") is not False:
        raise ValueError("interrupted integration or failed control progress")
    expected = dict(profile=row["profile"], seed=row["seed"], durationSeconds=row["duration_seconds"],
                    cycleSeconds=row["cycle_seconds"], maximumRSSBytes=row["maximum_rss_bytes"],
                    observerMode=row["observer_mode"])
    if any(type(configuration.get(key)) is not type(value) or configuration.get(key) != value
           for key, value in expected.items()):
        raise ValueError("participant configuration mismatch")
    if finite(configuration.get("maximumCPUSeconds"), "configured CPU cap") != row["maximum_cpu_seconds"]:
        raise ValueError("participant CPU cap mismatch")
    duration = integer(measurement.get("durationNanoseconds"), "measured duration", minimum=1)
    if duration < row["duration_seconds"] * 1_000_000_000:
        raise ValueError("short measurement cannot satisfy requested duration")
    if row["profile"] == "soak" and row["duration_seconds"] < 1800:
        raise ValueError("a successful soak requires at least 1800 seconds")
    identity = common["identity"]
    dimensions = dict(durationSeconds=row["duration_seconds"], cycleSeconds=row["cycle_seconds"],
                      maximumActive=8, maximumPending=8, workingSet=64,
                      maximumRSSBytes=row["maximum_rss_bytes"], maximumCPUSeconds=row["maximum_cpu_seconds"])
    actual_dimensions = identity["inputSizes"]
    instrumentation = "driver-aggregate+operation-" + row["observer_mode"]
    if (common.get("format") != "DiscordBenchmarkReport" or type(common.get("schemaVersion")) is not int or
            common["schemaVersion"] != 1 or common.get("status") != "completed" or
            identity.get("catalogVersion") != 9 or identity.get("scenario") != SCENARIO or
            identity.get("profile") != row["profile"] or identity.get("scheduler") != SCHEDULER or
            type(identity.get("seed")) is not int or identity["seed"] != row["seed"] or
            type(identity.get("concurrency")) is not int or identity["concurrency"] != 8 or
            identity.get("instrumentation") != instrumentation or
            set(actual_dimensions) != set(dimensions) or
            any(type(actual_dimensions.get(key)) is not int or actual_dimensions[key] != value
                for key, value in dimensions.items()) or
            identity.get("measuredNanoseconds") != duration):
        raise ValueError("common identity or duration mismatch")
    if type(common.get("clockDomain")) is not str or not common["clockDomain"] or measurement.get("clockDomain") != common["clockDomain"]:
        raise ValueError("mixed or missing monotonic clock domains")
    counts = common["counts"]
    if counts != measurement.get("counts"):
        raise ValueError("native and common population disagree")
    for key in ("offered", "admitted", "completed", "deadlineMisses"):
        integer(counts.get(key), key)
    outcomes = counts["outcomes"]
    if type(outcomes) is not dict or set(outcomes) != OUTCOMES:
        raise ValueError("missing terminal outcome")
    for key, count in outcomes.items():
        integer(count, key)
    if (counts["completed"] != counts["offered"] or counts["offered"] == 0 or
            not 0 <= counts["admitted"] <= counts["offered"] or
            counts["deadlineMisses"] > counts["offered"] or sum(outcomes.values()) != counts["completed"]):
        raise ValueError("incomplete terminal population")
    for cleanup in (measurement["cleanup"], common["cleanup"]):
        if cleanup.get("completed") is not True or type(cleanup.get("remainingOwners")) is not int or cleanup["remainingOwners"] != 0:
            raise ValueError("unjoined integration cleanup")
    for key, fields in (("restCleanup", ("active", "queued", "ordered", "flights", "waiters", "cacheEntries", "transportBodies", "transportActive")),
                        ("gatewayCleanup", ("subscriptions", "bufferedEvents", "bufferedBytes", "waitingConsumers"))):
        actual = measurement[key]
        if set(actual) != set(fields) or any(integer(actual[field], field) != 0 for field in fields):
            raise ValueError("retained final fixture owners")
    if integer(measurement.get("cacheEntriesAfterClose"), "closed cache entries") != 0:
        raise ValueError("retained closed-cache entries")
    resources = measurement["resources"]
    rss = integer(resources.get("maximumRSSBytes"), "observed maximum RSS", minimum=1)
    cpu = finite(resources.get("cpuSeconds"), "observed CPU")
    if resources.get("capExceeded") is not False or rss > row["maximum_rss_bytes"] or cpu > row["maximum_cpu_seconds"]:
        raise ValueError("participant resource cap hit")
    cycles = measurement["cycles"]
    if (type(cycles) is not list or not 1 <= len(cycles) <= min(MAX_CYCLES, row["duration_seconds"] // row["cycle_seconds"]) or
            type(measurement.get("completedCycles")) is not int or measurement["completedCycles"] != len(cycles) or
            type(measurement.get("omittedCycles", 0)) is not int or measurement.get("omittedCycles", 0) != 0):
        raise ValueError("missing or capped cycle receipts")
    aggregate = [band_receipt(value, name) for value, name in zip(measurement["bands"], BANDS)]
    if len(measurement["bands"]) != 4:
        raise ValueError("missing aggregate load/recovery bands")
    sums = {name: dict.fromkeys(("offered", "submitted", "completed", "successful", "rejected", "cancelled", "controlProgress", "generatorCensored", "elapsedNanoseconds"), 0) for name in BANDS}
    maxima = {name: dict.fromkeys(("peakActive", "peakPending", "peakPendingAgeNanoseconds", "schedulerMaximumLatenessNanoseconds", "recoveryNanoseconds"), 0) for name in BANDS}
    outcome_sums = {name: dict.fromkeys(OUTCOMES, 0) for name in BANDS}
    for ordinal, cycle in enumerate(cycles):
        if type(cycle.get("ordinal")) is not int or cycle["ordinal"] != ordinal:
            raise ValueError("missing, duplicate or reordered cycle")
        integer(cycle.get("cacheEntries"), "retained cache entries", maximum=64)
        integer(cycle.get("gatewayBufferedEvents"), "retained gateway events", maximum=64)
        for key in ("cacheRefreshes", "cacheWaiters", "remainingArrivalOwners"):
            if integer(cycle.get(key), key) != 0:
                raise ValueError("cycle recovery retained an owner")
        if type(cycle.get("bands")) is not list or len(cycle["bands"]) != 4:
            raise ValueError("incomplete recovery cycle")
        for name, value in zip(BANDS, cycle["bands"]):
            band_receipt(value, name)
            for key in sums[name]:
                sums[name][key] += value[key]
            for key in maxima[name]:
                maxima[name][key] = max(maxima[name][key], value[key])
            for outcome in OUTCOMES:
                outcome_sums[name][outcome] += value["outcomes"][outcome]
    for band in aggregate:
        if (any(band[key] != value for key, value in (sums[band["name"]] | maxima[band["name"]]).items()) or
                band["outcomes"] != outcome_sums[band["name"]]):
            raise ValueError("aggregate bands disagree with complete cycle receipts")
    if (sum(value["offered"] for value in aggregate) != counts["offered"] or
            sum(value["completed"] for value in aggregate) != counts["completed"] or
            sum(value["successful"] for value in aggregate) != outcomes["success"] or
            sum(value["rejected"] for value in aggregate) != outcomes["rejected"] or
            sum(value["cancelled"] for value in aggregate) != outcomes["cancelled"] or
            sum(value["submitted"] for value in aggregate) != counts["admitted"] or
            any(sum(value["outcomes"][outcome] for value in aggregate) != outcomes[outcome] for outcome in OUTCOMES) or
            integer(measurement.get("controlProgress"), "control progress") < sum(value["controlProgress"] for value in aggregate)):
        raise ValueError("terminal, control and band populations disagree")
    metrics = common["metrics"]
    if metrics != measurement.get("metrics") or type(metrics) is not list:
        raise ValueError("native and common metrics disagree")
    identities: set[tuple[str, str]] = set()
    for metric in metrics:
        key = metric["id"], metric["outcome"]
        if (key in identities or key[1] not in OUTCOMES or metric.get("clockDomain") != common["clockDomain"] or
                key[0] not in ("arrival.scheduledResponse", "arrival.submittedResponse", "arrival.lateness") or
                type(metric.get("version")) is not int or metric["version"] != 1):
            raise ValueError("duplicate or relabeled metric population")
        identities.add(key)
        distribution = metric["distribution"]
        integer(distribution.get("observedCount"), "metric population")
        if type(distribution.get("droppedCount")) is not int or distribution["droppedCount"] != 0 or distribution.get("counterOverflow") is not False:
            raise ValueError("aggregate timing loss")
    if row["observer_mode"] == "aggregate":
        submitted = sum(value["submitted"] for value in aggregate)
        for metric_id in ("arrival.scheduledResponse", "arrival.submittedResponse", "arrival.lateness"):
            if sum(metric["distribution"]["observedCount"] for metric in metrics if metric["id"] == metric_id) != submitted:
                raise ValueError("missing primary submitted population")
        for outcome, count in outcomes.items():
            populations = [sum(metric["distribution"]["observedCount"] for metric in metrics
                               if metric["id"] == metric_id and metric["outcome"] == outcome)
                           for metric_id in ("arrival.scheduledResponse", "arrival.submittedResponse", "arrival.lateness")]
            if len(set(populations)) != 1 or populations[0] > count or (outcome not in ("cancelled", "rejected") and populations[0] != count):
                raise ValueError("biased per-outcome submitted population")
    elif metrics:
        raise ValueError("disabled observer reported operation metrics")
    return dict(status="completed", profile=row["profile"], seed=row["seed"], observerMode=row["observer_mode"],
                requestedDurationSeconds=row["duration_seconds"], durationNanoseconds=duration,
                completedCycles=len(cycles), counts=counts, bands=aggregate, cycles=cycles,
                successfulPerSecond=outcomes["success"] * 1_000_000_000 / duration,
                terminalOutcomesPerSecond=counts["completed"] * 1_000_000_000 / duration,
                resources=resources, cleanup=common["cleanup"],
                controlProgress=measurement["controlProgress"],
                controlProgressOutsideBands=measurement["controlProgress"] - sum(value["controlProgress"] for value in aggregate),
                metrics=[{key: metric[key] for key in ("id", "outcome", "p50", "p95", "p99", "maximum")} for metric in metrics])


def inspect_process(output: Path, process: dict, row: dict) -> dict:
    """Keep failed external-process evidence out of accepted numerical populations."""
    cleanup = process["cleanup"]
    if (process.get("status") != "completed" or type(process.get("exit_code")) is not int or process["exit_code"] != 0 or
            cleanup.get("owner_reaped") is not True or cleanup.get("unexpected_descendants") is not False or
            cleanup.get("group_has_live_members_after_cleanup") is not False or
            any(type(value) is not int or value != 0 for value in process["dropped_bytes"].values())):
        raise ValueError("external process cap, failure or incomplete process-group teardown")
    observation = process["observation"]
    directory = output / f"{observation['repetition'] * 2 + observation['position']:02}-{observation['arm']}"
    # In unpaired profiles there is only one fresh process.
    if observation["arm"] == "single":
        directory = output / "00-single"
    native_path = directory / "native-report.json"
    for path in (native_path, directory / "benchmark-envelope.json"):
        receipts = [value for value in process["reports"] if Path(value["path"]).resolve() == path.resolve()]
        if len(receipts) != 1 or receipts[0]["bytes"] != path.stat().st_size or receipts[0]["sha256"] != driver.sha256_file(path):
            raise ValueError("artifact changed after supervised collection")
    native, envelope = read_json(native_path), read_json(directory / "benchmark-envelope.json")
    if native.get("common") != envelope:
        raise ValueError("native and independent common-envelope artifacts disagree")
    captured = compact(native, dict(row, seed=observation["seed"]))
    if captured["durationNanoseconds"] > integer(process.get("elapsed_ns"), "external process elapsed"):
        raise ValueError("native duration exceeds external process lifetime")
    captured.update(arm=observation["arm"], repetition=observation["repetition"],
                    nativeReport=str(native_path.relative_to(output)),
                    nativeSHA256=driver.sha256_file(native_path), commonSHA256=driver.sha256_file(directory / "benchmark-envelope.json"))
    return captured


def main(argv: list[str] | None = None) -> int:
    """Persist a truthful summary even when the shared driver retains a failed capture."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=("smoke", "standard", "soak"), default="smoke")
    parser.add_argument("--executable", type=Path)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--baseline-executable", type=Path)
    parser.add_argument("--baseline-receipt", type=Path)
    parser.add_argument("--candidate-executable", type=Path)
    parser.add_argument("--candidate-receipt", type=Path)
    parser.add_argument("--validator", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--duration-seconds", type=int)
    parser.add_argument("--cycle-seconds", type=int)
    parser.add_argument("--observer-mode", choices=("aggregate", "disabled"), default="aggregate")
    parser.add_argument("--seed", type=int, default=1)
    arguments = parser.parse_args(argv)
    profile = driver.PROFILES[arguments.profile]
    duration = arguments.duration_seconds if arguments.duration_seconds is not None else {"smoke": 8, "standard": 32, "soak": 1800}[arguments.profile]
    try:
        if not (1800 if arguments.profile == "soak" else 4) <= duration <= profile.measured_cap_seconds:
            raise ValueError("duration outside profile bounds; soak requires 1800...3600 measured seconds")
        cycle = choose_cycle(duration, arguments.cycle_seconds)
        if arguments.output_dir.exists():
            raise ValueError("output directory must be fresh")
        paired = bool(arguments.baseline_executable or arguments.candidate_executable or arguments.baseline_receipt or arguments.candidate_receipt)
        if paired and (arguments.executable or arguments.receipt or not all((arguments.baseline_executable, arguments.baseline_receipt, arguments.candidate_executable, arguments.candidate_receipt))):
            raise ValueError("provide a complete pair or one executable/receipt")
        if arguments.profile == "standard" and not paired:
            raise ValueError("standard requires an explicit baseline/candidate pair")
        if not paired and not all((arguments.executable, arguments.receipt)):
            raise ValueError("an executable and release receipt are required")
        if paired and arguments.profile != "standard":
            raise ValueError("paired captures use the standard profile")
    except ValueError as error:
        parser.error(str(error))
    row = dict(profile=arguments.profile, duration_seconds=duration, cycle_seconds=cycle,
               maximum_rss_bytes=profile.rss_cap_bytes, maximum_cpu_seconds=duration * 4 + 30,
               observer_mode=arguments.observer_mode)
    package = Path(__file__).resolve().parents[1]
    shared = argparse.Namespace(profile=arguments.profile, scenario=SCENARIO, seed=arguments.seed,
        fixture=[package / "Sources" / "DiscordKitLoadTests" / "Phase10TimingRunner.swift",
                 package / "Sources" / "DiscordKitLoadTests" / "Phase10TimingConfiguration.swift",
                 package / "Sources" / "DiscordKitLoadTests" / "Phase10TimingCommand.swift"],
        command=participant_command(arguments.executable, row) if not paired else None, receipt=arguments.receipt,
        baseline_command=participant_command(arguments.baseline_executable, row) if paired else None,
        baseline_receipt=arguments.baseline_receipt,
        candidate_command=participant_command(arguments.candidate_executable, row) if paired else None,
        candidate_receipt=arguments.candidate_receipt, output_dir=arguments.output_dir,
        warmup_seconds=0, warmup_policy="cold-process-no-in-process-warmup", duration_seconds=duration,
        concurrency=8, scheduler_policy=SCHEDULER)
    cancellation = driver.Cancellation()
    previous = {value: signal.signal(value, cancellation.request) for value in (signal.SIGINT, signal.SIGTERM)}
    summary = dict(format=FORMAT, schemaVersion=1, status="failed", informationalOnly=True, policyMode="reporting-only",
                   profile=arguments.profile, durationSeconds=duration, cycleSeconds=cycle,
                   sharedSchemaValidation="unavailable", cases=[], failures=[],
                   qualification="Reporting only on the named host; no numerical, shared-runner, platform or live-service qualification.")
    try:
        manifest = driver.run_suite(shared, cancellation)
        for process_index, process in enumerate(manifest["processes"]):
            try:
                captured = inspect_process(arguments.output_dir, process, row)
                if arguments.validator:
                    common_path = arguments.output_dir / Path(captured["nativeReport"]).parent / "benchmark-envelope.json"
                    validation_dir = arguments.output_dir / f"validation-{process_index:02}"
                    validated = driver.run_process([str(arguments.validator.resolve()), "validate", str(common_path.resolve())],
                        validation_dir, driver.ProcessLimits(30, diagnostic_bytes=1024 * 1024), cancellation)
                    if validated["status"] != "completed":
                        raise ValueError("shared schema validator failed")
                    response = read_json(validation_dir / "stdout.log", cap=1024 * 1024)
                    if response.get("valid") is not True or response.get("status") != "completed" or response.get("numericalQualification") is not False:
                        raise ValueError("shared schema validator did not confirm completed schema")
                    summary["sharedSchemaValidation"] = "available"
                summary["cases"].append(captured)
            except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
                summary["failures"].append(dict(observation=process.get("observation"), reason=str(error)[:1024]))
        if (manifest["status"] == "completed" and not summary["failures"] and
                len(summary["cases"]) == len(manifest["schedule"])):
            summary["status"] = "completed"
        elif cancellation.requested:
            summary["status"] = "cancelled"
        else:
            summary["failures"].append(dict(reason="shared orchestration did not complete every scheduled process"))
    except (OSError, ValueError, KeyError, TypeError) as error:
        summary["status"] = "cancelled" if cancellation.requested else "failed"
        summary["failures"].append(dict(reason=str(error)[:1024]))
    finally:
        for value, handler in previous.items():
            signal.signal(value, handler)
        arguments.output_dir.mkdir(parents=True, exist_ok=True)
        driver.atomic_json(arguments.output_dir / "integration-summary.json", summary)
    print(json.dumps(dict(status=summary["status"], format=FORMAT, acceptedProcesses=len(summary["cases"]))))
    return 0 if summary["status"] == "completed" else 130 if summary["status"] == "cancelled" else 1


if __name__ == "__main__":
    raise SystemExit(main())
