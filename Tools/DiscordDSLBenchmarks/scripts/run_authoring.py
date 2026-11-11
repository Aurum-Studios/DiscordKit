#!/usr/bin/env python3
# File: Tools/DiscordDSLBenchmarks/scripts/run_authoring.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Compare direct/DSL authoring in counterbalanced fresh processes using shared supervision.

The shared driver owns release receipts, bounded artifacts/RSS/timeouts, signal
handling and process-group teardown. This wrapper only declares equivalent mode
arguments. Standard performs five pairs with alternating first mode; smoke runs
one randomly seeded pair and checks integrity without numerical qualification.
"""

import argparse
import json
from pathlib import Path
import subprocess
import sys


def supervised_command(arguments):
    """Declare one explicit direct/DSL pair with identical finite working-set dimensions.

    The same successful release receipt binds both arms. Every observation uses a
    new process; no matrix row can inherit another mode's allocator or peak RSS.
    """
    shared = Path(__file__).resolve().parents[2] / "DiscordBenchmarkSupport/scripts/run_benchmarks.py"
    fixture = Path(__file__).resolve().parents[1] / "fixture.txt"
    base = [str(arguments.executable.resolve()), "authoring", "--handlers", str(arguments.handlers),
            "--modules", str(arguments.modules), "--invocations", str(arguments.invocations),
            "--definitions", str(arguments.definitions), "--warmup-invocations", str(arguments.warmup_invocations),
            "--concurrency", "{concurrency}", "--profile", "{profile}", "--seed", "{seed}",
            "--duration-seconds", "{duration_seconds}", "--warmup-seconds", "{warmup_seconds}", "--output", "{output}"]
    return [sys.executable, str(shared), "run", "--profile", arguments.profile, "--seed", str(arguments.seed),
            "--scenario", "authoring-direct-dsl", "--fixture", str(fixture),
            "--baseline-command", json.dumps(base + ["--mode", "direct"]),
            "--candidate-command", json.dumps(base + ["--mode", "dsl"]),
            "--baseline-receipt", str(arguments.receipt.resolve()), "--candidate-receipt", str(arguments.receipt.resolve()),
            "--output-dir", str(arguments.output_dir.resolve()), "--concurrency", str(arguments.concurrency),
            "--scheduler-policy", "counterbalanced-fresh-process-authoring",
            "--warmup-seconds", "1" if arguments.warmup_invocations else "0", "--warmup-policy", "participant-declared"]


def main(argv=None):
    """Validate finite suite dimensions and return the shared supervisor's unchanged exit status."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--profile", choices=["smoke", "standard", "stress", "soak"], default="smoke")
    parser.add_argument("--handlers", type=int, choices=[10, 100, 1000], default=10)
    parser.add_argument("--modules", type=int, default=1)
    parser.add_argument("--invocations", type=int, default=128)
    parser.add_argument("--definitions", type=int, default=3)
    parser.add_argument("--warmup-invocations", type=int, default=16)
    parser.add_argument("--concurrency", type=int, default=2)
    parser.add_argument("--seed", type=int, default=1)
    arguments = parser.parse_args(argv)
    if not 1 <= arguments.modules <= min(arguments.handlers, 100) or not 1 <= arguments.invocations <= 1_000_000:
        parser.error("invalid finite modules or invocation population")
    if not 1 <= arguments.definitions <= 100 or not 0 <= arguments.warmup_invocations <= 1_000_000:
        parser.error("invalid finite definition or warmup population")
    if not 1 <= arguments.concurrency <= min(64, arguments.invocations) or not 0 <= arguments.seed < 2**63:
        parser.error("invalid cohort or seed")
    return subprocess.run(supervised_command(arguments), check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
