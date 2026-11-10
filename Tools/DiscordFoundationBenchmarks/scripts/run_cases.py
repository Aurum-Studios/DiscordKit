#!/usr/bin/env python3
# File: Tools/DiscordFoundationBenchmarks/scripts/run_cases.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Run representative CPU cases through the shared release-process supervisor.

The shared driver owns receipts, timeouts, resource bounds and fresh processes.
This entry point selects finite cases and exports a size-scaling index; it neither
reimplements statistics nor turns a smoke capture into a numerical comparison.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import signal
import subprocess
import sys


class CaseProcesses:
    """Forward wrapper cancellation to its current shared supervisor and await teardown."""

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
                # A signal can arrive between the initial check and assigning the child.
                if self.cancelled:
                    process.terminate()
                try:
                    stdout, stderr = process.communicate(timeout=timeout)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    try:
                        process.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill(); process.communicate()
                    raise
                return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
            finally:
                self.active = None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--case", action="append", default=[])
    parser.add_argument("--batches", type=int, default=100)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--warmup-batches", type=int, default=8)
    arguments = parser.parse_args()
    processes = CaseProcesses()
    signal.signal(signal.SIGINT, processes.request)
    signal.signal(signal.SIGTERM, processes.request)
    if not 1 <= arguments.batches <= 100_000 or not 1 <= arguments.batch_size <= 1_024 or not 0 <= arguments.warmup_batches <= 10_000:
        parser.error("invalid finite batch budget")
    executable = arguments.executable.resolve()
    listed = processes.run([str(executable), "--list-cases"], text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    if processes.cancelled:
        return 130
    listed.check_returncode()
    cases = listed.stdout.splitlines()
    if arguments.case:
        if not set(arguments.case).issubset(cases):
            parser.error("unknown case")
        cases = list(dict.fromkeys(arguments.case))
    arguments.output_dir.mkdir(parents=True, exist_ok=False)
    package = Path(__file__).resolve().parents[1]
    shared = package.parent / "DiscordBenchmarkSupport" / "scripts" / "run_benchmarks.py"
    rows = []
    for case in cases:
        if processes.cancelled:
            return 130
        destination = (arguments.output_dir / case).resolve()
        command = [str(executable), "--case", case, "--output", "{output}", "--profile", "{profile}",
                   "--seed", "{seed}", "--duration-seconds", "{duration_seconds}", "--warmup-seconds", "{warmup_seconds}",
                   "--batches", str(arguments.batches), "--batch-size", str(arguments.batch_size),
                   "--warmup-batches", str(arguments.warmup_batches)]
        supervised = [sys.executable, str(shared), "run", "--profile", "smoke", "--scenario", "pure-" + case,
                      "--fixture", str(package / "Sources" / "DiscordFoundationBenchmarks" / "Workload.swift"),
                      "--receipt", str(arguments.receipt.resolve()), "--command", json.dumps(command),
                      "--output-dir", str(destination), "--concurrency", "1", "--scheduler-policy", "serial-synchronous-batches",
                      "--warmup-seconds", "1", "--warmup-policy", "participant-declared"]
        status = processes.run(supervised).returncode
        if processes.cancelled:
            return 130
        if status:
            return status
        native = json.loads((destination / "00-single" / "native-report.json").read_text())
        common = native["common"]
        metric = common["metrics"][0]
        distribution = metric["distribution"]
        rows.append({"case": case, "inputSizes": common["identity"]["inputSizes"],
                     "completedBatches": native["completedBatches"], "completedCalls": native["completedCalls"],
                     "rejectedCalls": native["rejectedCalls"], "normalizedBatchMeanNanosecondsPerCall": native["normalizedMeanNanoseconds"],
                     "batchSummary": {key: metric[key] for key in ("p50", "p95", "p99", "maximum")},
                     "histogramEvidence": {key: value for key, value in distribution.items() if key != "bucketCounts"},
                     "callsPerSecond": common["throughputPerSecond"],
                     "nativeReport": str(Path(case) / "00-single" / "native-report.json")})
        summary = {"format": "DiscordFoundationBenchmarks.scaling", "schemaVersion": 1,
                   "qualification": "informational local CPU smoke; batch percentiles are not call percentiles", "cases": rows}
        (arguments.output_dir / "scaling.json").write_text(json.dumps(summary, indent=2, sort_keys=True, allow_nan=False) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
