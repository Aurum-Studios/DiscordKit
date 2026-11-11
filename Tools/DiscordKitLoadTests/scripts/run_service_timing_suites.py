#!/usr/bin/env python3
# File: Tools/DiscordKitLoadTests/scripts/run_service_timing_suites.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Capture bounded OAuth, RPC, Activities and service composition timing cases."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import signal
import subprocess
import sys

from run_timing_suites import SuiteProcesses

OAUTH_SCALING_CASES = {"oauth.sharedRefreshV2", "oauth.unrelatedRefreshV2", "oauth.partialCancellationV2"}


def versioned_dimensions(row: dict) -> dict[str, int]:
    """Return only dimensions belonging to the selected versioned workload identity."""
    case = row.get("case") or row["name"]
    if case in OAUTH_SCALING_CASES:
        return dict(storageDelayMicroseconds=row.get("storage_delay_microseconds", 0),
                    backendDelayMicroseconds=row.get("backend_delay_microseconds", 0))
    if case == "activities.subscriptionGroupsV1":
        return dict(subscriptionGroups=row.get("subscription_groups", 1), ownersPerGroup=row.get("owners_per_group", 1))
    if case == "rpc.queuedRepliesV1":
        return dict(queueDepth=row.get("queue_depth", 0), replyCohort=64)
    return {}


def primary_metric(case: str) -> str:
    """Return the closed caller population; child samples never multiply terminal counts."""
    if case == "oauth.storage":
        return "oauth.install"
    if case == "oauth.revoke":
        return "oauth.revoke"
    if case == "rpc.queuedRepliesV1":
        return "rpc.queuedReplyCohortV1"
    for prefix, metric in (("oauth.", "oauth.lookup"), ("rpc.", "rpc.request"),
                           ("activities.", "activities.request"), ("service.", "service.operation")):
        if case.startswith(prefix):
            return metric
    raise ValueError("unsupported service case family")


def matrix(cases: list[str]) -> list[dict]:
    """Sweep explicit contention, subscriber and injected-wait dimensions with finite cohorts."""
    rows: list[dict] = []
    for case in dict.fromkeys(cases):
        primary_metric(case)
        base = dict(name=case, case=case, concurrency=4, fan_out=2, delay_microseconds=2000,
                    storage_delay_microseconds=0, backend_delay_microseconds=0,
                    subscription_groups=1, owners_per_group=1, queue_depth=0,
                    profile="smoke", duration_seconds=10, warmup_seconds=1)
        if case in OAUTH_SCALING_CASES:
            base["delay_microseconds"] = 0
        if case in ("activities.subscriptionGroupsV1", "rpc.queuedRepliesV1"):
            base.update(concurrency=1, requests=2, warmup_requests=1, delay_microseconds=0)
        rows.append(base)
        if case in ("oauth.singleFlight", "rpc.requests", "activities.requests", "service.socialProfile"):
            for concurrency in (1, 8, 32):
                rows.append(dict(base, name=f"{case}-c{concurrency}", concurrency=concurrency))
        if case in ("rpc.events", "activities.events", "activities.subscriptions"):
            for fan_out in (1, 8, 32):
                rows.append(dict(base, name=f"{case}-fan{fan_out}", fan_out=fan_out))
        if case in ("oauth.refresh", "rpc.requests", "activities.requests", "service.gameMembers"):
            for delay in (0, 10000):
                rows.append(dict(base, name=f"{case}-delay{delay}", delay_microseconds=delay))
        if case in OAUTH_SCALING_CASES:
            for concurrency in (1, 64, 256):
                rows.append(dict(base, name=f"{case}-c{concurrency}", concurrency=concurrency,
                                 requests=2 * concurrency, warmup_requests=concurrency,
                                 profile="soak" if concurrency > 64 else "smoke"))
            for owner, key in (("storage", "storage_delay_microseconds"), ("backend", "backend_delay_microseconds")):
                rows.append(dict(base, name=f"{case}-{owner}10000", **{key: 10000}))
        if case == "activities.subscriptionGroupsV1":
            for groups, owners in ((1, 4095), (16, 255), (256, 15), (1024, 3)):
                rows.append(dict(base, name=f"{case}-groups{groups}-tokens4096",
                                 subscription_groups=groups, owners_per_group=owners))
        if case == "rpc.queuedRepliesV1":
            for depth in (64, 1024, 4096):
                rows.append(dict(base, name=f"{case}-queued{depth}", queue_depth=depth))
    return rows


