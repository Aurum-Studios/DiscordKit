# File: Tools/ci/test_qualification_fault.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Exercise bounded fault injection after real orchestration with synthetic native children."""

from contextlib import ExitStack, redirect_stderr, redirect_stdout
import copy
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import native_jobs as jobs
import native_receipts as receipts
import qualification_fault as fault
from test_test_results import definition, event


class QualificationSelectionTests(unittest.TestCase):
    def selection(self, **changes):
        return fault.validate_selection(enabled=True, **{**fault.SCOPE, **changes})

    def test_only_explicit_boolean_enables_the_exact_diagnostic_scope(self):
        self.assertIs(self.selection(), True)
        for enabled in (None, "true", 1, 0, [], {}):
            with self.subTest(enabled=enabled), self.assertRaisesRegex(ValueError, "boolean"):
                fault.validate_selection(enabled=enabled, **fault.SCOPE)
        self.assertIs(fault.validate_selection(enabled=False, mode="preflight", platform=None,
            component=None, suite=None, publication=False), False)
        for field, value in (("mode", "full"), ("mode", "preflight"), ("platform", "macos-arm64"),
                ("component", "load"), ("suite", "DiscordMLSTests"), ("suite", None),
                ("publication", True), ("publication", 0)):
            with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, "requires diagnostic"):
                self.selection(**{field: value})


