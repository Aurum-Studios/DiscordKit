# File: Tools/ci/test_native_receipts.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Reject incomplete provenance and keep consumer identity separate from producer compatibility."""

import copy
import io
import os
from pathlib import Path
import unittest
from unittest.mock import patch

import native_receipts as receipts


class NativeReceiptTrustTests(unittest.TestCase):
    """Exercise hosted provenance with valid but differently scoped execution identities."""

    def setUp(self):
        self.environment = {"GITHUB_ACTIONS": "true", "GITHUB_REPOSITORY": "aurum/DiscordKit",
                            "GITHUB_REPOSITORY_ID": "123", "GITHUB_WORKFLOW_REF":
                            "aurum/DiscordKit/.github/workflows/native-platform.yml@refs/heads/main",
                            "GITHUB_WORKFLOW_SHA": "a" * 40, "GITHUB_RUN_ID": "42",
                            "GITHUB_RUN_ATTEMPT": "2", "GITHUB_JOB": "compile",
                            "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main"}
        with patch.dict(os.environ, self.environment, clear=True):
            self.producer_execution = receipts.execution_identity(Path.cwd())
        self.compatibility = {"identity": {"commit": "a" * 40, "sourceSHA256": "b" * 64,
            "dependencyPinsSHA256": {"Package.resolved": "c" * 64}, "repository": str(Path.cwd()),
            "platform": "linux-x64", "system": "Linux", "machine": "x64",
            "swiftVersion": "Swift version 6.4.1", "swiftTarget": "x86_64-unknown-linux-gnu",
            "buildSystem": "native", "runtime": {"requiredRuntime": "fixture"}, "buildEnvironment": {}},
            "build": {"testPackages": ["."]}}
        tests = {".": {"CoreTests": ["CoreTests.Suite/test()"]}}
        self.metadata = {"formatVersion": 2, "status": "passed", "component": "root",
                         "compatibility": self.compatibility, "producer": receipts.producer_receipt(
                             self.producer_execution, tests, startedAt="2000-01-01T00:00:00Z"),
                         "tests": tests, "buildRoots": [".build"], "payloadSHA256": "d" * 64}

    def validate(self, execution):
        receipts.validate_metadata(self.metadata, self.compatibility, execution, "root", [".build"])

    def test_consumer_owns_its_job_and_retains_selected_producer_and_artifact(self):
        """The build job's provenance survives while the independent suite records its own identity."""
        consumer_execution = {**self.producer_execution, "jobID": "test_CoreTests"}
        self.validate(consumer_execution)
        consumer = receipts.consumer_receipt(consumer_execution, self.metadata["producer"], "e" * 64, "9001")
        self.assertEqual(consumer["execution"], consumer_execution)
        self.assertEqual(consumer["selectedProducer"], self.producer_execution)
        self.assertNotEqual(consumer["execution"]["jobID"], consumer["selectedProducer"]["jobID"])
        self.assertEqual(consumer["selectedProducer"]["runAttempt"], "2")
        self.assertEqual(consumer["artifact"]["id"], "9001")
        self.assertEqual(consumer["artifact"]["archiveSHA256"], "e" * 64)
        self.assertTrue(consumer["compatibilityVerified"])
        self.assertEqual(consumer["discovery"], "pending")
        self.assertNotIn("runAttempt", self.compatibility["identity"])
        self.assertNotIn("runID", self.compatibility["identity"])

    def test_default_admission_rejects_other_valid_attempts_runs_and_trust_scopes(self):
        """Phase 4 defines the new receipt without enabling Phase 5 reuse across successful attempts."""
        for field, value in (("runAttempt", "1"), ("runAttempt", "3"), ("runID", "43"),
                             ("repositoryID", "124"), ("workflowSHA", "f" * 40),
                             ("workflowRef", "aurum/DiscordKit/.github/workflows/other.yml@refs/heads/main"),
                             ("event", "workflow_dispatch"), ("ref", "refs/heads/other")):
            consumer_execution = {**self.producer_execution, "jobID": "test", field: value}
            receipts.validate_execution(consumer_execution)
            with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, "attempt|workflow|repository"):
                self.validate(consumer_execution)

    def test_incomplete_hosted_environment_never_falls_back_to_local_scope(self):
        """Every required hosted identifier must be observed; partial GitHub assignment is an error."""
        required = ("GITHUB_REPOSITORY", "GITHUB_REPOSITORY_ID", "GITHUB_WORKFLOW_REF", "GITHUB_WORKFLOW_SHA",
                    "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_JOB", "GITHUB_EVENT_NAME", "GITHUB_REF")
        for field in required:
            environment = {key: value for key, value in self.environment.items() if key != field}
            with self.subTest(missing=field), patch.dict(os.environ, environment, clear=True), self.assertRaises(ValueError):
                receipts.execution_identity(Path.cwd())
        with patch.dict(os.environ, {"GITHUB_RUN_ID": "42"}, clear=True), self.assertRaises(ValueError):
            receipts.execution_identity(Path.cwd())
        with patch.dict(os.environ, {}, clear=True):
            local = receipts.execution_identity(Path.cwd())
        self.assertEqual(local["scope"], "local")
        self.assertEqual(local["repository"], str(Path.cwd().resolve()))

    def test_pull_request_scope_requires_merge_ref_and_both_branch_names(self):
        """Pull-request identity cannot be replaced with a push or a partially specified trust scope."""
        execution = {**self.producer_execution, "event": "pull_request", "ref": "refs/pull/15/merge",
                     "headRef": "ci/phase4", "baseRef": "main"}
        receipts.validate_execution(execution)
        for field, value in (("ref", "refs/heads/main"), ("headRef", ""), ("baseRef", ""),
                             ("event", "pull_request_target")):
            with self.subTest(field=field), self.assertRaises(ValueError):
                receipts.validate_execution({**execution, field: value})
        self.metadata["producer"]["execution"] = execution
        with self.assertRaises(ValueError):
            self.validate(self.producer_execution)

    def test_unknown_required_execution_fields_and_malformed_ids_fail_closed(self):
        """Schema extensions and invalid immutable identifiers require deliberate support."""
        unknown = {**self.producer_execution, "requiredNewTrustField": "unknown"}
        with self.assertRaisesRegex(ValueError, "fields"):
            receipts.validate_execution(unknown)
        for field, value in (("runID", "0"), ("runAttempt", "-1"), ("repositoryID", "unknown"),
                             ("workflowSHA", "a" * 39), ("jobID", "suite/other"),
                             ("workflowRef", "foreign/DiscordKit/.github/workflows/ci.yml@refs/heads/main")):
            with self.subTest(field=field), self.assertRaises(ValueError):
                receipts.validate_execution({**self.producer_execution, field: value})
        for artifact_id in ("", "0", "-1", "mutable-name", "1.0"):
            with self.subTest(artifact_id=artifact_id), self.assertRaises(ValueError):
                receipts.consumer_receipt(self.producer_execution, self.metadata["producer"], "e" * 64, artifact_id)

    def test_components_without_test_packages_record_discovery_as_not_applicable(self):
        """Release graphs carry an empty inventory only when their exact build profile has no test packages."""
        compatibility = copy.deepcopy(self.compatibility)
        compatibility["build"]["testPackages"] = []
        metadata = copy.deepcopy(self.metadata)
        metadata.update(component="release", compatibility=compatibility, tests={},
                        producer=receipts.producer_receipt(self.producer_execution, {}))
        self.assertEqual(metadata["producer"]["discovery"], "not-applicable")
        receipts.validate_metadata(metadata, compatibility, self.producer_execution, "release", [".build"])
        for discovery in ("passed", "failed", "pending"):
            metadata["producer"]["discovery"] = discovery
            with self.subTest(discovery=discovery), self.assertRaises(ValueError):
                receipts.validate_metadata(metadata, compatibility, self.producer_execution, "release", [".build"])
        metadata["producer"]["discovery"] = "not-applicable"
        compatibility["build"]["testPackages"] = ["."]
        with self.assertRaises(ValueError):
            receipts.validate_metadata(metadata, compatibility, self.producer_execution, "release", [".build"])

    def test_receipt_json_rejects_duplicate_keys_and_nonfinite_numbers(self):
        """A parser must reject ambiguous identity facts before schema validation selects a value."""
        for document in ('{"formatVersion":1,"formatVersion":2}', '{"identity":{"commit":"a","commit":"b"}}',
                         '{"required":NaN}', '{"required":Infinity}', '{"required":-Infinity}'):
            with self.subTest(document=document), self.assertRaises(ValueError):
                receipts.read_json(io.StringIO(document))
        self.assertEqual(receipts.read_json(io.StringIO('{"formatVersion":2}')), {"formatVersion": 2})


if __name__ == "__main__":
    unittest.main()
