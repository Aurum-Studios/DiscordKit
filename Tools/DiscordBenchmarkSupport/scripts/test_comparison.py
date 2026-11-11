#!/usr/bin/env python3
# File: Tools/DiscordBenchmarkSupport/scripts/test_comparison.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Test paired capture with finite real processes; these tests are not timing data."""

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import run_benchmarks as runner
import run_comparison as comparison


class CaptureTests(unittest.TestCase):
    """Use isolated source, receipts and output so failures cannot affect the checkout."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.repository = self.root / "source"
        self.repository.mkdir()
        subprocess.run(["git", "init", "-q", str(self.repository)], check=True)
        self.git("config", "user.name", "Comparison test")
        self.git("config", "user.email", "comparison@example.invalid")
        (self.repository / "Package.resolved").write_text('{"pins":[]}\n')
        self.program = self.repository / "participant.py"
        self.program.write_text(self.participant())
        self.git("add", ".")
        self.git("commit", "-qm", "capture fixture")
        self.receipt = self.root / "receipt.json"
        binary = Path(sys.executable).resolve()
        runner.atomic_json(self.receipt, {"format": runner.RECEIPT_FORMAT, "version": 1,
            "status": "completed", "optimization": "release", "compiler": "fixture compiler 1",
            "target_info": {"target": {"triple": "fixture-target"}},
            "sdk": {"version": "fixture-sdk", "path": "fixture-sdk-path"},
            "build_flags": ["-c", "release"], "source": runner.source_identity(self.repository),
            "executable": runner.artifact(binary)})
        self.spec = {"format": comparison.SPEC_FORMAT, "version": 1, "profile": "smoke",
            "scenario": "capture-fixture", "seed": 123, "fixtures": [str(self.program)],
            "host": {"name": "fixture-host", "controlled": True, "contention": "none",
                     "notes": "Isolated deterministic test subprocesses; not numerical qualification."},
            "baseline": {"command": [str(binary), str(self.program)], "receipt": str(self.receipt)},
            "candidate": {"command": [str(binary), str(self.program)], "receipt": str(self.receipt)},
            "warmup_seconds": 0, "warmup_policy": "cold-process-no-in-process-warmup",
            "duration_seconds": 1, "concurrency": 1, "scheduler_policy": "fixture-sequential"}
        self.spec_path = self.root / "spec.json"

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.repository, check=True, capture_output=True)

    def participant(self):
        """Preserve real scope notes and internal-input receipts during hydration."""
        return """import json,os,pathlib
report={'format':'DiscordBenchmarkReport','schemaVersion':1,
 'identity':{'scenario':'capture-fixture','profile':os.environ['DK_BENCHMARK_PROFILE'],
 'seed':int(os.environ['DK_BENCHMARK_SEED']),'concurrency':int(os.environ['DK_BENCHMARK_CONCURRENCY']),
 'scheduler':'fixture-sequential','requestedWarmupNanoseconds':0,
 'fixtureHashes':{'generated-input':'a'*64}},'provenance':{'unavailabilityReasons':{}},
 'status':'completed','qualificationLimitations':['Synthetic fixture; not live Discord.']}
