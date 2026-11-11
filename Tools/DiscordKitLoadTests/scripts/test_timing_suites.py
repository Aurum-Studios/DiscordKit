#!/usr/bin/env python3
# File: Tools/DiscordKitLoadTests/scripts/test_timing_suites.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Validate bounded sweep selection and fail-closed retained evidence."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import run_timing_suites as suites


class TimingSuiteTests(unittest.TestCase):
    def test_sigterm_forwards_and_awaits_supervisor_cleanup(self):
        """Signal the wrapper PID alone, then explicitly release its child's cleanup gate."""
        child_source = r'''
import os
from pathlib import Path
import signal
import sys
import time

directory = Path(sys.argv[1])
def cleanup(signum, _frame):
    (directory / "received").write_text(str(signum))
    deadline = time.monotonic() + 7
    while not (directory / "allow-cleanup").exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    if not (directory / "allow-cleanup").exists():
        raise SystemExit(4)
    (directory / "cleaned").write_text("complete")
    raise SystemExit(0)

signal.signal(signal.SIGTERM, cleanup)
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

spec = importlib.util.spec_from_file_location("timing_suites", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
directory = Path(sys.argv[2])
processes = module.SuiteProcesses()
signal.signal(signal.SIGTERM, processes.request)
result = processes.run([sys.executable, "-c", sys.argv[3], str(directory)],
                       timeout=9, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
assert result.returncode == 0, (result.stdout, result.stderr)
assert processes.active is None
assert (directory / "cleaned").read_text() == "complete"
# Cancellation must also prevent a later real subprocess from being launched.
next_result = processes.run([sys.executable, "-c",
    "import pathlib, sys; pathlib.Path(sys.argv[1]).touch()", str(directory / "unexpected-next-case")])
assert next_result.returncode == 130
raise SystemExit(130 if processes.cancelled else 0)
'''
        module = Path(suites.__file__).resolve()
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            wrapper = subprocess.Popen(
                [sys.executable, "-c", wrapper_source, str(module), str(directory), child_source],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True,
            )
            child_pid = None
            try:
                self.wait_for_marker(directory / "ready", wrapper)
                child_pid = int((directory / "ready").read_text())
                # This targets one PID, so the wrapper must forward SIGTERM to its active child.
                wrapper.send_signal(signal.SIGTERM)
                self.wait_for_marker(directory / "received", wrapper)
                self.assertEqual((directory / "received").read_text(), str(signal.SIGTERM))
                self.assertIsNone(wrapper.poll(), "Wrapper returned while child cleanup was gated")
                self.assertFalse((directory / "cleaned").exists())
                (directory / "allow-cleanup").touch()
                output, error = wrapper.communicate(timeout=5)
                self.assertEqual(wrapper.returncode, 130, f"{output} {error}")
                self.assertEqual((directory / "cleaned").read_text(), "complete")
                self.assertFalse((directory / "unexpected-next-case").exists())
                self.assertFalse(self.process_exists(child_pid), "Wrapper returned without reaping its child")
            finally:
                # This session belongs exclusively to this test; failure cannot leak a gated child.
                try:
                    os.killpg(wrapper.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                wrapper.communicate(timeout=2)

    def test_native_dimensions_are_separate(self):
        rows = suites.matrix(["transport.smallBody", "rest.noCache", "arrival.rest"])
        self.assertEqual(len(rows), 16)
        self.assertEqual(len({row["name"] for row in rows}), len(rows))
        self.assertEqual(sum(row["tls"] for row in rows), 1)
        self.assertTrue(all(row["concurrency"] == 1 for row in rows if row["connection"] == "cold"))
        self.assertTrue(all(row["adapter"] == "nio" for row in rows if row["tls"]))

    def test_sweep_remains_bounded_and_complete(self):
        rows = suites.matrix(["arrival.rest"])
        self.assertEqual({(row["concurrency"], row["rate"]) for row in rows},
                         {(c, r) for c in (1, 4, 16) for r in (200, 2000, 20000)})
        self.assertTrue(all(row["pending"] + row["concurrency"] <= 1024 for row in rows))
        self.assertEqual(len(suites.matrix(["transport.smallBody"], native=False)), 1)

    def test_versioned_arrival_controls_match_service_load_dimensions(self):
        """Driver/no-op and mutation controls share offered load while legacy names remain stable."""
        cases = ["arrival.rest", "arrival.noopV1", "arrival.orderedMutationDefaultSharedV1",
                 "arrival.orderedMutationDefaultIndependentV1"]
        rows = suites.matrix(cases)
        self.assertEqual(len(rows), 36)
        self.assertEqual(len({row["name"] for row in rows}), 36)
        dimensions = lambda case: {(row["concurrency"], row["rate"], row["pending"])
                                   for row in rows if row["case"] == case}
        self.assertTrue(all(dimensions(case) == dimensions("arrival.rest") for case in cases))
        self.assertIn("arrival-c4-r2000", {row["name"] for row in rows})
        self.assertIn("arrival.noopV1-c4-r2000", {row["name"] for row in rows})

    def test_partial_cleanup_is_never_indexed_as_success(self):
        native = dict(common=dict(status="completed", cleanup=dict(completed=True, remainingOwners=1)))
        with self.assertRaises(ValueError):
            suites.compact(native, dict(name="case"))
        native["common"]["status"] = "interrupted"
        native["common"]["cleanup"]["remainingOwners"] = 0
        with self.assertRaises(ValueError):
            suites.compact(native, dict(name="case"))

    def test_cancellation_stops_next_process(self):
        processes = suites.SuiteProcesses()
        processes.request(15, None)
        with mock.patch.object(suites.subprocess, "Popen") as spawned:
            self.assertEqual(processes.run(["unused"]).returncode, 130)
        spawned.assert_not_called()

    def wait_for_marker(self, path, wrapper):
        """Wait for a bounded readiness event while surfacing premature subprocess failures."""
        deadline = time.monotonic() + 5
        while not path.exists() and time.monotonic() < deadline:
            if wrapper.poll() is not None:
                output, error = wrapper.communicate(timeout=1)
                self.fail(f"Wrapper exited before {path.name}: {output} {error}")
            time.sleep(0.01)
        self.assertTrue(path.exists(), f"Timed out waiting for {path.name}")

    @staticmethod
    def process_exists(pid):
        """A reaped owned child leaves no PID, including no unreaped zombie."""
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        return True


if __name__ == "__main__":
    unittest.main()