class QualificationFaultTests(unittest.TestCase):
    """Actual native_jobs emits receipts; no native subprocess or network operation executes."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repository = Path(self.temporary.name) / "checkout"
        self.repository.mkdir()
        self.output = Path(self.temporary.name) / "consumer"
        self.marker = self.output / "qualification-fault.json"
        self.commit = "a" * 40
        self.environment = {"GITHUB_ACTIONS": "true", "GITHUB_REPOSITORY": "aurum/DiscordKit",
            "GITHUB_REPOSITORY_ID": "123", "GITHUB_WORKFLOW_REF":
            "aurum/DiscordKit/.github/workflows/ci.yml@refs/heads/main", "GITHUB_WORKFLOW_SHA": self.commit,
            "GITHUB_RUN_ID": "42", "GITHUB_RUN_ATTEMPT": "1", "GITHUB_JOB": "tests-root",
            "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": self.commit,
            "ADMISSION_MODE": "diagnostic", "ADMISSION_PLATFORM": "linux-x64", "ADMISSION_COMPONENT": "root",
            "ADMISSION_SUITE": "DiscordBitsTests", "ADMISSION_PUBLICATION": "false",
            "ADMISSION_QUALIFICATION_FAULT": "true"}
        self.environment_patch = patch.dict(os.environ, self.environment, clear=True)
        self.environment_patch.start()
        self.addCleanup(self.environment_patch.stop)
        self.execution = receipts.execution_identity(self.repository)
        self.bits = ["DiscordBitsTests.Bits/check()", "DiscordBitsTests.Bits/other()"]
        inventory = {".": {"DiscordBitsTests": self.bits, "OtherTests": ["OtherTests.Suite/check()"]}}
        compatibility = {"identity": {"commit": self.commit, "sourceSHA256": "b" * 64,
            "dependencyPinsSHA256": {"Package.resolved": "c" * 64}, "repository": str(self.repository),
            "platform": "linux-x64", "system": "Linux", "machine": "x64", "swiftVersion": "Swift 6.4.1",
            "swiftTarget": "x86_64-unknown-linux-gnu", "buildSystem": "native", "runtime": {"fixture": True},
            "buildEnvironment": {}}, "build": {"testPackages": ["."], "testExclusions": {}}}
        self.metadata = {"formatVersion": 2, "status": "passed", "component": "root",
            "compatibility": compatibility, "producer": receipts.producer_receipt(
                {**self.execution, "jobID": "build-core"}, inventory), "tests": inventory,
            "buildRoots": [".build"], "payloadSHA256": "d" * 64}
        self.commands = []
        self.produce()

    def produce(self):
        """Drive real group and consumer receipt generation, mocking transport and child execution only."""
        self.execution = receipts.execution_identity(self.repository)
        producer = self.metadata["producer"]
        selection = {"formatVersion": 1, "execution": copy.deepcopy(self.execution), "sourceCommit": self.commit,
            "platform": "linux-x64", "expectedComponents": ["root"], "components": {"root": {
                "artifactID": "9001", "artifactDigest": "sha256:" + "f" * 64, "archiveSHA256": "e" * 64,
                "artifactName": f"compiled-linux-x64-root-{self.commit}-42-{producer['execution']['runAttempt']}-t1",
                "producer": copy.deepcopy(producer), "metadata": copy.deepcopy(self.metadata), "receiptArtifactID": "9002"}}}

        def restore(repository, component, platform, archive, output, **options):
            consumer = receipts.consumer_receipt(self.execution, producer, "e" * 64,
                selection=selection, metadata=self.metadata)
            jobs.write_json(output / "restored.json", {**self.metadata, "archiveSHA256": "e" * 64,
                                                       "consumer": consumer})
            return copy.deepcopy(self.metadata)

        def execute(command, repository, log, *, stdout_log=None, deadline=None):
            self.assertIsNotNone(deadline)
            self.commands.append(command.arguments)
            log.write_text("synthetic native child\n")
            if "list" in command.arguments:
                stdout_log.write_text("\n".join(leaf for leaves in self.metadata["tests"]["."].values() for leaf in leaves))
            elif "--event-stream-output-path" in command.arguments:
                records = [definition(leaf) for leaf in self.bits] + [event("runStarted")]
                for leaf in self.bits:
                    records.extend((event("testStarted", leaf), event("testEnded", leaf)))
                records.append(event("runEnded"))
                path = Path(command.arguments[command.arguments.index("--event-stream-output-path") + 1])
                path.write_text("".join(json.dumps(record) + "\n" for record in records))
            elif command.arguments[:2] == ("git", "rev-parse"):
                stdout_log.write_text(self.commit + "\n")
            else:
                self.fail(f"unexpected child command {command.arguments}")
            return {"status": "passed", "returnCode": 0}

        def identity(repository, component, platform, **options):
            # Real final identity commands are appended after the suite commands.
            jobs.metadata_output(["git", "rev-parse", "HEAD"], repository, **options)
            return copy.deepcopy(self.metadata["compatibility"])

        with ExitStack() as stack:
            stack.enter_context(patch.object(jobs, "restore_archive", side_effect=restore))
            stack.enter_context(patch.object(jobs, "compatibility_identity", side_effect=identity))
            stack.enter_context(patch.object(jobs.native_resources, "compiler_admission", return_value={"jobs": 2}))
            stack.enter_context(patch.object(jobs.linux_ci, "execute", side_effect=execute))
            stack.enter_context(patch.object(jobs.linux_ci, "_console_write"))
            jobs.run_tests(self.repository, "root", "DiscordBitsTests", "linux-x64", 2,
                self.output, self.repository / "compiled.tar.gz", suites=["DiscordBitsTests"])

    def invoke(self):
        output, errors = io.StringIO(), io.StringIO()
        with redirect_stdout(output), redirect_stderr(errors):
            code = fault.main(["--repository", str(self.repository), "--consumer", str(self.output),
                               "--output", str(self.marker)])
        return code, output.getvalue() + errors.getvalue()

    def change(self, filename, mutate):
        path = self.output / filename
        value = json.loads(path.read_text())
        mutate(value)
        jobs.write_json(path, value)

    def test_first_attempt_fails_only_after_completed_actual_suite_and_writes_proof(self):
        code, output = self.invoke()
        self.assertEqual(code, 1)
        self.assertIn("Intentional first-attempt", output)
        marker = json.loads(self.marker.read_text())
        self.assertEqual(marker["status"], "intentional-failure")
        self.assertIs(marker["intentionalFailure"], True)
        self.assertEqual(marker["execution"], self.execution)
        self.assertEqual(marker["scope"], fault.SCOPE)
        self.assertEqual(marker["consumerSHA256"], receipts.digest(json.loads((self.output / "consumer.json").read_text())))
        self.assertEqual(len(self.commands), 3)
        self.assertEqual(self.commands[0][:2], ("swift", "test"))
        self.assertTrue(all("build" not in command for command in self.commands))

    def test_rerun_requires_new_complete_tests_and_reuses_first_attempt_producer(self):
        os.environ["GITHUB_RUN_ATTEMPT"] = "2"
        self.assertEqual(self.invoke()[0], 2)
        self.assertFalse(self.marker.exists())
        self.produce()
        code, output = self.invoke()
        self.assertEqual(code, 0, output)
        marker = json.loads(self.marker.read_text())
        self.assertEqual(marker["status"], "passed")
        self.assertIs(marker["intentionalFailure"], False)
        self.assertEqual(marker["execution"]["runAttempt"], "2")
        self.assertEqual(marker["producerExecution"]["runAttempt"], "1")
        self.assertEqual(len(self.commands), 6)

    def test_missing_incomplete_corrupt_foreign_and_stale_receipts_never_count_as_injection(self):
        originals = {name: (self.output / name).read_bytes() for name in
                     ("consumer.json", "group-coverage.json", "restored.json")}
        mutations = {
            "failed-consumer": ("consumer.json", lambda v: v.update(status="failed")),
            "pending-discovery": ("consumer.json", lambda v: v.update(discovery="pending")),
            "unverified-compatibility": ("consumer.json", lambda v: v.update(compatibilityVerified=False)),
            "missing-completed": ("consumer.json", lambda v: v.pop("completedAt")),
            "stale-consumer": ("consumer.json", lambda v: v["execution"].update(runAttempt="2")),
            "foreign-run": ("consumer.json", lambda v: v["execution"].update(runID="43")),
            "failed-command": ("consumer.json", lambda v: v["executionResults"][1].update(status="failed")),
            "missing-tests": ("consumer.json", lambda v: v.update(executionResults=v["executionResults"][:1])),
            "wrong-filter": ("consumer.json", lambda v: v["executionResults"][1]["arguments"].append("--filter")),
            "unexpected-build": ("consumer.json", lambda v: v["executionResults"][2].update(operation="coldCompileCommand")),
            "failed-group": ("group-coverage.json", lambda v: v.update(status="failed")),
            "stale-group": ("group-coverage.json", lambda v: v["execution"].update(runAttempt="2")),
            "different-group-id": ("group-coverage.json", lambda v: v.update(suite="root-01")),
            "extra-suite": ("group-coverage.json", lambda v: v["suites"].append("OtherTests")),
            "missing-leaf": ("group-coverage.json", lambda v: v["executedLeaves"].pop()),
            "skipped-leaf": ("group-coverage.json", lambda v: v["suiteResults"][0]["result"]["leaves"][self.bits[0]].update(outcome="skipped")),
            "different-source": ("group-coverage.json", lambda v: v.update(sourceCommit="b" * 40)),
            "different-producer": ("restored.json", lambda v: v["producer"]["execution"].update(runID="43")),
            "future-producer": ("restored.json", lambda v: v["producer"]["execution"].update(runAttempt="2")),
            "local-artifact": ("consumer.json", lambda v: v["artifact"].update(idSource="local-content-address")),
            "stale-selection": ("consumer.json", lambda v: v["selection"]["resolverExecution"].update(runAttempt="2")),
            "wrong-inventory": ("consumer.json", lambda v: v.update(inventorySHA256="0" * 64)),
        }
        for name, (filename, mutate) in mutations.items():
            with self.subTest(fault=name):
                self.change(filename, mutate)
                self.marker.write_text('{"status":"passed"}')
                code, output = self.invoke()
                self.assertEqual(code, 2, output)
                self.assertNotIn("Intentional first-attempt", output)
                self.assertFalse(self.marker.exists())
                for path, content in originals.items():
                    (self.output / path).write_bytes(content)
        for filename in originals:
            with self.subTest(missing=filename):
                (self.output / filename).unlink()
                self.assertEqual(self.invoke()[0], 2)
                self.assertFalse(self.marker.exists())
                (self.output / filename).write_bytes(originals[filename])
        for text in ('{"status":"passed","status":"failed"}', '{"number":NaN}', '{'):
            with self.subTest(corrupt=text):
                (self.output / "consumer.json").write_text(text)
                self.assertEqual(self.invoke()[0], 2)
                self.assertFalse(self.marker.exists())

    def test_disabled_or_invalid_scope_and_incomplete_hosted_environment_remove_stale_marker(self):
        changes = (("ADMISSION_QUALIFICATION_FAULT", "false"), ("ADMISSION_QUALIFICATION_FAULT", "1"),
                   ("ADMISSION_MODE", "full"), ("ADMISSION_PUBLICATION", "true"),
                   ("ADMISSION_PLATFORM", "macos-arm64"), ("GITHUB_JOB", "build-core"),
                   ("GITHUB_RUN_ATTEMPT", "0"), ("GITHUB_REPOSITORY_ID", ""), ("GITHUB_SHA", "b" * 40))
        for key, value in changes:
            with self.subTest(environment=key), patch.dict(os.environ, {key: value}):
                self.marker.write_text('{"status":"passed"}')
                code, output = self.invoke()
                self.assertEqual(code, 2, output)
                self.assertFalse(self.marker.exists())
        with patch.dict(os.environ, {key: value for key, value in self.environment.items()
                        if not key.startswith("GITHUB_")}, clear=True):
            self.assertEqual(self.invoke()[0], 2)

    def test_marker_cannot_overwrite_native_receipts_and_bounded_reads_reject_oversize(self):
        for filename in ("consumer.json", "group-coverage.json", "restored.json", "commands.json"):
            with self.subTest(filename=filename), redirect_stderr(io.StringIO()):
                path = self.output / filename
                original = path.read_bytes()
                code = fault.main(["--consumer", str(self.output), "--output", str(path)])
                self.assertEqual(code, 2)
                self.assertEqual(path.read_bytes(), original)
        with patch.object(fault, "MAX_RECEIPT_BYTES", 1):
            self.assertEqual(self.invoke()[0], 2)
            self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main()
