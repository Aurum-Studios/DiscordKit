# File: Tools/ci/test_baseline_usage.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Offline evidence accounting, never hosted CI or invoice qualification."""

from datetime import date
import gzip
import json
from pathlib import Path
import tempfile
import unittest

import baseline_usage
import scheduling_policy


class BaselineUsageTests(unittest.TestCase):
    def setUp(self):
        self.policy = scheduling_policy.load_policy()
        self.as_of = date(2026, 11, 12)

    def job(self, **changes):
        return {"id": 1, "name": "Linux x64 / Tests / load", "conclusion": "success",
                "runner_group_name": "linux-x64-8", "created_at": "2026-11-12T00:00:00Z",
                "started_at": "2026-11-12T00:01:00Z", "completed_at": "2026-11-12T00:01:01Z",
                "steps": [], **changes}

    def summarize(self, job):
        return baseline_usage.summarize_job(job, self.policy, self.as_of)

    def test_rounds_each_job_before_adding_cost(self):
        jobs = [self.summarize(self.job(id=identity)) for identity in (1, 2)]
        self.assertEqual(sum(job["billedMinutesEstimate"] for job in jobs), 2)
        self.assertEqual([job["listPriceUSDEstimate"] for job in jobs], ["0.022", "0.022"])

    def test_exact_minute_and_fractional_second_rounding(self):
        for completed, expected in (("00:02:00", 1), ("00:02:00.001", 2)):
            with self.subTest(completed=completed):
                result = self.summarize(self.job(completed_at=f"2026-11-12T{completed}Z"))
                self.assertEqual(result["billedMinutesEstimate"], expected)

    def test_skipped_unassigned_is_zero_but_assigned_cancellation_is_billed(self):
        skipped = self.summarize(self.job(conclusion="skipped", runner_group_name=None,
                                          started_at=None, completed_at=None))
        self.assertEqual(skipped["billedMinutesEstimate"], 0)
        self.assertEqual(skipped["unknownReasons"], [])
        cancelled = self.summarize(self.job(conclusion="cancelled"))
        self.assertEqual(cancelled["billedMinutesEstimate"], 1)

    def test_unassigned_cancelled_and_missing_timestamps_stay_unknown(self):
        for changes in ({"started_at": None}, {"completed_at": None},
                        {"completed_at": "2026-11-12T00:00:59Z", "runner_group_name": None}):
            result = self.summarize(self.job(conclusion="cancelled", **changes))
            self.assertIsNone(result["listPriceUSDEstimate"])
            self.assertIsNone(result["runnerSeconds"])
            self.assertTrue(result["unknownReasons"])

    def test_unknown_group_does_not_fall_back_to_job_name_or_cheap_rate(self):
        result = self.summarize(self.job(runner_group_name="unreviewed-128-core"))
        self.assertEqual(result["runnerSeconds"], 1)
        self.assertIsNone(result["policyRunnerGroup"])
        self.assertIsNone(result["listPriceUSDEstimate"])

    def test_unknown_missing_and_stale_rate_fail_closed(self):
        for group in (None, "linux-x64-128"):
            self.assertIsNone(self.summarize(self.job(runner_group_name=group))["listPriceUSDEstimate"])
        self.policy["runnerRates"]["Linux-x64-8"]["verifiedOn"] = "2026-01-01"
        result = self.summarize(self.job())
        self.assertIsNone(result["listPriceUSDEstimate"])
        self.assertTrue(result["unknownReasons"])

    def test_dependency_wait_is_only_an_upper_bound(self):
        result = self.summarize(self.job())
        self.assertEqual(result["createdToStartedSecondsUpperBound"], 60)
        self.assertNotIn("queueSeconds", result)

    def test_duration_rejects_invalid_and_naive_timestamps(self):
        for start in (None, "broken", "2026-11-12T00:00:00"):
            self.assertIsNone(baseline_usage.duration(start, "2026-11-12T00:01:00Z"))

    def test_categories_preserve_compound_step_ownership(self):
        cases = {"Run ./.github/actions/setup-native": "setup",
                 "Compile selected products and tests without running suites": "compile",
                 "Discover owned test targets and assign runner sizes": "discovery",
                 "Verify and restore all three compiled packages": "restore",
                 "Run only the selected suite without rebuilding": "tests",
                 "Compare scoped public API and convert all public DocC modules": "conversion",
                 "Retain selected suite evidence": "upload",
                 "Download compiled macOS root": "download", "Complete job": "other"}
        for name, category in cases.items():
            self.assertEqual(baseline_usage.step_category(name)[0], category)
        self.assertIn("discovery", baseline_usage.step_category(list(cases)[1])[1])
        self.assertIn("restore", baseline_usage.step_category(list(cases)[4])[1])

    def test_skipped_and_missing_step_timestamps_do_not_invent_work(self):
        result = self.summarize(self.job(steps=[
            {"number": 1, "name": "Compile things", "conclusion": "skipped"},
            {"number": 2, "name": "Download artifact", "conclusion": "cancelled"}]))
        self.assertEqual(result["stepSecondsByCategory"]["compile"], 0)
        self.assertEqual(result["unknownStepDurations"], 1)

    def write_page(self, directory, number, rows, total=2, collection="jobs", wrapped=False):
        value = {"total_count": total, collection: rows}
        if wrapped:
            value = {collection: value}
        (directory / f"{collection}-page-{number}.json").write_text(json.dumps(value))

    def test_reads_both_jobs_pages_and_standard_artifact_pages(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.write_page(directory, 1, [{"id": 2}], wrapped=True)
            self.write_page(directory, 2, [{"id": 1}], wrapped=True)
            self.assertEqual([row["id"] for row in baseline_usage.read_pages(directory, "jobs")], [1, 2])
            self.write_page(directory, 1, [], total=0, collection="artifacts")
            self.assertEqual(baseline_usage.read_pages(directory, "artifacts"), [])

    def test_rejects_missing_duplicate_and_inconsistent_pages(self):
        for mutation in ("missing", "duplicate", "gap", "count"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                self.write_page(directory, 1, [{"id": 1}])
                if mutation != "missing":
                    self.write_page(directory, 3 if mutation == "gap" else 2,
                                    [{"id": 1 if mutation == "duplicate" else 2}],
                                    total=3 if mutation == "count" else 2)
                with self.assertRaises(ValueError):
                    baseline_usage.read_pages(directory, "jobs")

    def test_download_bytes_require_observed_completed_download(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "logs").mkdir()
            with gzip.open(directory / "logs/job-1.log.gz", "wt") as stream:
                stream.write("artifact (ID: 7, Size: 123, Expected Digest: sha256:a)\n")
                stream.write("Artifact download completed successfully.\n")
                stream.write("artifact (ID: 8, Size: 456, Expected Digest: sha256:b)\nfailed\n")
            result = baseline_usage.summarize_download_logs(directory)
            self.assertEqual(result["observedCompletedDownloadArchiveBytes"], 123)
            self.assertIsNone(result["workflowTotalDownloadedBytes"])
            self.assertIsNone(result["wireBytes"])

    def test_retained_baseline_regenerates_deterministically(self):
        result = baseline_usage.summarize(baseline_usage.DEFAULT_BASELINE)
        self.assertEqual(result, baseline_usage.summarize(baseline_usage.DEFAULT_BASELINE))
        self.assertEqual(sorted(run["jobCount"] for run in result["runs"]), [7, 152])
        self.assertFalse(result["billingMappingVerified"])
        self.assertFalse(result["invoiceReconciled"])

    def test_run_rejects_missing_or_mismatched_source_identity(self):
        for owner in ("job", "artifact"):
            for source in (None, "other-sha"):
                with self.subTest(owner=owner, source=source), tempfile.TemporaryDirectory() as temporary:
                    directory = Path(temporary)
                    run = {"id": 7, "head_sha": "expected-sha"}
                    (directory / "run.json").write_text(json.dumps(run))
                    job = self.job(run_id=7, head_sha=source if owner == "job" else "expected-sha")
                    artifact = {"id": 2, "workflow_run": {"id": 7,
                        "head_sha": source if owner == "artifact" else "expected-sha"}}
                    self.write_page(directory, 1, [job], total=1)
                    self.write_page(directory, 1, [artifact], total=1, collection="artifacts")
                    with self.assertRaisesRegex(ValueError, "source identity"):
                        baseline_usage.summarize_run(directory, self.policy)


if __name__ == "__main__":
    unittest.main()
