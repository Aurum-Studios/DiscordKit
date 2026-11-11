#!/usr/bin/env python3
# File: Tools/DiscordKitLoadTests/scripts/run_cache_client_timing_suites.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Capture bounded cache, broadcast and local client timing cases."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import signal
import subprocess
import sys

from run_timing_suites import SuiteProcesses


def matrix(cases: list[str]) -> list[dict]:
    """Sweep one declared dimension at a time while keeping every active cohort finite."""
    rows: list[dict] = []
    for case in dict.fromkeys(cases):
        base = dict(name=case, case=case, concurrency=4, working_set=16,
                    identities=1, hit_percent=100, fan_out=2, slow_subscriber=False,
                    profile="smoke", duration_seconds=10, warmup_seconds=1)
        rows.append(base)
        if case == "cache.lookup":
            for size in (256, 4096):
                # The full 4,096-entry public-API setup exceeds smoke's wall cap.
                # Use the single-process soak profile with explicitly lowered caps;
                # this finite fixture capture does not qualify a sustained soak.
                rows.append(dict(base, name=f"{case}-w{size}", working_set=size,
                                 profile="soak" if size == 4096 else "smoke",
                                 duration_seconds=60 if size == 4096 else 10,
                                 warmup_seconds=60 if size == 4096 else 1))
            for hit in (0, 50):
                rows.append(dict(base, name=f"{case}-hit{hit}", hit_percent=hit))
            rows.append(dict(base, name=f"{case}-identities8", identities=8))
        if case in ("cache.lookup", "cache.singleFlight"):
            for concurrency in (1, 8, 32):
                rows.append(dict(base, name=f"{case}-c{concurrency}", concurrency=concurrency))
        if case == "cache.broadcast":
            for fan_out in (1, 8, 32):
                for slow in (False, True):
                    rows.append(dict(base, name=f"{case}-fan{fan_out}-slow{int(slow)}",
                                     fan_out=fan_out, slow_subscriber=slow))
    return rows


def compact(native: dict, row: dict) -> dict:
    """Fail closed on partial terminal populations, aggregate loss and retained owners."""
    if (native.get("format") != "DiscordKitLoadTests.cache-client-timing" or
            type(native.get("schemaVersion")) is not int or native["schemaVersion"] != 1):
        raise ValueError("unsupported native cache-client-timing report")
    common = native["common"]
    cleanup, counts, metrics = common["cleanup"], common["counts"], common["metrics"]
    outcomes = counts["outcomes"]
    if (common["status"] != "completed" or common["identity"]["catalogVersion"] != 7 or
            cleanup.get("completed") is not True or cleanup.get("remainingOwners") != 0 or
            not 0 < counts["completed"] == counts["offered"] or
            not 0 <= counts["admitted"] <= counts["offered"] or
            set(outcomes) != {"success", "failure", "cancelled", "timedOut", "rejected", "uncertain"} or
            any(type(value) is not int or value < 0 for value in outcomes.values()) or
            sum(outcomes.values()) != counts["completed"] or not metrics):
        raise ValueError("incomplete timing population or runtime cleanup")
    required = "cache.call" if row.get("case", row["name"]).startswith("cache.") else "client.construct"
    if sum(metric["distribution"].get("observedCount", 0) for metric in metrics if metric["id"] == required) != counts["completed"]:
        raise ValueError("incomplete primary operation distribution")
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
    return [str(executable), "cache-client-timing", "--case", row["case"], "--concurrency", "{concurrency}",
            "--working-set", str(row["working_set"]), "--identities", str(row["identities"]),
            "--hit-percent", str(row["hit_percent"]), "--fan-out", str(row["fan_out"]),
            "--slow-subscriber", str(row["slow_subscriber"]).lower(), "--requests", str(requests), "--warmup-requests", str(warmup_requests),
            "--output", "{output}", "--profile", "{profile}", "--seed", "{seed}",
            "--duration-seconds", "{duration_seconds}", "--warmup-seconds", "{warmup_seconds}"]


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
    listed = processes.run([str(executable), "cache-client-timing", "--list-cases"], timeout=30,
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
    for row in rows:
        if processes.cancelled:
            return 130
        destination = (arguments.output_dir / row["name"]).resolve()
        command = participant_command(executable, row, arguments.requests, arguments.warmup_requests)
        supervised = [sys.executable, str(shared), "run", "--profile", row["profile"], "--scenario", row["name"],
                      "--receipt", str(arguments.receipt.resolve()), "--command", json.dumps(command),
                      "--output-dir", str(destination), "--concurrency", str(row["concurrency"]),
                      "--scheduler-policy", "bounded-cache-cohort" if row["case"].startswith("cache.") else "bounded-client-cohort",
                      "--duration-seconds", str(row["duration_seconds"]),
                      "--warmup-seconds", str(row["warmup_seconds"]), "--warmup-policy", "participant-declared"]
        for fixture in ("CacheTimingRunner.swift", "Phase7ClientTimingRunner.swift"):
            supervised.extend(["--fixture", str(package / "Sources" / "DiscordKitLoadTests" / fixture)])
        status = processes.run(supervised).returncode
        if processes.cancelled:
            return 130
        if status:
            return status
        native = json.loads((destination / "00-single" / "native-report.json").read_text())
        captured.append(compact(native, row))
        summary = dict(format="DiscordKitLoadTests.cache-client-timing-matrix", schemaVersion=1,
                       qualification="informational local smoke; no numerical or live-service qualification", cases=captured)
        # Each successful row becomes a retained recovery point; a later failure cannot erase it.
        temporary = arguments.output_dir / "matrix.json.tmp"
        temporary.write_text(json.dumps(summary, sort_keys=True, indent=2, allow_nan=False) + "\n")
        temporary.replace(arguments.output_dir / "matrix.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
