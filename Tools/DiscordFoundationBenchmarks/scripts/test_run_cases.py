#!/usr/bin/env python3
# File: Tools/DiscordFoundationBenchmarks/scripts/test_run_cases.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Exercise wrapper cancellation against real, finite subprocesses without Swift builds."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).with_name("run_cases.py")
SPEC = importlib.util.spec_from_file_location("foundation_run_cases", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
RUN_CASES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUN_CASES)


def process_exists(pid: int) -> bool:
    """A joined child has no remaining process identity, including a zombie."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


class CaseProcessesTests(unittest.TestCase):
    def test_sigterm_forwards_and_awaits_supervisor_cleanup(self) -> None:
        """Signal only the wrapper PID; its active child must finish cleanup before return."""
        child_source = r'''
import os
from pathlib import Path
import signal
import sys
import time

directory = Path(sys.argv[1])
def cleanup(signum, frame):
    (directory / "received").write_text(str(signum))
    time.sleep(0.15)
    (directory / "cleaned").write_text("complete")
    raise SystemExit(0)

signal.signal(signal.SIGTERM, cleanup)
signal.signal(signal.SIGINT, cleanup)
(directory / "ready").write_text(str(os.getpid()))
deadline = time.monotonic() + 10
while time.monotonic() < deadline:
    time.sleep(0.02)
raise SystemExit(3)
'''
        wrapper_source = r'''
import importlib.util
from pathlib import Path
import signal
import subprocess
import sys

spec = importlib.util.spec_from_file_location("foundation_run_cases", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
processes = module.CaseProcesses()
signal.signal(signal.SIGINT, processes.request)
signal.signal(signal.SIGTERM, processes.request)
result = processes.run([sys.executable, "-c", sys.argv[3], sys.argv[2]],
                       timeout=7, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
if processes.cancelled:
    raise SystemExit(130)
raise SystemExit(result.returncode)
'''
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            wrapper = subprocess.Popen(
                [sys.executable, "-c", wrapper_source, str(MODULE_PATH), str(directory), child_source],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            child_pid = None
            try:
                deadline = time.monotonic() + 5
                while not (directory / "ready").exists() and time.monotonic() < deadline:
                    if wrapper.poll() is not None:
                        output, error = wrapper.communicate(timeout=1)
                        self.fail(f"Wrapper exited before child readiness: {output} {error}")
                    time.sleep(0.01)
                self.assertTrue((directory / "ready").exists(), "Child did not become ready")
                child_pid = int((directory / "ready").read_text())
                # send_signal targets this PID only, so forwarding must be done by CaseProcesses.
                wrapper.send_signal(signal.SIGTERM)
                output, error = wrapper.communicate(timeout=5)
                self.assertEqual(wrapper.returncode, 130, f"{output} {error}")
                self.assertEqual((directory / "received").read_text(), str(signal.SIGTERM))
                self.assertEqual((directory / "cleaned").read_text(), "complete")
                self.assertFalse(process_exists(child_pid), "Wrapper returned without reaping its child")
            finally:
                if wrapper.poll() is None:
                    wrapper.kill()
                    wrapper.communicate(timeout=2)
                if child_pid is None and (directory / "ready").exists():
                    child_pid = int((directory / "ready").read_text())
                if child_pid is not None and process_exists(child_pid):
                    try:
                        os.kill(child_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_cancelled_wrapper_never_starts_another_case(self) -> None:
        processes = RUN_CASES.CaseProcesses()
        processes.request(signal.SIGTERM, None)
        command = [sys.executable, "-c", "raise SystemExit(99)"]
        with mock.patch.object(RUN_CASES.subprocess, "Popen") as launch:
            result = processes.run(command, stdout=subprocess.PIPE, text=True)
        self.assertTrue(processes.cancelled)
        self.assertEqual(result.returncode, 130)
        launch.assert_not_called()

    def test_timeout_reaps_child_before_raising(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            ready = Path(temporary) / "ready"
            command = [sys.executable, "-c", "import os, pathlib, sys, time; "
                       "pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(10)", str(ready)]
            processes = RUN_CASES.CaseProcesses()
            child_pid = None
            try:
                with self.assertRaises(subprocess.TimeoutExpired):
                    processes.run(command, timeout=0.5, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                self.assertTrue(ready.exists(), "Child did not run before its timeout")
                child_pid = int(ready.read_text())
                self.assertFalse(process_exists(child_pid), "Timeout returned without reaping its child")
            finally:
                if child_pid is None and ready.exists():
                    child_pid = int(ready.read_text())
                if child_pid is not None and process_exists(child_pid):
                    try:
                        os.kill(child_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    unittest.main()
