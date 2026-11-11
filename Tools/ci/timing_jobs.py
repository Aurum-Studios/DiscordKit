#!/usr/bin/env python3
# File: Tools/ci/timing_jobs.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Run separately invoked bounded timing comparisons and periodic offline workloads.

These jobs never adopt baselines or modify reviewed policies. Shared runners
produce informational numbers; correctness, process ownership and resource bounds
remain hard checks. Standard comparisons require prepared receipts, a named
controlled host and an independent no-change series.
"""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

import linux_ci
import native_jobs

SUPPORT = "Tools/DiscordBenchmarkSupport"
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "DiscordBenchmarkSupport/scripts"))
import run_benchmarks as runner


def build_product(repository, package, product, output, report, *, receipt_name="release.json"):
    """Use the common pinned release builder and verify its exact executable receipt."""
    receipt = output / receipt_name
    command = linux_ci.Command("release-build", (sys.executable, str(repository / SUPPORT / "scripts/run_benchmarks.py"),
        "build", "--repository", str(repository), "--package", str(repository / package),
        "--product", product, "--receipt", str(receipt)), 1860)
    native_jobs.execute_commands([command], repository, output, report)
    document = runner.strict_json(receipt.read_bytes())
    executable = Path(document["executable"]["path"])
    runner.validate_receipt(receipt, [str(executable)])
    return executable, receipt


def periodic_command(repository, profile, executable, receipt, output, duration, *, validator=None):
    """Select a bounded CPU sweep, cache soak or integrated load/recovery soak."""
    shared = repository / SUPPORT / "scripts/run_benchmarks.py"
    if profile == "integration":
        if validator is None:
            raise ValueError("periodic integration requires the prebuilt shared schema validator")
        wrapper = repository / "Tools/DiscordKitLoadTests/scripts/run_integration_timing_suites.py"
        return linux_ci.Command("integration-capture", (sys.executable, str(wrapper),
            "--profile", "soak", "--executable", str(executable), "--receipt", str(receipt),
            "--validator", str(validator),
            "--duration-seconds", str(duration), "--output-dir", str(output / "capture")), duration + 60)
    if profile == "stress":
        participant = [str(executable), "--mode", "callbackContention", "--profile", "{profile}",
            "--concurrency", "{concurrency}", "--seed", "{seed}", "--iterations", "1000000",
            "--warmup-iterations", "128", "--duration-seconds", "{duration_seconds}",
            "--warmup-seconds", "{warmup_seconds}", "--output", "{output}"]
        fixture = "Tools/DiscordTimingBenchmarks/fixture.txt"
        scenario, scheduler, warmup = "instrumentation.cpu-fixture", "finite-structured-worker-cohort", 1
    elif profile == "soak":
        # Legacy load reports retain their explicit unqualified common adapter.
        # This is continuity/resource evidence, never a timing-baseline population.
        participant = [str(executable), "--scenario", "soak", "--profile", "accounts-10000",
                       "--rounds", "64", "--duration-seconds", "{duration_seconds}"]
        fixture = "Tools/DiscordKitLoadTests/Profiles/accounts-10000.json"
        scenario, scheduler, warmup = "cache-broadcast-continuity", "legacy-bounded-cohort", 0
    else:
        raise ValueError("periodic workloads support stress, soak or integration only")
    return linux_ci.Command("periodic-capture", (sys.executable, str(shared), "run", "--profile", profile,
        "--scenario", scenario, "--fixture", str(repository / fixture), "--receipt", str(receipt),
        "--command", json.dumps(participant), "--output-dir", str(output / "capture"),
        "--concurrency", "16", "--scheduler-policy", scheduler, "--duration-seconds", str(duration),
        "--warmup-seconds", str(warmup), "--warmup-policy", "participant-declared" if warmup else "cold-process-no-in-process-warmup"),
        (duration + warmup + 30) * (3 if profile == "stress" else 1) + 30)


def verify_periodic(output, profile, duration):
    """Keep resource/continuity assertions hard while retaining numerical evidence as reporting."""
    manifest = native_jobs.read_timing_json(output / "capture/orchestration.json")
    expected = 3 if profile == "stress" else 1
    if manifest.get("status") != "completed" or len(manifest.get("processes", [])) != expected:
        raise ValueError("periodic workload has missing or failed observations")
    if profile == "integration":
        summary = native_jobs.read_timing_json(output / "capture/integration-summary.json")
        if (summary.get("format") != "DiscordKitLoadTests.integration-matrix"
                or type(summary.get("schemaVersion")) is not int or summary["schemaVersion"] != 1
                or summary.get("status") != "completed" or summary.get("informationalOnly") is not True
                or summary.get("policyMode") != "reporting-only" or summary.get("failures") != []
                or summary.get("sharedSchemaValidation") != "available"
                or summary.get("profile") != "soak" or summary.get("durationSeconds") != duration
                or len(summary.get("cases", [])) != 1):
            raise ValueError("integrated soak is incomplete or lacks reporting-only integrity evidence")
        case = summary["cases"][0]
        if (case.get("status") != "completed" or case.get("requestedDurationSeconds") != duration
                or case.get("durationNanoseconds", -1) < duration * 1_000_000_000):
            raise ValueError("integrated soak did not complete the requested measured duration")
    for index, process in enumerate(manifest["processes"]):
        if process.get("status") != "completed":
            raise ValueError("periodic child did not complete")
        directory = output / f"capture/{index:02}-single"
        if profile == "integration":
            # The integration wrapper validates each native report's measured
            # duration, resource ceilings, terminal accounting and joined owners.
            continue
        elif profile == "stress":
            native_jobs.verify_common_smoke(native_jobs.read_timing_json(directory / "benchmark-envelope.json"))
        else:
            native = native_jobs.read_timing_json(directory / "stdout.log")
            if (native.get("scenario") != "soak" or native.get("profile") != "accounts-10000"
                    or native.get("configuredDurationSeconds") != duration or native.get("durationSeconds", -1) < duration
                    or native.get("completedRounds", 0) < 64
                    or any(native.get(key) != 0 for key in ("entriesAfterShutdown", "refreshesAfterShutdown",
                            "waitersAfterShutdown", "subscriptionsAfterShutdown", "bufferedEventsAfterShutdown"))
                    or native.get("peakEntries", 1) > native.get("maximumEntries", 0)
                    or native.get("peakAccountedBytes", 1) > native.get("maximumAccountedBytes", 0)):
                raise ValueError("soak continuity, retained-resource or shutdown assertion failed")


def retain_inputs(inputs, output):
    """Retain the exact bounded JSON inputs without changing their operator-owned originals."""
    for source, name in inputs:
        if not source.is_file() or source.stat().st_size > runner.MAX_REPORT_BYTES:
            raise ValueError("comparison inputs must be present bounded JSON files")
        runner.strict_json(source.read_bytes())
        shutil.copyfile(source, output / name)


def controlled_capture_commands(repository, spec, noise, executable, output):
    """Capture frozen pairs for subsequent policy review; no preapproved policy can hash fresh timings."""
    retain_inputs(((spec, "comparison-spec.json"), (noise, "no-change-series.json")), output)
    specification = runner.strict_json(spec.read_bytes())
    if specification.get("profile") != "standard" or specification.get("host", {}).get("controlled") is not True:
        raise ValueError("full comparison requires a standard profile on an explicitly controlled host")
    wrapper = str(repository / SUPPORT / "scripts/run_comparison.py")
    return [linux_ci.Command("paired-capture", (sys.executable, wrapper, "capture", "--spec", str(spec),
                "--noise-series", str(noise), "--output-dir", str(output / "capture")), 4200),
            linux_ci.Command("review-hashes", (str(executable), "hash-series", str(output / "capture/series.json")), 120)]


def controlled_evaluate_commands(repository, series, policy, executable, output):
    """Evaluate the exact retained series after review, without recapturing or replacing any baseline."""
    retain_inputs(((series, "reviewed-series.json"), (policy, "reviewed-policy.json")), output)
    wrapper = str(repository / SUPPORT / "scripts/run_comparison.py")
    return [linux_ci.Command("reviewed-policy-evaluation", (sys.executable, wrapper, "evaluate",
                "--series", str(output / "reviewed-series.json"), "--policy", str(output / "reviewed-policy.json"),
                "--evaluator", str(executable), "--output-dir", str(output / "evaluation")), 120)]


def main(argv=None):
    """Expose workflow operations with bounded process groups and durable partial/failure logs."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("periodic", "controlled"))
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--profile", choices=("stress", "soak", "integration"))
    parser.add_argument("--stage", choices=("capture", "evaluate"))
    parser.add_argument("--duration-seconds", type=int)
    parser.add_argument("--spec", type=Path)
    parser.add_argument("--policy", type=Path)
    parser.add_argument("--noise-series", type=Path)
    parser.add_argument("--series", type=Path)
    args = parser.parse_args(argv)
    if args.operation == "periodic" and not args.profile:
        parser.error("periodic requires --profile")
    if args.operation == "controlled":
        if not args.stage:
            parser.error("controlled requires an explicit --stage capture or evaluate")
        if args.stage == "capture" and not all((args.spec, args.noise_series)):
            parser.error("capture requires --spec and --noise-series")
        if args.stage == "evaluate" and not all((args.series, args.policy)):
            parser.error("evaluate requires --series and --policy")
    repository, output = args.repository.resolve(), args.output.resolve()
    if output.exists():
        parser.error("output must be a new directory")
    report = {"status": "running", "operation": args.operation, "commands": [],
              "numericalQualification": "reporting only until a reviewed workload policy promotes its gate"}
    try:
        output.mkdir(parents=True, exist_ok=False)
        native_jobs.write_json(output / "commands.json", report)
        if args.operation == "periodic":
            minimum, default, cap = {"stress": (1, 60, 60), "soak": (1, 600, 600),
                                     "integration": (1800, 1800, 3600)}[args.profile]
            duration = default if args.duration_seconds is None else args.duration_seconds
            if not minimum <= duration <= cap:
                raise ValueError(f"duration must be between {minimum} and {cap} seconds for this job")
            package, product = (("Tools/DiscordTimingBenchmarks", "DiscordTimingBenchmarks") if args.profile == "stress"
                                else ("Tools/DiscordKitLoadTests", "DiscordKitLoadTests"))
            executable, receipt = build_product(repository, package, product, output, report)
            validator = validator_receipt = None
            if args.profile == "integration":
                validator, validator_receipt = build_product(repository, SUPPORT, "DiscordBenchmarkReports", output,
                    report, receipt_name="schema-validator-release.json")
            command = periodic_command(repository, args.profile, executable, receipt, output, duration, validator=validator)
            native_jobs.execute_commands([command], repository, output, report)
            verify_periodic(output, args.profile, duration)
            if validator_receipt is not None:
                runner.validate_receipt(validator_receipt, [str(validator)])
        else:
            executable, receipt = build_product(repository, SUPPORT, "DiscordBenchmarkReports", output, report)
            if args.stage == "capture":
                commands = controlled_capture_commands(repository, args.spec.resolve(), args.noise_series.resolve(), executable, output)
                native_jobs.execute_commands(commands[:1], repository, output, report)
                hashes = native_jobs.execute_commands(commands[1:], repository, output, report, capture_stdout=True)[0]
                runner.strict_json(hashes.read_bytes())
                shutil.copyfile(hashes, output / "review-hashes.json")
            else:
                commands = controlled_evaluate_commands(repository, args.series.resolve(), args.policy.resolve(), executable, output)
                native_jobs.execute_commands(commands, repository, output, report)
        runner.validate_receipt(receipt, [str(executable)])
        report["status"] = "passed"
        native_jobs.write_json(output / "commands.json", report)
        return 0
    except (ValueError, OSError, KeyError, TypeError, AttributeError, RecursionError, subprocess.SubprocessError) as error:
        report.update(status="failed", error=str(error))
        native_jobs.write_json(output / "commands.json", report)
        print(f"Timing job failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
