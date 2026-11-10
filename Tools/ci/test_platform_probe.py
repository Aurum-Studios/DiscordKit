# File: Tools/ci/test_platform_probe.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Exercise admission failure paths without claiming hosted platform qualification."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import platform_probe


class PlatformProbeTests(unittest.TestCase):
    """A probe must really execute and retain diagnostics on every failed boundary."""

    def run_probe(self, run, identity=None):
        """Run with injected compiler commands and return the durable probe result."""
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with patch.object(platform_probe, "native_preflight"), \
                    patch.object(platform_probe.subprocess, "run", side_effect=run), \
                    patch.dict(os.environ, identity or {"RUNNER_OS": "Linux", "RUNNER_ARCH": "X64"}):
                try:
                    platform_probe.probe(directory, directory / "evidence", "linux-x64")
                except (ValueError, subprocess.SubprocessError):
                    pass
            return json.loads((directory / "evidence/probe.json").read_text())

    def test_compile_success_requires_the_runtime_roundtrip(self):
        """A compiler exit alone cannot qualify the host's installed Swift runtime."""
        calls = []

        def run(arguments, **options):
            """Record bounded children and report the expected executable output."""
            calls.append(arguments)
            self.assertEqual(options["timeout"], 120)
            self.assertTrue(options["check"])
            return subprocess.CompletedProcess(arguments, 0,
                "DiscordKit native probe passed\n" if len(calls) == 2 else "", "")

        record = self.run_probe(run)
        self.assertEqual(record["status"], "passed")
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0][0], "swiftc")

    def test_unexpected_runtime_output_denies_admission(self):
        """A stale or incorrect executable must not admit expensive build jobs."""
        record = self.run_probe(lambda args, **kw: subprocess.CompletedProcess(args, 0, "", ""))
        self.assertEqual(record["status"], "failed")
        self.assertEqual(record["commands"][-1]["status"], "failed")

    def test_compile_failure_is_retained_and_never_executes(self):
        """Compiler/linker failures remain visible and cannot fall through to execution."""
        record = self.run_probe(lambda args, **kw: (_ for _ in ()).throw(
            subprocess.CalledProcessError(1, args, output="compile failed", stderr="linker failure")))
        self.assertEqual(record["status"], "failed")
        self.assertEqual(len(record["commands"]), 1)

    def test_compile_and_runtime_timeouts_deny_admission(self):
        """A deadline at either child leaves a terminal failure and stops later work."""
        for timed_out_command in ("compile", "execute"):
            with self.subTest(command=timed_out_command):
                calls = []

                def run(arguments, **options):
                    """Time out the selected boundary after recording the actual deadline."""
                    calls.append(arguments)
                    command = "compile" if arguments[0] == "swiftc" else "execute"
                    if command == timed_out_command:
                        raise subprocess.TimeoutExpired(arguments, options["timeout"])
                    return subprocess.CompletedProcess(arguments, 0, "", "")

                record = self.run_probe(run)
                self.assertEqual(record["status"], "failed")
                self.assertIn("timed out after 120 seconds", record["error"])
                self.assertEqual(record["commands"][-1]["name"], timed_out_command)
                self.assertEqual(record["commands"][-1]["status"], "failed")
                expected_count = 1 if timed_out_command == "compile" else 2
                self.assertEqual(len(calls), expected_count)
                self.assertEqual(len(record["commands"]), expected_count)
                if timed_out_command == "execute":
                    self.assertEqual(record["commands"][0]["status"], "passed")

    def test_assigned_runner_mismatch_stops_before_compilation(self):
        """Group routing cannot override the observed and assigned platform identities."""
        record = self.run_probe(lambda *args, **kw: self.fail("must not compile"),
                                {"RUNNER_OS": "Windows", "RUNNER_ARCH": "X64"})
        self.assertEqual(record["status"], "failed")
        self.assertEqual(record["commands"], [])


if __name__ == "__main__":
    unittest.main()
