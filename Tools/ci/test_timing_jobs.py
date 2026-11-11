# File: Tools/ci/test_timing_jobs.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Protect finite periodic workloads, prepared comparison inputs and retained failure evidence."""

from contextlib import redirect_stderr
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import timing_jobs as jobs


class TimingJobTests(unittest.TestCase):
    """Separate process/resource correctness from informational shared-runner timing numbers."""

    def test_periodic_cpu_sweep_and_real_duration_soak_are_bounded_and_use_receipts(self):
        """Stress changes real cohorts; soak uses the existing measured wall-duration loop."""
        for profile, duration, timeout in (("stress", 60, 303), ("soak", 600, 660)):
            command = jobs.periodic_command(Path("/checkout"), profile, Path("/binary $ literal"),
                                            Path("/receipt.json"), Path("/output"), duration)
            self.assertEqual(command.timeout, timeout)
            self.assertIn("--receipt", command.arguments)
            participant = json.loads(command.arguments[command.arguments.index("--command") + 1])
            self.assertEqual(participant[0], "/binary $ literal")
            self.assertIn("{duration_seconds}", participant)
            if profile == "stress":
                self.assertIn("{concurrency}", participant)
                self.assertIn("callbackContention", participant)
            else:
                self.assertIn("soak", participant)
                self.assertNotIn("--output", participant)
        with self.assertRaises(ValueError):
            jobs.periodic_command(Path("/checkout"), "standard", Path("/binary"), Path("/receipt"), Path("/output"), 1)

    def test_soak_requires_actual_duration_bounded_resources_and_zero_shutdown_owners(self):
        """A completed child with a short or leaking legacy report cannot count as soak evidence."""
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            capture = output / "capture/00-single"
            capture.mkdir(parents=True)
            (capture.parent / "orchestration.json").write_text(json.dumps({"status": "completed", "processes": [{"status": "completed"}]}))
            valid = {"scenario": "soak", "profile": "accounts-10000", "configuredDurationSeconds": 600,
                     "durationSeconds": 600.1, "completedRounds": 64, "entriesAfterShutdown": 0,
                     "refreshesAfterShutdown": 0, "waitersAfterShutdown": 0, "subscriptionsAfterShutdown": 0,
                     "bufferedEventsAfterShutdown": 0, "maximumEntries": 32, "peakEntries": 32,
                     "maximumAccountedBytes": 131072, "peakAccountedBytes": 12000}
            report = capture / "stdout.log"
            report.write_text(json.dumps(valid))
            jobs.verify_periodic(output, "soak", 600)
            for key, value in (("durationSeconds", 599.9), ("completedRounds", 63), ("refreshesAfterShutdown", 1),
                               ("peakEntries", 33), ("peakAccountedBytes", 131073)):
                report.write_text(json.dumps({**valid, key: value}))
                with self.subTest(field=key), self.assertRaises(ValueError):
                    jobs.verify_periodic(output, "soak", 600)

    def test_integration_uses_receipt_bound_soak_without_numeric_policy_adoption(self):
        """The separate integrated job invokes the supervised native soak with literal paths."""
        command = jobs.periodic_command(Path("/checkout"), "integration", Path("/binary $ literal"),
                                        Path("/receipt $ literal.json"), Path("/output"), 1800,
                                        validator=Path("/validator $ literal"))
        self.assertEqual(command.timeout, 1860)
        self.assertEqual(command.arguments[command.arguments.index("--profile") + 1], "soak")
        self.assertEqual(command.arguments[command.arguments.index("--executable") + 1], "/binary $ literal")
        self.assertEqual(command.arguments[command.arguments.index("--receipt") + 1], "/receipt $ literal.json")
        self.assertEqual(command.arguments[command.arguments.index("--validator") + 1], "/validator $ literal")
        self.assertEqual(command.arguments[command.arguments.index("--duration-seconds") + 1], "1800")
        self.assertNotIn("--policy", command.arguments)
        with self.assertRaises(ValueError):
            jobs.periodic_command(Path("/checkout"), "integration", Path("/binary"), Path("/receipt"), Path("/output"), 1800)

    def test_integrated_soak_refuses_short_runs_missing_evidence_and_numeric_promotion(self):
        """Partial, shortened or numerically promoted integrated reports never pass periodic integrity."""
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            capture = output / "capture"
            capture.mkdir()
            manifest = {"status": "completed", "processes": [{"status": "completed"}]}
            (capture / "orchestration.json").write_text(json.dumps(manifest))
            case = {"status": "completed", "requestedDurationSeconds": 1800,
                    "durationNanoseconds": 1_800_000_000_000}
            valid = {"format": "DiscordKitLoadTests.integration-matrix", "schemaVersion": 1,
                     "status": "completed", "informationalOnly": True, "policyMode": "reporting-only",
                     "sharedSchemaValidation": "available",
                     "profile": "soak", "durationSeconds": 1800, "failures": [], "cases": [case]}
            report = capture / "integration-summary.json"
            report.write_text(json.dumps(valid))
            jobs.verify_periodic(output, "integration", 1800)
            for change in ({"status": "failed"}, {"informationalOnly": False}, {"policyMode": "required"},
                           {"sharedSchemaValidation": "unavailable"},
                           {"profile": "smoke"}, {"durationSeconds": 1799}, {"failures": ["resource cap"]},
                           {"cases": []}, {"cases": [{**case, "status": "cancelled"}]},
                           {"cases": [{**case, "requestedDurationSeconds": 1799}]},
                           {"cases": [{**case, "durationNanoseconds": 1_799_999_999_999}]}):
                report.write_text(json.dumps({**valid, **change}))
                with self.subTest(change=change), self.assertRaises(ValueError):
                    jobs.verify_periodic(output, "integration", 1800)
            report.write_text(json.dumps(valid))
            (capture / "orchestration.json").write_text(json.dumps({**manifest, "processes": [{"status": "failed"}]}))
            with self.assertRaises(ValueError):
                jobs.verify_periodic(output, "integration", 1800)

    def test_integrated_soak_rejects_under_duration_and_excessive_duration_before_build(self):
        """A short smoke or an oversized soak cannot masquerade as the scheduled 30-minute job."""
        with tempfile.TemporaryDirectory() as directory:
            for duration in (1799, 3601):
                output = Path(directory) / str(duration)
                with patch.object(jobs, "build_product") as build, redirect_stderr(io.StringIO()):
                    self.assertEqual(jobs.main(["periodic", "--profile", "integration", "--duration-seconds",
                                                str(duration), "--output", str(output)]), 1)
                    build.assert_not_called()
                self.assertEqual(json.loads((output / "commands.json").read_text())["status"], "failed")

    def test_integrated_job_keeps_distinct_build_receipts_and_defaults_to_thirty_minutes(self):
        """The validator cannot replace the workload receipt, and both binaries are rechecked after capture."""
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory).resolve() / "output"
            binary, receipt = Path(directory) / "load", output / "release.json"
            validator, validator_receipt = Path(directory) / "validator", output / "schema-validator-release.json"
            with patch.object(jobs, "build_product", side_effect=[(binary, receipt), (validator, validator_receipt)]) as build, \
                    patch.object(jobs.native_jobs, "execute_commands") as execute, \
                    patch.object(jobs, "verify_periodic") as verify, \
                    patch.object(jobs.runner, "validate_receipt") as recheck:
                self.assertEqual(jobs.main(["periodic", "--profile", "integration", "--output", str(output)]), 0)
            self.assertEqual(build.call_args_list[0].args[2], "DiscordKitLoadTests")
            self.assertEqual(build.call_args_list[1].args[2], "DiscordBenchmarkReports")
            self.assertEqual(build.call_args_list[1].kwargs["receipt_name"], "schema-validator-release.json")
            command = execute.call_args.args[0][0]
            self.assertEqual(command.arguments[command.arguments.index("--duration-seconds") + 1], "1800")
            self.assertEqual(command.arguments[command.arguments.index("--receipt") + 1], str(receipt))
            self.assertEqual(command.arguments[command.arguments.index("--validator") + 1], str(validator))
            verify.assert_called_once_with(output, "integration", 1800)
            self.assertEqual([call.args for call in recheck.call_args_list],
                             [(validator_receipt, [str(validator)]), (receipt, [str(binary)])])

    def test_standard_comparison_requires_controlled_host_and_explicit_independent_noise(self):
        """Prepared paths remain literal, retained inputs stay reviewable and no policy gets rewritten."""
        with tempfile.TemporaryDirectory(prefix="timing $ literal ") as directory:
            root = Path(directory)
            output = root / "output"
            output.mkdir()
            spec, policy, noise = [root / filename for filename in ("spec.json", "policy.json", "noise.json")]
            document = {"profile": "standard", "host": {"controlled": True}}
            spec.write_text(json.dumps(document)); policy.write_text('{"reviewed":true}'); noise.write_text('{"pairs":[]}')
            original = policy.read_bytes()
            commands = jobs.controlled_capture_commands(root, spec, noise, root / "evaluator", output)
            self.assertEqual([command.timeout for command in commands], [4200, 120])
            self.assertEqual(commands[0].arguments[commands[0].arguments.index("--noise-series") + 1], str(noise))
            self.assertEqual(commands[1].arguments[1], "hash-series")
            self.assertNotIn("--policy", commands[0].arguments)
            self.assertEqual(policy.read_bytes(), original)
            evaluation = jobs.controlled_evaluate_commands(root, noise, policy, root / "evaluator", output)
            self.assertEqual(len(evaluation), 1)
            self.assertEqual(evaluation[0].arguments[evaluation[0].arguments.index("--policy") + 1], str(output / "reviewed-policy.json"))
            self.assertEqual(evaluation[0].arguments[evaluation[0].arguments.index("--series") + 1], str(output / "reviewed-series.json"))
            self.assertNotIn("capture", evaluation[0].arguments)
            self.assertEqual((output / "reviewed-policy.json").read_bytes(), original)
            for invalid in ({**document, "profile": "smoke"}, {**document, "host": {"controlled": False}}):
                spec.write_text(json.dumps(invalid))
                with self.assertRaises(ValueError):
                    jobs.controlled_capture_commands(root, spec, noise, root / "evaluator", output)
            noise.unlink()
            with self.assertRaises(ValueError):
                jobs.controlled_capture_commands(root, spec, noise, root / "evaluator", output)

    def test_cli_preserves_existing_evidence_and_retains_new_build_failure(self):
        """Reruns cannot overwrite observations; a failed build remains available for upload."""
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            with patch.object(jobs, "build_product", side_effect=ValueError("source changed")), redirect_stderr(io.StringIO()):
                self.assertEqual(jobs.main(["periodic", "--profile", "stress", "--output", str(output)]), 1)
            recorded = (output / "commands.json").read_bytes()
            self.assertEqual(json.loads(recorded)["error"], "source changed")
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                jobs.main(["periodic", "--profile", "stress", "--output", str(output)])
            self.assertEqual((output / "commands.json").read_bytes(), recorded)


if __name__ == "__main__":
    unittest.main()
