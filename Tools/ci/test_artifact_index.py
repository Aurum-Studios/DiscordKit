# File: Tools/ci/test_artifact_index.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Resolve exact native producer identities and reject ambiguous or incomplete evidence."""

import copy
from contextlib import contextmanager
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

import artifact_index as index
import artifact_transfer as transfer
import native_receipts as receipts


class FakeGitHub:
    """Model the independent API provenance and receipt artifacts, never matrix outputs."""

    def __init__(self):
        self.run = {"id": 42, "repository": {"id": 123, "full_name": "aurum/DiscordKit"},
                    "head_repository": {"id": 123}, "event": "push", "head_sha": "a" * 40,
                    "path": ".github/workflows/ci.yml"}
        self.artifacts = []
        self.receipts = {}
        self.jobs = {}
        self.queries = []

    def get_run(self):
        return self.run

    @contextmanager
    def within(self, budget, deadline):
        self.budget = budget
        self.deadline = deadline
        yield

    def list_artifacts(self):
        return self.artifacts

    def list_jobs(self, attempt):
        self.queries.append(attempt)
        return self.jobs.get(attempt, [])

    def read_zip_json(self, artifact_id, digest, member):
        assert member == "producer-receipt.json"
        assert self.receipts[artifact_id][0] == digest
        return self.receipts[artifact_id][1]


