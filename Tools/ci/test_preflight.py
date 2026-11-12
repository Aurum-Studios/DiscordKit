# File: Tools/ci/test_preflight.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Keep cheap source/helper gates complete, finite and unable to certify native work."""

from contextlib import redirect_stderr, redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import preflight


class PreflightPlanTests(unittest.TestCase):
    """Require each existing helper suite exactly once and literal source-only commands."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="preflight $ literal ")
        self.addCleanup(self.temporary.cleanup)
        self.repository = Path(self.temporary.name).resolve()
        self.policy = preflight.scheduling_policy.load_policy()
        for entries in preflight.GROUPS.values():
            for _name, directory in entries:
                location = self.repository / directory
                location.mkdir(parents=True, exist_ok=True)
                (location / "test_fixture.py").touch()
        browser = self.repository / "Browser/DiscordActivityBridge"
        browser.mkdir(parents=True)
        (browser / "bridge.test.mjs").touch()
        workflows = self.repository / ".github/workflows"
        workflows.mkdir(parents=True)
        (workflows / "ci.yml").touch()

    def plan(self, operation, group=None):
        return preflight.plan_commands(operation, self.repository, group=group, policy=self.policy)

    def test_helper_groups_partition_every_existing_suite_without_compiler_commands(self):
        planned = [command for group in preflight.GROUPS for command in self.plan("group", group)]
        self.assertEqual(len(planned), 7)
        self.assertEqual(len({command.name for command in planned}), 7)
        self.assertEqual({command.arguments[command.arguments.index("-s") + 1]
                          for command in planned if command.arguments[0] == sys.executable},
                         {"Tools/DiscordKitTools/scripts", "Tools/DiscordKitLoadTests/scripts",
                          "Tools/DiscordDSLBenchmarks/scripts", "Tools/DiscordBenchmarkSupport/scripts",
                          "Tools/DiscordFoundationBenchmarks/scripts", "Tools/ci"})
        for command in planned:
            self.assertIn(command.arguments[0], (sys.executable, "node"))
            self.assertEqual(command.timeout, self.policy["deadlinesSeconds"]["localHelperCheck"])
            self.assertEqual(command.operation, "localHelperCheck")
        self.assertEqual([command.name for command in self.plan("group", "ci-python")], ["ci-python"])

    def test_source_checks_do_not_evaluate_manifests_or_require_symbol_graphs(self):
        planned = self.plan("source")
        self.assertEqual([command.name for command in planned],
                         ["policy-source-inventory", "documentation-example-snapshots"])
        self.assertTrue(all(command.arguments[0] == sys.executable for command in planned))
        self.assertIn("validate", planned[0].arguments)
        self.assertIn(str(self.repository / "Tools/ci/scheduling-policy.v1.json"), planned[0].arguments)
        self.assertTrue(all("--write" not in command.arguments for command in planned))
        self.assertFalse(any("curate_docc" in argument or "dump-package" in argument
                             for command in planned for argument in command.arguments))

    def test_browser_and_actionlint_receive_sorted_literal_nonempty_file_inventories(self):
        browser = self.repository / "Browser/DiscordActivityBridge"
        (browser / "a test.test.mjs").touch()
        (browser / "ignore.mjs").touch()
        self.assertEqual(self.plan("group", "browser")[0].arguments,
                         ("node", "--test", "Browser/DiscordActivityBridge/a test.test.mjs",
                          "Browser/DiscordActivityBridge/bridge.test.mjs"))
        workflows = self.repository / ".github/workflows"
        (workflows / "a workflow.yaml").touch()
        (workflows / "ignore.json").touch()
        self.assertEqual(self.plan("workflow")[0].arguments,
                         ("actionlint", ".github/workflows/a workflow.yaml", ".github/workflows/ci.yml"))

    def test_missing_python_browser_and_workflow_suites_fail_before_empty_discovery(self):
        for operation, group, pattern in (("group", "tooling-python", "Tools/DiscordKitTools/scripts/test_*.py"),
                                          ("group", "browser", "Browser/DiscordActivityBridge/*.test.mjs"),
                                          ("workflow", None, ".github/workflows/*.yml")):
            for path in self.repository.glob(pattern):
                path.unlink()
            with self.subTest(operation=operation, group=group), self.assertRaisesRegex(ValueError, "missing"):
                self.plan(operation, group)

    def test_unknown_or_mismatched_selections_fail_before_any_command(self):
        for operation, group in (("full", None), ("group", None), ("group", "missing"),
                                 ("source", "browser"), ("workflow", "ci-python")):
            with self.subTest(operation=operation, group=group), self.assertRaises(ValueError):
                self.plan(operation, group)


class PreflightExecutionTests(unittest.TestCase):
    """Exercise real supervisor success, assertion failure, deadlines and durable planning errors."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="preflight execution $ ")
        self.addCleanup(self.temporary.cleanup)
        self.repository = Path(self.temporary.name).resolve()
        self.output = self.repository / "evidence"
        policy = self.repository / "Tools/ci/scheduling-policy.v1.json"
        policy.parent.mkdir(parents=True)
        policy.write_text(json.dumps(preflight.scheduling_policy.load_policy()))

    def retained(self):
        return json.loads((self.output / "commands.json").read_text())

    def execute_fixture(self, code, timeout=3, following=()):
        command = preflight.linux_ci.Command("fixture", (sys.executable, "-c", code), timeout,
                                             operation="localHelperCheck", stage="preflight-fixture")
        with patch.object(preflight, "plan_commands", return_value=[command, *following]), \
                redirect_stdout(io.StringIO()):
            return preflight.run_checks("source", self.repository, self.output)

    def test_success_retains_noncertifying_results_and_shared_aggregate_deadline(self):
        report = self.execute_fixture("print('completed')")
        self.assertEqual(report["status"], "passed")
        self.assertFalse(report["certifying"])
        self.assertEqual(report["aggregateSeconds"], 300)
        record = self.retained()["commands"][0]
        self.assertEqual(record["status"], "passed")
        self.assertEqual(record["execution"]["status"], "passed")
        self.assertLessEqual(record["execution"]["deadlineMonotonic"], report["deadlineMonotonic"])

    def test_child_failure_retains_failed_status_and_stops_following_commands(self):
        following = preflight.linux_ci.Command("must-not-start", (sys.executable, "-c", "print('unexpected')"), 3)
        with self.assertRaises(subprocess.CalledProcessError):
            self.execute_fixture("raise AssertionError('preflight fixture')", following=[following])
        report = self.retained()
        self.assertEqual(report["status"], "failed")
        self.assertEqual(len(report["commands"]), 1)
        self.assertEqual(report["commands"][0]["status"], "failed")
        self.assertNotEqual(report["commands"][0]["execution"]["exitCode"], 0)

    @unittest.skipUnless(os.name == "posix", "process deadlines use the POSIX supervisor")
    def test_hung_child_fails_with_retained_timeout_and_cleanup_evidence(self):
        started = time.monotonic()
        with patch.object(preflight.linux_ci, "_stacks", return_value={"status": "denied"}), \
                self.assertRaises(subprocess.TimeoutExpired):
            self.execute_fixture("import time; time.sleep(60)", timeout=.3)
        report = self.retained()
        self.assertEqual(report["status"], "failed")
        record = report["commands"][0]
        self.assertEqual(record["status"], "failed")
        self.assertEqual(record["timeoutCategory"], "execution")
        self.assertIn("cleanup", record["execution"])
        self.assertLess(time.monotonic() - started, 10)

    def test_planning_and_policy_failures_are_retained_without_children(self):
        with patch.object(preflight.native_jobs, "execute_commands") as execute:
            with self.assertRaisesRegex(ValueError, "missing"):
                preflight.run_checks("group", self.repository, self.output, group="browser")
            report = self.retained()
            self.assertEqual(report["status"], "failed")
            self.assertEqual(report["commands"], [])
            policy = self.repository / "Tools/ci/scheduling-policy.v1.json"
            policy.write_text('{}')
            with self.assertRaises(ValueError):
                preflight.run_checks("source", self.repository, self.output)
            self.assertEqual(self.retained()["status"], "failed")
            execute.assert_not_called()

    def test_cli_returns_nonzero_for_failure_and_never_claims_certification(self):
        with redirect_stderr(io.StringIO()), redirect_stdout(io.StringIO()), \
                patch.object(preflight, "run_checks", side_effect=subprocess.TimeoutExpired("fixture", .1)):
            self.assertEqual(preflight.main(["source", "--output", str(self.output)]), 1)
        with redirect_stdout(io.StringIO()) as stdout, \
                patch.object(preflight, "run_checks", return_value={"status": "passed"}):
            self.assertEqual(preflight.main(["source", "--output", str(self.output)]), 0)
        self.assertFalse(json.loads(stdout.getvalue())["certifying"])


if __name__ == "__main__":
    unittest.main()
