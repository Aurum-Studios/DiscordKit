# File: Tools/ci/test_usage_report.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Offline usage reconciliation and bounded read-only API fixtures."""

import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import artifact_transfer
import usage_report


class UsageReportTests(unittest.TestCase):
    def setUp(self):
        self.plan = {
            "status": "rejected", "admitted": False, "reasons": ["billing mapping unverified"],
            "runID": "7", "runAttempt": 2, "source": {"commit": "abc"},
            "identity": {"runID": "7", "runAttempt": 2},
            "jobs": [{"id": "linux/build", "jobName": "Linux / Build", "group": "Linux-x64-8", "maximumSeconds": 61},
                     {"id": "linux/tests", "jobName": "Linux / Tests", "group": "Linux-x64-8", "maximumSeconds": 120}],
            "runnerRates": {"Linux-x64-8": {"sku": "linux-8-core", "usdPerMinute": "0.022",
                                              "billingMappingVerified": False}},
            "totals": {"allowanceUSD": "1.00", "maximumUSD": "0.276", "remainingUSD": "0.724", "safetyUSD": "0.10"},
            "reservations": [{"id": f"{job}/{attempt}", "jobID": job, "group": "Linux-x64-8", "attempt": attempt,
                              "billedMaximumMinutes": 2, "totalUSD": "0.044"}
                             for attempt in (1, 2) for job in ("linux/build", "linux/tests")]}

    def job(self, **changes):
        return {"id": 10, "name": "Linux / Build", "status": "completed", "conclusion": "success",
                "run_attempt": 2, "run_id": 7, "head_sha": "abc", "runner_group_name": "linux-x64-8",
                "created_at": "2026-11-12T00:00:00Z", "started_at": "2026-11-12T00:01:00Z",
                "completed_at": "2026-11-12T00:01:01Z", "steps": [], **changes}

    def complete_jobs(self):
        return [self.job(), self.job(id=11, name="Linux / Tests")]

    def test_rounds_per_job_per_attempt_and_retains_historical_failure(self):
        rows = [self.job(id=9, run_attempt=1, conclusion="failure"), *self.complete_jobs()]
        report = usage_report.reconcile(self.plan, rows)
        sku = report["runnerSKUs"]["linux-8-core"]
        self.assertEqual(sku["maximumMinutesPerAttempt"], 4)
        self.assertEqual(sku["reservedMaximumMinutes"], 8)
        self.assertEqual(sku["observedRoundedMinutesKnown"], 3)
        self.assertEqual(report["failedJobIDsAllAttempts"], [9])
        self.assertEqual(report["remainingCoverage"], [])
        self.assertFalse(report["invoiceReconciled"])
        self.assertFalse(report["providerEnforcedDollarCap"])
        self.assertEqual(report["planReasons"], self.plan["reasons"])
        self.assertFalse(report["planAdmitted"])

    def test_partial_rerun_cannot_reset_reservations(self):
        report = usage_report.reconcile(self.plan, [self.job()])
        accounting = report["reservationAccounting"]
        self.assertEqual(accounting["attemptedCumulativeReservationUSD"], "0.176")
        self.assertEqual(accounting["remainingAllowanceAfterAttemptReservationsUSD"], "0.724")
        self.assertEqual(accounting["attemptedCumulativeMaximumMinutes"], 8)
        self.assertEqual(report["remainingCoverage"], ["linux/tests"])
        self.assertEqual(report["status"], "incomplete")

    def test_engine_string_attempt_and_local_snapshot_are_supported(self):
        self.plan["runAttempt"] = "2"
        self.assertEqual(usage_report.reconcile(self.plan, self.complete_jobs())["remainingCoverage"], [])
        self.plan.update(runID="local", runAttempt="local")
        report = usage_report.reconcile(self.plan, [])
        self.assertEqual(report["status"], "incomplete")
        self.assertIsNone(report["reservationAccounting"]["attemptedCumulativeReservationUSD"])

    def test_unpriced_reservations_never_become_free(self):
        self.plan["runnerRates"]["Linux-x64-8"]["usdPerMinute"] = None
        self.plan["reservations"][0]["totalUSD"] = None
        report = usage_report.reconcile(self.plan, [])
        self.assertIsNone(report["reservationAccounting"]["attemptedCumulativeReservationUSD"])
        self.assertIsNone(report["reservationAccounting"]["remainingAllowanceAfterAttemptReservationsUSD"])
        self.assertEqual(report["runnerSKUs"]["linux-8-core"]["reservedMaximumMinutes"], 8)

    def test_missing_unknown_skipped_and_failed_work_does_not_pass(self):
        rows = [self.job(conclusion="skipped"), self.job(id=12, name="Unplanned expensive job", conclusion="failure")]
        report = usage_report.reconcile(self.plan, rows)
        self.assertEqual(report["status"], "incomplete")
        self.assertEqual(report["remainingCoverage"], ["linux/build", "linux/tests"])
        self.assertEqual(report["unknownJobIDs"], [12])
        self.assertEqual(report["jobs"][0]["observedRoundedMinutes"], 0)
        self.assertEqual(report["failedJobIDsAllAttempts"], [12])

    def test_running_job_keeps_unknown_duration_and_coverage(self):
        report = usage_report.reconcile(self.plan, [self.job(status="in_progress", conclusion=None, completed_at=None)])
        self.assertIsNone(report["jobs"][0]["observedRoundedMinutes"])
        self.assertEqual(report["runnerSKUs"]["linux-8-core"]["observedUnknownMinutesJobIDs"], [10])
        self.assertEqual(report["status"], "incomplete")

    def test_missing_or_mismatched_actual_runner_identity_stays_unknown(self):
        for group in (None, "GitHub Actions", "expensive-unreviewed"):
            with self.subTest(group=group):
                report = usage_report.reconcile(self.plan, [self.job(runner_group_name=group)])
                self.assertIsNone(report["jobs"][0]["sku"])
                self.assertIn(10, report["unknownJobIDs"])
                self.assertIn("linux/build", report["remainingCoverage"])

    def test_success_does_not_cover_wrong_source_run_or_unreserved_attempt(self):
        mutations = ({"run_id": 8}, {"run_id": None}, {"head_sha": "other"}, {"head_sha": None},
                     {"run_attempt": 99}, {"run_attempt": None}, {"run_attempt": True})
        for changes in mutations:
            with self.subTest(changes=changes):
                report = usage_report.reconcile(self.plan, [self.job(**changes)])
                self.assertIn(10, report["unknownJobIDs"])
                self.assertIn("linux/build", report["remainingCoverage"])

    def test_current_attempt_without_its_exact_job_reservation_does_not_pass(self):
        self.plan["reservations"] = [row for row in self.plan["reservations"]
                                     if (row["jobID"], row["attempt"]) != ("linux/build", 2)]
        report = usage_report.reconcile(self.plan, self.complete_jobs())
        self.assertEqual(report["status"], "incomplete")
        self.assertIn("reservation", " ".join(report["jobs"][0]["unknownReasons"]))

    def test_job_overrun_stays_visible_even_when_provider_says_success(self):
        report = usage_report.reconcile(self.plan, [self.job(completed_at="2026-11-12T00:02:01.001Z")])
        self.assertIn("exceeds", " ".join(report["jobs"][0]["unknownReasons"]))
        self.assertEqual(report["jobs"][0]["observedRoundedMinutes"], 2)
        self.assertIn("linux/build", report["remainingCoverage"])

    def test_exact_minute_rounding_and_invalid_durations(self):
        self.assertEqual(usage_report.minutes(60), 1)
        self.assertEqual(usage_report.minutes(60.001), 2)
        for start in (None, "broken", "2026-11-12T00:00:00", "2026-11-12T00:02:00Z"):
            self.assertIsNone(usage_report.duration(start, "2026-11-12T00:01:00Z"))
        for value in (-1, True, float("nan"), float("inf"), "1"):
            self.assertIsNone(usage_report.elapsed(value))

    def test_queue_is_only_upper_bound_whole_steps_and_missing_stage_are_explicit(self):
        step = {"started_at": "2026-11-12T00:01:00Z", "completed_at": "2026-11-12T00:01:01Z", "conclusion": "success"}
        row = self.job(steps=[{**step, "name": "Set up job"}, {**step, "name": "Run actions/checkout"},
                              {**step, "name": "Run ./.github/actions/setup-native"},
                              {**step, "name": "Download compiled archive"}])
        report = usage_report.reconcile(self.plan, [row])
        job = report["jobs"][0]
        self.assertIsNone(job["queueSeconds"])
        self.assertEqual(job["dependencyAndQueueSecondsUpperBound"], 60)
        self.assertEqual(set(job["stageSeconds"].values()), {1})
        row["steps"].append({"name": "Upload evidence", "conclusion": "failure"})
        self.assertIsNone(usage_report.reconcile(self.plan, [row])["jobs"][0]["stageSeconds"]["archiveTransferSeconds"])

    def test_command_timeout_and_transport_retry_results_are_retained_without_double_counting(self):
        command = {"name": "tests", "status": "failed", "timeoutCategory": "wall-clock", "exitCode": -15,
                   "operation": "suite", "elapsedSeconds": 5, "identity": {"executionID": "one"}}
        transfer = {"operation": "upload", "status": "verified", "elapsedSeconds": 2,
                    "attempts": [{"attempt": 1, "result": "failed", "classification": "transient"},
                                 {"attempt": 2, "result": "verified"}]}
        report = usage_report.reconcile(self.plan, self.complete_jobs(),
            [command, {"jobID": "linux/tests", "receipt": command}, transfer])
        self.assertEqual(len(report["commandResults"]), 2)
        self.assertEqual(report["commandResults"][0]["classification"], "timeout")
        self.assertEqual(report["commandResults"][1]["transferAttempts"], transfer["attempts"])
        self.assertEqual(report["unattributedReceiptCount"], 2)
        self.assertEqual(report["status"], "incomplete")

    def test_unknown_receipt_job_identity_is_not_inferred(self):
        report = usage_report.reconcile(self.plan, [], [{"jobID": "other", "status": "passed"}])
        self.assertIsNone(report["commandResults"][0]["jobID"])
        self.assertEqual(report["unattributedReceiptCount"], 1)

    def test_stale_stored_receipt_provenance_cannot_be_attributed_to_current_guard(self):
        for changes in ({"GITHUB_RUN_ID": "8"}, {"GITHUB_RUN_ATTEMPT": "1"},
                        {"GITHUB_SHA": "other"}, {"GITHUB_JOB": "build"}):
            with self.subTest(changes=changes):
                identity = {"executionID": "stale", "GITHUB_RUN_ID": "7", "GITHUB_RUN_ATTEMPT": "2",
                            "GITHUB_SHA": "abc", "GITHUB_JOB": "tests", **changes}
                receipt = {"status": "passed", "timeoutCategory": None, "identity": identity}
                report = usage_report.reconcile(self.plan, self.complete_jobs(),
                    [{"receipt": receipt, "jobID": "linux/tests", "expectedGitHubJob": "tests"}])
                result = report["commandResults"][0]
                self.assertIsNone(result["jobID"])
                self.assertEqual(result["provenance"], identity)
                self.assertTrue(result["unknownReasons"])
                self.assertEqual(report["status"], "incomplete")

    def test_duplicate_job_ids_or_ambiguous_plan_names_reject(self):
        with self.assertRaisesRegex(ValueError, "duplicate"):
            usage_report.reconcile(self.plan, [self.job(), self.job()])
        self.plan["jobs"][1]["jobName"] = "Linux / Build"
        with self.assertRaisesRegex(ValueError, "unique"):
            usage_report.reconcile(self.plan, [])

    def test_duplicate_executions_do_not_establish_coverage(self):
        report = usage_report.reconcile(self.plan, [self.job(), self.job(id=15)])
        self.assertIn("linux/build", report["remainingCoverage"])
        self.assertEqual(report["runnerSKUs"]["linux-8-core"]["observedRoundedMinutesKnown"], 2)

    def test_cli_writes_json_and_summary_with_retained_guard_receipt_attribution(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.plan["guard"] = {"jobID": "linux/tests", "status": "rejected", "reasons": ["unverified rate"]}
            (root / "plan.json").write_text(json.dumps(self.plan))
            receipts = root / "receipts"
            receipts.mkdir()
            (receipts / "test.receipt.json").write_text(json.dumps({"status": "passed", "timeoutCategory": None,
                "operation": "suite", "elapsedSeconds": 1, "identity": {"executionID": "known"}}))
            with patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(root / "summary.md")}):
                self.assertEqual(usage_report.main(["--plan", str(root / "plan.json"), "--output", str(root / "report.json"),
                                                    "--receipts", str(receipts)]), 0)
            report = json.loads((root / "report.json").read_text())
            self.assertEqual(report["commandResults"][0]["jobID"], "linux/tests")
            self.assertEqual(report["status"], "incomplete")
            summary = (root / "summary.md").read_text()
            self.assertIn("incomplete", summary)
            self.assertIn("linux/build", summary)
            self.assertIn("cumulative attempted reservations", summary)
            self.assertIn("Local command/transfer receipts", summary)

    def test_cli_failure_still_retains_json_and_summary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(root / "summary.md")}):
                result = usage_report.main(["--plan", str(root / "missing.json"), "--output", str(root / "report.json")])
            self.assertEqual(result, 1)
            self.assertEqual(json.loads((root / "report.json").read_text())["status"], "failed")
            self.assertIn("failed", (root / "summary.md").read_text())

    def test_cli_rejects_incomplete_offline_snapshot(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "plan.json").write_text(json.dumps(self.plan))
            (root / "jobs.json").write_text(json.dumps({"total_count": 2, "jobs": [self.job()]}))
            self.assertEqual(usage_report.main(["--plan", str(root / "plan.json"), "--output", str(root / "report.json"),
                                               "--jobs", str(root / "jobs.json")]), 1)

    def test_receipt_loader_ignores_nonreceipts_and_rejects_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "other.json").write_text('{"jobs":[]}')
            self.assertEqual(usage_report.read_receipts(root), [])
            (root / "alias.receipt.json").symlink_to(root / "other.json")
            with self.assertRaisesRegex(ValueError, "symlink"):
                usage_report.read_receipts(root)

    def test_receipt_walk_prunes_dependency_and_artifact_json_and_reads_command_records(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ("checkouts", "node_modules", "artifacts"):
                child = root / name
                child.mkdir()
                (child / "commands.json").write_text("not valid JSON")
            (root / "large-symbol-graph.json").write_text("not valid JSON")
            receipt = {"status": "passed", "timeoutCategory": None, "identity": {"executionID": "command"}}
            (root / "commands.json").write_text(json.dumps({"commands": [{"execution": receipt}]}))
            self.assertEqual(usage_report.read_receipts(root)[0]["receipt"], receipt)

    def test_actual_engine_plan_can_be_reported_offline(self):
        import spend_admission
        source = {"commit": "a" * 40, "sourceSHA256": "b" * 64, "dependencyPinsSHA256": {}}
        plan = spend_admission.make_plan("preflight", source=source)
        report = usage_report.reconcile(plan, [])
        self.assertEqual(report["status"], "incomplete")
        self.assertEqual(report["planStatus"], "rejected")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "plan.json").write_text(json.dumps(plan))
            self.assertEqual(usage_report.main(["--plan", str(root / "plan.json"), "--output", str(root / "usage.json")]), 0)