pathlib.Path(os.environ['DK_BENCHMARK_ENVELOPE']).write_text(json.dumps(report))
print(json.dumps({'pid':os.getpid()}))
"""

    def capture(self, name="run", noise=None):
        runner.atomic_json(self.spec_path, self.spec)
        return comparison.capture_series(self.spec_path, self.root / name, noise, runner.Cancellation())

    def test_five_pairs_are_fresh_counterbalanced_with_verified_receipts(self):
        self.spec["profile"] = "standard"
        result = self.capture()
        self.assertEqual(result["status"], "completed", result)
        series = comparison.read_json(self.root / "run/series.json")
        self.assertEqual(len(series["pairs"]), 5)
        processes = []
        for index, pair in enumerate(series["pairs"]):
            processes.extend([pair["baselineProcess"], pair["candidateProcess"]])
            if index:
                self.assertNotEqual(pair["order"], series["pairs"][index - 1]["order"])
            report = pair["baseline"]
            self.assertEqual(report["qualificationLimitations"], ["Synthetic fixture; not live Discord."])
            self.assertEqual(report["identity"]["fixtureHashes"], report["provenance"]["fixtureHashes"])
            self.assertEqual(report["identity"]["fixtureHashes"]["participant:generated-input"], "a" * 64)
            self.assertIn("participant:generated-input", report["provenance"]["fixtureHashes"])
            self.assertTrue(any(key.startswith("capture:") for key in report["provenance"]["fixtureHashes"]))
            self.assertEqual(report["provenance"]["executableHash"], runner.sha256_file(Path(sys.executable).resolve()))
        self.assertEqual(len(set(processes)), 10)
        self.assertTrue((self.root / "run/capture/00-baseline/benchmark-envelope.json").is_file() or
                        (self.root / "run/capture/00-candidate/benchmark-envelope.json").is_file())

    def test_no_change_noise_capture_remains_separate_and_merges_explicitly(self):
        self.assertEqual(self.capture("noise")["status"], "completed")
        result = self.capture("candidate", self.root / "noise/series.json")
        self.assertEqual(result["status"], "completed", result)
        series = comparison.read_json(self.root / "candidate/series.json")
        self.assertEqual(len(series["noisePairs"]), 1)
        self.assertNotEqual(series["pairs"][0]["baselineProcess"], series["noisePairs"][0]["baselineProcess"])
        noise = comparison.read_json(self.root / "noise/series.json")
        noise["pairs"][0]["candidate"]["provenance"]["executableHash"] = "b" * 64
        runner.atomic_json(self.root / "invalid-noise.json", noise)
        result = self.capture("invalid", self.root / "invalid-noise.json")
        self.assertEqual(result["status"], "failed")
        self.assertIn("unchanged source", result["failure"])

    def test_standard_series_uses_compact_json_without_raising_its_byte_ceiling(self):
        """Twenty realistic 100,001-cell reports fit the series cap without pretty whitespace."""
        self.spec["profile"] = "standard"
        histogram = """report['metrics']=[{'id':'pure.batch','version':1,'outcome':'success',
 'clockDomain':'fixture-clock','distribution':{
 'configuration':{'lowerBoundNanoseconds':0,'upperBoundNanoseconds':100000000,'bucketWidthNanoseconds':1000},
 'bucketCounts':[10000]+[0]*100000,'observedCount':10000,'inRangeCount':10000,
 'underflowCount':0,'overflowCount':0,'droppedCount':0,'counterOverflow':False,'maxInRangeNanoseconds':0}}]
