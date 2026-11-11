#!/usr/bin/env python3
# File: Tools/DiscordKitLoadTests/scripts/run_command_timing_suites.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Capture bounded Gateway, signed interaction and synthetic command timing cases."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import signal
import subprocess
import sys

from run_timing_suites import SuiteProcesses


def matrix(cases: list[str]) -> list[dict]:
    """Sweep actual Gateway offered rates and concurrency; isolate each case in a fresh process."""
    rows: list[dict] = []
    for case in dict.fromkeys(cases):
        if case in ("gateway.slowHandler", "gateway.overloadRecovery"):
            for concurrency in (1, 4, 16):
                for rate in (200, 2_000, 20_000):
                    rows.append(dict(name=f"{case}-c{concurrency}-r{rate}", case=case,
                                     concurrency=concurrency, rate=rate))
        else:
            rows.append(dict(name=case, case=case, concurrency=4, rate=1_000))
    # Capture direct/DSL pairs in both orders across independent fresh processes.
    synthetic = [row for row in rows if row["case"].startswith("synthetic.")]
    rows.extend(dict(row, name=row["name"] + "-reverse") for row in reversed(synthetic))
    return rows


def compact(native: dict, row: dict) -> dict:
    """Fail closed on partial terminal populations, aggregate loss and retained owners."""
    if (native.get("format") != "DiscordKitLoadTests.command-timing" or
            type(native.get("schemaVersion")) is not int or native["schemaVersion"] != 1):
        raise ValueError("unsupported native command-timing report")
    common = native["common"]
    cleanup, counts, metrics = common["cleanup"], common["counts"], common["metrics"]
    outcomes = counts["outcomes"]
    if (common["status"] != "completed" or common["identity"]["catalogVersion"] != 6 or
            cleanup.get("completed") is not True or cleanup.get("remainingOwners") != 0 or
            not 0 < counts["completed"] == counts["offered"] or
            not 0 <= counts["admitted"] <= counts["offered"] or
            set(outcomes) != {"success", "failure", "cancelled", "timedOut", "rejected", "uncertain"} or
            any(type(value) is not int or value < 0 for value in outcomes.values()) or
            sum(outcomes.values()) != counts["completed"] or not metrics):
        raise ValueError("incomplete timing population or runtime cleanup")
    retained_metrics = []
    for metric in metrics:
        distribution = metric["distribution"]
        if distribution["droppedCount"] != 0 or distribution["counterOverflow"]:
            raise ValueError("aggregate timing loss")
        retained_metrics.append({key: metric[key] for key in ("id", "outcome", "p50", "p95", "p99", "maximum")})
    evidence = {}
    if row.get("case") == "gateway.overloadRecovery":
        gateway = native["measurement"]["gateway"]["_0"]
        if gateway["recoverySucceeded"] is not True or gateway["controlWhileHandlerBlocked"] is not True:
            raise ValueError("Gateway overload control or recovery did not complete")
        evidence = dict(recoverySucceeded=True, controlWhileHandlerBlocked=True)
    return dict(row, **evidence, counts=counts, metrics=retained_metrics, gauges=common["gauges"],
                terminalOutcomesPerSecond=common["throughputPerSecond"],
                nativeReport=str(Path(row["name"]) / "00-single" / "native-report.json"))


def participant_command(executable: Path, row: dict, requests: int, warmup_requests: int) -> list[str]:
    """Keep participant warmup and all profile/provenance substitutions explicit."""
    return [str(executable), "command-timing", "--case", row["case"], "--concurrency", "{concurrency}",
            "--rate", str(row["rate"]), "--requests", str(requests), "--warmup-requests", str(warmup_requests),
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
    if not 16 <= arguments.requests <= 100_000 or not 0 <= arguments.warmup_requests <= 10_000:
        parser.error("requests must be 16...100000; warmup requests must be 0...10000")
    processes = SuiteProcesses()
    signal.signal(signal.SIGINT, processes.request)
    signal.signal(signal.SIGTERM, processes.request)
    executable = arguments.executable.resolve()
    listed = processes.run([str(executable), "command-timing", "--list-cases"], timeout=30,
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
        supervised = [sys.executable, str(shared), "run", "--profile", "smoke", "--scenario", row["name"],
                      "--receipt", str(arguments.receipt.resolve()), "--command", json.dumps(command),
                      "--output-dir", str(destination), "--concurrency", str(row["concurrency"]),
                      "--scheduler-policy", "bounded-gateway-dispatch" if row["case"].startswith("gateway.") else "closed-loop-command-cohort",
                      "--warmup-seconds", "1", "--warmup-policy", "participant-declared"]
        for fixture in ("GatewayTimingRunner.swift", "InteractionTimingRunner.swift", "SyntheticCommandTimingRunner.swift"):
            supervised.extend(["--fixture", str(package / "Sources" / "DiscordKitLoadTests" / fixture)])
        status = processes.run(supervised).returncode
        if processes.cancelled:
            return 130
        if status:
            return status
        native = json.loads((destination / "00-single" / "native-report.json").read_text())
        captured.append(compact(native, row))
        summary = dict(format="DiscordKitLoadTests.command-timing-matrix", schemaVersion=1,
                       qualification="informational local smoke; no numerical or live-service qualification", cases=captured)
        # Each successful row becomes a retained recovery point; a later failure cannot erase it.
        temporary = arguments.output_dir / "matrix.json.tmp"
        temporary.write_text(json.dumps(summary, sort_keys=True, indent=2, allow_nan=False) + "\n")
        temporary.replace(arguments.output_dir / "matrix.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