class FakeClient:
    def __init__(self, *, run=None):
        self.run = run or {"id": 7, "run_attempt": 2, "head_sha": "abc"}
        self.attempts, self.queries, self.scopes = [], [], []

    def within(self, budget, deadline):
        self.scopes.append((budget, deadline))
        from contextlib import nullcontext
        return nullcontext()

    def get_run(self):
        return self.run

    def list_jobs(self, attempt):
        self.queries.append(attempt)
        return [{"id": 100 + attempt, "run_attempt": attempt}]


class GitHubUsageTests(unittest.TestCase):
    def test_queries_every_attempt_under_one_existing_bounded_budget(self):
        client = FakeClient()
        rows = usage_report.github_jobs(client, {"runID": "7", "source": {"commit": "abc"}})
        self.assertEqual(client.queries, [1, 2])
        self.assertEqual([row["run_attempt"] for row in rows], [1, 2])
        self.assertEqual(len(client.scopes), 1)
        self.assertIsInstance(client.scopes[0][0], artifact_transfer.Budget)
        self.assertEqual(client.attempts[0]["result"], "verified")

    def test_rejects_wrong_run_source_and_excessive_attempts(self):
        for mutation in ({"id": 8}, {"head_sha": "other"}, {"run_attempt": 101}, {"run_attempt": True}):
            with self.subTest(mutation=mutation):
                client = FakeClient(run={"id": 7, "run_attempt": 2, "head_sha": "abc", **mutation})
                with self.assertRaises(artifact_transfer.TransferError):
                    usage_report.github_jobs(client, {"runID": "7", "source": {"commit": "abc"}})
                self.assertEqual(client.queries, [])


if __name__ == "__main__":
    unittest.main()