def compact(native: dict, row: dict) -> dict:
    """Fail closed on partial terminal populations, aggregate loss and retained owners."""
    if (native.get("format") != "DiscordKitLoadTests.service-timing" or
            type(native.get("schemaVersion")) is not int or native["schemaVersion"] != 1):
        raise ValueError("unsupported native service-timing report")
    common = native["common"]
    configuration, identity = native["configuration"], common["identity"]
    expected_case = row.get("case", row["name"])
    expected = {"scenario": expected_case, "concurrency": row["concurrency"], "fanOut": row["fan_out"],
                "delayMicroseconds": row["delay_microseconds"], "profile": row["profile"],
                "durationSeconds": row["duration_seconds"], "warmupSeconds": row["warmup_seconds"],
                "requests": row["requests"], "warmupRequests": row["warmup_requests"]}
    if any(configuration.get(key) != value or type(configuration.get(key)) is not type(value)
           for key, value in expected.items()):
        raise ValueError("participant configuration does not match selected matrix row")
    extra = versioned_dimensions(row)
    defaults = dict(storageDelayMicroseconds=0, backendDelayMicroseconds=0,
                    subscriptionGroups=1, ownersPerGroup=1, queueDepth=0)
    for key, default in defaults.items():
        value = extra.get(key, default)
        actual = configuration.get(key, default if key not in extra else None)
        if type(actual) is not int or actual != value:
            raise ValueError("versioned participant dimensions do not match selected matrix row")
    dimensions = identity["inputSizes"]
    expected_dimensions = {"requests": row["requests"], "warmupRequests": row["warmup_requests"],
        "configuredConcurrency": row["concurrency"], "fanOut": row["fan_out"],
        "delayMicroseconds": row["delay_microseconds"], "durationCapSeconds": row["duration_seconds"]}
    expected_dimensions.update(extra)
    if (identity.get("scenario") != expected_case or identity.get("profile") != row["profile"] or
            identity.get("concurrency") != min(row["concurrency"], row["requests"]) or
            set(dimensions) != set(expected_dimensions) or
            any(dimensions.get(key) != value or type(dimensions.get(key)) is not int
                for key, value in expected_dimensions.items())):
        raise ValueError("common identity does not match selected matrix row")
    cleanup, counts, metrics = common["cleanup"], common["counts"], common["metrics"]
    outcomes = counts["outcomes"]
    if (common["status"] != "completed" or common["identity"]["catalogVersion"] != 8 or
            cleanup.get("completed") is not True or cleanup.get("remainingOwners") != 0 or
            not 0 < counts["completed"] == counts["offered"] or
            not 0 <= counts["admitted"] <= counts["offered"] or
            set(outcomes) != {"success", "failure", "cancelled", "timedOut", "rejected", "uncertain"} or
            any(type(value) is not int or value < 0 for value in outcomes.values()) or
            sum(outcomes.values()) != counts["completed"] or not metrics):
        raise ValueError("incomplete timing population or runtime cleanup")
    required = primary_metric(row.get("case", row["name"]))
    if sum(metric["distribution"].get("observedCount", 0) for metric in metrics if metric["id"] == required) != counts["completed"]:
        raise ValueError("incomplete primary operation distribution")
    for outcome, count in outcomes.items():
        if sum(metric["distribution"].get("observedCount", 0) for metric in metrics
               if metric["id"] == required and metric["outcome"] == outcome) != count:
            raise ValueError("primary outcome population mismatch")
    retained_metrics = []
    for metric in metrics:
        distribution = metric["distribution"]
        if distribution["droppedCount"] != 0 or distribution["counterOverflow"]:
            raise ValueError("aggregate timing loss")
        retained_metrics.append({key: metric[key] for key in ("id", "outcome", "p50", "p95", "p99", "maximum")})
    return dict(row, counts=counts, metrics=retained_metrics, gauges=common["gauges"],
                terminalOutcomesPerSecond=common["throughputPerSecond"],
                nativeReport=str(Path(row["name"]) / "00-single" / "native-report.json"))


