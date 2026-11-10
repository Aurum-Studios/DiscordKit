#!/usr/bin/env python3
# File: Tools/DiscordTimingBenchmarks/scripts/run_modes.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Invoke the shared fresh-process supervisor sequentially for selected instrumentation modes.

This convenience entry point owns no benchmark statistics, timing, build receipts
or process-group logic. Those remain in DiscordBenchmarkSupport. Build the exact
release receipt after finishing source edits, then pass its executable here.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys


def main(argv: list[str] | None = None) -> int:
    """Run finite selected modes and preserve the first shared-supervisor failure unchanged.

    Each subprocess uses argument arrays, inherits no shell interpretation, and
    delegates process timeouts, output bounds, RSS supervision and teardown to
    the shared runner. The output directory must be new, preventing overwrite.
    Apple-only modes are selected automatically only on Darwin.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--profile", choices=["smoke"], default="smoke")
    parser.add_argument("--mode", action="append", default=[])
    parser.add_argument("--iterations", type=int, default=1_000)
    parser.add_argument("--warmup-iterations", type=int, default=128)
    parser.add_argument("--concurrency", type=int, default=2)
    arguments = parser.parse_args(argv)
    executable = arguments.executable.resolve()
    listed = subprocess.run([str(executable), "--list-modes"], check=True, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    modes = listed.stdout.splitlines()
    if arguments.mode:
        if not set(arguments.mode).issubset(modes):
            parser.error("unknown mode")
        modes = list(dict.fromkeys(arguments.mode))
    elif sys.platform != "darwin":
        modes = [mode for mode in modes if mode not in {"unifiedLog", "signposts"}]
    if not 1 <= arguments.iterations <= 1_000_000 or not 0 <= arguments.warmup_iterations <= 1_000_000:
        parser.error("invalid finite iteration budget")
    if not 2 <= arguments.concurrency <= 64:
        parser.error("cohort must be in 2...64 so callbackContention is meaningful")
    arguments.output_dir.mkdir(parents=True, exist_ok=False)
    shared = Path(__file__).resolve().parents[2] / "DiscordBenchmarkSupport" / "scripts" / "run_benchmarks.py"
    fixture = Path(__file__).resolve().parents[1] / "fixture.txt"
    for mode in modes:
        command = [str(executable), "--mode", mode, "--output", "{output}",
                   "--profile", "{profile}", "--seed", "{seed}", "--concurrency", "{concurrency}",
                   "--duration-seconds", "{duration_seconds}", "--warmup-seconds", "{warmup_seconds}",
                   "--iterations", str(arguments.iterations), "--warmup-iterations", str(arguments.warmup_iterations)]
        supervised = [sys.executable, str(shared), "run", "--profile", arguments.profile,
                      "--scenario", "instrumentation-" + mode, "--fixture", str(fixture),
                      "--receipt", str(arguments.receipt.resolve()), "--command", json.dumps(command),
                      "--output-dir", str((arguments.output_dir / mode).resolve()),
                      "--concurrency", str(arguments.concurrency), "--scheduler-policy", "finite-structured-worker-cohort",
                      "--warmup-seconds", "1", "--warmup-policy", "participant-declared"]
        status = subprocess.run(supervised, check=False).returncode
        if status:
            return status
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
