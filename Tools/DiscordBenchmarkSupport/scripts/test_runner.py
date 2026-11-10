#!/usr/bin/env python3
# File: Tools/DiscordBenchmarkSupport/scripts/test_runner.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Exercise the portable driver with actual tiny subprocesses and finite budgets.

These are lifecycle/resource tests, not benchmarks: short timeout/byte budgets
make failure paths deterministic without executing Discord or network workloads.
"""

import argparse
import errno
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

import run_benchmarks as runner


class RunnerTests(unittest.TestCase):
    """Prove process isolation, bounded capture, ordering and cancellation semantics."""

    def setUp(self):
        """Give every test its own directory, including child artifacts."""
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        """Remove only this test's retained bounded artifacts."""
        self.temporary.cleanup()

    def run_python(self, source, *, name="run", limits=None, **kwargs):
        """Run literal Python under the same process owner used for native tools."""
        return runner.run_process([sys.executable, "-c", source], self.root / name,
                                  limits or runner.ProcessLimits(2, grace_seconds=0.1), **kwargs)

    def test_success_and_fresh_processes(self):
        """Every observation has a fresh PID and an awaited direct child."""
        first = self.run_python("import json,os; print(json.dumps({'pid':os.getpid()}))",
                                stdout_is_report=True, require_json=True)
        second = self.run_python("print('{}')", name="second", stdout_is_report=True, require_json=True)
        self.assertEqual(first["status"], "completed")
        self.assertTrue(first["native_json_valid"])
        self.assertTrue(first["cleanup"]["owner_reaped"])
        self.assertNotEqual(first["pid"], second["pid"])
        self.assertEqual(first["stdout"]["sha256"], runner.sha256_file(Path(first["stdout"]["path"])))
        with self.assertRaises(ChildProcessError):
            os.waitpid(first["pid"], os.WNOHANG)

    def test_incomplete_report_retains_partial_bytes(self):
        """Exit zero with truncated JSON cannot masquerade as a successful run."""
        result = self.run_python("import sys; sys.stdout.write('{\"partial\":')",
                                 stdout_is_report=True, require_json=True)
        self.assertEqual(result["status"], "incomplete_report")
        self.assertFalse(result["native_json_valid"])
        self.assertEqual(Path(result["stdout"]["path"]).read_text(), '{"partial":')
        self.assertTrue((self.root / "run/process.json").is_file())

    def test_nonfinite_report_cannot_qualify_as_complete_json(self):
        """Nonstandard NaN and overflowing JSON numbers remain invalid artifacts."""
        for index, value in enumerate(("NaN", "1e999")):
            result = self.run_python(f"print('{{\"value\":{value}}}')", name=f"nonfinite{index}",
                                     stdout_is_report=True, require_json=True)
            self.assertEqual(result["status"], "incomplete_report")

    def test_failed_process_keeps_report_and_exit_status(self):
        """A nonzero process result remains failure even with valid partial evidence."""
        result = self.run_python("import sys; print('{}'); sys.exit(7)",
                                 stdout_is_report=True, require_json=True)
        self.assertEqual(result["status"], "process_failed")
        self.assertEqual(result["exit_code"], 7)
        self.assertTrue(result["native_json_valid"])

    def test_timeout_terminates_group_kills_and_reaps(self):
        """Ignoring TERM in owner and descendant forces KILL within the grace cap."""
        pid_file = self.root / "child.pid"
        child = "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(20)"
        source = ("import subprocess,sys,signal,time,pathlib; "
                  "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                  f"p=subprocess.Popen([sys.executable,'-c',{child!r}]); "
                  f"pathlib.Path({str(pid_file)!r}).write_text(str(p.pid)); time.sleep(20)")
        started = time.monotonic()
        result = self.run_python(source, limits=runner.ProcessLimits(0.25, grace_seconds=0.15, sample_seconds=0.01))
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual(result["status"], "timed_out")
        self.assertTrue(result["cleanup"]["term_sent"])
        self.assertTrue(result["cleanup"]["kill_sent"])
        self.assertTrue(result["cleanup"]["owner_reaped"])
        pid = int(pid_file.read_text())
        # Orphan zombies are already terminated and await the platform's init;
        # they cannot run or keep descriptors open. The direct owner is reaped.
        if platform_is_linux():
            status_file = Path(f"/proc/{pid}/status")
            deadline = time.monotonic() + 0.5
            while status_file.exists() and "State:\tZ" not in status_file.read_text() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(not status_file.exists() or "State:\tZ" in status_file.read_text())
        else:
            deadline = time.monotonic() + 0.5
            while time.monotonic() < deadline:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.01)
            else:
                self.fail("owned descendant survived group cleanup")

    def test_early_owner_exit_cleans_remaining_descendant(self):
        """A child cannot outlive its owner simply by closing inherited pipes."""
        child = "import time; time.sleep(20)"
        source = ("import subprocess,sys; subprocess.Popen([sys.executable,'-c',"
                  f"{child!r}],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)")
        result = self.run_python(source, limits=runner.ProcessLimits(1, grace_seconds=0.1))
        self.assertEqual(result["status"], "cleanup_failed", json.dumps(result))
        self.assertTrue(result["cleanup"]["unexpected_descendants"])
        self.assertTrue(result["cleanup"]["term_sent"])

    def test_stale_pipe_readiness_retries_eagain_and_interruption(self):
        """Transient pipe readiness races cannot discard the cleanup classification."""
        original = os.read
        injected = []

        def interrupted_read(fd, count):
            """Inject only driver-sized reads, leaving Popen's error pipe untouched."""
            if count == 65536 and len(injected) < 2:
                error = (BlockingIOError(errno.EAGAIN, "stale readiness") if not injected else
                         InterruptedError(errno.EINTR, "interrupted read"))
                injected.append(error)
                raise error
            return original(fd, count)

        with mock.patch.object(runner.os, "read", side_effect=interrupted_read):
            result = self.run_python("print('{}')", stdout_is_report=True, require_json=True)
        self.assertEqual(len(injected), 2)
        self.assertEqual(result["status"], "completed", json.dumps(result))
        self.assertTrue(result["cleanup"]["owner_reaped"])

    def test_darwin_terminal_group_permission_race_checks_live_members(self):
        """EPERM is terminal only after a separate state check excludes live members."""
        denied = PermissionError(errno.EPERM, "orphan group transition")
        with mock.patch.object(runner.os, "killpg", side_effect=denied):
            with mock.patch.object(runner, "group_has_live_members", return_value=False):
                self.assertFalse(runner.group_exists(123456))
                self.assertFalse(runner.signal_group(123456, signal.SIGTERM))
            for live_state in (True, None):
                with mock.patch.object(runner, "group_has_live_members", return_value=live_state):
                    self.assertTrue(runner.group_exists(123456))
                    with self.assertRaises(PermissionError):
                        runner.signal_group(123456, signal.SIGTERM)

    def test_darwin_permission_race_uses_bounded_member_state_evidence(self):
        """Real group helpers distinguish zombie/absent states from live EPERM."""
        denied = PermissionError(errno.EPERM, "orphan group transition")
        with mock.patch.object(runner.platform, "system", return_value="Darwin"), \
                mock.patch.object(runner.os, "killpg", side_effect=denied):
            for states, expected in (("", False), ("Z\nZ+", False), ("S\nZ", True)):
                with mock.patch.object(runner, "capture", return_value=states) as capture:
                    self.assertEqual(runner.group_exists(123456), expected)
                    self.assertEqual(capture.call_args.kwargs["timeout_seconds"], 0.5)
                    self.assertEqual(capture.call_args.kwargs["accepted_returncodes"], (0, 1))

    def test_collection_error_still_terminates_owner_group(self):
        """An unexpected pipe failure cannot leave an exited owner's child alive."""
        original = os.read
        injected = []

        def failed_read(fd, count):
            """Let the tiny owner exit before injecting a permanent collection error."""
            if count == 65536 and not injected:
                injected.append(True)
                time.sleep(0.1)
                raise OSError(errno.EIO, "injected collection failure")
            return original(fd, count)

        child = "import time; time.sleep(20)"
        source = ("import subprocess,sys; subprocess.Popen([sys.executable,'-c',"
                  f"{child!r}],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); print('ready',flush=True)")
        with mock.patch.object(runner.os, "read", side_effect=failed_read):
            result = self.run_python(source, limits=runner.ProcessLimits(1, grace_seconds=0.1))
        self.assertEqual(result["status"], "launch_or_collection_failed", json.dumps(result))
        self.assertEqual(result["cleanup"]["error_errno"], errno.EIO)
        self.assertTrue(result["cleanup"]["term_sent"])
        self.assertTrue(result["cleanup"]["owner_reaped"])
        if not platform_is_linux():
            self.assertFalse(result["cleanup"]["group_has_live_members_after_cleanup"])

    def test_live_group_permission_error_is_cleanup_failure(self):
        """An unconfirmed live EPERM group is a cleanup failure with errno evidence."""
        denied = PermissionError(errno.EPERM, "live group permission failure")
        with mock.patch.object(runner, "group_exists", return_value=True), \
                mock.patch.object(runner, "signal_group", side_effect=denied):
            result = self.run_python("print('{}')")
        self.assertEqual(result["status"], "cleanup_failed", json.dumps(result))
        self.assertEqual(result["cleanup"]["error_errno"], errno.EPERM)
        self.assertEqual(result["cleanup"]["group_cleanup_error_errno"], errno.EPERM)
        self.assertTrue(result["cleanup"]["owner_reaped"])

    def test_group_permission_error_preserves_original_timeout(self):
        """A teardown permission failure cannot erase the timeout that caused it."""
        denied = PermissionError(errno.EPERM, "group permission failure")
        with mock.patch.object(runner, "signal_group", side_effect=denied):
            result = self.run_python("import time; time.sleep(20)",
                                     limits=runner.ProcessLimits(0.1, grace_seconds=0.1))
        self.assertEqual(result["status"], "timed_out", json.dumps(result))
        self.assertEqual(result["cleanup"]["error_errno"], errno.EPERM)
        self.assertTrue(result["cleanup"]["owner_reaped"])

    def test_cancellation_awaits_process_teardown(self):
        """Cancellation requests preserve evidence and join the direct owner."""
        cancellation = runner.Cancellation()
        timer = threading.Timer(0.1, cancellation.request)
        timer.start()
        try:
            result = self.run_python("import time; print('partial',flush=True); time.sleep(20)",
                                     cancellation=cancellation)
        finally:
            timer.join()
        self.assertEqual(result["status"], "cancelled")
        self.assertTrue(result["cleanup"]["owner_reaped"])
        self.assertIn(b"partial", Path(result["stdout"]["path"]).read_bytes())

    def test_prelaunch_cancellation_does_not_spawn(self):
        """Cancellation received between paired observations prevents a new process."""
        cancellation = runner.Cancellation()
        cancellation.request()
        result = self.run_python("raise AssertionError('must not run')", cancellation=cancellation)
        self.assertEqual(result["status"], "cancelled")
        self.assertIsNone(result["pid"])

    def test_bounded_diagnostics_count_truncation(self):
        """The shared stdout/stderr diagnostic budget cannot grow beyond its cap."""
        result = self.run_python("import os; os.write(1,b'x'*16384); os.write(2,b'y'*16384)",
                                 limits=runner.ProcessLimits(1, grace_seconds=0.1, diagnostic_bytes=128))
        self.assertEqual(result["status"], "diagnostic_limit_exceeded")
        self.assertLessEqual(result["stdout"]["bytes"] + result["stderr"]["bytes"], 128)
        self.assertGreater(result["dropped_bytes"]["stdout"] + result["dropped_bytes"]["stderr"], 0)

    def test_report_file_limit_retains_bounded_failure_artifact(self):
        """Oversize native output is stopped and truncated after writer teardown."""
        report = self.root / "native.json"
        source = f"import pathlib,time; pathlib.Path({str(report)!r}).write_bytes(b'x'*16384); time.sleep(20)"
        result = self.run_python(source, report_paths=[report],
                                 limits=runner.ProcessLimits(1, grace_seconds=0.1, report_bytes=128))
        self.assertEqual(result["status"], "report_limit_exceeded")
        self.assertEqual(report.stat().st_size, 128)
        self.assertEqual(result["dropped_bytes"]["report_files"], 16384 - 128)

    def test_stdout_and_sidecar_share_report_ceiling(self):
        """A source report and common envelope share the finite process report cap."""
        sidecar = self.root / "sidecar.json"
        source = (f"import pathlib,os,time; pathlib.Path({str(sidecar)!r}).write_bytes(b'x'*100); "
                  "os.write(1,b'y'*100); time.sleep(20)")
        result = self.run_python(source, report_paths=[sidecar], stdout_is_report=True,
                                 limits=runner.ProcessLimits(1, grace_seconds=0.1, report_bytes=128))
        self.assertEqual(result["status"], "report_limit_exceeded")
        self.assertLessEqual(result["stdout"]["bytes"] + sidecar.stat().st_size, 128)

    def test_rss_cap_uses_explicit_sampling_scope(self):
        """A deliberately tiny RSS budget invalidates a live allocation workload."""
        result = self.run_python("import time; data=bytearray(8*1024*1024); time.sleep(20)",
                                 limits=runner.ProcessLimits(1, grace_seconds=0.1, rss_bytes=1, sample_seconds=0.01))
        self.assertEqual(result["status"], "rss_limit_exceeded")
        self.assertGreater(result["rss"]["sampled_peak_bytes"], 1)
        self.assertIn("children excluded", result["rss"]["scope"])

    def test_pair_schedule_is_seeded_counterbalanced_and_finite(self):
        """Five pairs share within-pair seeds and alternate their execution order."""
        rows = runner.schedule(runner.PROFILES["standard"], 42, True)
        self.assertEqual(rows, runner.schedule(runner.PROFILES["standard"], 42, True))
        self.assertEqual(len(rows), 10)
        for pair in range(5):
            left, right = rows[pair * 2:pair * 2 + 2]
            self.assertNotEqual(left["arm"], right["arm"])
            self.assertEqual(left["seed"], right["seed"])
            if pair:
                self.assertNotEqual(left["arm"], rows[(pair - 1) * 2]["arm"])
        with self.assertRaises(ValueError):
            runner.schedule(runner.PROFILES["standard"], 42, False)
        self.assertEqual(len(runner.schedule(runner.PROFILES["smoke"], 42, False)), 1)

    def test_limits_reject_nonfinite_and_expanded_budgets(self):
        """Tests can lower budgets while production ceilings cannot silently expand."""
        for value in (float("inf"), float("nan"), 0, -1):
            with self.assertRaises(ValueError):
                runner.ProcessLimits(value)
        with self.assertRaises(ValueError):
            runner.ProcessLimits(1, grace_seconds=5.01)
        with self.assertRaises(ValueError):
            runner.ProcessLimits(1, diagnostic_bytes=runner.MAX_DIAGNOSTIC_BYTES + 1)
        with self.assertRaises(ValueError):
            runner.ProcessLimits(1, report_bytes=runner.MAX_REPORT_BYTES + 1)

    def test_command_is_json_array_without_shell_interpretation(self):
        """Shell punctuation stays literal and command strings are rejected."""
        command = runner.command_array('["/bin/echo", "$(touch forbidden)"]')
        self.assertEqual(command[1], "$(touch forbidden)")
        for value in ('"echo hi"', '[]', '[1]', '[""]'):
            with self.assertRaises(Exception):
                runner.command_array(value)


