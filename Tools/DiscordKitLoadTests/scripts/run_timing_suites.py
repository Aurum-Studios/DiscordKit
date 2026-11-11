#!/usr/bin/env python3
# File: Tools/DiscordKitLoadTests/scripts/run_timing_suites.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Capture transport/REST cases and an arrival-rate sweep with shared process supervision."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import signal
import subprocess
import sys


class SuiteProcesses:
    """Forward wrapper signals to the current supervisor and await its owned teardown."""

    def __init__(self) -> None:
        self.cancelled = False
        self.active: subprocess.Popen | None = None

    def request(self, signum: int, _frame: object) -> None:
        self.cancelled = True
        if self.active is not None:
            try:
                self.active.send_signal(signum)
            except ProcessLookupError:
                pass

    def run(self, command: list[str], *, timeout: float | None = None, **kwargs: object) -> subprocess.CompletedProcess:
        if self.cancelled:
            return subprocess.CompletedProcess(command, 130)
        with subprocess.Popen(command, **kwargs) as process:
            self.active = process
            try:
                if self.cancelled:
                    process.terminate()
                try:
                    stdout, stderr = process.communicate(timeout=timeout)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    try:
                        process.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.communicate()
                    raise
                return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
            finally:
                self.active = None


def matrix(cases: list[str], *, native: bool = True) -> list[dict]:
    """Select finite corrected cohorts and a 3-by-3 bounded overload/recovery sweep."""
    rows = []
    for case in cases:
        if case.startswith("arrival."):
            for concurrency in (1, 4, 16):
                for rate in (200, 2_000, 20_000):
                    prefix = "arrival" if case == "arrival.rest" else case
                    rows.append(dict(name=f"{prefix}-c{concurrency}-r{rate}", case=case,
                                     adapter="scripted", concurrency=concurrency, rate=rate,
                                     pending=concurrency * 2, connection="warm", tls=False))
        elif case.startswith("rest."):
            rows.append(dict(name=case, case=case, adapter="scripted", concurrency=4,
                             rate=1_000, pending=16, connection="warm", tls=False))
        else:
            for adapter in (("scripted", "nio", "foundation") if native else ("scripted",)):
                rows.append(dict(name=f"{case}-{adapter}-warm", case=case, adapter=adapter,
                                 concurrency=4, rate=1_000, pending=16, connection="warm", tls=False))
            if native and case == "transport.smallBody":
                for adapter in ("nio", "foundation"):
                    rows.append(dict(name=f"{case}-{adapter}-cold", case=case, adapter=adapter,
                                     concurrency=1, rate=1_000, pending=16, connection="cold", tls=False))
                rows.append(dict(name=f"{case}-nio-tls", case=case, adapter="nio", concurrency=4,
                                 rate=1_000, pending=16, connection="warm", tls=True))
    return rows


def compact(native: dict, row: dict) -> dict:
    """Retain counts, quantile evidence and resource receipts without copying histogram cells."""
    common = native["common"]
    cleanup = common["cleanup"]
    if common["status"] != "completed" or cleanup.get("completed") is not True or not (
        cleanup.get("remainingOwners") == 0 or
        ("remainingOwners" not in cleanup and row.get("adapter") == "foundation" and cleanup.get("reason"))
    ):
        raise ValueError("incomplete timing population or runtime cleanup")
    metrics = []
    for metric in common["metrics"]:
        metrics.append({key: metric[key] for key in ("id", "outcome", "p50", "p95", "p99", "maximum")})
    return dict(row, counts=common["counts"], metrics=metrics, gauges=common["gauges"],
                terminalOutcomesPerSecond=common["throughputPerSecond"],
                nativeReport=str(Path(row["name"]) / "00-single" / "native-report.json"))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--case", action="append", default=[])
    parser.add_argument("--requests", type=int, default=128)
    parser.add_argument("--warmup-requests", type=int, default=8)
    parser.add_argument("--scripted-only", action="store_true")
    arguments = parser.parse_args(argv)
    if not 16 <= arguments.requests <= 100_000 or not 0 <= arguments.warmup_requests <= 10_000:
        parser.error("requests must be 16...100000; warmup requests must be 0...10000")
    processes = SuiteProcesses()
    signal.signal(signal.SIGINT, processes.request)
    signal.signal(signal.SIGTERM, processes.request)
    executable = arguments.executable.resolve()
    listed = processes.run([str(executable), "timing", "--list-cases"], timeout=30,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if processes.cancelled:
        return 130
    listed.check_returncode()
    cases = listed.stdout.splitlines()
    if arguments.case:
        if not set(arguments.case).issubset(cases):
            parser.error("unknown case")
        cases = list(dict.fromkeys(arguments.case))
    rows = matrix(cases, native=not arguments.scripted_only)
    arguments.output_dir.mkdir(parents=True, exist_ok=False)
    package = Path(__file__).resolve().parents[1]
    shared = package.parent / "DiscordBenchmarkSupport" / "scripts" / "run_benchmarks.py"
    captured = []
    for row in rows:
        if processes.cancelled:
            return 130
        destination = (arguments.output_dir / row["name"]).resolve()
        command = [str(executable), "timing", "--case", row["case"], "--adapter", row["adapter"],
                   "--connection-mode", row["connection"], "--tls", str(row["tls"]).lower(),
                   "--concurrency", "{concurrency}", "--rate", str(row["rate"]), "--pending", str(row["pending"]),
                   "--requests", str(arguments.requests), "--warmup-requests", str(arguments.warmup_requests),
                   "--output", "{output}", "--profile", "{profile}", "--seed", "{seed}",
                   "--duration-seconds", "{duration_seconds}", "--warmup-seconds", "{warmup_seconds}"]
        supervised = [sys.executable, str(shared), "run", "--profile", "smoke", "--scenario", row["name"],
                      "--fixture", str(package / "Sources" / "DiscordKitLoadTests" / "RESTTimingRunner.swift"),
                      "--receipt", str(arguments.receipt.resolve()), "--command", json.dumps(command),
                      "--output-dir", str(destination), "--concurrency", str(row["concurrency"]),
                      "--scheduler-policy", "bounded-independent-arrivals" if row["case"].startswith("arrival.") else "closed-loop-cohort",
                      "--warmup-seconds", "1", "--warmup-policy", "participant-declared"]
        status = processes.run(supervised).returncode
        if processes.cancelled:
            return 130
        if status:
            return status
        native = json.loads((destination / "00-single" / "native-report.json").read_text())
        captured.append(compact(native, row))
        summary = dict(format="DiscordKitLoadTests.timing-matrix", schemaVersion=1,
                       qualification="informational local smoke; no numerical or live-service qualification", cases=captured)
        (arguments.output_dir / "matrix.json").write_text(json.dumps(summary, sort_keys=True, indent=2, allow_nan=False) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
