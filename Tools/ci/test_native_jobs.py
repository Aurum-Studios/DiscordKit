# File: Tools/ci/test_native_jobs.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Protect independent native scheduling and the compiled-artifact trust boundary."""

from contextlib import redirect_stdout
import copy
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import native_jobs as jobs


class NativePlanTests(unittest.TestCase):
    """Require a complete, nonduplicating suite partition on the intended runner sizes."""

    def test_platform_builds_precede_independent_small_suite_jobs(self):
        """Each compiled graph has one producer; platform-only targets never create empty suites."""
        modules = ["DiscordCoreTests", "DiscordUnixPlatformTests", "DiscordApplePlatformTests",
                   "DiscordFoundationTransportTests"]
        expected_modules = {
            "macos-arm64": set(modules),
            "linux-x64": set(modules) - {"DiscordFoundationTransportTests"},
            "windows-x64": set(modules) - {"DiscordFoundationTransportTests", "DiscordUnixPlatformTests"},
        }
        builds, tests = jobs.matrices(modules)
        self.assertEqual(len(builds["include"]), len(jobs.PLATFORMS) * len(jobs.COMPONENTS) - len(jobs.TIMING_PACKAGES))
        self.assertEqual(len({(entry["platform"], entry["component"]) for entry in builds["include"]}), len(builds["include"]))
        for native_platform in jobs.PLATFORMS:
            build_entries = [entry for entry in builds["include"] if entry["platform"] == native_platform]
            test_entries = [entry for entry in tests["include"] if entry["platform"] == native_platform]
            expected_components = set(jobs.COMPONENTS) - (set(jobs.TIMING_PACKAGES) if native_platform == "windows-x64" else set())
            self.assertEqual({entry["component"] for entry in build_entries}, expected_components)
            self.assertEqual({entry["component"] for entry in test_entries if entry["component"] in jobs.TIMING_PACKAGES},
                             set() if native_platform == "windows-x64" else set(jobs.TIMING_PACKAGES))
            self.assertEqual({entry["suite"] for entry in test_entries if entry["component"] == "root"},
                             expected_modules[native_platform])
            self.assertEqual({entry["suite"] for entry in test_entries if entry["component"] == "consumers"},
                             set(jobs.CONSUMER_TESTS) | set(jobs.CONSUMER_SMOKES))
            self.assertNotIn("release", {entry["component"] for entry in test_entries})
            for entry in build_entries + test_entries:
                self.assertEqual(entry["shell"], "pwsh" if native_platform == "windows-x64" else "bash")
                if native_platform == "macos-arm64":
                    self.assertEqual((entry["group"], entry["jobs"]), ("MacOS-26-5", 5))
                elif entry in build_entries:
                    self.assertTrue(entry["group"].endswith("-64"))
                else:
                    self.assertTrue(entry["group"].endswith("-8"))
        self.assertEqual(len({(entry["platform"], entry["component"], entry["suite"]) for entry in tests["include"]}), len(tests["include"]))

    def test_root_modules_come_from_evaluated_manifest(self):
        """Formatting or dependencies in Package.swift cannot confuse regular-expression target discovery."""
        document = {"targets": [{"name": "Runtime", "type": "regular"},
                                {"name": "ZTests", "type": "test"}, {"name": "ATests", "type": "test"}]}
        with patch.object(jobs.subprocess, "check_output", return_value=json.dumps(document)) as query:
            self.assertEqual(jobs.dump_targets(Path(".")), ["ATests", "ZTests"])
        self.assertIn("dump-package", query.call_args.args[0])

    def test_selected_platform_partitions_equal_complete_plan_without_overlap(self):
        """Independent platform workflows retain every original producer, suite and runner choice."""
        modules = ["DiscordCoreTests", "DiscordUnixPlatformTests", "DiscordApplePlatformTests",
                   "DiscordFoundationTransportTests"]
        complete = jobs.matrices(modules)
        partitioned = ([], [])
        for native_platform in jobs.PLATFORMS:
            selected = jobs.matrices(modules, native_platform)
            for complete_matrix, selected_matrix, gathered in zip(complete, selected, partitioned):
                with self.subTest(platform=native_platform):
                    self.assertTrue(selected_matrix["include"])
                    self.assertEqual(selected_matrix["include"], [entry for entry in complete_matrix["include"]
                        if entry["platform"] == native_platform])
                    gathered.extend(selected_matrix["include"])
        for complete_matrix, gathered in zip(complete, partitioned):
            self.assertEqual(gathered, complete_matrix["include"])
            unique = {json.dumps(entry, sort_keys=True) for entry in gathered}
            self.assertEqual(len(unique), len(gathered))

    def test_selected_platform_validates_name_and_its_own_matrix_limit(self):
        """One platform's matrix capacity is independent from the size of sibling platforms."""
        for native_platform in ("linux", "", "unsupported"):
            with self.subTest(platform=native_platform), self.assertRaisesRegex(ValueError, "platform"):
                jobs.matrices(["CoreTests"], native_platform)
        modules = [f"Module{number}Tests" for number in range(90)]
        for native_platform in jobs.PLATFORMS:
            builds, tests = jobs.matrices(modules, native_platform)
            timing_count = 0 if native_platform == "windows-x64" else len(jobs.TIMING_PACKAGES)
            self.assertEqual(len(builds["include"]), len(jobs.COMPONENTS) - len(jobs.TIMING_PACKAGES) + timing_count)
            self.assertEqual(len(tests["include"]), len(modules) + 5 + timing_count + len(jobs.CONSUMER_SUITES))
            with self.subTest(platform=native_platform), self.assertRaisesRegex(ValueError, "matrix limit"):
                jobs.matrices([f"Module{number}Tests" for number in range(256)], native_platform)

    def test_matrix_rejects_duplicate_empty_invalid_or_oversized_partitions(self):
        """Invalid discovery must fail before GitHub silently drops or truncates jobs."""
        for modules in ([], ["CoreTests", "CoreTests"], ["CoreTests|OtherTests"],
                        [f"Module{number}Tests" for number in range(90)]):
            with self.subTest(modules=modules[:2]), self.assertRaises(ValueError):
                jobs.matrices(modules)

    def test_all_execution_commands_skip_build_and_root_filter_is_anchored(self):
        """Independent jobs cannot compile again or accidentally match a similarly named module."""
        metadata = {"identity": {"repository": str(Path.cwd())}, "tests": {
            ".": {"CoreTests": ["CoreTests.Suite/test()"]},
            **{package: {"PackageTests": ["PackageTests.Suite/test()"]} for package in jobs.PACKAGES.values() if package != "."},
            **{f"Examples/{example}": {"ExampleTests": ["ExampleTests.Suite/test()"]} for example in jobs.CONSUMER_TESTS}}}
        root = jobs.test_commands("root", "CoreTests", 8, metadata)
        self.assertEqual(root[0].arguments[-2:], ("--filter", "^CoreTests[./]"))
        planned = root
        for component in ("macros", "extensions", "tooling", "load", "benchmarks", *jobs.TIMING_PACKAGES):
            planned += jobs.test_commands(component, component, 8, metadata)
        for example in jobs.CONSUMER_SUITES:
            planned += jobs.test_commands("consumers", example, 8, metadata)
        planned += jobs.test_commands("tooling", "audit", 8, metadata)
        for command in planned:
            if command.arguments[0] == "swift":
                self.assertIn("--skip-build", command.arguments)
                self.assertIn("--force-resolved-versions", command.arguments)
                self.assertEqual(command.arguments[command.arguments.index("--build-system") + 1], "native")
                if command.arguments[1] == "test":
                    self.assertIn("--no-parallel", command.arguments)
        with self.assertRaises(ValueError):
            jobs.test_commands("root", "OtherCoreTests", 8, metadata)
        with self.assertRaises(ValueError):
            jobs.test_commands("release", "release", 8, metadata)

    def test_builds_include_tests_and_distinct_consumer_metadata(self):
        """Consumer package scratch metadata must survive separately for later --skip-build jobs."""
        for component in jobs.COMPONENTS:
            commands = jobs.compile_commands(component, 12)
            for command in commands:
                self.assertEqual(command.arguments[:2], ("swift", "build"))
                self.assertIn("--disable-experimental-prebuilts", command.arguments)
                self.assertNotIn("--skip-build", command.arguments)
                self.assertEqual(command.arguments[command.arguments.index("--jobs") + 1], "12")
            if component not in ("release", "consumers"):
                self.assertIn("--build-tests", commands[0].arguments)
        consumers = jobs.compile_commands("consumers", 12)
        self.assertEqual({command.name for command in consumers}, set(jobs.linux_ci.EXAMPLES))
        self.assertEqual(len(set(jobs.build_roots("consumers"))), len(jobs.linux_ci.EXAMPLES))
        self.assertTrue(all("--scratch-path" not in command.arguments for command in consumers))
        self.assertIn("--configuration", jobs.compile_commands("benchmarks", 12)[-1].arguments)
        for component, product in jobs.TIMING_PRODUCTS.items():
            with self.subTest(component=component):
                optimized = jobs.compile_commands(component, 12)[-1].arguments
                self.assertEqual(optimized[optimized.index("--configuration") + 1], "release")
                self.assertEqual(optimized[optimized.index("--product") + 1], product)
                self.assertEqual(jobs.build_roots(component), [jobs.PACKAGES[component] + "/.build"])

    def test_timing_smoke_covers_cpu_observer_scripted_rest_and_local_io_with_finite_caps(self):
        """Short shared-runner numbers are informational while missing artifacts and leaks remain failures."""
        commands = [command for component in jobs.TIMING_PRODUCTS
                    for command in jobs.timing_smoke_commands(component, 8)]
        self.assertEqual(len(commands), 7)
        self.assertTrue(any("scalarAggregate" in command.arguments for command in commands))
        self.assertTrue(any("json.parse.1024.depth1.ascii" in command.arguments for command in commands))
        self.assertTrue(any("nio" in command.arguments for command in commands))
        for command in commands:
            self.assertEqual(command.timeout, 120)
            self.assertIn("--skip-build", command.arguments)
            for option, value in (("--configuration", "release"), ("--duration-seconds", "3"), ("--profile", "smoke")):
                self.assertEqual(command.arguments[command.arguments.index(option) + 1], value)
        self.assertEqual(jobs.timing_smoke_commands("root", 8), [])

    def test_test_discovery_rejects_empty_foreign_duplicate_and_prefix_collisions(self):
        """A successful SwiftPM invocation with zero selected tests must not produce a green suite."""
        self.assertEqual(jobs.discovered_tests("warning: ignored\nCoreTests.Suite/test()\n", ["CoreTests"]),
                         {"CoreTests": ["CoreTests.Suite/test()"]})
        for listing in ("", "OtherCoreTests.Suite/test()", "CoreTests.Suite/test()\nCoreTests.Suite/test()"):
            with self.subTest(listing=listing), self.assertRaises(ValueError):
                jobs.discovered_tests(listing, ["CoreTests"])
        with self.assertRaisesRegex(ValueError, "MissingTests"):
            jobs.discovered_tests("CoreTests.Suite/test()", ["CoreTests", "MissingTests"])

    def test_job_limit_obeys_visible_cpu_affinity(self):
        """Large host CPU counts cannot override a constrained execution allocation."""
        with patch.object(jobs.os, "cpu_count", return_value=64), patch.object(jobs.os, "sched_getaffinity", return_value={1, 2}, create=True):
            self.assertEqual(jobs.bounded_jobs(64), 2)
            self.assertEqual(jobs.bounded_jobs(1), 1)
        for requested in (0, -1, True):
            with self.assertRaises(ValueError):
                jobs.bounded_jobs(requested)

    def test_cli_writes_both_matrices_and_returns_visible_failure(self):
        """Workflow entry points expose concrete matrices and preserve rejected-operation evidence."""
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "plan"
            with patch.object(sys, "argv", ["native_jobs.py", "plan", "--output", str(output)]), patch.object(jobs, "dump_targets", return_value=["CoreTests"]):
                self.assertEqual(jobs.main(), 0)
            self.assertEqual(len(json.loads((output / "build-matrix.json").read_text())["include"]),
                             len(jobs.COMPONENTS) * len(jobs.PLATFORMS) - len(jobs.TIMING_PACKAGES))
            self.assertTrue(json.loads((output / "test-matrix.json").read_text())["include"])
            with patch.object(sys, "argv", ["native_jobs.py", "restore", "--output", str(output),
                    "--platform", "linux-x64", "--component", "root", "--archive", str(Path(directory) / "missing.tar.gz")]), patch.object(jobs, "identity", side_effect=ValueError("wrong compiler")), patch.object(sys, "stderr", io.StringIO()):
                self.assertEqual(jobs.main(), 1)
            failure = json.loads((output / "failure.json").read_text())
            self.assertEqual(failure, {"status": "failed", "operation": "restore", "error": "wrong compiler"})

    def test_plan_cli_selects_each_platform_and_rejects_unknown_platform(self):
        """Reusable workflows can request one exact platform through the existing CLI option."""
        modules = ["CoreTests", "DiscordUnixPlatformTests", "DiscordFoundationTransportTests"]
        with tempfile.TemporaryDirectory() as directory:
            for native_platform in jobs.PLATFORMS:
                output = Path(directory) / native_platform
                with self.subTest(platform=native_platform), patch.object(sys, "argv", ["native_jobs.py", "plan",
                        "--output", str(output), "--platform", native_platform]), patch.object(jobs, "dump_targets", return_value=modules):
                    self.assertEqual(jobs.main(), 0)
                expected = jobs.matrices(modules, native_platform)
                for filename, expected_matrix in zip(("build-matrix.json", "test-matrix.json"), expected):
                    actual = json.loads((output / filename).read_text())
                    self.assertEqual(actual, expected_matrix)
                    self.assertEqual({entry["platform"] for entry in actual["include"]}, {native_platform})
            invalid_output = Path(directory) / "invalid"
            with patch.object(sys, "argv", ["native_jobs.py", "plan", "--output", str(invalid_output),
                    "--platform", "unknown"]), patch.object(jobs, "dump_targets") as discover, patch.object(sys, "stderr", io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    jobs.main()
                self.assertEqual(error.exception.code, 2)
                discover.assert_not_called()
            self.assertFalse(invalid_output.exists())


class NativeArtifactTests(unittest.TestCase):
    """Exercise real compressed transport and reject stale, altered or unsafe compiled artifacts."""

    def setUp(self):
        """Create a synthetic binary tree outside the actual checkout's build directories."""
        self.temporary = tempfile.TemporaryDirectory(prefix="native artifact $ literal ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repository = self.root / "checkout"
        self.repository.mkdir()
        self.output = self.root / "evidence"
        self.archive = self.root / "compiled.tar.gz"
        self.current = {"repository": str(self.repository), "platform": "linux-x64", "commit": "a" * 40,
                        "sourceSHA256": "b" * 64, "runID": "42", "runAttempt": "2",
                        "swiftVersion": "Swift version 6.4.1", "buildSystem": "native"}
        self.metadata = {"formatVersion": 1, "status": "passed", "component": "root", "identity": self.current,
                         "tests": {".": {"CoreTests": ["CoreTests.Suite/test()"]}}}
        self.binary = self.repository / ".build/x86_64-unknown-linux-gnu/debug/PackageTests.xctest"
        self.binary.parent.mkdir(parents=True)
        self.binary.write_bytes(b"compiled executable\0payload")
        self.binary.chmod(0o755)

    def seal(self):
        """Seal the actual fixture bytes and remove them to emulate a fresh test runner."""
        result = jobs.create_archive(self.repository, "root", self.archive, self.metadata)
        shutil.rmtree(self.repository / ".build")
        return result

    def restore(self):
        """Use a deterministic host identity while exercising all real archive admission checks."""
        with patch.object(jobs, "identity", return_value=self.current):
            return jobs.restore_archive(self.repository, "root", "linux-x64", self.archive, self.output)

    def rewrite(self, update):
        """Rewrite an archive fixture without changing members unrelated to one negative case."""
        entries = []
        with tarfile.open(self.archive, "r:gz") as source:
            for member in source.getmembers():
                content = source.extractfile(member).read() if member.isfile() else None
                entries.append((member, content))
        entries = update(entries)
        with tarfile.open(self.archive, "w:gz") as destination:
            for member, content in entries:
                if content is not None:
                    member.size = len(content)
                destination.addfile(member, io.BytesIO(content) if content is not None else None)

    def test_transport_preserves_executable_and_internal_symlink_without_recursive_ci(self):
        """Later runners retain runnable bundles while evidence, archives and nested builds stay out."""
        (self.repository / ".build/ci").mkdir()
        (self.repository / ".build/ci/recursive.tar.gz").write_bytes(b"do not archive")
        nested = self.repository / ".build/checkouts/dependency/.build"
        nested.mkdir(parents=True)
        (nested / "discard").write_bytes(b"nested build")
        if os.name != "nt":
            (self.repository / ".build/debug").symlink_to("x86_64-unknown-linux-gnu/debug", target_is_directory=True)
        sealed = self.seal()
        restored = self.restore()
        self.assertEqual(sealed, restored)
        self.assertEqual(self.binary.read_bytes(), b"compiled executable\0payload")
        if os.name != "nt":
            self.assertTrue(self.binary.stat().st_mode & stat.S_IXUSR)
            self.assertTrue((self.repository / ".build/debug").is_symlink())
        self.assertFalse((self.repository / ".build/ci/recursive.tar.gz").exists())
        self.assertFalse((self.repository / ".build/checkouts/dependency/.build").exists())
        self.assertEqual(json.loads((self.output / "restored.json").read_text())["status"], "passed")

    def test_identity_change_rejects_before_any_binary_is_restored(self):
        """A different run attempt, path, source or compiler cannot borrow green build products."""
        self.seal()
        for field in ("runAttempt", "runID", "repository", "sourceSHA256", "commit", "swiftVersion", "platform"):
            changed = {**self.current, field: "different"}
            with self.subTest(field=field), patch.object(jobs, "identity", return_value=changed), self.assertRaises(ValueError):
                jobs.restore_archive(self.repository, "root", "linux-x64", self.archive, self.output)
            self.assertFalse(self.binary.exists())

    def test_corrupt_payload_is_rejected_before_extraction(self):
        """Repacking altered executable bytes cannot bypass the sealed payload digest."""
        self.seal()
        self.rewrite(lambda entries: [(member, b"tampered" if member.name.endswith(".xctest") else content)
                                      for member, content in entries])
        with self.assertRaisesRegex(ValueError, "payload digest"):
            self.restore()
        self.assertFalse(self.binary.exists())

    def test_traversal_member_and_duplicate_metadata_are_rejected(self):
        """Archive admission validates all member names before it writes any compiled files."""
        self.seal()
        original = self.archive.read_bytes()
        outside = tarfile.TarInfo("../outside")
        outside.size = 1
        self.rewrite(lambda entries: entries + [(outside, b"x")])
        with self.assertRaises(ValueError):
            self.restore()
        self.assertFalse((self.root / "outside").exists())
        self.assertFalse(self.binary.exists())
        self.archive.write_bytes(original)
        self.rewrite(lambda entries: entries + [(copy.copy(member), content) for member, content in entries if member.name == jobs.METADATA])
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.restore()

    def test_restore_refuses_to_overwrite_another_build(self):
        """A shared checkout with active or stale build outputs cannot be silently replaced."""
        self.seal()
        self.binary.parent.mkdir(parents=True)
        self.binary.write_bytes(b"unrelated existing build")
        with self.assertRaisesRegex(ValueError, "overwrite"):
            self.restore()
        self.assertEqual(self.binary.read_bytes(), b"unrelated existing build")

    def test_synthetic_compile_then_independent_test_uses_restored_inventory(self):
        """Exercise production orchestration through actual tar transport with a controlled compiler boundary."""
        calls = []

        def compiler(command, repository, log, *, stdout_log=None):
            """Model split diagnostics while production discovery, planning and transport remain real."""
            calls.append(command.arguments)
            if command.arguments[1] == "build":
                self.binary.parent.mkdir(parents=True, exist_ok=True)
                self.binary.write_bytes(b"fresh compilation")
                log.write_text("Build complete!\n")
            elif "list" in command.arguments:
                self.assertTrue(self.binary.is_file())
                # The hosted warning interrupted a test identifier when streams were merged.
                log.write_text("CoreTests.Suwarning: --build-system native is deprecated\nite/test()\n")
                self.assertIsNotNone(stdout_log)
                stdout_log.write_text("CoreTests.Suite/test()\n")
            else:
                self.assertEqual(self.binary.read_bytes(), b"fresh compilation")
                self.assertIn("--skip-build", command.arguments)
                log.write_text("Test run passed\n")

        with patch.object(jobs, "identity", return_value=self.current), \
                patch.object(jobs, "dump_targets", return_value=["CoreTests", "DiscordFoundationTransportTests"]), \
                patch.object(jobs.linux_ci, "execute", side_effect=compiler), redirect_stdout(io.StringIO()):
            metadata = jobs.compile_component(self.repository, "root", "linux-x64", 8, self.output / "compile", self.archive)
            shutil.rmtree(self.repository / ".build")
            report = jobs.run_tests(self.repository, "root", "CoreTests", "linux-x64", 2, self.output / "test", self.archive)
        self.assertEqual(report["status"], "passed")
        self.assertEqual(metadata["tests"]["."], {"CoreTests": ["CoreTests.Suite/test()"]})
        for phase in ("compile", "test"):
            retained = json.loads((self.output / phase / "commands.json").read_text())
            discovery = [record for record in retained["commands"] if "list" in record["arguments"]]
            self.assertEqual(len(discovery), 1)
            self.assertIn("warning:", (self.output / phase / discovery[0]["log"]).read_text())
            self.assertEqual((self.output / phase / discovery[0]["stdoutLog"]).read_text(),
                             "CoreTests.Suite/test()\n")
        self.assertEqual(sum(arguments[1] == "build" for arguments in calls), 1)
        self.assertTrue(all("--skip-build" in arguments for arguments in calls if arguments[1] == "test"))

    def test_discovery_stdout_excludes_warning_written_between_identifier_fragments(self):
        """A real child's stderr cannot corrupt the inventory parsed from its captured stdout."""
        script = ("import os; "
                  "os.write(1, b'CoreTests.Su'); "
                  "os.write(2, b'warning: --build-system native is deprecated\\n'); "
                  "os.write(1, b'ite/test()\\n')")
        command = jobs.linux_ci.Command("discovery", (sys.executable, "-c", script), 10)
        report = {"status": "running", "commands": []}
        with redirect_stdout(io.StringIO()):
            captured = jobs.execute_commands([command], self.repository, self.output, report,
                                             capture_stdout=True)
        self.assertEqual(jobs.discovered_tests(captured[0].read_text(), ["CoreTests"]),
                         {"CoreTests": ["CoreTests.Suite/test()"]})
        record = report["commands"][0]
        self.assertEqual(captured, [self.output / record["stdoutLog"]])
        self.assertIn("warning: --build-system native is deprecated", (self.output / record["log"]).read_text())
        self.assertNotIn("warning:", captured[0].read_text())

    def test_macos_archive_contains_fresh_public_graphs_from_the_build_phase(self):
        """The later API job must receive compiler graphs without needing stripped object files."""
        calls = []
        generated = self.repository / ".build/out/symbolgraph/Library.symbols.json"

        def compiler(command, repository, log, *, stdout_log=None):
            """Produce build outputs and documentation inputs at their actual archive locations."""
            calls.append(command.name)
            if command.name == "public-symbol-graphs":
                self.assertTrue(self.binary.exists())
                generated.parent.mkdir(parents=True)
                generated.write_text(json.dumps({"module": {"name": "Library"}}))
            log.write_text("CoreTests.Suite/test()\n" if "list" in command.arguments else "passed\n")
            if stdout_log is not None:
                stdout_log.write_text("CoreTests.Suite/test()\n")

        with patch.object(jobs, "identity", return_value=self.current), \
                patch.object(jobs, "dump_targets", return_value=["CoreTests"]), \
                patch.object(jobs.linux_ci, "execute", side_effect=compiler), redirect_stdout(io.StringIO()):
            jobs.compile_component(self.repository, "root", "macos-arm64", 5,
                                   self.output / "compile", self.archive)
        self.assertLess(calls.index("root"), calls.index("public-symbol-graphs"))
        self.assertLess(calls.index("public-symbol-graphs"), calls.index("discovery-0"))
        with tarfile.open(self.archive) as archive:
            self.assertIn(str(generated.relative_to(self.repository)), archive.getnames())

    def test_failed_execution_retains_durable_failure_report(self):
        """A child failure must remain failed even when diagnostic upload follows."""
        command = jobs.linux_ci.Command("fail", (sys.executable, "-c", "raise SystemExit(7)"), 10)
        report = {"status": "running", "commands": []}
        with self.assertRaises(subprocess.CalledProcessError), redirect_stdout(io.StringIO()):
            jobs.execute_commands([command], self.repository, self.output, report)
        retained = json.loads((self.output / "commands.json").read_text())
        self.assertEqual(retained["status"], "failed")
        self.assertEqual(retained["commands"][0]["status"], "failed")
        self.assertTrue((self.output / retained["commands"][0]["log"]).is_file())


class NativeSourceTests(unittest.TestCase):
    """Use real Git metadata to distinguish HEAD identity from dirty compiled source bytes."""

    def test_dirty_tracked_source_changes_identity_even_when_commit_stays_equal(self):
        """Artifact reuse cannot trust only the unchanged commit name of a dirty checkout."""
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            subprocess.run(["git", "init", "--quiet", str(repository)], check=True)
            source = repository / "source.swift"
            source.write_text("original\n")
            subprocess.run(["git", "-C", str(repository), "add", "source.swift"], check=True)
            subprocess.run(["git", "-C", str(repository), "-c", "user.name=CI Fixture", "-c", "user.email=fixture@example.invalid",
                            "commit", "--quiet", "-m", "fixture"], check=True)
            with patch.dict(os.environ, {}, clear=True):
                first = jobs.source_identity(repository)
                source.write_text("changed without committing\n")
                second = jobs.source_identity(repository)
            self.assertEqual(first["commit"], second["commit"])
            self.assertNotEqual(first["sourceSHA256"], second["sourceSHA256"])

    def test_native_identity_checks_actual_compiler_target_assigned_architecture_and_distribution(self):
        """A correct host kernel cannot conceal a cross compiler, wrong assigned pool or Ubuntu image."""
        from contextlib import ExitStack

        for target, assigned, distribution, accepted in (
                ("x86_64-unknown-linux-gnu", {"RUNNER_OS": "Linux", "RUNNER_ARCH": "X64"}, "24.04", True),
                ("aarch64-unknown-linux-gnu", {}, "24.04", False),
                ("x86_64-unknown-windows-msvc", {}, "24.04", False),
                ("x86_64-unknown-linux-gnu", {"RUNNER_ARCH": "ARM64"}, "24.04", False),
                ("x86_64-unknown-linux-gnu", {"RUNNER_OS": "macOS"}, "24.04", False),
                ("x86_64-unknown-linux-gnu", {}, "22.04", False)):
            with self.subTest(target=target, assigned=assigned, distribution=distribution), ExitStack() as stack:
                stack.enter_context(patch.object(jobs.platform, "system", return_value="Linux"))
                stack.enter_context(patch.object(jobs.platform, "machine", return_value="x86_64"))
                stack.enter_context(patch.object(jobs.platform, "freedesktop_os_release", return_value={"ID": "ubuntu", "VERSION_ID": distribution}, create=True))
                stack.enter_context(patch.object(jobs, "source_identity", return_value={"commit": "a" * 40}))
                stack.enter_context(patch.object(jobs.subprocess, "check_output", side_effect=["Swift version 6.4.1", json.dumps({"target": {"triple": target}})]))
                stack.enter_context(patch.dict(os.environ, assigned, clear=True))
                if accepted:
                    self.assertEqual(jobs.identity(Path.cwd(), "linux-x64")["swiftTarget"], target)
                else:
                    with self.assertRaises(ValueError):
                        jobs.identity(Path.cwd(), "linux-x64")


class TimingSmokeEvidenceTests(unittest.TestCase):
    """Reject silent empty/missing/incomplete timing evidence after an otherwise successful child."""

    def test_nonempty_matching_completed_reports_and_cleanup_are_required(self):
        """Correctness and cleanup remain hard checks even though latency has no shared-runner budget."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            commands = jobs.timing_smoke_commands("foundation", 2)
            command = commands[0]
            native_path, common_path = [root / command.arguments[command.arguments.index(option) + 1]
                                        for option in ("--output", "--common-report")]
            native_path.parent.mkdir(parents=True)
            common = {"format": "DiscordBenchmarkReport", "schemaVersion": 1, "status": "completed",
                      "counts": {"completed": 64, "offered": 64, "admitted": 64, "deadlineMisses": 0,
                                 "outcomes": {"success": 64, "failure": 0, "timedOut": 0, "cancelled": 0, "rejected": 0, "uncertain": 0}},
                      "metrics": [{"id": "cpu.batch", "outcome": "success", "distribution": {
                          "observedCount": 64, "inRangeCount": 64, "underflowCount": 0, "overflowCount": 0,
                          "droppedCount": 0, "counterOverflow": False, "bucketCounts": [32, 32],
                          "configuration": {"lowerBoundNanoseconds": 0, "upperBoundNanoseconds": 10, "bucketWidthNanoseconds": 10}}}],
                      "cleanup": {"completed": True, "remainingOwners": 0}}
            with self.assertRaises(OSError):
                jobs.verify_timing_smokes(root, commands)
            for field, value in (("status", "failed"), ("counts", {"completed": 0}), ("metrics", []),
                                 ("cleanup", {"completed": False, "remainingOwners": 1})):
                incomplete = {**common, field: value}
                native_path.write_text(json.dumps({"common": incomplete}))
                common_path.write_text(json.dumps(incomplete))
                with self.subTest(field=field), self.assertRaises(ValueError):
                    jobs.verify_timing_smokes(root, commands)
            native_path.write_text(json.dumps({"common": common}))
            common_path.write_text(json.dumps({**common, "status": "failed"}))
            with self.assertRaises(ValueError):
                jobs.verify_timing_smokes(root, commands)
            common_path.write_text(json.dumps(common))
            jobs.verify_timing_smokes(root, commands)
            for key, value in (("observedCount", 0), ("droppedCount", 1), ("counterOverflow", True),
                               ("inRangeCount", 63), ("bucketCounts", [32, 31]), ("overflowCount", 1)):
                malformed = copy.deepcopy(common)
                malformed["metrics"][0]["distribution"][key] = value
                with self.subTest(field=key), self.assertRaises(ValueError):
                    jobs.verify_common_smoke(malformed)
            censored = copy.deepcopy(common)
            censored["metrics"][0]["distribution"].update(inRangeCount=63, overflowCount=1, bucketCounts=[32, 31])
            jobs.verify_common_smoke(censored)
            for number in ("NaN", "Infinity", "1e999"):
                common_path.write_text('{"counter":' + number + '}')
                with self.subTest(number=number), self.assertRaises(ValueError):
                    jobs.read_timing_json(common_path)


if __name__ == "__main__":
    unittest.main()
