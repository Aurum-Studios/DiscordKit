# File: Tools/ci/test_native_groups.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Exercise real grouped orchestration and leaf parsing with synthetic native children.

Only archive/host identity and subprocess transport are mocked. No Swift build,
native test process, network access, or hosted qualification occurs here.
"""

from contextlib import ExitStack
import copy
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import native_jobs as jobs
import native_receipts as receipts
import test_results
from test_test_results import definition, event
import workflow_coverage


COMMIT = "a" * 40
ORACLE = "DiscordMLSTests.MLSNativeDAVEInteropTests/initialCandidateAcceptedByMLSpp(_:)"


class NativeGroupOrchestrationTests(unittest.TestCase):
    """Bounded whole-suite processes retain exact inventory and explicit failures."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repository = Path(self.temporary.name) / "repository"
        self.repository.mkdir()
        self.output = Path(self.temporary.name) / "result"
        self.execution = {"scope": "github", "repository": "aurum/DiscordKit", "repositoryID": "123",
            "workflowRef": "aurum/DiscordKit/.github/workflows/ci.yml@refs/heads/main",
            "workflowSHA": COMMIT, "runID": "42", "runAttempt": "2", "jobID": "test-core",
            "event": "push", "ref": "refs/heads/main", "headRef": "", "baseRef": ""}
        self.commands = []
        self.restore_calls = []
        self.fail_suite = None
        self.event_faults = {}
        self.discovery_fault = None
        self.component = "root"
        inventory = {f"{letter}Tests": [f"{letter}Tests.Suite/check()"] for letter in "ABCDEFGHIJKLMNOP"}
        self.configure({".": inventory})
        self.group = jobs.suite_groups.root_groups(sorted(inventory), "linux-x64")[0]
        self.suite = self.group["suite"]
        self.suites = self.group["suites"]

    def configure(self, tests, exclusions=None):
        self.metadata = {"tests": tests, "compatibility": {"identity": {"commit": COMMIT},
            "build": {"testExclusions": exclusions or {}}},
            "producer": receipts.producer_receipt({**self.execution, "jobID": "build-core"}, tests)}

    def restore(self, repository, component, platform, archive, output, *, selection=None):
        self.restore_calls.append((repository, component, platform, archive, selection))
        jobs.write_json(output / "restored.json", {"consumer": {
            "execution": copy.deepcopy(self.execution), "discovery": "pending", "status": "running"}})
        return copy.deepcopy(self.metadata)

    def records(self, leaves, exclusions):
        records = [definition(leaf, parameterized=":" in leaf) for leaf in leaves]
        records.append(event("runStarted"))
        for leaf in leaves:
            if leaf in exclusions:
                records.append(event("testSkipped", leaf))
                continue
            records.append(event("testStarted", leaf))
            if ":" in leaf:
                records.extend([event("testCaseStarted", leaf, iteration=1),
                                event("testCaseEnded", leaf, iteration=1)])
            records.append(event("testEnded", leaf))
        records.append(event("runEnded"))
        return records

    def execute(self, command, repository, log, *, stdout_log=None, deadline=None):
        self.commands.append(command)
        self.assertIsNotNone(deadline)
        self.assertGreater(command.timeout, 0)
        log.write_text("synthetic subprocess output\n")
        arguments = command.arguments
        package = arguments[arguments.index("--package-path") + 1]
        if arguments[:2] == ("swift", "test") and "list" in arguments:
            self.assertIsNotNone(stdout_log)
            self.assertNotIn("--event-stream-output-path", arguments)
            inventory = self.metadata["tests"][package]
            leaves = [leaf for module in inventory.values() for leaf in module]
            stdout_log.write_text(self.discovery_fault if self.discovery_fault is not None
                                  else "\n".join(leaves) + "\n")
        elif arguments[:2] == ("swift", "test"):
            suite = command.name.removesuffix("-tests")
            if suite == self.fail_suite:
                raise subprocess.CalledProcessError(1, arguments)
            inventory = self.metadata["tests"][package]
            leaves = inventory[suite] if self.component == "root" else [
                leaf for module in inventory.values() for leaf in module]
            exclusions = self.metadata["compatibility"]["build"]["testExclusions"].get(package, {})
            records = self.records(leaves, exclusions)
            fault = self.event_faults.get(suite)
            if fault == "wrong-filter":
                records = self.records(["UnselectedTests.Suite/check()"], {})
            elif fault == "zero-execution":
                records = [event("runStarted"), event("runEnded")]
            elif fault == "unexpected-skip":
                records = [definition(leaves[0]), event("runStarted"), event("testSkipped", leaves[0]), event("runEnded")]
            elif fault == "duplicate":
                records[-1:-1] = [event("testStarted", leaves[0]), event("testEnded", leaves[0])]
            elif fault == "execute-exclusion":
                records = self.records(leaves, {})
            destination = Path(arguments[arguments.index("--event-stream-output-path") + 1])
            self.assertTrue(destination.is_absolute())
            self.assertEqual(arguments[arguments.index("--event-stream-version") + 1], "6.4")
            destination.write_text("".join(json.dumps(record) + "\n" for record in records))
        else:
            self.assertEqual(arguments[:2], ("swift", "run"))
            self.assertIn("--skip-build", arguments)
            self.assertNotIn("--event-stream-output-path", arguments)
        return {"status": "passed", "returnCode": 0}

    def run_group(self):
        with ExitStack() as stack:
            stack.enter_context(patch.object(jobs, "restore_archive", side_effect=self.restore))
            stack.enter_context(patch.object(jobs, "compatibility_identity", return_value=self.metadata["compatibility"]))
            stack.enter_context(patch.object(jobs.receipts, "execution_identity", return_value=self.execution))
            stack.enter_context(patch.object(jobs.native_resources, "compiler_admission", return_value={"jobs": 2}))
            stack.enter_context(patch.object(jobs.linux_ci, "execute", side_effect=self.execute))
            stack.enter_context(patch.object(jobs.linux_ci, "_console_write"))
            return jobs.run_tests(self.repository, self.component, self.suite, "linux-x64", 8,
                                  self.output, self.repository / "compiled.tar.gz", suites=self.suites)

    def coverage(self):
        return json.loads((self.output / "group-coverage.json").read_text())

    def runtime_commands(self):
        return [command for command in self.commands if command.arguments[:2] == ("swift", "test")
                and "list" not in command.arguments]

    def validate_coverage(self):
        value = self.coverage()
        scope = {"component": self.component, "suite": self.suite, "suites": self.suites,
                 "platform": "linux-x64", "jobID": "test-core"}
        return workflow_coverage.validate_group_receipt(value, scope=scope, manifest={"commit": COMMIT},
            metadata=self.metadata, execution={**self.execution, "jobID": "complete"}, job_attempt="2")

    def test_root_restores_and_discovers_once_then_executes_every_anchored_module(self):
        report = self.run_group()
        self.assertEqual(report["status"], "passed")
        self.assertEqual(len(self.restore_calls), 1)
        discovery = [command for command in self.commands if "list" in command.arguments]
        self.assertEqual(len(discovery), 1)
        self.assertEqual(len(self.runtime_commands()), len(self.suites))
        for command, suite in zip(self.runtime_commands(), self.suites):
            arguments = command.arguments
            self.assertIn("--skip-build", arguments)
            self.assertIn("--no-parallel", arguments)
            self.assertEqual(arguments[arguments.index("--filter") + 1], "^" + re.escape(suite) + "[./]")
            self.assertEqual(arguments[arguments.index("--jobs") + 1], "2")
        coverage = self.validate_coverage()
        self.assertEqual(coverage["status"], "passed")
        self.assertEqual(coverage["expectedLeaves"], coverage["executedLeaves"])
        self.assertEqual(len(coverage["expectedLeaves"]), len(self.suites))
        for row in coverage["suiteResults"]:
            self.assertEqual(row["status"], "passed")
            self.assertEqual(row["result"]["counts"]["executed"], 1)
            self.assertEqual(row["result"]["eventStreamVersion"], test_results.EVENT_STREAM_VERSION)
        persisted = json.loads((self.output / "commands.json").read_text())
        self.assertEqual(persisted["consumer"]["discovery"], "passed")
        self.assertTrue(all((self.output / record["log"]).is_file() for record in persisted["commands"]))

    def test_first_and_middle_process_failures_keep_remaining_suites_explicitly_not_run(self):
        for index in (0, 1):
            with self.subTest(failing_index=index):
                self.output = Path(self.temporary.name) / f"failure-{index}"
                self.commands.clear()
                self.fail_suite = self.suites[index]
                with self.assertRaises(subprocess.CalledProcessError):
                    self.run_group()
                rows = self.coverage()["suiteResults"]
                self.assertEqual([row["status"] for row in rows],
                    ["passed"] * index + ["failed"] + ["not-run"] * (len(self.suites) - index - 1))
                self.assertEqual(len(self.runtime_commands()), index + 1)
                self.assertEqual(self.coverage()["status"], "failed")
                with self.assertRaises(ValueError):
                    self.validate_coverage()

    def test_exit_zero_wrong_filter_empty_skip_and_duplicate_events_fail_the_group(self):
        for fault in ("wrong-filter", "zero-execution", "unexpected-skip", "duplicate"):
            with self.subTest(fault=fault):
                self.output = Path(self.temporary.name) / fault
                self.commands.clear()
                self.event_faults = {self.suites[0]: fault}
                with self.assertRaises(ValueError):
                    self.run_group()
                self.assertEqual(self.coverage()["status"], "failed")
                self.assertEqual([row["status"] for row in self.coverage()["suiteResults"]],
                    ["failed"] + ["not-run"] * (len(self.suites) - 1))
                # The child exit receipt succeeds; structured coverage still rejects it.
                persisted = json.loads((self.output / "commands.json").read_text())
                self.assertEqual(persisted["commands"][-1]["execution"]["returnCode"], 0)
                self.assertEqual(persisted["status"], "failed")

    def test_restored_discovery_drift_prevents_any_runtime_suite(self):
        self.discovery_fault = "ATests.Suite/different()\n"
        with self.assertRaises(ValueError):
            self.run_group()
        self.assertFalse(self.runtime_commands())
        self.assertTrue(all(row["status"] == "not-run" for row in self.coverage()["suiteResults"]))
        report = json.loads((self.output / "commands.json").read_text())
        self.assertEqual(report["consumer"]["discovery"], "failed")

    def test_batched_consumers_share_restore_with_separate_package_discovery_tests_and_smokes(self):
        self.component, self.suite, self.suites = "consumers", "consumers", list(jobs.CONSUMER_SUITES)
        tests = {f"Examples/{suite}": {f"{suite}Tests": [f"{suite}Tests.Suite/offline()"]}
                 for suite in jobs.CONSUMER_TESTS}
        self.configure(tests)
        self.run_group()
        self.assertEqual(len(self.restore_calls), 1)
        discovery = [command for command in self.commands if "list" in command.arguments]
        self.assertEqual(len(discovery), 6)
        packages = [command.arguments[command.arguments.index("--package-path") + 1] for command in discovery]
        self.assertEqual(set(packages), set(tests))
        self.assertEqual(len(self.runtime_commands()), 6)
        self.assertEqual(len([command for command in self.commands if command.arguments[:2] == ("swift", "run")]), 7)
        coverage = self.validate_coverage()
        self.assertEqual(len(coverage["suiteResults"]), 8)
        self.assertEqual(len(coverage["executedLeaves"]), 6)
        for row in coverage["suiteResults"]:
            if row["suite"] not in jobs.CONSUMER_TESTS:
                self.assertIsNone(row["result"])
                self.assertEqual(row["executedLeaves"], [])

    def test_declared_opt_in_oracle_exclusion_is_bound_before_execution_and_final_barrier(self):
        declarations = jobs.build_profile("root")["testExclusions"]
        self.configure({".": {"DiscordMLSTests": [
            "DiscordMLSTests.MLSNativeDAVEInteropTests/goldenPayload()", ORACLE]}}, declarations)
        self.suite, self.suites = "DiscordMLSTests", ["DiscordMLSTests"]
        self.run_group()
        coverage = self.validate_coverage()
        self.assertEqual(coverage["excludedLeaves"], {".::" + ORACLE: declarations["."][ORACLE]})
        self.assertEqual(coverage["suiteResults"][0]["result"]["counts"]["excluded"], 1)
        self.assertEqual(len(coverage["expectedLeaves"]), 2)
        self.assertEqual(len(coverage["executedLeaves"]), 1)
        # A postexecution forged exclusion is rejected against the producer declaration.
        forged = copy.deepcopy(self.metadata)
        forged["compatibility"]["build"]["testExclusions"] = {}
        scope = {"component": self.component, "suite": self.suite, "suites": self.suites,
                 "platform": "linux-x64", "jobID": "test-core"}
        with self.assertRaises(ValueError):
            workflow_coverage.validate_group_receipt(coverage, scope=scope, manifest={"commit": COMMIT},
                metadata=forged, execution=self.execution, job_attempt="2")

    def test_declared_oracle_execution_instead_of_skip_fails(self):
        declarations = jobs.build_profile("root")["testExclusions"]
        self.configure({".": {"DiscordMLSTests": [
            "DiscordMLSTests.MLSNativeDAVEInteropTests/goldenPayload()", ORACLE]}}, declarations)
        self.suite, self.suites = "DiscordMLSTests", ["DiscordMLSTests"]
        self.event_faults = {self.suite: "execute-exclusion"}
        with self.assertRaisesRegex(ValueError, "inventory-excluded leaf executed"):
            self.run_group()
        self.assertEqual(self.coverage()["status"], "failed")


if __name__ == "__main__":
    unittest.main()
