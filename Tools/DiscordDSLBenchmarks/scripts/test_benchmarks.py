# File: Tools/DiscordDSLBenchmarks/scripts/test_benchmarks.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Deterministic failure, isolation and budget checks; no compiler timing assertions."""

import copy
import contextlib
import io
import json
import signal
import sys
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import subprocess

import baseline
import run_authoring
import compile_benchmarks as compiler


def process_receipt(directory, status="completed", stdout=b"", stderr=b"", elapsed=1):
    """Provide exact bounded supervisor output for unit conversion tests, with no subprocess mutation."""
    directory.mkdir(parents=True)
    (directory / "stdout.log").write_bytes(stdout)
    (directory / "stderr.log").write_bytes(stderr)
    result = {"status": status, "elapsed_ns": elapsed,
              "cleanup": {"owner_reaped": True, "group_has_live_members_after_cleanup": False, "unexpected_descendants": False},
              "dropped_bytes": {"stdout": 0, "stderr": 0, "report_files": 0}}
    (directory / "process.json").write_text(json.dumps(result))
    return result


def reports():
    """Provide finite synthetic complete matrices for parser and threshold tests only."""
    environment = {"compiler": "Swift version 6.4", "operatingSystem": "test", "architecture": "test",
                   "processorCount": 4, "hardwareModel": "test", "physicalMemoryBytes": 1024}
    compile_report = {"schemaVersion": 1, "configuration": {"samples": 1, "jobs": 4, "handlerCounts": [10, 100, 1000],
                      "modes": ["manual", "macro"], "handlersPerFile": 10, "optionsPerHandler": 1,
                      "configuration": "debug", "buildSystem": "native", "dependencyColdBuildIncluded": False}, "environment": environment,
                      "fixtureHash": "a" * 64, "resolutionHash": "b" * 64, "workloads": []}
    runtime_report = {"schemaVersion": 1, "configuration": {"invocations": 1000, "handlerCounts": [10, 100, 1000],
                      "concurrency": 8, "sampleLimit": 1000, "payloadBytes": 64, "minimumDurationSeconds": 0}, "environment": environment,
                      "workloads": []}
    for count in (10, 100, 1000):
        for mode in ("manual", "macro"):
            compile_report["workloads"].append({"mode": mode, "handlerCount": count, "functionalGatesPassed": True,
                "samples": [{"clean": {"wallSeconds": 2, "peakRSSBytes": 100},
                             "incremental": {"wallSeconds": 1, "peakRSSBytes": 100}, "binaryBytes": 100}]})
        for mode in ("direct", "dsl"):
            row = {"mode": mode, "handlerCount": count, "functionalGatesPassed": True, "invocations": 1000,
                   "planCompilationMilliseconds": 1, "durationSeconds": 10, "invocationsPerSecond": 100,
                   "latency": {"sampleCount": 1000, "p50Milliseconds": 1, "p95Milliseconds": 2, "p99Milliseconds": 3},
                   "schemaBuilds": count, "schemasAfterInvocations": count,
                   "accountedState": {"declaredHandlers": count, "retainedSchemas": count, "fixedInteractionCount": count,
                        "fixedInteractionJSONBytes": 1000, "registrationJSONBytes": 1000, "routeMetadataJSONBytes": 1000,
                        "planDescriptionTextBytes": 0 if mode == "direct" else 1000, "maximumWorkers": 8,
                        "maximumLatencySamples": 1000, "maximumMemorySamples": 121, "maximumPayloadBytes": 64,
                        "maximumActualInvocations": 100_000_000},
                   "counters": {"schemas": 0, "handlers": 1000, "callbacks": 1000, "activeWorkers": 0, "peakWorkers": 8},
                   "implicitHydrationRequests": 0, "implicitRegistrationRequests": 0,
                   "cleanup": {"activeHandlers": 0, "activeAcknowledgements": 0, "acknowledgementBytes": 0, "activeWorkers": 0}}
            for snapshot in baseline.SNAPSHOTS:
                row[snapshot] = {"peakRSSBytes": 100, "residentBytes": 100, "cpuSeconds": 1,
                                 "liveAllocationBlocks": 20, "liveAllocationBytes": 100}
            row["memoryObservations"] = [{"elapsedSeconds": 1, "completedInvocations": 100,
                                           "process": copy.deepcopy(row["afterPlan"])}]
            runtime_report["workloads"].append(row)
    return compile_report, runtime_report


