#!/usr/bin/env python3
# File: Tools/DiscordTimingBenchmarks/scripts/test_run_modes.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Deterministic CLI delegation tests; no build, benchmark or performance capture is started."""

from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import run_modes


class ObserverModeCLITests(unittest.TestCase):
    """Verify supported finite matrices and exact shared-supervisor argument delegation."""

    def invoke(self, extra: list[str], *, failure: int = 0) -> list[list[str]]:
        """Run the parser against mocked subprocesses and return only supervised command arrays."""
        commands: list[list[str]] = []

        def subprocess_run(command: list[str], **_kwargs: object) -> SimpleNamespace:
            """Supply mode discovery or a supervisor exit without running child processes."""
            if command[-1] == "--list-modes":
                return SimpleNamespace(stdout="disabled\naggregate\ncallbackContention\n", returncode=0)
            commands.append(command)
            return SimpleNamespace(returncode=failure)

        with tempfile.TemporaryDirectory() as temporary:
            arguments = ["--executable", str(Path(temporary) / "benchmark"), "--receipt", str(Path(temporary) / "receipt.json"),
                         "--output-dir", str(Path(temporary) / "new-output"), *extra]
            with patch.object(run_modes.subprocess, "run", side_effect=subprocess_run):
                self.assertEqual(run_modes.main(arguments), failure)
        return commands

    def test_single_worker_is_supported_except_contention(self) -> None:
        """Single-worker aggregate controls must not inherit the contention-only lower bound."""
        commands = self.invoke(["--concurrency", "1", "--mode", "aggregate"])
        self.assertEqual(len(commands), 1)
        self.assertEqual(commands[0][commands[0].index("--concurrency") + 1], "1")
        self.assertEqual(json.loads(commands[0][commands[0].index("--command") + 1])[-4:],
                         ["--iterations", "1000", "--warmup-iterations", "128"])
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            self.invoke(["--concurrency", "1", "--mode", "callbackContention"])
        self.assertEqual(raised.exception.code, 2)

    def test_explicit_cohort_and_collector_matrix(self) -> None:
        """The supported matrix runs every selected topology sequentially with distinct destinations."""
        commands = self.invoke(["--cohort", "1", "--cohort", "4", "--cohort", "16",
                                "--collector-scope", "shared", "--collector-scope", "perWorker", "--mode", "aggregate"])
        self.assertEqual(len(commands), 6)
        destinations = [command[command.index("--output-dir") + 1] for command in commands]
        self.assertEqual(len(set(destinations)), 6)
        self.assertTrue(destinations[0].endswith("cohort-1/shared/aggregate"))
        self.assertTrue(destinations[-1].endswith("cohort-16/perWorker/aggregate"))
        for command in commands:
            native = json.loads(command[command.index("--command") + 1])
            self.assertIn(native[native.index("--collector-scope") + 1], ["shared", "perWorker"])

    def test_default_mode_set_omits_unsupported_single_worker_contention(self) -> None:
        """Default mode discovery runs only supported combinations for cohort one."""
        commands = self.invoke(["--concurrency", "1"])
        self.assertEqual(len(commands), 2)
        self.assertTrue(all("callbackContention" not in json.loads(command[command.index("--command") + 1]) for command in commands))

    def test_default_paths_and_first_supervisor_failure_are_preserved(self) -> None:
        """Legacy defaults keep cohort two and mode directories; failures stop subsequent runs."""
        commands = self.invoke(["--mode", "aggregate"])
        self.assertEqual(commands[0][commands[0].index("--concurrency") + 1], "2")
        self.assertTrue(commands[0][commands[0].index("--output-dir") + 1].endswith("new-output/aggregate"))
        self.assertEqual(len(self.invoke([], failure=17)), 1)


if __name__ == "__main__":
    unittest.main()
