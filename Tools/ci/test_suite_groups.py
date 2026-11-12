# File: Tools/ci/test_suite_groups.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Offline grouping coverage, stable assignment and retained timing provenance."""

import copy
import json
from pathlib import Path
import random
import tempfile
import unittest

import suite_groups


class SuiteGroupsTests(unittest.TestCase):
    def setUp(self):
        self.data = suite_groups.load_duration_data()
        self.targets = sorted(self.data["platforms"]["macos-arm64"]["suites"])

    def test_retained_mixed_step_weights_match_hashed_baseline_api_pages(self):
        self.assertTrue(suite_groups.verify_retained_sources(self.data))
        self.assertEqual(len(self.data["platforms"]["linux-x64"]["suites"]), 33)
        self.assertEqual(len(self.data["platforms"]["macos-arm64"]["suites"]), 34)

    def test_changed_derived_weight_or_owner_fails_provenance(self):
        for field, value in (("seconds", 900), ("jobID", 0), ("startedAt", "2000-01-01T00:00:00Z")):
            with self.subTest(field=field):
                data = copy.deepcopy(self.data)
                entry = next(iter(data["platforms"]["linux-x64"]["suites"].values()))
                entry[field] = value
                with self.assertRaises((ValueError, KeyError)):
                    suite_groups.verify_retained_sources(data)

    def test_four_stable_groups_cover_each_active_module_once(self):
        for platform, count in (("linux-x64", 33), ("macos-arm64", 34), ("windows-x64", 32)):
            with self.subTest(platform=platform):
                groups = suite_groups.root_groups(self.targets, platform)
                self.assertEqual([row["name"] for row in groups], list(suite_groups.GROUP_NAMES))
                self.assertEqual([row["suite"] for row in groups], list(suite_groups.GROUP_NAMES))
                selected = [suite for row in groups for suite in row["suites"]]
                self.assertEqual(len(selected), count)
                self.assertEqual(len(set(selected)), count)
                self.assertEqual(sorted(selected), suite_groups.active_targets(self.targets, platform))
                self.assertTrue(all(row["suites"] for row in groups))

    def test_inventory_order_does_not_change_assignment_or_metadata(self):
        expected = suite_groups.root_groups(self.targets, "linux-x64")
        shuffled = self.targets.copy()
        for seed in range(8):
            random.Random(seed).shuffle(shuffled)
            self.assertEqual(suite_groups.root_groups(shuffled, "linux-x64"), expected)

    def test_greedy_balance_preserves_weights_and_bounds_initial_imbalance(self):
        groups = suite_groups.root_groups(self.targets, "linux-x64")
        totals = [row["planningWeightSeconds"] for row in groups]
        observations = self.data["platforms"]["linux-x64"]["suites"]
        self.assertEqual(sum(totals), sum(row["seconds"] for row in observations.values()))
        self.assertLessEqual(max(totals) - min(totals), max(row["seconds"] for row in observations.values()))
        for row in groups:
            self.assertEqual(row["planningWeightSeconds"], sum(item["seconds"] for item in row["durationSources"]))

    def test_new_module_uses_maximum_observed_platform_fallback_with_explicit_status(self):
        groups = suite_groups.root_groups([*self.targets, "NewModuleTests"], "linux-x64")
        fallback = next(item for row in groups for item in row["durationSources"]
                        if item["suite"] == "NewModuleTests")
        maximum = max(row["seconds"] for row in self.data["platforms"]["linux-x64"]["suites"].values())
        self.assertEqual(fallback["seconds"], maximum)
        self.assertEqual(fallback["kind"], "unmeasured-conservative-fallback")
        self.assertNotIn("jobID", fallback)

    def test_rejects_invalid_inventory_and_platform(self):
        for targets, platform in (([], "linux-x64"), (["A", "A"], "linux-x64"),
                                  (["A|Other"], "linux-x64"), (["A"], "emulated-linux")):
            with self.subTest(targets=targets, platform=platform), self.assertRaises(ValueError):
                suite_groups.root_groups(targets, platform)

    def test_rejects_missing_or_nonconservative_weight_contract(self):
        for mutation in ("schema", "fallback", "platform", "weight"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                data = copy.deepcopy(self.data)
                if mutation == "schema":
                    data["schemaVersion"] = 99
                elif mutation == "fallback":
                    data["platforms"]["linux-x64"]["fallbackWeightSeconds"] = 1
                elif mutation == "platform":
                    del data["platforms"]["windows-x64"]
                else:
                    next(iter(data["platforms"]["linux-x64"]["suites"].values()))["seconds"] = 0
                path = Path(directory) / "durations.json"
                path.write_text(json.dumps(data))
                with self.assertRaises(ValueError):
                    suite_groups.load_duration_data(path)

    def test_comparison_retains_baseline_unknowns_and_never_estimates_postchange_savings(self):
        result = suite_groups.compare_baseline({"include": [{}] * 24}, {"include": [{}] * 28})
        self.assertEqual(result["plannedNative"], {"buildJobs": 24, "testGroupJobs": 28,
                                                  "totalBuildAndTestJobs": 52})
        self.assertIsNone(result["postChangeMeasurements"])
        offline = next(row for row in result["baseline"] if row["runID"] == 43146954720)
        self.assertEqual(offline["wholeWorkflowJobCount"], 152)
        self.assertEqual(offline["nativeTestJobCount"], 101)
        self.assertEqual(offline["nativeBuildJobCount"], 24)
        self.assertEqual(offline["wholeWorkflowSetupSeconds"], 8444)
        self.assertEqual(offline["wholeWorkflowSeparateRestoreSeconds"], 17)
        self.assertEqual(offline["storedArchiveBytes"], 10743621569)
        self.assertEqual(offline["observedCompletedDownloadArchiveBytes"], 3191057466)
        self.assertIsNone(offline["wholeWorkflowWallSeconds"])
        self.assertIsNone(offline["workflowTotalDownloadedBytes"])


if __name__ == "__main__":
    unittest.main()