class CompilerFixtureTests(unittest.TestCase):
    """Generated work is finite, concrete and preserves runtime product independence."""

    def test_concrete_handlers_and_bounded_file_groups(self):
        for count in compiler.COUNTS:
            for macro in (False, True):
                source = compiler.generated_sources(count, macro)
                handlers = [text for name, text in source.items() if name.startswith("Handlers")]
                self.assertEqual(len(handlers), count // 10)
                self.assertEqual(sum(text.count(": SlashCommandHandler") for text in handlers), count)
                self.assertTrue(all(text.count(": SlashCommandHandler") == 10 for text in handlers))
                self.assertEqual(sum(text.count("@SlashCommand") for text in handlers), count if macro else 0)
                self.assertNotIn("DiscordDSLMacros", "".join(source.values()) if not macro else "")
                self.assertIn(f"compiled.routes.count == {count}", source["Main.swift"])
                first = source["Handlers000.swift"]
                self.assertNotEqual(first, first.replace('fixture \\(', 'edited \\(', 1))
        for invalid in (0, 11, 1001, 10000):
            with self.assertRaises(ValueError):
                compiler.generated_sources(invalid, True)

    def test_module_fanout_is_hash_bound_and_rejects_invalid_populations(self):
        """Module dimensions alter exact fixture hashes and reject unsupported workspace inputs first."""
        one = compiler.generated_sources(100, False, 1)
        ten = compiler.generated_sources(100, False, 10)
        self.assertIn("0..<1", one["Main.swift"])
        self.assertIn("0..<10", ten["Main.swift"])
        self.assertIn('Module(id: "module\\(index)")', ten["Main.swift"])
        self.assertEqual(one["Handlers000.swift"], ten["Handlers000.swift"])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "Main.swift"
            path.write_text(one["Main.swift"])
            first = compiler.digest_files([path], root)
            path.write_text(ten["Main.swift"])
            self.assertNotEqual(first, compiler.digest_files([path], root))
            for counts, modules in (((), 1), ((10, 10), 1), ((11,), 1), ((10,), 2), ((100,), 0)):
                with self.assertRaises(ValueError):
                    compiler.prepare_workspace(root, root / "must-not-exist", counts, modules)
                self.assertFalse((root / "must-not-exist").exists())

    def test_integer_wall_receipt_keeps_full_monotonic_population(self):
        """Compiler timing preserves shared launch-through-reap nanoseconds before parsing diagnostics."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def supervise(command, destination, limits, cancellation, **kwargs):
                """Provide a completed shared-supervisor receipt without starting any compiler."""
                return process_receipt(destination, stderr=b"123 maximum resident set size\n", elapsed=2_000_000_023)
            with mock.patch.object(compiler.SUPERVISOR, "run_process", side_effect=supervise), mock.patch.object(compiler.platform, "system", return_value="Darwin"):
                result = compiler.run_timed(["swift"], 1, root, root / "log")
            self.assertEqual(result["wallNanoseconds"], 2_000_000_023)
            self.assertEqual(result["wallSeconds"], 2_000_000_023 / 1e9)
            self.assertIn("collection", result["wallSemantics"])
            self.assertTrue(Path(result["processReceipt"]).is_file())
            self.assertEqual(result["command"], ["/usr/bin/time", "-l", "swift"])
            self.assertEqual(result["workingDirectory"], str(root))

    def test_workspace_does_not_overwrite_unrelated_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "important").write_text("retain")
            with self.assertRaises(ValueError):
                compiler.prepare_workspace(root, root)
            self.assertEqual((root / "important").read_text(), "retain")

    def test_selected_build_paths_remove_stale_generated_sources_and_macro_dependency(self):
        """A manual-only consumer does not bootstrap the authoring package; reuse hashes only selected sources."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pin = root / "Tests/Fixtures/DSLCompile/Package.resolved"
            pin.parent.mkdir(parents=True)
            pin.write_text('{"pins": []}')
            workspace = root / "consumer"
            self.assertEqual(compiler.prepare_workspace(root, workspace, (10, 100)),
                             ["Manual10", "Macro10", "Manual100", "Macro100"])
            self.assertEqual(compiler.prepare_workspace(root, workspace, (10,), modes=("manual",)), ["Manual10"])
            manifest = (workspace / "Package.swift").read_text()
            self.assertNotIn('.package(name: "DiscordDSLMacros"', manifest)
            self.assertNotIn("DiscordDSLMacros", (workspace / "Sources/Warmup/Warmup.swift").read_text())
            self.assertEqual(sorted(path.name for path in (workspace / "Sources").iterdir()), ["Manual10", "Warmup"])
            for modes in ((), ("manual", "manual"), ("unknown",)):
                with self.assertRaises(ValueError):
                    compiler.prepare_workspace(root, root / "rejected", (10,), modes=modes)
                self.assertFalse((root / "rejected").exists())

    def test_build_input_identity_includes_manifests_and_pins_without_changing_legacy_source_hash(self):
        """A manifest-only edit changes build identity while retaining source-only historical hashes."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Sources/Runtime.swift"
            source.parent.mkdir()
            source.write_text("struct Runtime {}")
            manifest = root / "Package.swift"
            manifest.write_text("original manifest")
            before = compiler.repository_inputs(root)
            manifest.write_text("changed manifest")
            after = compiler.repository_inputs(root)
            self.assertEqual(before["sourceHash"], after["sourceHash"])
            self.assertNotEqual(before["buildInputHash"], after["buildInputHash"])
            self.assertNotEqual(before["manifestAndPinHashes"], after["manifestAndPinHashes"])
            source.write_text("struct Changed {}")
            self.assertNotEqual(after["sourceHash"], compiler.repository_inputs(root)["sourceHash"])

    def test_native_time_cpu_and_rss_are_distinct_resource_gauges(self):
        """Parse reported zero CPU, platform RSS units and an explicitly unavailable CPU pair."""
        darwin = compiler.parse_time_resources("1.25 real 0.75 user 0.00 sys\n123 maximum resident set size", "Darwin")
        self.assertEqual((darwin["cpuUserSeconds"], darwin["cpuSystemSeconds"], darwin["cpuSeconds"]), (.75, 0, .75))
        self.assertEqual(darwin["peakRSSBytes"], 123)
        self.assertIsNone(darwin["cpuUnavailableReason"])
        linux = compiler.parse_time_resources("User time (seconds): 0.75\nSystem time (seconds): 0.25\nMaximum resident set size (kbytes): 123", "Linux")
        self.assertEqual(linux["cpuSeconds"], 1)
        self.assertEqual(linux["peakRSSBytes"], 125952)
        missing = compiler.parse_time_resources("123 maximum resident set size", "Darwin")
        self.assertIsNone(missing["cpuSeconds"])
        self.assertIn("omitted", missing["cpuUnavailableReason"])

    def test_probe_matrix_keeps_noop_startup_and_incremental_scopes_separate(self):
        """An injected build creates only finite fixture outputs; every additional probe has its own command."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pin = root / "Tests/Fixtures/DSLCompile/Package.resolved"
            pin.parent.mkdir(parents=True)
            pin.write_text('{"pins": []}')
            workspace = root / "consumer"
            commands = []

            def timed(command, timeout, repository, log_path):
                """Model a completed command and the one generated binary without launching a compiler."""
                commands.append(command)
                binary = workspace / "build/test/debug/Manual10"
                if "--product" in command:
                    binary.parent.mkdir(parents=True, exist_ok=True)
                    binary.write_bytes(b"bounded binary")
                return {"wallSeconds": 1, "wallNanoseconds": 1_000_000_000, "peakRSSBytes": 1,
                        "command": command, "stdoutSHA256": compiler.hashlib.sha256(b"qualified 10 inert declarations\n").hexdigest()}

            original_incremental = compiler.run_incremental

            def edited(source, command, timeout, repository, log_path):
                """Retain the unpatched edit helper while replacing only the subprocess clock."""
                return original_incremental(source, command, timeout, repository, log_path, timed)

            def captured(command, repository):
                """Return exact finite environment command values without subprocesses."""
                return "a" * 40 if command[0] == "git" else "{}" if "-print-target-info" in command else "qualified 10 inert declarations"

            with mock.patch.object(compiler, "environment", return_value={}), mock.patch.object(compiler, "capture", side_effect=captured), \
                    mock.patch.object(compiler, "run_timed", side_effect=timed), mock.patch.object(compiler, "run_incremental", side_effect=edited):
                report = compiler.run_matrix(root, workspace, "swift", 4, 60, 1, root / "cache", (10,), 1, ("manual",), True)
            sample = report["workloads"][0]["samples"][0]
            self.assertEqual(len(commands), 5)
            self.assertEqual(commands[1], commands[2])
            self.assertEqual(len(sample["coldStartup"]["command"]), 1)
            self.assertIn("not isolated package planning", sample["noOpBuild"]["scope"])
            self.assertIn("OS file cache not flushed", sample["coldStartup"]["scope"])
            self.assertEqual(report["configuration"]["additionalProbes"], ["no-op-build", "cold-startup"])
            self.assertEqual(report["configuration"]["modes"], ["manual"])
            self.assertNotIn("edited", (workspace / "Sources/Manual10/Handlers000.swift").read_text())

    def test_target_cleanup_preserves_dependencies(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            consumer = root / "test/debug/Manual10.build"
            dependency = root / "test/debug/DiscordCommandDSL.build"
            for path in (consumer, dependency):
                path.mkdir(parents=True)
                (path / "object.o").write_bytes(b"object")
                (path / "output-file-map.json").write_text("{}")
            self.assertTrue(compiler.remove_consumer_outputs(root, "Manual10"))
            self.assertFalse((consumer / "object.o").exists())
            self.assertTrue((consumer / "output-file-map.json").exists())
            self.assertTrue(dependency.exists())
            with self.assertRaises(ValueError):
                compiler.remove_consumer_outputs(root, "../DiscordCommandDSL")

    def test_hash_ignores_mtime_and_includes_names(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            one = root / "one.swift"
            one.write_text("one")
            before = compiler.digest_files([one], root)
            one.touch()
            self.assertEqual(before, compiler.digest_files([one], root))
            two = root / "two.swift"
            one.rename(two)
            self.assertNotEqual(before, compiler.digest_files([two], root))

    def test_incremental_restores_source_after_success_or_compiler_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Handlers.swift"
            original = b'fixture \\(arguments.text)\nfixture \\(arguments.text)'
            for fail in (False, True):
                source.write_bytes(original)

                def timed(command, timeout, repository, log_path):
                    self.assertEqual(source.read_bytes().count(b"edited"), 1)
                    self.assertEqual(source.read_bytes().count(b"fixture"), 1)
                    if fail:
                        raise RuntimeError("compiler failed")
                    return {"wallSeconds": 1, "peakRSSBytes": 100}

                if fail:
                    with self.assertRaises(RuntimeError):
                        compiler.run_incremental(source, ["swift"], 1, root, root / "log", timed)
                else:
                    self.assertEqual(compiler.run_incremental(source, ["swift"], 1, root, root / "log", timed)["wallSeconds"], 1)
                self.assertEqual(source.read_bytes(), original)
            source.write_text("unrelated source")
            with self.assertRaises(ValueError):
                compiler.run_incremental(source, ["swift"], 1, root, root / "log", timed)
            self.assertEqual(source.read_text(), "unrelated source")

    def test_process_failure_and_missing_rss_rejected(self):
        """Supervisor failure and absent /usr/bin/time evidence cannot become qualified compiler rows."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for status in ("process_failed", "timed_out", "completed"):
                def supervise(command, destination, limits, cancellation, **kwargs):
                    """Supply a finite failed or resource-incomplete supervisor receipt."""
                    return process_receipt(destination, status=status, stderr=b"no resource evidence\n")
                with mock.patch.object(compiler.SUPERVISOR, "run_process", side_effect=supervise):
                    with self.assertRaises(RuntimeError):
                        compiler.run_timed(["swift"], 1, root, root / "log")

    def test_process_resource_evidence_uses_platform_units(self):
        """The supervisor retains raw time diagnostics; platform RSS units are converted exactly once."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for system, output, expected in (("Darwin", b"123 maximum resident set size\n", 123),
                                              ("Linux", b"Maximum resident set size (kbytes): 123\n", 125952)):
                def supervise(command, destination, limits, cancellation, **kwargs):
                    """Check exact command delegation and provide bounded platform diagnostics."""
                    self.assertEqual(command[:2], ["/usr/bin/time", "-l" if system == "Darwin" else "-v"])
                    self.assertEqual(kwargs["cwd"], root)
                    return process_receipt(destination, stderr=output)
                with mock.patch.object(compiler.SUPERVISOR, "run_process", side_effect=supervise), mock.patch.object(compiler.platform, "system", return_value=system):
                    self.assertEqual(compiler.run_timed(["swift"], 1, root, root / "log")["peakRSSBytes"], expected)

    def test_linux_completed_receipt_does_not_require_darwin_live_member_probe(self):
        """Linux shared cleanup has no Darwin ps live-member probe; successful reap/status still establish ownership."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def supervise(command, destination, limits, cancellation, **kwargs):
                """Model the shared Linux receipt after its process-group cleanup already succeeded."""
                result = process_receipt(destination)
                result["cleanup"]["group_has_live_members_after_cleanup"] = None
                return result
            with mock.patch.object(compiler.SUPERVISOR, "run_process", side_effect=supervise):
                result = compiler.run_supervised(["fixture"], 1, root, root / "process")
            self.assertEqual(result["status"], "completed")
            self.assertTrue(result["cleanup"]["owner_reaped"])
            self.assertIsNone(result["cleanup"]["group_has_live_members_after_cleanup"])

    def test_real_timeout_cancel_and_diagnostic_excess_join_process_groups(self):
        """Real Python-only scripts exercise timeout, SIGTERM forwarding and diagnostic overflow cleanup."""
        spawned = "import subprocess,sys,time; child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); print(child.pid,flush=True); "
        scripts = {
            "timed_out": spawned + "time.sleep(60)",
            "cancelled": spawned + "import os,signal; os.kill(os.getppid(),signal.SIGTERM); time.sleep(60)",
            "diagnostic_limit_exceeded": "import sys,time; sys.stdout.write('x'*1000000); sys.stdout.flush(); time.sleep(60)",
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for status, script in scripts.items():
                handlers = {value: signal.getsignal(value) for value in (signal.SIGINT, signal.SIGTERM)}
                destination = root / status
                limits = compiler.SUPERVISOR.ProcessLimits(.15 if status == "timed_out" else 5,
                    grace_seconds=.1, diagnostic_bytes=1024, sample_seconds=.01)
                with self.assertRaisesRegex(RuntimeError, status):
                    compiler.run_supervised([sys.executable, "-c", script], limits.timeout_seconds,
                        root, destination, limits=limits)
                receipt = json.loads((destination / "process.json").read_text())
                self.assertEqual(receipt["status"], status)
                self.assertTrue(receipt["cleanup"]["owner_reaped"])
                self.assertFalse(receipt["cleanup"]["group_has_live_members_after_cleanup"])
                self.assertLessEqual((destination / "stdout.log").stat().st_size + (destination / "stderr.log").stat().st_size, 1024)
                if status == "diagnostic_limit_exceeded":
                    self.assertGreater(receipt["dropped_bytes"]["stdout"], 0)
                for value, handler in handlers.items():
                    self.assertEqual(signal.getsignal(value), handler)

    def test_real_capture_is_bounded_and_restores_handlers(self):
        """Environment/catalog capture shares cleanup and fails instead of returning truncated over-budget evidence."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.assertEqual(compiler.capture([sys.executable, "-c", "print('qualified local fixture')"], root), "qualified local fixture")
            handlers = {value: signal.getsignal(value) for value in (signal.SIGINT, signal.SIGTERM)}
            with self.assertRaisesRegex(RuntimeError, "diagnostic_limit_exceeded"):
                compiler.capture([sys.executable, "-c", "print('x'*1000000)"], root)
            for value, handler in handlers.items():
                self.assertEqual(signal.getsignal(value), handler)


class AuthoringDriverTests(unittest.TestCase):
    """The convenience driver delegates lifecycle supervision and declares equivalent paired work."""

    def test_equivalent_arms_and_shared_counterbalance(self):
        """Every dimension is identical across fresh-process arms except the explicit direct/DSL mode."""
        from argparse import Namespace
        arguments = Namespace(executable=Path("binary"), receipt=Path("receipt.json"), output_dir=Path("results"),
                              profile="standard", seed=7, handlers=100, modules=10, invocations=128,
                              definitions=3, warmup_invocations=16, concurrency=2)
        command = run_authoring.supervised_command(arguments)
        direct = json.loads(command[command.index("--baseline-command") + 1])
        dsl = json.loads(command[command.index("--candidate-command") + 1])
        self.assertEqual(direct[:-1], dsl[:-1])
        self.assertEqual(direct[-1], "direct")
        self.assertEqual(dsl[-1], "dsl")
        self.assertEqual(command[command.index("--profile") + 1], "standard")
        self.assertEqual(command[command.index("--baseline-receipt") + 1], command[command.index("--candidate-receipt") + 1])
        self.assertIn("{output}", direct)
        self.assertIn("{concurrency}", direct)

    def test_driver_propagates_failure_and_rejects_before_subprocess(self):
        """Unknown dimensions start no process; a shared supervisor failure remains nonzero."""
        base = ["--executable", "binary", "--receipt", "receipt", "--output-dir", "results"]
        with mock.patch.object(run_authoring.subprocess, "run", return_value=mock.Mock(returncode=17)) as run:
            self.assertEqual(run_authoring.main(base), 17)
            self.assertEqual(run.call_count, 1)
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                run_authoring.main(base + ["--modules", "11"])
            self.assertEqual(run.call_count, 1)


class BaselineTests(unittest.TestCase):
    """Complete evidence and separate finite budgets fail closed on malformed reports."""

    def setUp(self):
        self.compile, self.runtime = reports()
        self.record = baseline.record(self.compile, self.runtime)
        self.budgets = baseline.budgets(self.record)

    def test_record_does_not_set_budgets_and_roundtrip_checks(self):
        self.assertNotIn("limits", self.record)
        self.assertTrue(baseline.check(self.record, self.budgets, self.compile, self.runtime)["passed"])
        self.assertGreater(len(self.record["measurements"]), 100)

    def test_regressions_cover_compile_tail_throughput_and_rss(self):
        self.compile["workloads"][0]["samples"][0]["clean"]["wallSeconds"] = 30
        row = self.runtime["workloads"][0]
        row["latency"]["p99Milliseconds"] = 30
        row["invocationsPerSecond"] = 1
        row["durationSeconds"] = 1000
        row["afterCleanup"]["residentBytes"] = 100_000_000
        result = baseline.check(self.record, self.budgets, self.compile, self.runtime)
        self.assertFalse(result["passed"])
        self.assertEqual(len(result["misses"]), 5)

    def test_incomplete_and_duplicate_matrices_rejected(self):
        for kind in ("compile", "runtime"):
            for duplicate in (False, True):
                report = copy.deepcopy(self.compile if kind == "compile" else self.runtime)
                report["workloads"].pop()
                if duplicate:
                    report["workloads"].append(report["workloads"][0])
                with self.assertRaises(ValueError):
                    baseline.collect_report(report, kind)

    def test_functional_gates_cleanup_and_schema_growth_rejected(self):
        mutations = [lambda row: row.update(functionalGatesPassed=False),
                     lambda row: row["cleanup"].update(activeHandlers=1),
                     lambda row: row.update(schemasAfterInvocations=10000),
                     lambda row: row.update(schemaBuilds=0, schemasAfterInvocations=0),
                     lambda row: row.update(invocations=1),
                     lambda row: row.update(invocations=True),
                     lambda row: row["latency"].update(p95Milliseconds=100),
                     lambda row: row["latency"].update(sampleCount=1001),
                     lambda row: row["afterCleanup"].update(peakRSSBytes=0),
                     lambda row: row["accountedState"].update(maximumWorkers=9),
                     lambda row: row["accountedState"].update(retainedSchemas=0),
                     lambda row: row["counters"].update(peakWorkers=9),
                     lambda row: row["counters"].update(callbacks=999),
                     lambda row: row.update(implicitHydrationRequests=1),
                     lambda row: row.update(memoryObservations=[]),
                     lambda row: row["memoryObservations"][0].update(elapsedSeconds=11),
                     lambda row: row["memoryObservations"][0].update(completedInvocations=1001)]
        for mutate in mutations:
            report = copy.deepcopy(self.runtime)
            mutate(report["workloads"][0])
            with self.assertRaises(ValueError):
                baseline.collect_report(report, "runtime")

    def test_configuration_bounds_are_not_overridden_by_success_assertion(self):
        for key, value in (("invocations", True), ("concurrency", 0), ("concurrency", 65), ("sampleLimit", 100_001),
                           ("payloadBytes", 1025), ("minimumDurationSeconds", 1801), ("handlerCounts", [10])):
            report = copy.deepcopy(self.runtime)
            report["configuration"][key] = value
            with self.assertRaises(ValueError):
                baseline.collect_report(report, "runtime")

    def test_compiler_supervised_boundary_cannot_reuse_legacy_budget(self):
        """Gross supervised build costs have an explicit configuration identity distinct from old wall timers."""
        self.compile["configuration"]["timingBoundary"] = "supervised-process-lifetime-v1"
        with self.assertRaises(ValueError):
            baseline.check(self.record, self.budgets, self.compile, self.runtime)

    def test_duration_floor_requires_real_elapsed_time(self):
        self.runtime["configuration"]["minimumDurationSeconds"] = 60
        with self.assertRaises(ValueError):
            baseline.collect_report(self.runtime, "runtime")

    def test_nonfinite_negative_bool_missing_and_incompatible_evidence_rejected(self):
        for value in (float("nan"), float("inf"), -1, True, None):
            report = copy.deepcopy(self.compile)
            report["workloads"][0]["samples"][0]["clean"]["wallSeconds"] = value
            with self.assertRaises(ValueError):
                baseline.collect_report(report, "compile")
        self.runtime["environment"]["compiler"] = "other compiler"
        with self.assertRaises(ValueError):
            baseline.check(self.record, self.budgets, self.compile, self.runtime)

    def test_unavailable_environment_cannot_become_a_baseline(self):
        for key in baseline.ENVIRONMENT_KEYS:
            report = copy.deepcopy(self.runtime)
            report["environment"][key] = "unavailable"
            with self.assertRaises(ValueError):
                baseline.collect_report(report, "runtime")

    def test_budget_binding_coverage_and_direction_rejected(self):
        for mutate in (lambda budget: budget.update(baselineHash="bad"),
                       lambda budget: budget["limits"].pop(next(iter(budget["limits"]))),
                       lambda budget: budget["limits"].update({next(iter(budget["limits"])): {"minimum": 1}})):
            budget = copy.deepcopy(self.budgets)
            mutate(budget)
            with self.assertRaises(ValueError):
                baseline.check(self.record, budget, self.compile, self.runtime)

    def test_finite_tolerances_and_time_units(self):
        for value in (float("nan"), float("inf"), -0.1, 1.1):
            with self.assertRaises(ValueError):
                baseline.budgets(self.record, value)
        self.assertAlmostEqual(self.budgets["limits"]["compile.manual.10.0.clean.wallSeconds"]["maximum"], 2.200001)
        self.assertAlmostEqual(self.budgets["limits"]["runtime.direct.10.planCompilationMilliseconds"]["maximum"], 1.101)
        self.assertEqual(self.budgets["limits"]["runtime.direct.10.invocationsPerSecond"]["minimum"], 90)

    def test_submillisecond_tail_regression_exceeds_reviewed_observation_floor(self):
        self.runtime["workloads"][0]["latency"].update(p50Milliseconds=0.1, p95Milliseconds=0.15, p99Milliseconds=0.2)
        measured = baseline.record(self.compile, self.runtime)
        reviewed = baseline.budgets(measured)
        self.runtime["workloads"][0]["latency"]["p99Milliseconds"] = 0.4
        result = baseline.check(measured, reviewed, self.compile, self.runtime)
        self.assertFalse(result["passed"])
        self.assertEqual([miss["metric"] for miss in result["misses"]], ["runtime.direct.10.latency.p99Milliseconds"])
        self.assertAlmostEqual(result["misses"][0]["maximum"], 0.221)
        # The superseded 1 ms floor would conceal this twofold tail-latency change.
        self.assertTrue(baseline.check(measured, baseline.budgets(measured, time_floor=0.001), self.compile, self.runtime)["passed"])

    def test_json_nonfinite_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            path.write_text('{"value": NaN}')
            with self.assertRaises(ValueError):
                baseline.read(path)
            path.write_text('{"value": 1, "value": 2}')
            with self.assertRaises(ValueError):
                baseline.read(path)


class LinuxHardwareIdentityTests(unittest.TestCase):
    """Hardware models carry native evidence instead of silently aliasing architectures."""

    def test_dmi_and_device_tree_sources(self):
        """DMI is preferred; ARM models strip NUL bytes only after bounded admission."""
        self.assertEqual(compiler.linux_hardware_model(
            lambda path: "Board A\n" if "dmi" in path else "Board B"), "linux-model-v1:Board A")
        self.assertEqual(compiler.linux_hardware_model(
            lambda path: "Unknown" if "dmi" in path else "Board B\u0000\n"), "linux-model-v1:Board B")

    def test_unknown_oversized_or_missing_remain_unavailable(self):
        """No fallback to a CPU architecture can qualify an absent machine model."""
        for value in (None, "", "\n", "Unavailable", "To Be Filled By O.E.M.", "x" * 16385):
            with self.subTest(value_type=type(value).__name__):
                self.assertEqual(compiler.linux_hardware_model(lambda _path: value), "unavailable")


if __name__ == "__main__":
    unittest.main()
