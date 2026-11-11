# File: Tools/DiscordBenchmarkSupport/scripts/test_host_observation.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Deterministic bounded environment receipts; no numerical qualification claims."""

from pathlib import Path
import tempfile
import unittest
from unittest import mock

import run_benchmarks as runner


class HostObservationTests(unittest.TestCase):
    """Retain actual observations and explicit unknowns without process arguments."""

    def test_peer_bounds_and_thermal_absence(self):
        """Sort visible CPU estimates, bound rows and omit command path/arguments."""
        rows = "\n".join(f"{i} 1 {i}.0 00:01 /private/tool{i}" for i in range(1, 101))
        with mock.patch.object(runner, "optional_capture", side_effect=[rows, None]), \
                mock.patch.object(runner.platform, "system", return_value="Darwin"):
            value = runner.host_observation()
        self.assertEqual(value["visible_process_count"], 100)
        self.assertEqual(len(value["peer_processes"]), 64)
        self.assertTrue(value["peer_processes_truncated"])
        self.assertEqual(value["peer_processes"][0]["pid"], 100)
        self.assertEqual(value["peer_processes"][0]["executable_basename"], "tool100")
        self.assertIsNone(value["thermal_power_observation"])
        self.assertIsNotNone(value["thermal_power_unavailable_reason"])

    def test_unavailable_is_not_zero(self):
        """Missing process APIs never become a claim of zero peer activity."""
        with mock.patch.object(runner, "optional_capture", return_value=None), \
                mock.patch.object(runner.platform, "system", return_value="Darwin"):
            value = runner.host_observation()
        self.assertIsNone(value["visible_process_count"])
        self.assertIsNotNone(value["peer_processes_unavailable_reason"])

    def test_nested_throttling_and_missing_controller(self):
        """Read leaf and ancestor counters independently, preserving real zeroes."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            leaf = root / "child"
            leaf.mkdir()
            membership = root / "membership"
            membership.write_text("0::/child\n")
            (root / "cpu.stat").write_text("nr_throttled 3\nthrottled_usec 17\n")
            (leaf / "cpu.stat").write_text("nr_throttled 0\nthrottled_usec 0\n")
            result = runner.cgroup_cpu_stat(root, membership)
            self.assertTrue(result["available"])
            self.assertEqual([x["counters"]["nr_throttled"] for x in result["ancestors"]], [0, 3])
            (root / "cpu.stat").unlink()
            (leaf / "cpu.stat").unlink()
            self.assertFalse(runner.cgroup_cpu_stat(root, membership)["available"])
            membership.write_text("0::/../../outside\n")
            self.assertFalse(runner.cgroup_cpu_stat(root, membership)["available"])


if __name__ == "__main__":
    unittest.main()
