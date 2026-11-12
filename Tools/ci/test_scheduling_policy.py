# File: Tools/ci/test_scheduling_policy.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Protect Phase 0 scope, evidence boundaries and conservative cost arithmetic."""

from contextlib import redirect_stderr, redirect_stdout
import copy
from datetime import date, timedelta
from decimal import Decimal
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import scheduling_policy as scheduling


class SchedulingPolicyTests(unittest.TestCase):
    """Check the retained source inventory without invoking Swift or paid work."""

    def setUp(self):
        """Load a fresh policy so rejection fixtures cannot alter other cases."""
        self.policy = scheduling.load_policy()

    def test_retained_inventory_matches_the_existing_source_planner(self):
        """Literal targets are explicitly weaker evidence than evaluation/discovery."""
        result = scheduling.validate_source_inventory(self.policy)
        self.assertEqual(result["rootTargets"], 34)
        self.assertFalse(result["evaluatedSwiftPM"])
        self.assertFalse(result["discoveredTestLeaves"])
        self.assertEqual(result["components"], len(scheduling.native_jobs.COMPONENTS))

    def test_unknown_version_and_malformed_policy_are_rejected(self):
        """Unknown contracts and malformed values cannot silently use defaults."""
        for version in (0, 2, True, "1"):
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, "version"):
                policy = copy.deepcopy(self.policy)
                policy["schemaVersion"] = version
                scheduling.validate_policy(policy)
        for malformed in ({}, [], {**self.policy, "runnerRates": []}, {**self.policy, "bootstrap": None}):
            with self.subTest(malformed=type(malformed)), self.assertRaises(ValueError):
                scheduling.validate_policy(malformed)

    def test_phase_zero_has_no_paid_or_native_execution_authorization(self):
        """A configuration edit cannot quietly grant future bootstrap permission."""
        bootstrap = scheduling.describe_bootstrap(self.policy)
        self.assertFalse(bootstrap["bootstrap"]["nativeExecutionAuthorized"])
        self.assertEqual(bootstrap["bootstrap"]["localNativeTestAttempts"], 0)
        self.assertEqual(bootstrap["bootstrap"]["localNativeCompilations"], 0)
        self.assertEqual(bootstrap["allowances"]["maximumPaidJobs"], 0)
        self.assertFalse(bootstrap["bootstrap"]["futureDiagnostic"]["authorized"])
        for field in ("experimentUSD", "workflowUSD", "safetyUSD"):
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "no paid allowance"):
                policy = copy.deepcopy(self.policy)
                policy["allowances"][field] = "0.01"
                scheduling.validate_policy(policy)
        for field in ("maximumPaidJobs", "maximumPaidMinutes", "maximumPaidAttempts"):
            with self.subTest(field=field), self.assertRaises(ValueError):
                policy = copy.deepcopy(self.policy)
                policy["allowances"][field] = 1
                scheduling.validate_policy(policy)

    def test_scope_is_explicit_and_unknown_or_mismatched_selections_fail(self):
        """Diagnostic selection cannot silently expand or become certification."""
        scope = scheduling.plan_scope(self.policy, "diagnostic", platform="linux-x64",
                                      component="load", suite="load")
        self.assertEqual(len(scope["nativeBuilds"]), 1)
        self.assertEqual(len(scope["nativeSuites"]), 1)
        self.assertEqual(scope["nativeSuites"][0]["artifactProducer"], "build/linux-x64/load")
        self.assertEqual(scope["nativeSuites"][0]["needs"], ["plan", "build"])
        self.assertFalse(scope["executionAuthorized"])
        self.assertFalse(scope["certificationEstablished"])
        self.assertFalse(scope["completeWorkflowCostPlan"])
        compilation = scheduling.plan_scope(self.policy, "diagnostic", platform="linux-x64", component="load")
        self.assertEqual(compilation["nativeSuites"], [])
        invalid = [("unknown", {}), ("full", {"platform": "linux-x64"}),
                   ("preflight", {"component": "load"}), ("diagnostic", {}),
                   ("diagnostic", {"platform": "windows-x64", "component": "load"}),
                   ("diagnostic", {"platform": "linux-x64", "component": "missing"}),
                   ("diagnostic", {"platform": "linux-x64", "component": "load", "suite": "root"}),
                   ("diagnostic", {"platform": "linux-x64", "component": "root", "suite": "DiscordFoundationTransportTests"})]
        for mode, selection in invalid:
            with self.subTest(mode=mode, selection=selection), self.assertRaises(ValueError):
                scheduling.plan_scope(self.policy, mode, **selection)

    def test_full_scope_delegates_exactly_to_supported_platform_matrices(self):
        """Current native planner Windows support must not expand this policy."""
        original = scheduling.native_jobs.matrices
        with patch.object(scheduling.native_jobs, "matrices", wraps=original) as matrices:
            scope = scheduling.plan_scope(self.policy, "full")
        self.assertEqual([call.args[1] for call in matrices.call_args_list], ["linux-x64", "macos-arm64"])
        self.assertEqual(len(scope["nativeBuilds"]), 24)
        self.assertEqual(len(scope["nativeSuites"]), 101)
        self.assertEqual({entry["platform"] for entry in scope["nativeBuilds"] + scope["nativeSuites"]},
                         set(self.policy["platforms"]))
        self.assertEqual(len({entry["id"] for entry in scope["nativeBuilds"]}), len(scope["nativeBuilds"]))
        self.assertEqual(len({(entry["platform"], entry["component"], entry["suite"])
                              for entry in scope["nativeSuites"]}), len(scope["nativeSuites"]))
        self.assertFalse(scope["certificationEstablished"])
        preflight = scheduling.plan_scope(self.policy, "preflight")
        self.assertEqual(preflight["nativeBuilds"], [])
        self.assertEqual(preflight["nativeSuites"], [])

    def test_manifest_digest_and_declared_inventory_drift_fail_closed(self):
        """Even benign source edits need inventory review; regex is not Swift evaluation."""
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "Package.swift"
            manifest.write_bytes((scheduling.REPOSITORY / "Package.swift").read_bytes() + b"\n")
            with self.assertRaisesRegex(ValueError, "manifest changed"):
                scheduling.validate_source_inventory(self.policy, directory)
            changed = copy.deepcopy(self.policy)
            changed["inventory"]["rootManifestSHA256"] = hashlib.sha256(manifest.read_bytes()).hexdigest()
            changed["inventory"]["rootTargets"] = changed["inventory"]["rootTargets"][:-1]
            with self.assertRaisesRegex(ValueError, "target inventory drift"):
                scheduling.validate_source_inventory(changed, directory)
        for attribute, replacement, message in [
                ("COMPONENTS", (*scheduling.native_jobs.COMPONENTS, "new-component"), "component inventory drift"),
                ("CONSUMER_SUITES", (*scheduling.native_jobs.CONSUMER_SUITES, "NewExample"), "consumer inventory drift")]:
            with self.subTest(attribute=attribute), patch.object(scheduling.native_jobs, attribute, replacement), \
                    self.assertRaisesRegex(ValueError, message):
                scheduling.validate_source_inventory(self.policy)

    def test_deadline_reserves_attempts_and_aggregate_commands_are_consistent(self):
        """A command limit cannot consume required cleanup or omit compile commands."""
        for section, field, value in [("jobSeconds", "focusedTest", 90),
                ("reservesSeconds", "cleanup", 0), ("deadlinesSeconds", "transportTotal", 359),
                ("attempts", "testProcessesPerExperiment", 3), ("concurrency", "buildsPerPlatform", True),
                ("retentionDays", "diagnosticArtifacts", 91)]:
            with self.subTest(section=section, field=field), self.assertRaises(ValueError):
                policy = copy.deepcopy(self.policy)
                policy[section][field] = value
                scheduling.validate_policy(policy)
        policy = copy.deepcopy(self.policy)
        policy["componentCompileSeconds"]["load"] = policy["deadlinesSeconds"]["coldCompileCommand"] - 1
        with self.assertRaisesRegex(ValueError, "aggregate compilation budget is shorter"):
            scheduling.validate_source_inventory(policy)
        # A serial component may have a stricter elapsed ceiling than the sum of
        # its command maxima, but cannot consume cleanup or packaging time.
        self.assertEqual(self.policy["componentCompileSeconds"]["consumers"], 5400)
        policy = copy.deepcopy(self.policy)
        # Transfer recovery widens the enclosing job without changing the compute
        # policy. Test its actual boundary rather than the former 120-minute cap.
        import native_jobs
        policy["componentCompileSeconds"]["consumers"] = native_jobs.BUILD_JOB_SECONDS
        with self.assertRaisesRegex(ValueError, "enclosing workflow"):
            scheduling.validate_source_inventory(policy)

    def test_rounding_is_per_job_including_each_attempt(self):
        """Two short jobs cost two rounded minutes; attempts do not share rounding."""
        for seconds, expected in [(0, 0), (0.001, 1), (59, 1), (60, 1), (60.001, 2), (120, 2)]:
            self.assertEqual(scheduling.billed_minutes(seconds), expected)
        for invalid in (-1, True, "1", float("nan"), float("inf")):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                scheduling.billed_minutes(invalid)
        jobs = [{"group": "Linux-x64-8", "maximumSeconds": 1, "attempts": 1},
                {"group": "Linux-x64-8", "maximumSeconds": 1, "attempts": 2}]
        estimate = scheduling.estimate_runner_cost(self.policy, jobs, as_of=date(2026, 11, 12),
                                                   require_verified_mapping=False)
        self.assertEqual(Decimal(estimate["runnerCostUSD"]), Decimal("0.066"))
        self.assertEqual(sum(job["billedMaximumMinutes"] for job in estimate["jobs"]), 3)
        self.assertEqual(estimate["pricingAssurance"], "published-list-price-only")
        self.assertFalse(estimate["executionAuthorized"])
        self.assertFalse(estimate["completeWorkflowCostPlan"])
        with self.assertRaisesRegex(ValueError, "startup time"):
            scheduling.estimate_runner_cost(self.policy, [{**jobs[0], "maximumSeconds": 0}])

    def test_unknown_stale_future_and_unverified_runner_prices_reject(self):
        """Published prices remain unusable for paid planning until mappings are verified."""
        checked = date(2026, 11, 12)
        with self.assertRaisesRegex(ValueError, "mapping is unverified"):
            scheduling.runner_rate(self.policy, "Linux-x64-8", as_of=checked)
        self.assertEqual(scheduling.runner_rate(self.policy, "MacOS-26-5", as_of=checked,
                                                require_verified_mapping=False), Decimal("0.102"))
        for as_of in (checked - timedelta(days=1), checked + timedelta(days=31)):
            with self.subTest(as_of=as_of), self.assertRaisesRegex(ValueError, "stale or future"):
                scheduling.runner_rate(self.policy, "Linux-x64-8", as_of=as_of, require_verified_mapping=False)
        with self.assertRaisesRegex(ValueError, "unknown runner group"):
            scheduling.runner_rate(self.policy, "unknown", as_of=checked)
        policy = copy.deepcopy(self.policy)
        policy["runnerRates"]["Linux-x64-8"]["usdPerMinute"] = None
        policy["runnerRates"]["Linux-x64-8"]["verifiedOn"] = None
        scheduling.validate_policy(policy)
        with self.assertRaisesRegex(ValueError, "unknown runner rate"):
            scheduling.runner_rate(policy, "Linux-x64-8", as_of=checked, require_verified_mapping=False)
        policy = copy.deepcopy(self.policy)
        policy["runnerRates"]["Linux-x64-8"]["usdPerMinute"] = "NaN"
        with self.assertRaises(ValueError):
            scheduling.validate_policy(policy)
        policy = copy.deepcopy(self.policy)
        policy["runnerRates"]["Linux-x64-8"]["billingMappingVerified"] = True
        self.assertEqual(scheduling.runner_rate(policy, "Linux-x64-8", as_of=checked), Decimal("0.022"))
        self.assertEqual(scheduling.estimate_runner_cost(policy, [], as_of=checked)["runnerCostUSD"], "0")
        with self.assertRaisesRegex(ValueError, "requires a date"):
            scheduling.runner_rate(policy, "Linux-x64-8", as_of=0)

    def test_cli_reports_valid_local_contract_and_rejects_invalid_scope(self):
        """The CLI provides reviewable JSON and visible failure without side effects."""
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(scheduling.main(["validate"]), 0)
        self.assertEqual(json.loads(output.getvalue())["status"], "valid")
        with redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(scheduling.main(["scope", "--mode", "diagnostic", "--platform", "windows-x64",
                                               "--component", "load"]), 1)
        self.assertIn("supported platform", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
