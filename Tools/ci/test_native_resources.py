# File: Tools/ci/test_native_resources.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Compiler admission covers affinity, memory pressure and unavailable observations."""

from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import native_resources


class NativeResourcesTests(unittest.TestCase):
    def admission(self, **changes):
        values = {"cpu_count": 64, "affinity_count": 64,
                  "available_memory_bytes": 128 * native_resources.GIB}
        values.update(changes)
        return native_resources.compiler_admission(64, **values)

    def test_nominal_sixty_four_core_runner_stays_at_initial_policy_two(self):
        report = self.admission()
        self.assertEqual(report["jobs"], 2)
        self.assertEqual(report["requestedJobs"], 64)
        self.assertEqual(report["observed"]["cpuCount"], 64)
        self.assertIn("policy-cap", report["reasons"])

    def test_affinity_restriction_dominates_nominal_cpu_count(self):
        report = self.admission(affinity_count=1)
        self.assertEqual(report["jobs"], 1)
        self.assertIn("cpu-cap", report["reasons"])
        self.assertEqual(report["observed"]["affinityCount"], 1)

    def test_memory_reserve_and_per_process_budget_cap_compilers(self):
        for gib, expected in ((0, 1), (2, 1), (6, 1), (9, 1), (10, 2)):
            with self.subTest(gib=gib):
                report = self.admission(available_memory_bytes=gib * native_resources.GIB)
                self.assertEqual(report["jobs"], expected)
        self.assertIn("insufficient-observed-memory-headroom-fallback-one",
                      self.admission(available_memory_bytes=0)["flags"])

    def test_unknown_memory_and_cpu_record_separate_fallback_flags(self):
        report = self.admission(cpu_count=None, affinity_count=None, available_memory_bytes=None)
        self.assertEqual(report["jobs"], 1)
        self.assertIn("cpu-observation-unavailable-fallback-one", report["flags"])
        self.assertIn("memory-observation-unavailable-fallback-one", report["flags"])
        self.assertIsNone(report["observed"]["availableMemoryBytes"])

    def test_configurable_memory_inputs_and_lower_policy_cap(self):
        report = self.admission(policy_cap=1, memory_reserve_bytes=0,
                                bytes_per_compiler=native_resources.GIB)
        self.assertEqual(report["jobs"], 1)
        self.assertEqual(report["memoryPolicy"]["reserveBytes"], 0)
        self.assertEqual(report["memoryPolicy"]["bytesPerCompiler"], native_resources.GIB)

    def test_invalid_or_expanded_initial_policy_fails(self):
        for changes in ({"policy_cap": 3}, {"policy_cap": True}, {"cpu_count": 0},
                        {"affinity_count": -1}, {"available_memory_bytes": -1},
                        {"bytes_per_compiler": 0}, {"memory_reserve_bytes": -1}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.admission(**changes)

    def test_linux_cgroup_headroom_bounds_host_available_memory(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            meminfo = directory / "meminfo"
            meminfo.write_text("MemAvailable: 100000000 kB\n")
            (directory / "memory.max").write_text(str(8 * native_resources.GIB))
            (directory / "memory.current").write_text(str(2 * native_resources.GIB))
            report = native_resources.linux_memory_observation(meminfo, directory)
            self.assertEqual(report["availableMemoryBytes"], 6 * native_resources.GIB)
            self.assertEqual(report["memorySources"], ["linux-memavailable", "cgroup-headroom"])
            (directory / "memory.max").write_text("max")
            self.assertEqual(native_resources.linux_memory_observation(meminfo, directory)["availableMemoryBytes"],
                             100000000 * 1024)

    def test_linux_missing_memavailable_can_use_cgroup_or_remain_unknown(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            report = native_resources.linux_memory_observation(directory / "missing", directory)
            self.assertIsNone(report["availableMemoryBytes"])
            (directory / "memory.max").write_text("1000")
            (directory / "memory.current").write_text("2000")
            self.assertEqual(native_resources.linux_memory_observation(directory / "missing", directory)
                             ["availableMemoryBytes"], 0)

    def test_darwin_query_is_bounded_and_excludes_credential_environment(self):
        output = "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 100.\nPages inactive: 99999.\nPages speculative: 25.\n"
        with patch("native_resources.subprocess.run", return_value=subprocess.CompletedProcess([], 0, output)) as run:
            report = native_resources.darwin_memory_observation()
        self.assertEqual(report["availableMemoryBytes"], 125 * 16384)
        self.assertEqual(run.call_args.kwargs["timeout"], 2)
        self.assertEqual(run.call_args.kwargs["env"], {"LANG": "C", "LC_ALL": "C"})

    def test_darwin_missing_or_timed_out_observation_remains_unknown(self):
        for error in (OSError("absent"), subprocess.TimeoutExpired("vm_stat", 2)):
            with self.subTest(error=error), patch("native_resources.subprocess.run", side_effect=error):
                self.assertIsNone(native_resources.darwin_memory_observation()["availableMemoryBytes"])


if __name__ == "__main__":
    unittest.main()
