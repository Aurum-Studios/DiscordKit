# File: Tools/ci/test_workflow_coverage.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Coverage barriers reject omitted rows, ambiguous attempts and scoped promotion."""

import copy
from contextlib import contextmanager
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import native_receipts as receipts
import workflow_coverage as coverage


class FakeGitHub:
    def __init__(self, jobs):
        self.jobs = jobs
        self.queries = []
        self.run = {"id": 42, "repository": {"id": 123, "full_name": "aurum/DiscordKit"},
                    "head_repository": {"id": 123}, "event": "push", "head_sha": "a" * 40,
                    "path": ".github/workflows/ci.yml", "run_attempt": 2}

    @contextmanager
    def within(self, budget, deadline):
        yield

    def get_run(self):
        return self.run

    def list_jobs(self, attempt):
        self.queries.append(attempt)
        return copy.deepcopy(self.jobs.get(attempt, []))


class WorkflowCoverageTests(unittest.TestCase):
    def setUp(self):
        self.manifest = {"schemaVersion": 1, "mode": "full", "commit": "a" * 40,
                         "runID": "42", "runAttempt": "2", "platform": "linux-x64",
                         "entries": [{"id": "canary", "jobName": "Linux x64 / Canary / load tests and smokes"},
                                     {"id": "root", "jobName": "Linux x64 / Builds / linux-x64 / root"},
                                     {"id": "bits", "jobName": "Linux x64 / Tests / DiscordBitsTests",
                                      "stepName": "Run selected suite"}]}
        self.execution = {"scope": "github", "repository": "aurum/DiscordKit", "repositoryID": "123",
                          "workflowRef": "aurum/DiscordKit/.github/workflows/ci.yml@refs/heads/main",
                          "workflowSHA": "a" * 40, "runID": "42", "runAttempt": "2", "jobID": "complete",
                          "event": "push", "ref": "refs/heads/main", "headRef": "", "baseRef": ""}
        self.jobs = [self.job(entry["jobName"], 100 + i) for i, entry in enumerate(self.manifest["entries"])]
        self.client = FakeGitHub({"2": self.jobs})

    def job(self, name, job_id, *, attempt=2, conclusion="success"):
        return {"id": job_id, "name": name, "run_id": 42, "head_sha": "a" * 40,
                "run_attempt": attempt, "status": "completed", "conclusion": conclusion,
                "steps": [{"name": "Run selected suite", "status": "completed", "conclusion": "success"}]}

    def validate(self, jobs=None, manifest=None):
        return coverage.validate_jobs(manifest or self.manifest, self.jobs if jobs is None else jobs,
                                      head_sha="a" * 40)

    def certify(self, **kwargs):
        return coverage.certify(self.client, manifest=self.manifest, execution=self.execution,
                                source_commit="a" * 40, **kwargs)

    def test_complete_scope_has_one_immutable_job_per_expected_row(self):
        summary = self.certify()
        self.assertEqual(summary["manifestSHA256"], receipts.digest(self.manifest))
        self.assertEqual([entry["jobID"] for entry in summary["entries"]], ["100", "101", "102"])
        self.assertEqual(self.client.queries, ["1", "2"])
        self.assertIs(coverage.validate_summary(self.manifest, summary, require_full=True), summary)

    def test_partial_rerun_keeps_successes_and_seals_fresh_barrier_attempt(self):
        self.client.jobs = {"1": [{**job, "run_attempt": 1} for job in self.jobs[:2]], "2": self.jobs[2:]}
        summary = self.certify()
        self.assertEqual(summary["runAttempt"], "2")
        self.assertEqual([entry["jobAttempt"] for entry in summary["entries"]], ["1", "1", "2"])

    def test_missing_attempt_field_uses_attempt_specific_endpoint_provenance(self):
        del self.jobs[0]["run_attempt"]
        self.assertEqual(self.certify()["entries"][0]["jobAttempt"], "2")

    def test_api_attempt_cannot_disagree_with_requested_attempt(self):
        self.jobs[0]["run_attempt"] = 1
        with self.assertRaisesRegex(ValueError, "different attempt"):
            self.certify()

    def test_missing_expected_row_is_not_implicit_success(self):
        with self.assertRaisesRegex(ValueError, "missing expected"):
            self.validate(self.jobs[1:])

    def test_empty_and_duplicate_expected_scope_rejected(self):
        for entries in ([], [self.manifest["entries"][0]] * 2,
                        [{"id": "a", "jobName": "same"}, {"id": "b", "jobName": "same"}]):
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                coverage.validate_manifest({**self.manifest, "entries": entries})

    def test_manifest_rejects_malformed_or_unknown_identity(self):
        mutations = [("schemaVersion", True), ("mode", "unknown"), ("commit", "b" * 39),
                     ("runID", 42), ("runAttempt", "0"), ("platform", []), ("unknown", "value")]
        for key, value in mutations:
            with self.subTest(key=key), self.assertRaises(ValueError):
                coverage.validate_manifest({**self.manifest, key: value})

    def test_latest_replacement_blocks_earlier_success(self):
        old = {**self.jobs[0], "id": 99, "run_attempt": 1}
        for status, conclusion in [("completed", "failure"), ("completed", "cancelled"),
                                   ("completed", "skipped"), ("completed", "neutral"),
                                   ("in_progress", None), ("queued", None)]:
            jobs = copy.deepcopy(self.jobs)
            jobs[0].update(status=status, conclusion=conclusion)
            with self.subTest(conclusion=conclusion), self.assertRaisesRegex(ValueError, "did not pass"):
                self.validate([old] + jobs)

    def test_newer_success_replaces_earlier_failed_row(self):
        old = {**self.jobs[0], "id": 99, "run_attempt": 1, "conclusion": "failure"}
        self.assertEqual(self.validate([old] + self.jobs)["entries"][0]["jobID"], "100")

    def test_duplicate_latest_row_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "duplicate expected coverage job"):
            self.validate(self.jobs + [{**self.jobs[0], "id": 200}])

    def test_duplicate_api_job_id_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "duplicate GitHub job identity"):
            self.validate(self.jobs + [self.jobs[0]])

    def test_job_from_other_source_run_or_future_attempt_is_rejected(self):
        for key, value in [("head_sha", "b" * 40), ("run_id", 43), ("run_attempt", 3),
                           ("run_attempt", None)]:
            jobs = copy.deepcopy(self.jobs)
            jobs[0][key] = value
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "source, run or attempt"):
                self.validate(jobs)

    def test_names_are_exact_and_cannot_alias_platform_prefix(self):
        self.jobs[0]["name"] = "macOS ARM64 / Canary / load tests and smokes"
        with self.assertRaisesRegex(ValueError, "missing expected"):
            self.validate()

    def test_unexpected_canonical_build_and_suite_rows_fail_closed(self):
        for suffix in ("Builds / linux-x64 / unplanned", "Tests / UnplannedTests"):
            for conclusion in ("success", "skipped", "failure"):
                extra = self.job("Linux x64 / " + suffix, 200, conclusion=conclusion)
                with self.subTest(suffix=suffix, conclusion=conclusion), \
                     self.assertRaisesRegex(ValueError, "unexpected canonical"):
                    self.validate(self.jobs + [extra])

    def test_unexpected_earlier_canonical_replay_also_fails_closed(self):
        extra = self.job("Linux x64 / Tests / ReplayTests", 200, attempt=1)
        with self.assertRaisesRegex(ValueError, "unexpected canonical"):
            self.validate([extra] + self.jobs)

    def test_explicit_diagnostic_replay_and_other_platform_jobs_are_excluded(self):
        extra = [self.job("Linux x64 / Diagnostic replay / Tests / FocusedTests", 200),
                 self.job("macOS ARM64 / Builds / macos-arm64 / root", 201),
                 self.job("macOS ARM64 / Tests / OtherTests", 202)]
        summary = self.validate(self.jobs + extra)
        self.assertEqual(len(summary["entries"]), len(self.manifest["entries"]))
        self.assertFalse({"200", "201", "202"} & {entry["jobID"] for entry in summary["entries"]})

    def test_unexpected_rows_are_checked_for_each_native_platform(self):
        for platform, prefix in (("macos-arm64", "macOS ARM64 / "), ("windows-x64", "Windows x64 / ")):
            manifest = copy.deepcopy(self.manifest)
            manifest["platform"] = platform
            for entry in manifest["entries"]:
                entry["jobName"] = entry["jobName"].replace("Linux x64 / ", prefix)
            jobs = [self.job(entry["jobName"], 100 + i) for i, entry in enumerate(manifest["entries"])]
            jobs.append(self.job(prefix + "Tests / UnexpectedTests", 200))
            with self.subTest(platform=platform), self.assertRaisesRegex(ValueError, "unexpected canonical"):
                self.validate(jobs, manifest=manifest)

    def combined_manifest(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["platform"] = "shared"
        manifest["entries"] += [
            {"id": "macos/root", "jobName": "macOS ARM64 / Builds / macos-arm64 / root"},
            {"id": "helper/browser", "jobName": "Helper suites / browser"}]
        jobs = copy.deepcopy(self.jobs) + [self.job(entry["jobName"], 200 + i)
                                         for i, entry in enumerate(manifest["entries"][-2:])]
        return manifest, jobs

    def test_combined_root_manifest_rejects_extra_rows_from_each_covered_family(self):
        manifest, jobs = self.combined_manifest()
        for name in ("Linux x64 / Builds / linux-x64 / Unexpected", "Linux x64 / Tests / UnexpectedTests",
                     "macOS ARM64 / Builds / macos-arm64 / Unexpected", "macOS ARM64 / Tests / UnexpectedTests",
                     "Helper suites / unexpected-python"):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "unexpected canonical"):
                self.validate(jobs + [self.job(name, 300)], manifest=manifest)

    def test_combined_root_manifest_excludes_explicit_diagnostic_replays(self):
        manifest, jobs = self.combined_manifest()
        replays = [self.job("Linux x64 / Diagnostic replay / Tests / FocusedTests", 300),
                   self.job("macOS ARM64 / Diagnostic replay / Builds / root", 301),
                   self.job("Diagnostic replay / Helper suites / focused-python", 302)]
        summary = self.validate(jobs + replays, manifest=manifest)
        self.assertEqual(len(summary["entries"]), len(manifest["entries"]))
        self.assertEqual(summary["platform"], "shared")
        self.assertFalse({"300", "301", "302"} & {entry["jobID"] for entry in summary["entries"]})

    def test_shared_only_manifest_rejects_extra_helpers_without_claiming_native_rows(self):
        manifest = {**self.manifest, "platform": "shared", "entries": [
            {"id": "helper/browser", "jobName": "Helper suites / browser"}]}
        jobs = [self.job("Helper suites / browser", 200),
                self.job("Linux x64 / Tests / OutsideThisManifest", 201)]
        self.assertEqual(len(self.validate(jobs, manifest=manifest)["entries"]), 1)
        with self.assertRaisesRegex(ValueError, "unexpected canonical"):
            self.validate(jobs + [self.job("Helper suites / unplanned", 202)], manifest=manifest)

    def test_step_gate_requires_exact_unique_success(self):
        step = self.jobs[2]["steps"][0]
        for steps in ([], [step, step], [{**step, "conclusion": "skipped"}],
                      [{**step, "status": "in_progress"}], None):
            self.jobs[2]["steps"] = steps
            with self.subTest(steps=steps), self.assertRaises(ValueError):
                self.validate()

    def test_summary_cannot_omit_add_or_duplicate_entries(self):
        valid = self.validate()
        for entries in (valid["entries"][:-1], valid["entries"] + [valid["entries"][0]],
                        [valid["entries"][0]] * len(valid["entries"])):
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                coverage.validate_summary(self.manifest, {**valid, "entries": entries})

    def test_summary_cannot_change_current_source_attempt_or_scope(self):
        valid = self.validate()
        for key, value in [("schemaVersion", True), ("commit", "b" * 40), ("runID", "43"), ("runAttempt", "1"),
                           ("mode", "diagnostic"), ("manifestSHA256", "b" * 64), ("status", "failed")]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                coverage.validate_summary(self.manifest, {**valid, key: value})

    def test_summary_cannot_add_identity_fields_or_future_job_attempt(self):
        valid = self.validate()
        for key, value in [("jobID", "0"), ("jobAttempt", "3"), ("status", "failed"),
                           ("jobName", "other"), ("unexpected", "value")]:
            changed = copy.deepcopy(valid)
            changed["entries"][0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                coverage.validate_summary(self.manifest, changed)

    def test_diagnostic_success_never_qualifies_as_full(self):
        diagnostic = {**self.manifest, "mode": "diagnostic"}
        summary = self.validate(manifest=diagnostic)
        self.assertEqual(summary["status"], "passed")
        with self.assertRaises(ValueError):
            coverage.validate_summary(diagnostic, summary, require_full=True)

    def test_manifest_source_and_run_must_match_current_execution(self):
        for key, value in [("commit", "b" * 40), ("runID", "43"), ("runAttempt", "1")]:
            manifest = {**self.manifest, key: value}
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "current CI workflow"):
                coverage.certify(self.client, manifest=manifest, execution=self.execution, source_commit="a" * 40)

    def test_wrong_workflow_or_repository_api_provenance_is_rejected(self):
        for key, value in [("path", ".github/workflows/other.yml"), ("head_sha", "b" * 40),
                           ("repository", {"id": 999, "full_name": "attacker/DiscordKit"}), ("run_attempt", 3)]:
            previous = self.client.run[key]
            self.client.run[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.certify()
            self.client.run[key] = previous

    def test_pr_merge_checkout_is_distinct_from_api_head_but_bound_to_execution(self):
        self.execution.update(event="pull_request", ref="refs/pull/1/merge", headRef="feature", baseRef="main")
        self.client.run.update(event="pull_request", head_sha="b" * 40)
        for job in self.jobs:
            job["head_sha"] = "b" * 40
        summary = self.certify()
        self.assertEqual(summary["commit"], "a" * 40)
        self.assertEqual(summary["headSHA"], "b" * 40)

    def test_cli_seals_output_only_after_successful_api_validation(self):
        with tempfile.TemporaryDirectory() as temporary:
            output, github_output = Path(temporary) / "coverage.json", Path(temporary) / "github-output"
            environment = {"GITHUB_SHA": "a" * 40, "GITHUB_OUTPUT": str(github_output), "GH_TOKEN": "test-token"}
            with patch.dict(os.environ, environment), patch.object(receipts, "execution_identity", return_value=self.execution), \
                 patch("workflow_coverage.subprocess.check_output", return_value="a" * 40 + "\n"), \
                 patch("artifact_transfer.GitHubArtifactClient", return_value=self.client), patch("sys.stdout", io.StringIO()):
                summary = coverage.main(["certify", "--manifest-json", json.dumps(self.manifest),
                                         "--output", str(output), "--github-output"])
            self.assertEqual(json.loads(output.read_text()), summary)
            self.assertEqual(json.loads(github_output.read_text().split("=", 1)[1]), summary)

    def test_cli_wrong_checkout_does_not_emit_certificate(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "coverage.json"
            with patch.dict(os.environ, {"GITHUB_SHA": "b" * 40}), \
                 patch.object(receipts, "execution_identity", return_value=self.execution), \
                 patch("workflow_coverage.subprocess.check_output", return_value="a" * 40 + "\n"), \
                 self.assertRaisesRegex(ValueError, "checked-out source"):
                coverage.main(["certify", "--manifest-json", json.dumps(self.manifest), "--output", str(output)])
            self.assertFalse(output.exists())


class ExecutedLeafCoverageTests(unittest.TestCase):
    """Successful Actions rows require separately digest-verified complete leaf evidence."""

    job = WorkflowCoverageTests.job
    validate = WorkflowCoverageTests.validate

    def setUp(self):
        WorkflowCoverageTests.setUp(self)
        import test_results
        self.scope = {"platform": "linux-x64", "component": "root", "suite": "root-01",
                      "suites": ["DiscordBitsTests"], "jobID": "tests-root"}
        self.manifest.update(mode="diagnostic", entries=[{
            "id": "suite/root/root-01", "jobName": "Linux x64 / Tests / root-01",
            "stepName": "Run selected complete suites without rebuilding", "testCoverage": self.scope}])
        self.jobs = [self.job(self.manifest["entries"][0]["jobName"], 100)]
        self.jobs[0]["steps"][0]["name"] = self.manifest["entries"][0]["stepName"]
        self.client = FakeGitHub({"2": self.jobs})
        leaves = ["DiscordBitsTests.Bits/first()", "DiscordBitsTests.Bits/second()"]
        self.metadata = {"producer": {"execution": {**self.execution, "jobID": "build-core"}},
                         "compatibility": {"identity": {"commit": "a" * 40}, "build": {}},
                         "tests": {".": {"DiscordBitsTests": leaves}}}
        self.result = {"formatVersion": 1, "status": "passed", "framework": "swift-testing",
                       "eventStreamVersion": test_results.EVENT_STREAM_VERSION,
                       "expectedLeaves": leaves[:], "executedLeaves": leaves[:], "excludedLeaves": {},
                       "leaves": {leaf: {"outcome": "passed", "parameterized": False, "caseCount": 1}
                                  for leaf in leaves},
                       "counts": {"expected": 2, "executed": 2, "passed": 2, "excluded": 0, "cases": 2},
                       "runCount": 1}
        qualified = [".::" + leaf for leaf in leaves]
        self.receipt = {"formatVersion": 1, "status": "passed", "component": "root", "suite": "root-01",
                        "suites": ["DiscordBitsTests"], "platform": "linux-x64", "sourceCommit": "a" * 40,
                        "execution": {**self.execution, "jobID": "tests-root"},
                        "producer": copy.deepcopy(self.metadata["producer"]),
                        "compatibility": copy.deepcopy(self.metadata["compatibility"]),
                        "inventory": copy.deepcopy(self.metadata["tests"]),
                        "inventorySHA256": receipts.digest(self.metadata["tests"]),
                        "expectedLeaves": qualified[:], "executedLeaves": qualified[:], "excludedLeaves": {},
                        "suiteResults": [{"suite": "DiscordBitsTests", "status": "passed",
                                          "expectedLeaves": qualified[:], "executedLeaves": qualified[:],
                                          "excludedLeaves": {}, "result": self.result}]}
        self.artifacts = [self.artifact()]
        self.payloads = {"500": self.receipt}
        self.client.list_artifacts = lambda: copy.deepcopy(self.artifacts)
        self.reads = []
        def read_zip_json(artifact_id, digest, member):
            self.reads.append((artifact_id, digest, member))
            return copy.deepcopy(self.payloads[artifact_id])
        self.client.read_zip_json = read_zip_json

    def artifact(self, *, artifact_id=500, attempt="2", transfer=1):
        return {"id": artifact_id,
                "name": coverage.evidence_prefix(self.scope, self.manifest, attempt) + f"-t{transfer}",
                "digest": "sha256:" + "b" * 64, "expired": False,
                "workflow_run": {"id": 42, "repository_id": 123, "head_repository_id": 123,
                                 "head_sha": "a" * 40}}

    def certify(self, **kwargs):
        index = {"components": {"root": {"metadata": self.metadata}}}
        with patch("artifact_index.resolve", return_value=index):
            return WorkflowCoverageTests.certify(self, **kwargs)

    def test_executed_receipt_seals_artifact_digest_and_complete_producer_leaf_population(self):
        result = self.certify()
        selected = result["entries"][0]
        self.assertEqual(selected["jobID"], "100")
        self.assertEqual(selected["testEvidence"], {
            "artifactID": "500", "artifactName": self.artifacts[0]["name"],
            "artifactDigest": "sha256:" + "b" * 64, "receiptSHA256": receipts.digest(self.receipt)})
        self.assertEqual(self.reads, [("500", "sha256:" + "b" * 64, "group-coverage.json")])

    def test_job_success_without_executed_leaf_proof_fails(self):
        with self.assertRaisesRegex(ValueError, "executed-leaf evidence is missing"):
            self.validate()
        self.artifacts.clear()
        with self.assertRaisesRegex(ValueError, "missing immutable executed-leaf artifact"):
            self.certify()

    def test_partial_rerun_uses_only_unchanged_successful_jobs_exact_receipt_attempt(self):
        self.jobs[0]["run_attempt"] = 1
        self.client.jobs = {"1": self.jobs}
        self.artifacts[0] = self.artifact(attempt="1")
        self.receipt["execution"]["runAttempt"] = "1"
        result = self.certify()
        self.assertEqual(result["entries"][0]["jobAttempt"], "1")
        self.assertEqual(result["runAttempt"], "2")
        self.jobs[0]["run_attempt"] = 2
        self.client.jobs = {"2": self.jobs}
        with self.assertRaisesRegex(ValueError, "missing immutable executed-leaf artifact"):
            self.certify()

    def test_newer_failed_job_cannot_reuse_old_successful_leaf_receipt(self):
        old = {**copy.deepcopy(self.jobs[0]), "id": 99, "run_attempt": 1}
        self.client.jobs = {"1": [old], "2": self.jobs}
        self.jobs[0]["conclusion"] = "failure"
        with self.assertRaisesRegex(ValueError, "did not pass"):
            self.certify()
        self.assertFalse(self.reads)

    def test_artifact_api_source_digest_expiry_and_name_are_required(self):
        valid = copy.deepcopy(self.artifacts[0])
        mutations = [("expired", True), ("digest", ""), ("workflow_run", {"id": 99}),
                     ("name", valid["name"][:-1] + "4")]
        for key, value in mutations:
            self.artifacts[0] = {**valid, key: value}
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.certify()

    def test_receipt_wrong_source_scope_producer_and_consumer_attempt_fail(self):
        valid = copy.deepcopy(self.receipt)
        mutations = [("sourceCommit", "c" * 40), ("suite", "root-02"), ("suites", ["UnknownTests"]),
                     ("platform", "macos-arm64"), ("inventorySHA256", "c" * 64),
                     ("producer", {}), ("compatibility", {}), ("inventory", {})]
        for key, value in mutations:
            self.payloads["500"] = {**valid, key: value}
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.certify()
        for key, value in [("runID", "43"), ("runAttempt", "1"), ("jobID", "tests"),
                           ("repository", "attacker/repo")]:
            self.payloads["500"] = {**valid, "execution": {**valid["execution"], key: value}}
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.certify()

    def test_zero_wrong_filter_missing_duplicate_unexpected_and_unexecuted_leaves_fail(self):
        valid = copy.deepcopy(self.receipt)
        for changed in ([], valid["executedLeaves"][:1], [valid["executedLeaves"][0]] * 2,
                        valid["executedLeaves"] + [".::UnknownTests.test()"]):
            self.payloads["500"] = {**valid, "executedLeaves": changed}
            with self.subTest(executed=changed), self.assertRaises(ValueError):
                self.certify()
        for status in ("unexecuted", "failed", "skipped"):
            changed = copy.deepcopy(valid)
            changed["suiteResults"][0]["status"] = status
            self.payloads["500"] = changed
            with self.subTest(status=status), self.assertRaises(ValueError):
                self.certify()

    def test_nested_structured_result_is_independently_reconciled(self):
        for key, value in [("executedLeaves", []), ("leaves", {}), ("counts", {}),
                           ("framework", "stdout-count"), ("status", "failed")]:
            changed = copy.deepcopy(self.receipt)
            changed["suiteResults"][0]["result"][key] = value
            self.payloads["500"] = changed
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.certify()

    def test_exclusions_are_exactly_predeclared_by_selected_producer(self):
        leaf = self.metadata["tests"]["."]["DiscordBitsTests"][-1]
        reason = "Explicit platform qualification requires external oracle"
        self.metadata["compatibility"]["build"]["testExclusions"] = {".": {leaf: reason}}
        self.receipt["compatibility"] = copy.deepcopy(self.metadata["compatibility"])
        self.receipt["excludedLeaves"] = {".::" + leaf: reason}
        self.receipt["executedLeaves"].remove(".::" + leaf)
        row = self.receipt["suiteResults"][0]
        row["excludedLeaves"] = {".::" + leaf: reason}
        row["executedLeaves"].remove(".::" + leaf)
        row["result"]["excludedLeaves"] = {leaf: reason}
        row["result"]["expectedLeaves"].remove(leaf)
        row["result"]["executedLeaves"].remove(leaf)
        del row["result"]["leaves"][leaf]
        row["result"]["counts"] = {"expected": 1, "executed": 1, "passed": 1, "excluded": 1, "cases": 1}
        self.assertEqual(self.certify()["status"], "passed")
        self.receipt["executedLeaves"].append(".::" + leaf)
        with self.assertRaises(ValueError):
            self.certify()

    def test_receipt_cannot_invent_exclusion_after_execution(self):
        leaf = self.receipt["expectedLeaves"][-1]
        self.receipt["excludedLeaves"] = {leaf: "made up at runtime"}
        with self.assertRaises(ValueError):
            self.certify()

    def test_transport_retry_may_repeat_identical_receipt_but_not_alter_results(self):
        self.artifacts.append(self.artifact(artifact_id=501, transfer=2))
        self.payloads["501"] = copy.deepcopy(self.receipt)
        self.assertEqual(self.certify()["entries"][0]["testEvidence"]["artifactID"], "500")
        self.payloads["501"]["suiteResults"][0]["result"]["runCount"] = 2
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            self.certify()

    def test_full_manifest_cannot_omit_an_entire_component(self):
        self.manifest["mode"] = "full"
        with self.assertRaisesRegex(ValueError, "omits a test component"):
            self.certify()

    def test_full_manifest_cannot_omit_producer_leaves_outside_scheduled_groups(self):
        self.manifest["mode"] = "full"
        self.metadata["tests"]["."]["OtherTests"] = ["OtherTests.Other/test()"]
        self.receipt["inventory"] = copy.deepcopy(self.metadata["tests"])
        self.receipt["inventorySHA256"] = receipts.digest(self.metadata["tests"])
        with patch("native_jobs.COMPONENTS", ("root", "release")), \
             self.assertRaisesRegex(ValueError, "omits producer inventory"):
            self.certify()

    def test_manifest_requires_stable_explicit_unique_whole_suite_selection(self):
        valid = copy.deepcopy(self.scope)
        for key, value in [("suites", []), ("suites", ["DiscordBitsTests"] * 2),
                           ("suite", "root 01"), ("jobID", "tests"), ("platform", []),
                           ("component", [])]:
            self.manifest["entries"][0]["testCoverage"] = {**valid, key: value}
            with self.subTest(key=key), self.assertRaises(ValueError):
                coverage.validate_manifest(self.manifest)

    def test_selected_summary_cannot_drop_or_change_receipt_identity(self):
        valid = self.certify()
        for key, value in [("artifactID", "0"), ("artifactDigest", "sha256:invalid"),
                           ("receiptSHA256", "b" * 63), ("artifactName", "different"), ("unexpected", True)]:
            changed = copy.deepcopy(valid)
            changed["entries"][0]["testEvidence"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                coverage.validate_summary(self.manifest, changed)
        changed = copy.deepcopy(valid)
        del changed["entries"][0]["testEvidence"]
        with self.assertRaises(ValueError):
            coverage.validate_summary(self.manifest, changed)


if __name__ == "__main__":
    unittest.main()