class ProvenanceTests(unittest.TestCase):
    """Check exact source and dependency content independently of file timestamps."""

    def setUp(self):
        """Create a small committed repository with a real dependency pin file."""
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.git("config", "user.name", "Runner test")
        self.git("config", "user.email", "runner-test@example.invalid")
        (self.root / "source.swift").write_text("fixture one\n")
        (self.root / "Package.resolved").write_text('{"pins":[]}\n')
        self.git("add", "source.swift", "Package.resolved")
        self.git("commit", "-qm", "test fixture")

    def tearDown(self):
        """Remove the isolated Git fixture after all subprocesses have exited."""
        self.temporary.cleanup()

    def git(self, *args):
        """Run only explicit test Git operations inside the temporary checkout."""
        subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)

    def test_dirty_content_and_pins_are_checked(self):
        """Changing dirty bytes twice produces distinct identities with unchanged HEAD."""
        clean = runner.source_identity(self.root)
        self.assertFalse(clean["dirty"])
        self.assertIn("Package.resolved", clean["dependency_hashes"])
        (self.root / "source.swift").write_text("fixture two\n")
        first = runner.source_identity(self.root)
        (self.root / "source.swift").write_text("fixture three\n")
        second = runner.source_identity(self.root)
        self.assertEqual(first["revision"], second["revision"])
        self.assertNotEqual(first["dirty_fingerprint_sha256"], second["dirty_fingerprint_sha256"])
        (self.root / "Package.resolved").write_text('{"pins":[1]}\n')
        pins = runner.source_identity(self.root)
        self.assertNotEqual(clean["dependency_hashes"], pins["dependency_hashes"])
        (self.root / "untracked.fixture").write_text("late fixture")
        self.assertNotEqual(pins["dirty_fingerprint_sha256"], runner.source_identity(self.root)["dirty_fingerprint_sha256"])

    def test_receipt_rejects_debug_and_executable_mismatch(self):
        """A receipt cannot accidentally authorize debug or another executable."""
        with tempfile.TemporaryDirectory() as outside:
            path = Path(outside) / "receipt.json"
            binary = Path(sys.executable).resolve()
            receipt = {"format": runner.RECEIPT_FORMAT, "version": 1, "status": "completed",
                       "optimization": "debug", "source": runner.source_identity(self.root),
                       "executable": runner.artifact(binary)}
            path.write_text(json.dumps(receipt))
            with self.assertRaisesRegex(ValueError, "release build"):
                runner.validate_receipt(path, [str(binary)])
            receipt["optimization"] = "release"
            receipt["executable"]["sha256"] = "incorrect"
            path.write_text(json.dumps(receipt))
            with self.assertRaisesRegex(ValueError, "does not match"):
                runner.validate_receipt(path, [str(binary)])

    def test_receipt_version_requires_integer_identity(self):
        """Boolean and floating receipt versions cannot impersonate integer v1."""
        with tempfile.TemporaryDirectory() as outside:
            path = Path(outside) / "receipt.json"
            binary = Path(sys.executable).resolve()
            for version in (True, 1.0):
                receipt = {"format": runner.RECEIPT_FORMAT, "version": version, "status": "completed",
                           "optimization": "release", "source": runner.source_identity(self.root),
                           "executable": runner.artifact(binary)}
                path.write_text(json.dumps(receipt))
                with self.assertRaisesRegex(ValueError, "unsupported release-build receipt"):
                    runner.validate_receipt(path, [str(binary)])

    def test_filenames_with_leading_spaces_are_hashed_exactly(self):
        """NUL-delimited Git metadata preserves valid whitespace in source names."""
        source = self.root / " leading.fixture "
        source.write_text("first")
        first = runner.source_identity(self.root)
        source.write_text("second")
        second = runner.source_identity(self.root)
        self.assertNotEqual(first["dirty_fingerprint_sha256"], second["dirty_fingerprint_sha256"])

    def suite_arguments(self, outside, source, profile="standard"):
        """Construct explicit test receipts outside the source checkout for real runs."""
        binary = Path(sys.executable).resolve()
        receipt = Path(outside) / "receipt.json"
        receipt.write_text(json.dumps({"format": runner.RECEIPT_FORMAT, "version": 1, "status": "completed",
                                      "optimization": "release", "source": runner.source_identity(self.root),
                                      "executable": runner.artifact(binary)}))
        command = [str(binary), "-c", source]
        return argparse.Namespace(profile=profile, seed=123, warmup_seconds=0, duration_seconds=1,
                                  warmup_policy="cold-process-no-in-process-warmup", concurrency=1,
                                  scheduler_policy="test-sequential", baseline_command=command,
                                  baseline_receipt=receipt, candidate_command=command,
                                  candidate_receipt=receipt, command=None, receipt=None,
                                  fixture=[self.root / "source.swift"], output_dir=Path(outside) / "runs",
                                  scenario="tiny-lifecycle-fixture")

    def test_standard_runs_ten_fresh_processes_and_preserves_common_artifacts(self):
        """Execute all five pairs, checking seeds, distinct PIDs and JSON artifacts."""
        source = ("import json,os,pathlib; "
                  "pathlib.Path(os.environ['DK_BENCHMARK_ENVELOPE']).write_text("
                  "json.dumps({'format':'DiscordBenchmarkReport','schemaVersion':1})); "
                  "print(json.dumps({'pid':os.getpid(),'seed':os.environ['DK_BENCHMARK_SEED']}))")
        with tempfile.TemporaryDirectory() as outside:
            args = self.suite_arguments(outside, source)
            result = runner.run_suite(args, runner.Cancellation())
            self.assertEqual(result["status"], "completed")
            self.assertEqual(len(result["processes"]), 10)
            self.assertEqual(len({row["pid"] for row in result["processes"]}), 10)
            self.assertTrue(all(row["common_envelope"]["available"] for row in result["processes"]))
            manifest = json.loads((args.output_dir / "orchestration.json").read_bytes())
            self.assertEqual(manifest["status"], "completed")
            self.assertTrue(manifest["informational_only"])

    def test_missing_common_envelope_fails_without_discarding_native_report(self):
        """Native JSON alone cannot impersonate the adopted shared report sidecar."""
        with tempfile.TemporaryDirectory() as outside:
            args = self.suite_arguments(outside, "print('{}')", profile="smoke")
            result = runner.run_suite(args, runner.Cancellation())
            self.assertEqual(result["status"], "failed")
            self.assertTrue(all(row["status"] == "incomplete_report" for row in result["processes"]))
            self.assertTrue(all(row["native_json_valid"] for row in result["processes"]))

    def test_common_envelope_version_requires_integer_identity(self):
        """Boolean and floating versions cannot compare equal to integer schema v1."""
        for version in (True, 1.0):
            source = ("import json,os,pathlib; "
                      "pathlib.Path(os.environ['DK_BENCHMARK_ENVELOPE']).write_text("
                      f"json.dumps({{'format':'DiscordBenchmarkReport','schemaVersion':{version!r}}})); "
                      "print('{}')")
            with tempfile.TemporaryDirectory() as outside:
                args = self.suite_arguments(outside, source, profile="smoke")
                result = runner.run_suite(args, runner.Cancellation())
                self.assertEqual(result["status"], "failed")
                self.assertTrue(all(row["status"] == "incomplete_report" for row in result["processes"]))
                self.assertTrue(all(not row["common_envelope"]["available"] for row in result["processes"]))

    def test_source_change_during_final_observation_preserves_partial_manifest(self):
        """Post-run provenance validation invalidates even the last integrity run."""
        source = ("import json,os,pathlib; "
                  "pathlib.Path(os.environ['DK_BENCHMARK_ENVELOPE']).write_text("
                  "json.dumps({'format':'DiscordBenchmarkReport','schemaVersion':1})); "
                  f"pathlib.Path({str(self.root / 'source.swift')!r}).write_text('changed during run'); print('{{}}')")
        with tempfile.TemporaryDirectory() as outside:
            args = self.suite_arguments(outside, source, profile="smoke")
            # Use the production error handler, which changes the persisted suite
            # status after run_suite has already retained the process evidence.
            arguments = ["run", "--profile", "smoke", "--scenario", "provenance-change", "--concurrency", "1",
                         "--scheduler-policy", "test-sequential", "--fixture", str(self.root / "source.swift"),
                         "--command", json.dumps(args.baseline_command), "--receipt", str(args.baseline_receipt),
                         "--output-dir", str(args.output_dir)]
            self.assertEqual(runner.main(arguments), 1)
            manifest = json.loads((args.output_dir / "orchestration.json").read_bytes())
            self.assertEqual(manifest["status"], "failed")
            self.assertEqual(len(manifest["processes"]), 1)
            self.assertIn("changed since release build", manifest["failure"])


def platform_is_linux():
    """Detect the procfs lifecycle assertion without assuming all Unix hosts use it."""
    return sys.platform.startswith("linux")


if __name__ == "__main__":
    unittest.main()
