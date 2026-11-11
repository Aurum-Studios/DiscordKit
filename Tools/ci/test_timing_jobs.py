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