"""
        self.program.write_text(self.participant().replace("pathlib.Path(os.environ['DK_BENCHMARK_ENVELOPE'])",
                                                        histogram + "pathlib.Path(os.environ['DK_BENCHMARK_ENVELOPE'])"))
        receipt = comparison.read_json(self.receipt)
        receipt["source"] = runner.source_identity(self.repository)
        runner.atomic_json(self.receipt, receipt)
        self.assertEqual(self.capture("large-noise")["status"], "completed")
        result = self.capture("large-candidate", self.root / "large-noise/series.json")
        self.assertEqual(result["status"], "completed", result)
        path = self.root / "large-candidate/series.json"
        series = comparison.read_json(path)
        self.assertEqual(len(series["pairs"]), 5)
        self.assertEqual(len(series["noisePairs"]), 5)
        self.assertLess(path.stat().st_size, runner.MAX_REPORT_BYTES)
        for pair in series["pairs"] + series["noisePairs"]:
            for arm in ("baseline", "candidate"):
                distribution = pair[arm]["metrics"][0]["distribution"]
                self.assertEqual(len(distribution["bucketCounts"]), 100001)
                self.assertEqual(sum(distribution["bucketCounts"]), 10000)
        with self.assertRaisesRegex(ValueError, "ceiling"):
            runner.atomic_json(self.root / "pretty-series.json", series)
        self.assertFalse((self.root / "pretty-series.json").exists())
        with self.assertRaisesRegex(ValueError, "ceiling"):
            runner.atomic_json(self.root / "too-large-compact.json", series, cap=1024, compact=True)
        self.assertFalse((self.root / "too-large-compact.json").exists())

    def test_missing_report_preserves_all_original_failure_artifacts(self):
        self.spec["baseline"]["command"] = [str(Path(sys.executable).resolve()), "-c", "print('{}')"]
        result = self.capture()
        self.assertEqual(result["status"], "failed")
        series = comparison.read_json(self.root / "run/series.json")
        self.assertEqual(series["pairs"], [])
        self.assertEqual(series["missingObservations"][0]["reason"], "incomplete_report")
        manifest = comparison.read_json(self.root / "run/capture/orchestration.json")
        self.assertEqual(len(manifest["processes"]), 2)
        for row in manifest["processes"]:
            self.assertTrue(Path(row["stdout"]["path"]).is_file())

    def test_stale_source_refused_and_failed_capture_receipt_retained(self):
        self.program.write_text(self.participant() + "# changed after build\n")
        result = self.capture()
        self.assertEqual(result["status"], "failed")
        self.assertIn("changed since release build", result["failure"])
        self.assertTrue((self.root / "run/capture.json").is_file())
        self.assertFalse((self.root / "run/series.json").exists())

    def test_metadata_subprocess_timeout_preserves_failed_capture_receipt(self):
        with mock.patch.object(runner, "run_suite", side_effect=subprocess.TimeoutExpired("git", 30)):
            result = self.capture()
        self.assertEqual(result["status"], "failed")
        self.assertIn("timed out", result["failure"])
        persisted = comparison.read_json(self.root / "run/capture.json")
        self.assertEqual(persisted["status"], "failed")

    def test_timeout_retains_partial_native_data_and_reaps_owner(self):
        command = [str(Path(sys.executable).resolve()), "-c",
                   "import time; print('{',flush=True); time.sleep(30)"]
        self.spec["baseline"]["command"] = command
        real_run = runner.run_process

        def bounded(command, directory, limits, *args, **kwargs):
            return real_run(command, directory, runner.ProcessLimits(0.15, grace_seconds=0.1), *args, **kwargs)

        with mock.patch.object(runner, "run_process", side_effect=bounded):
            result = self.capture()
        self.assertEqual(result["status"], "failed")
        manifest = comparison.read_json(self.root / "run/capture/orchestration.json")
        row = next(item for item in manifest["processes"] if item["observation"]["arm"] == "baseline")
        self.assertEqual(row["status"], "timed_out")
        self.assertTrue(row["cleanup"]["owner_reaped"])
        self.assertEqual(Path(row["stdout"]["path"]).read_text(), "{\n")

    def test_unknown_contention_cannot_become_controlled_qualification(self):
        self.spec["host"]["contention"] = "unknown"
        self.assertEqual(self.capture()["status"], "completed")
        series = comparison.read_json(self.root / "run/series.json")
        self.assertTrue(series["informationalOnly"])
        self.assertTrue(series["pairs"][0]["hostContended"])

    def test_existing_output_never_overwritten(self):
        self.assertEqual(self.capture()["status"], "completed")
        original = (self.root / "run/capture.json").read_bytes()
        with self.assertRaises(FileExistsError):
            self.capture()
        self.assertEqual((self.root / "run/capture.json").read_bytes(), original)

    def test_mismatching_native_policy_is_preserved_as_capture_failure(self):
        self.spec["scheduler_policy"] = "operator-guessed-policy"
        result = self.capture()
        self.assertEqual(result["status"], "failed")
        self.assertIn("workload policy differs", result["failure"])
        self.assertTrue((self.root / "run/capture/orchestration.json").is_file())

    def test_collected_envelope_identity_prevents_later_artifact_substitution(self):
        real_suite = runner.run_suite

        def changed_report(*args, **kwargs):
            manifest = real_suite(*args, **kwargs)
            row = manifest["processes"][0]
            path = Path(row["stdout"]["path"]).parent / "benchmark-envelope.json"
            report = comparison.read_json(path)
            report["qualificationLimitations"] = []
            runner.atomic_json(path, report)
            return manifest

        with mock.patch.object(runner, "run_suite", side_effect=changed_report):
            result = self.capture()
        self.assertEqual(result["status"], "failed")
        self.assertIn("envelope changed", result["failure"])

    def test_evaluation_retains_classified_decision_on_nonzero_exit(self):
        self.assertEqual(self.capture()["status"], "completed")
        policy = self.root / "policy.json"
        policy.write_text('{"mode":"required"}\n')
        evaluator = self.root / "evaluator"
        evaluator.write_text("#!" + sys.executable + "\nimport json,sys\n"
            "assert sys.argv[1]=='evaluate'\n"
            "print(json.dumps({'status':'measuredRegression','exitCode':7}))\n"
            "sys.exit(7)\n")
        evaluator.chmod(0o755)
        original_policy = policy.read_bytes()
        result = comparison.evaluate_series(self.root / "run/series.json", policy, evaluator,
            self.root / "evaluation", runner.Cancellation())
        self.assertEqual(result["status"], "process_failed")
        self.assertEqual(result["decision"]["status"], "measuredRegression")
        self.assertEqual(result["process"]["exit_code"], 7)
        self.assertEqual(policy.read_bytes(), original_policy)
        self.assertTrue((self.root / "evaluation/evaluation.json").is_file())

    def test_linux_allocation_requires_affinity_quota_and_memory_visibility(self):
        environment = {"operating_system": "Linux-test", "logical_cpu_count": 32,
            "cpu_affinity": [2, 3], "cpu_quota": {"state": "finite", "effective_cores": 1},
            "memory_bytes": 1024, "memory_limit_bytes": 512, "memory_limit_state": "finite"}
        cpu, memory = comparison.allocation(environment)
        self.assertEqual(memory, 512)
        self.assertEqual(json.loads(cpu)["cpu_quota"]["effective_cores"], 1)
        for field in ("cpu_affinity", "cpu_quota", "memory_limit_state"):
            missing = copy.deepcopy(environment)
            missing[field] = None
            self.assertEqual(comparison.allocation(missing), (None, None))

    def test_cgroup_v2_ancestor_caps_and_explicit_unlimited_are_distinct(self):
        root = self.root / "cgroup"
        leaf = root / "group/job"
        leaf.mkdir(parents=True)
        membership = self.root / "membership"
        membership.write_text("0::/group/job\n")
        (root / "cpu.max").write_text("max 100000\n")
        (root / "memory.max").write_text("max\n")
        unlimited = runner.linux_cgroup_limits(root, membership)
        self.assertEqual(unlimited["cpu_quota"]["state"], "unlimited")
        self.assertEqual(unlimited["memory_limit_state"], "unlimited")
        (leaf / "cpu.max").write_text("200000 100000\n")
        (root / "group/cpu.max").write_text("100000 100000\n")
        (leaf / "memory.max").write_text("2048\n")
        (root / "group/memory.max").write_text("1024\n")
        finite = runner.linux_cgroup_limits(root, membership)
        self.assertEqual(finite["cpu_quota"]["effective_cores"], 1)
        self.assertEqual(finite["memory_limit_bytes"], 1024)
        (leaf / "cpu.max").write_text("malformed\n")
        unknown = runner.linux_cgroup_limits(root, membership)
        self.assertIsNone(unknown["cpu_quota"])
        self.assertEqual(unknown["memory_limit_state"], "unavailable")

    def test_host_allocation_change_invalidates_capture_with_logs_retained(self):
        original = runner.environment()
        changed = dict(original, logical_cpu_count=(original["logical_cpu_count"] or 1) + 1)
        with mock.patch.object(runner, "environment", side_effect=[original, original, changed, original, original]):
            result = self.capture()
        self.assertEqual(result["status"], "failed")
        self.assertIn("host allocation changed", result["failure"])
        self.assertTrue((self.root / "run/capture/orchestration.json").is_file())


if __name__ == "__main__":
    unittest.main()