class ArtifactIndexTests(unittest.TestCase):
    def setUp(self):
        self.execution = {"scope": "github", "repository": "aurum/DiscordKit", "repositoryID": "123",
                          "workflowRef": "aurum/DiscordKit/.github/workflows/ci.yml@refs/heads/main",
                          "workflowSHA": "a" * 40, "runID": "42", "runAttempt": "2", "jobID": "tests",
                          "event": "push", "ref": "refs/heads/main", "headRef": "", "baseRef": ""}
        self.client = FakeGitHub()
        self.add_producer()

    def api_artifact(self, artifact_id, name, digest):
        artifact = {"id": int(artifact_id), "name": name, "digest": digest, "expired": False,
                    "workflow_run": {"id": 42, "repository_id": 123, "head_repository_id": 123,
                                     "head_sha": "a" * 40}}
        self.client.artifacts.append(artifact)
        return artifact

    def add_producer(self, *, component="root", attempt="1", artifact_id="101", receipt_id="201",
                     upload_attempt=1):
        execution = {**self.execution, "jobID": "build", "runAttempt": attempt}
        tests = {".": {"CoreTests": ["CoreTests.Suite/test()"]}}
        metadata = {"formatVersion": 2, "status": "passed", "component": component,
                    "compatibility": {"identity": {"commit": "a" * 40, "sourceSHA256": "b" * 64,
                         "dependencyPinsSHA256": {"Package.resolved": "c" * 64},
                         "repository": str(Path.cwd()), "platform": "linux-x64", "system": "Linux",
                         "machine": "x64", "swiftVersion": "Swift 6.4.1", "swiftTarget": "linux",
                         "buildSystem": "native", "runtime": {"compiler": "fixture"}, "buildEnvironment": {}},
                         "build": {"testPackages": ["."]}}, "tests": tests, "buildRoots": [".build"],
                    "payloadSHA256": "d" * 64,
                    "producer": receipts.producer_receipt(execution, tests, "2000-01-01T00:00:00Z")}
        artifact = self.api_artifact(artifact_id, index.artifact_prefix("linux-x64", component, "a" * 40,
                                    execution) + f"-t{upload_attempt}", "sha256:" + "e" * 64)
        receipt_artifact = self.api_artifact(receipt_id, index.artifact_prefix("linux-x64", component,
                           "a" * 40, execution, receipt=True) + f"-t{upload_attempt}", "sha256:" + "f" * 64)
        envelope = {"formatVersion": 1, "metadata": metadata,
                    "artifact": {"id": artifact_id, "name": artifact["name"], "digest": artifact["digest"],
                                 "archiveSHA256": "1" * 64}}
        self.client.receipts[receipt_id] = (receipt_artifact["digest"], envelope)
        job = {"id": int(artifact_id), "run_id": 42, "head_sha": "a" * 40, "run_attempt": int(attempt),
               "name": f"Linux native / Builds / linux-x64 / {component}",
               "status": "completed", "conclusion": "success"}
        # Multiple receipt uploads in the same producer refer to one attempt-specific job.
        jobs = self.client.jobs.setdefault(attempt, [])
        if not any(item["name"] == job["name"] for item in jobs):
            jobs.append(job)
        return artifact, receipt_artifact, envelope

    def resolve(self, components=None):
        return index.resolve(self.client, execution=self.execution, platform="linux-x64",
                             components=components or ["root"], source_commit="a" * 40)

    def validate(self, selection):
        return index.validate_selection(selection, execution=self.execution, component="root",
                                        platform="linux-x64", archive_sha256="1" * 64,
                                        metadata=selection["components"]["root"]["metadata"])

    def test_partial_rerun_selects_successful_earlier_producer_and_current_consumer(self):
        selection = self.resolve()
        entry = self.validate(selection)
        self.assertEqual(selection["execution"]["runAttempt"], "2")
        self.assertEqual(entry["producer"]["execution"]["runAttempt"], "1")
        self.assertEqual(entry["artifactID"], "101")
        self.assertEqual(entry["artifactDigest"], "sha256:" + "e" * 64)
        self.assertEqual(self.client.queries, ["1"])
        # A resolver's job ID differs from the consumer but every other execution fact is current.
        selection["execution"]["jobID"] = "resolve"
        self.validate(selection)

    def test_explicit_matrix_reconciles_every_component_and_rejects_missing_or_duplicate(self):
        matrix = {"include": [{"platform": "linux-x64", "component": "root", "jobs": 64},
                               {"platform": "linux-x64", "component": "macros", "jobs": 64}]}
        with self.assertRaisesRegex(ValueError, "missing successful.*macros"):
            self.resolve(matrix)
        self.add_producer(component="macros", artifact_id="102", receipt_id="202")
        selection = self.resolve(matrix)
        self.assertEqual(selection["expectedComponents"], ["macros", "root"])
        self.assertEqual(set(selection["components"]), {"macros", "root"})
        for invalid in ([], ["root", "root"], ["root", "../other"],
                        {"include": [{"platform": "macos-arm64", "component": "root"}]}):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                index.expected_components(invalid, "linux-x64")

    def test_latest_successful_attempt_wins_and_ambiguous_same_attempt_ids_fail(self):
        self.add_producer(attempt="2", artifact_id="102", receipt_id="202")
        self.assertEqual(self.resolve()["components"]["root"]["artifactID"], "102")
        self.add_producer(attempt="2", artifact_id="103", receipt_id="203", upload_attempt=2)
        with self.assertRaisesRegex(ValueError, "ambiguous immutable"):
            self.resolve()

    def test_duplicate_receipt_transfers_collapse_only_an_identical_reference(self):
        first = self.client.receipts["201"][1]
        second = self.api_artifact("202", self.client.artifacts[1]["name"][:-1] + "2", "sha256:" + "2" * 64)
        self.client.receipts["202"] = (second["digest"], copy.deepcopy(first))
        self.assertEqual(self.resolve()["components"]["root"]["receiptArtifactID"], "201")
        self.client.receipts["202"][1]["artifact"]["archiveSHA256"] = "3" * 64
        with self.assertRaisesRegex(ValueError, "ambiguous immutable"):
            self.resolve()

    def test_unsuccessful_new_build_cannot_replace_successful_producer(self):
        self.add_producer(attempt="2", artifact_id="102", receipt_id="202")
        self.client.jobs["2"][0]["conclusion"] = "failure"
        self.assertEqual(self.resolve()["components"]["root"]["artifactID"], "101")
        self.client.jobs["1"][0]["conclusion"] = "failure"
        with self.assertRaisesRegex(ValueError, "missing successful"):
            self.resolve()

    def test_expired_older_attempt_does_not_poison_an_explicit_fresh_build(self):
        self.add_producer(attempt="2", artifact_id="102", receipt_id="202")
        self.client.artifacts[0]["expired"] = True
        self.client.artifacts[1]["expired"] = True
        self.assertEqual(self.resolve()["components"]["root"]["artifactID"], "102")

    def test_missing_expired_corrupt_and_wrong_source_api_artifacts_fail_closed(self):
        original = copy.deepcopy(self.client.artifacts)
        for field, value in (("expired", True), ("digest", None), ("digest", "sha256:" + "0" * 64),
                             ("workflow_run", {"id": 43})):
            self.client.artifacts = copy.deepcopy(original)
            self.client.artifacts[0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.resolve()
        self.client.artifacts = original[1:]
        with self.assertRaisesRegex(ValueError, "missing.*fresh build"):
            self.resolve()

    def test_producer_scope_future_attempt_and_v1_metadata_are_rejected(self):
        envelope = self.client.receipts["201"][1]
        original = copy.deepcopy(envelope)
        for key, value in (("runID", "43"), ("workflowSHA", "0" * 40), ("jobID", "audit"),
                           ("event", "workflow_dispatch"), ("runAttempt", "3")):
            envelope.clear()
            envelope.update(copy.deepcopy(original))
            envelope["metadata"]["producer"]["execution"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.resolve()
        envelope.clear()
        envelope.update(copy.deepcopy(original))
        envelope["metadata"]["formatVersion"] = 1
        with self.assertRaisesRegex(ValueError, "version"):
            self.resolve()

    def test_api_workflow_and_job_scope_are_independently_verified(self):
        self.client.run["path"] = ".github/workflows/other.yml"
        with self.assertRaisesRegex(ValueError, "workflow run"):
            self.resolve()
        self.client.run["path"] = ".github/workflows/ci.yml"
        self.client.jobs["1"].append(copy.deepcopy(self.client.jobs["1"][0]))
        with self.assertRaisesRegex(ValueError, "ambiguous.*producer job"):
            self.resolve()

    def test_boolean_api_ids_and_noninteger_schema_versions_are_not_admitted(self):
        for invalid in (True, False, 1.0, "0", "-1"):
            with self.subTest(value=invalid):
                self.assertFalse(index.positive_id(invalid))
        self.client.artifacts[0]["id"] = True
        with self.assertRaisesRegex(ValueError, "artifact listing"):
            self.resolve()
        self.client.artifacts[0]["id"] = 101
        self.client.receipts["201"][1]["formatVersion"] = True
        with self.assertRaisesRegex(ValueError, "version"):
            self.resolve()

    def test_current_attempt_index_binding_and_downloaded_digest_are_mandatory(self):
        selection = self.resolve()
        for field, value in (("runAttempt", "1"), ("workflowSHA", "0" * 40), ("runID", "43")):
            changed = copy.deepcopy(selection)
            changed["execution"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.validate(changed)
        with self.assertRaisesRegex(ValueError, "digest.*differs"):
            index.validate_selection(selection, execution=self.execution, component="root", platform="linux-x64",
                                     archive_sha256="0" * 64, metadata=selection["components"]["root"]["metadata"])
        changed = copy.deepcopy(selection["components"]["root"]["metadata"])
        changed["payloadSHA256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "metadata differs"):
            index.validate_selection(selection, execution=self.execution, component="root", platform="linux-x64",
                                     archive_sha256="1" * 64, metadata=changed)

    def test_edited_incomplete_or_unknown_selection_fields_fail_closed(self):
        selection = self.resolve()
        for edit in (lambda value: value["components"]["root"].update(artifactID="mutable-name"),
                     lambda value: value["components"]["root"].update(artifactDigest="0" * 64),
                     lambda value: value.update(expectedComponents=["root", "macros"]),
                     lambda value: value.update(requiredNewIdentity="unsupported"),
                     lambda value: value["components"]["root"]["producer"].update(compilation="failed")):
            changed = copy.deepcopy(selection)
            edit(changed)
            with self.subTest(edit=edit), self.assertRaises(ValueError):
                self.validate(changed)

    def test_pull_request_api_head_and_checked_out_merge_source_remain_separate(self):
        self.execution.update(event="pull_request", ref="refs/pull/15/merge", headRef="feature", baseRef="main")
        self.client.run.update(event="pull_request", head_sha="2" * 40, head_repository={"id": 456})
        for artifact in self.client.artifacts:
            artifact["workflow_run"].update(head_sha="2" * 40, head_repository_id=456)
        self.client.jobs["1"][0]["head_sha"] = "2" * 40
        producer_execution = self.client.receipts["201"][1]["metadata"]["producer"]["execution"]
        producer_execution.update(event="pull_request", ref="refs/pull/15/merge", headRef="feature", baseRef="main")
        self.assertEqual(self.resolve()["sourceCommit"], "a" * 40)
        producer_execution.update(event="push", ref="refs/heads/main", headRef="", baseRef="")
        with self.assertRaisesRegex(ValueError, "trust scope"):
            self.resolve()

    def test_resolution_retries_only_transient_failures_at_most_three_times(self):
        attempts = []
        with patch.object(self.client, "get_run", side_effect=transfer.TransferError("network", transient=True)) as request:
            with self.assertRaises(transfer.TransferError):
                index.resolve(self.client, execution=self.execution, platform="linux-x64", components=["root"],
                              source_commit="a" * 40, attempts=attempts)
        self.assertEqual(request.call_count, 3)
        self.assertEqual([entry["classification"] for entry in attempts], ["transient"] * 3)
        attempts.clear()
        self.client.run["event"] = "workflow_dispatch"
        with self.assertRaises(transfer.TransferError):
            index.resolve(self.client, execution=self.execution, platform="linux-x64", components=["root"],
                          source_commit="a" * 40, attempts=attempts)
        self.assertEqual(len(attempts), 1)
        self.assertEqual(attempts[0]["classification"], "permanent")

    def test_whole_resolver_deadline_includes_stalled_metadata_and_receipts(self):
        started = time.monotonic()
        with patch.object(self.client, "get_run", side_effect=lambda: time.sleep(10)):
            with self.assertRaisesRegex(transfer.TransferError, "timed out|deadline"):
                index.resolve(self.client, execution=self.execution, platform="linux-x64", components=["root"],
                              source_commit="a" * 40, budget=transfer.Budget(0.03))
        self.assertLess(time.monotonic() - started, 0.5)

    def test_cli_retains_terminal_failure_evidence_and_no_stale_index(self):
        environment = {"GITHUB_ACTIONS": "true", "GITHUB_REPOSITORY": "aurum/DiscordKit",
                       "GITHUB_REPOSITORY_ID": "123", "GITHUB_WORKFLOW_REF": self.execution["workflowRef"],
                       "GITHUB_WORKFLOW_SHA": "a" * 40, "GITHUB_RUN_ID": "42", "GITHUB_RUN_ATTEMPT": "2",
                       "GITHUB_JOB": "tests", "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main",
                       "GITHUB_SHA": "a" * 40, "GH_TOKEN": "fixture"}
        self.client.run["path"] = ".github/workflows/other.yml"
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "index.json"
            destination.write_text("stale")
            with patch.dict(os.environ, environment, clear=True), patch.object(
                    transfer, "GitHubArtifactClient", return_value=self.client), self.assertRaises(SystemExit) as error:
                index.main(["resolve", "--platform", "linux-x64", "--components-json", '["root"]',
                            "--output", str(destination)])
            self.assertEqual(error.exception.code, 1)
            self.assertFalse(destination.exists())
            report = json.loads(destination.with_suffix(".resolution.json").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertEqual(len(report["attempts"]), 1)
            self.assertIn("workflow run", report["error"])


if __name__ == "__main__":
    unittest.main()