def participant_command(executable: Path, row: dict, requests: int, warmup_requests: int) -> list[str]:
    """Keep participant warmup and all profile/provenance substitutions explicit."""
    command = [str(executable), "service-timing", "--case", row["case"], "--concurrency", "{concurrency}",
            "--fan-out", str(row["fan_out"]), "--delay-microseconds", str(row["delay_microseconds"]),
            "--requests", str(requests), "--warmup-requests", str(warmup_requests),
            "--output", "{output}", "--profile", "{profile}", "--seed", "{seed}",
            "--duration-seconds", "{duration_seconds}", "--warmup-seconds", "{warmup_seconds}"]
    switches = dict(storageDelayMicroseconds="--storage-delay-microseconds",
        backendDelayMicroseconds="--backend-delay-microseconds", subscriptionGroups="--subscription-groups",
        ownersPerGroup="--owners-per-group", queueDepth="--queue-depth")
    for key, value in versioned_dimensions(row).items():
        if key in switches:
            command.extend([switches[key], str(value)])
    return command



def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--case", action="append", default=[])
    parser.add_argument("--requests", type=int, default=128)
    parser.add_argument("--warmup-requests", type=int, default=8)
    arguments = parser.parse_args(argv)
    if not 32 <= arguments.requests <= 100_000 or not 0 <= arguments.warmup_requests <= 10_000:
        parser.error("requests must be 32...100000; warmup requests must be 0...10000")
    processes = SuiteProcesses()
    signal.signal(signal.SIGINT, processes.request)
    signal.signal(signal.SIGTERM, processes.request)
    executable = arguments.executable.resolve()
    listed = processes.run([str(executable), "service-timing", "--list-cases"], timeout=30,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if processes.cancelled:
        return 130
    listed.check_returncode()
    cases = listed.stdout.splitlines()
    if not cases or len(cases) != len(set(cases)):
        raise ValueError("participant returned empty or duplicate finite cases")
    if arguments.case:
        if not set(arguments.case).issubset(cases):
            parser.error("unknown case")
        cases = list(dict.fromkeys(arguments.case))
    rows = matrix(cases)
    arguments.output_dir.mkdir(parents=True, exist_ok=False)
    package = Path(__file__).resolve().parents[1]
    shared = package.parent / "DiscordBenchmarkSupport" / "scripts" / "run_benchmarks.py"
    captured = []
    for selected in rows:
        row = dict(selected, requests=selected.get("requests", arguments.requests),
                   warmup_requests=selected.get("warmup_requests", arguments.warmup_requests))
        if processes.cancelled:
            return 130
        destination = (arguments.output_dir / row["name"]).resolve()
        command = participant_command(executable, row, row["requests"], row["warmup_requests"])
        supervised = [sys.executable, str(shared), "run", "--profile", row["profile"], "--scenario", row["name"],
                      "--receipt", str(arguments.receipt.resolve()), "--command", json.dumps(command),
                      "--output-dir", str(destination), "--concurrency", str(row["concurrency"]),
                      "--scheduler-policy", "bounded-rpc-reply-cohort" if row["case"] == "rpc.queuedRepliesV1" else "bounded-service-cohort",
                      "--duration-seconds", str(row["duration_seconds"]),
                      "--warmup-seconds", str(row["warmup_seconds"]), "--warmup-policy", "participant-declared"]
        for fixture in ("OAuthTimingRunner.swift", "OAuthScalingTimingRunner.swift", "RPCActivitiesTimingRunner.swift",
                        "RPCQueueTimingRunner.swift", "ServiceTimingRunner.swift"):
            supervised.extend(["--fixture", str(package / "Sources" / "DiscordKitLoadTests" / fixture)])
        status = processes.run(supervised).returncode
        if processes.cancelled:
            return 130
        if status:
            return status
        native = json.loads((destination / "00-single" / "native-report.json").read_text())
        captured.append(compact(native, row))
        summary = dict(format="DiscordKitLoadTests.service-timing-matrix", schemaVersion=1,
                       qualification="informational local smoke; no numerical or live-service qualification", cases=captured)
        # Each successful row becomes a retained recovery point; a later failure cannot erase it.
        temporary = arguments.output_dir / "matrix.json.tmp"
        temporary.write_text(json.dumps(summary, sort_keys=True, indent=2, allow_nan=False) + "\n")
        temporary.replace(arguments.output_dir / "matrix.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
