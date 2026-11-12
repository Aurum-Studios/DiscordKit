# File: Tools/ci/test_native_jobs.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Protect independent native scheduling and the compiled-artifact trust boundary."""

from contextlib import redirect_stderr, redirect_stdout
import copy
import hashlib
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
import time
import unittest
from unittest.mock import patch

import native_jobs as jobs
from test_test_results import successful


def emit_events(command, leaves=("CoreTests.Suite/test()",)):
    """Model only the pinned compiler boundary; production reconciliation remains real."""
    if "--event-stream-output-path" in command.arguments:
        path = Path(command.arguments[command.arguments.index("--event-stream-output-path") + 1])
        records = successful(leaves[0])
        for leaf in leaves[1:]:
            from test_test_results import definition, event
            records.insert(0, definition(leaf))
            records[-1:-1] = [event("testStarted", leaf), event("testEnded", leaf)]
        path.write_text("".join(json.dumps(row) + "\n" for row in records))


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
            self.assertEqual({suite for entry in test_entries if entry["component"] == "root" for suite in entry["suites"]},
                             expected_modules[native_platform])
            self.assertEqual({suite for entry in test_entries if entry["component"] == "consumers" for suite in entry["suites"]},
                             set(jobs.CONSUMER_TESTS) | set(jobs.CONSUMER_SMOKES))
            self.assertNotIn("release", {entry["component"] for entry in test_entries})
            for entry in build_entries + test_entries:
                self.assertEqual(entry["shell"], "pwsh" if native_platform == "windows-x64" else "bash")
                if native_platform == "macos-arm64":
                    self.assertEqual((entry["group"], entry["jobs"]), ("MacOS-26-5", 2))
                elif entry in build_entries:
                    self.assertTrue(entry["group"].endswith("-8" if entry["component"] in ("tooling", "timing-support") else "-64"))
                else:
                    self.assertTrue(entry["group"].endswith("-8"))
        self.assertEqual(len({(entry["platform"], entry["component"], entry["suite"]) for entry in tests["include"]}), len(tests["include"]))

    def test_root_modules_come_from_evaluated_manifest(self):
        """Formatting or dependencies in Package.swift cannot confuse regular-expression target discovery."""
        document = {"targets": [{"name": "Runtime", "type": "regular"},
                                {"name": "ZTests", "type": "test"}, {"name": "ATests", "type": "test"}]}
        def manifest(command, repository, log, *, stdout_log=None, deadline=None):
            log.write_text("warning: manifest diagnostics\n")
            stdout_log.write_text(json.dumps(document))

        with patch.object(jobs.linux_ci, "execute", side_effect=manifest) as query, redirect_stdout(io.StringIO()):
            self.assertEqual(jobs.dump_targets(Path(".")), ["ATests", "ZTests"])
        self.assertIn("dump-package", query.call_args.args[0].arguments)
        self.assertEqual(query.call_args.args[0].timeout, 60)

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
            self.assertEqual(len(tests["include"]), 4 + 5 + timing_count + 1)
            larger = jobs.matrices([f"Module{number}Tests" for number in range(256)], native_platform)
            self.assertEqual(len(larger[1]["include"]), len(tests["include"]))

    def test_matrix_rejects_duplicate_empty_invalid_or_oversized_partitions(self):
        """Invalid discovery must fail before GitHub silently drops or truncates jobs."""
        for modules in ([], ["CoreTests", "CoreTests"], ["CoreTests|OtherTests"]):
            with self.subTest(modules=modules[:2]), self.assertRaises(ValueError):
                jobs.matrices(modules)

    def test_all_execution_commands_skip_build_and_root_filter_is_anchored(self):
        """Independent jobs cannot compile again or accidentally match a similarly named module."""
        metadata = {"compatibility": {"identity": {"repository": str(Path.cwd())}}, "tests": {
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

    def test_operation_limits_replace_generic_swift_timeout_without_retries(self):
        """Cold builds, inventories, suites and finite smokes use the shared operation policy."""
        policy = jobs.execution_policy()
        for component in jobs.COMPONENTS:
            for command in jobs.compile_commands(component, 2):
                self.assertEqual(command.operation, "coldCompileCommand")
                self.assertEqual(command.timeout, policy["deadlinesSeconds"]["coldCompileCommand"])
        for package, arguments, operation in ((".", ("list", "--skip-build"), "discovery"),
                (".", ("--skip-build",), "suite"),
                (jobs.PACKAGES["load"], ("--skip-build",), "wholeLoadPackage")):
            command = jobs.swift_command("test", "test", package, 2, *arguments)
            self.assertEqual((command.operation, command.timeout), (operation, policy["deadlinesSeconds"][operation]))
        self.assertEqual(jobs.swift_command("smoke", "run", ".", 2, "--skip-build").timeout, 120)
        focused = jobs.swift_command("reproduction", "test", jobs.PACKAGES["load"], 2,
            "--skip-build", "--no-parallel", "--filter", "SyntheticCommandTimingRunnerTests", operation="focusedTest")
        self.assertEqual((focused.timeout, focused.operation), (90, "focusedTest"))
        audit = jobs.test_commands("tooling", "audit", 2, {"compatibility": {"identity": {"repository": str(Path.cwd())}}})
        self.assertTrue(all(command.timeout <= 300 for command in audit))
        self.assertEqual(sum(command.arguments[:2] == ("swift", "run") for command in audit), 4)

    def test_component_compute_budget_leaves_room_for_bounded_transfer_recovery(self):
        """The unchanged compute budget leaves two transfer aggregates inside the enclosing build job."""
        policy = jobs.execution_policy()
        from artifact_transfer import AGGREGATE_SECONDS
        for component in jobs.COMPONENTS:
            required = jobs.validate_enclosing_budget(jobs.compilation_budget(component, policy),
                jobs.BUILD_JOB_SECONDS, packaging=True, policy=policy)
            actual_required = required - policy["reservesSeconds"]["upload"] + 2 * AGGREGATE_SECONDS
            self.assertLessEqual(actual_required, jobs.BUILD_JOB_SECONDS)
        self.assertEqual(jobs.compilation_budget("consumers", policy), 5400 + 6 * 60)
        self.assertEqual(policy["componentCompileSeconds"]["consumers"], 5400)
        with self.assertRaisesRegex(ValueError, "enclosing workflow"):
            jobs.validate_enclosing_budget(7200, 7200, policy=policy)

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
        with (patch.object(jobs.os, "cpu_count", return_value=64),
              patch.object(jobs.os, "sched_getaffinity", return_value={1, 2}, create=True),
              patch.object(jobs.native_resources, "observed_memory", return_value={"availableMemoryBytes": 16 * 1024**3, "memorySources": ["fixture"]})):
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

    def test_restore_cli_loads_complete_selection_and_rejects_ambiguous_or_oversized_json(self):
        """A workflow passes the exact bounded resolver document through restore admission."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            selection_path, output = root / "selection.json", root / "evidence"
            arguments = ["native_jobs.py", "restore", "--output", str(output), "--platform", "linux-x64",
                         "--component", "root", "--archive", str(root / "compiled.tar.gz"),
                         "--selection", str(selection_path)]
            document = {"formatVersion": 1, "components": {"root": {"artifactID": "9001"}}}
            selection_path.write_text(json.dumps(document))
            with patch.object(sys, "argv", arguments), patch.object(jobs, "restore_archive") as restore:
                self.assertEqual(jobs.main(), 0)
            self.assertEqual(restore.call_args.kwargs["selection"], document)
            for text, limit in (("{\"formatVersion\":1,\"formatVersion\":2}", 64 * 1024 * 1024),
                                (json.dumps(document), 1)):
                selection_path.write_text(text)
                with (self.subTest(document=text, limit=limit), patch.object(sys, "argv", arguments),
                      patch.object(jobs, "MAX_SELECTION_BYTES", limit), patch.object(jobs, "restore_archive") as restore,
                      patch.object(sys, "stderr", io.StringIO())):
                    self.assertEqual(jobs.main(), 1)
                restore.assert_not_called()
                self.assertEqual(json.loads((output / "failure.json").read_text())["status"], "failed")


class NativeArtifactTests(unittest.TestCase):
    """Exercise real compressed transport and reject stale, altered or unsafe compiled artifacts."""

    def setUp(self):
        """Create a synthetic binary tree outside the actual checkout's build directories."""
        self.temporary = tempfile.TemporaryDirectory(prefix="native artifact $ literal ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repository = self.root / "checkout"
        self.repository.mkdir()
        self.output = self.root / "evidence"
        self.archive = self.root / "compiled.tar.gz"
        self.current = {"repository": str(self.repository), "platform": "linux-x64", "commit": "a" * 40,
                        "sourceSHA256": "b" * 64, "system": "Linux", "machine": "x64",
                        "swiftVersion": "Swift version 6.4.1", "swiftTarget": "x86_64-unknown-linux-gnu",
                        "buildSystem": "native", "dependencyPinsSHA256": {"Package.resolved": "c" * 64},
                        "buildEnvironment": jobs.build_environment(),
                        "runtime": {"policyVersion": 1, "system": "Linux", "release": "fixture",
                                    "version": "fixture", "swiftVersion": "Swift version 6.4.1",
                                    "swiftTarget": "x86_64-unknown-linux-gnu",
                                    "swiftTargetInfo": {"target": {"triple": "x86_64-unknown-linux-gnu"}},
                                    "image": {"kind": "unmanaged"}, "osRuntime": {"fixture": "same"}, "xcode": None}}
        self.execution = {"scope": "local", "repository": str(self.repository),
                          **{field: "local" for field in ("repositoryID", "workflowRef", "workflowSHA", "runID",
                                                          "runAttempt", "jobID", "event")},
                          "ref": "", "headRef": "", "baseRef": ""}
        execution = patch.object(jobs.receipts, "execution_identity", return_value=self.execution)
        execution.start()
        self.addCleanup(execution.stop)
        tests = {".": {"CoreTests": ["CoreTests.Suite/test()"]}}
        self.metadata = {"formatVersion": 2, "status": "passed", "component": "root",
                         "compatibility": {"identity": self.current, "build": jobs.build_profile("root")},
                         "producer": jobs.receipts.producer_receipt(self.execution, tests), "tests": tests}
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

    def selection(self, metadata, execution):
        """Use all immutable resolver fields to bind bytes, producer and the current rerun attempt."""
        return {"formatVersion": 1, "execution": {**execution, "jobID": "resolve"},
                "sourceCommit": self.current["commit"], "platform": "linux-x64", "expectedComponents": ["root"],
                "components": {"root": {"artifactID": "9001", "artifactDigest": "sha256:" + "f" * 64,
                    "archiveSHA256": jobs.file_digest(self.archive),
                    "artifactName": "compiled-linux-x64-root-" + self.current["commit"] + "-42-2-t1",
                    "producer": copy.deepcopy(metadata["producer"]), "metadata": copy.deepcopy(metadata),
                    "receiptArtifactID": "9002"}}}

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

    def rewrite_metadata(self, update):
        """Alter only the embedded producer receipt while keeping the sealed payload intact."""
        def alter(entries):
            changed = []
            for member, content in entries:
                if member.name == jobs.METADATA:
                    metadata = json.loads(content)
                    update(metadata)
                    content = json.dumps(metadata, sort_keys=True).encode()
                changed.append((member, content))
            return changed
        self.rewrite(alter)

    def rewrite_sealed_payload(self, update):
        """Give an unsafe payload a valid seal so path admission, rather than digest failure, rejects it."""
        def alter(entries):
            entries = update(entries)
            payload = hashlib.sha256()
            for member, content in entries:
                if member.name != jobs.METADATA:
                    if content is not None:
                        member.size = len(content)
                    jobs.member_digest(payload, member, io.BytesIO(content) if content is not None else None)
            for index, (member, content) in enumerate(entries):
                if member.name == jobs.METADATA:
                    metadata = json.loads(content)
                    metadata["payloadSHA256"] = payload.hexdigest()
                    entries[index] = (member, json.dumps(metadata, sort_keys=True).encode())
            return entries
        self.rewrite(alter)

    def test_transport_preserves_executable_and_internal_symlink_without_recursive_ci(self):
        """Later runners retain runnable bundles while evidence, archives and nested builds stay out."""
        (self.repository / ".build/ci").mkdir()
        (self.repository / ".build/ci/recursive.tar.gz").write_bytes(b"do not archive")
        resource = self.binary.parent / "Library_Library.resources/fixture.json"
        resource.parent.mkdir()
        resource.write_bytes(b'{"resource":"retained"}')
        resource.chmod(0o644)
        nested = self.repository / ".build/checkouts/dependency/.build"
        nested.mkdir(parents=True)
        (nested / "discard").write_bytes(b"nested build")
        if os.name != "nt":
            (self.repository / ".build/debug").symlink_to("x86_64-unknown-linux-gnu/debug", target_is_directory=True)
        sealed = self.seal()
        restored = self.restore()
        self.assertEqual(sealed, restored)
        self.assertEqual(self.binary.read_bytes(), b"compiled executable\0payload")
        self.assertEqual(resource.read_bytes(), b'{"resource":"retained"}')
        self.assertEqual(stat.S_IMODE(resource.stat().st_mode), 0o644)
        if os.name != "nt":
            self.assertTrue(self.binary.stat().st_mode & stat.S_IXUSR)
            self.assertTrue((self.repository / ".build/debug").is_symlink())
        self.assertFalse((self.repository / ".build/ci/recursive.tar.gz").exists())
        self.assertFalse((self.repository / ".build/checkouts/dependency/.build").exists())
        self.assertEqual(json.loads((self.output / "restored.json").read_text())["status"], "passed")

    def test_identity_change_rejects_before_any_binary_is_restored(self):
        """A different run attempt, path, source or compiler cannot borrow green build products."""
        self.seal()
        for field in ("repository", "sourceSHA256", "commit", "swiftVersion", "swiftTarget", "platform",
                      "system", "machine", "buildSystem", "dependencyPinsSHA256", "runtime", "buildEnvironment"):
            changed = {**self.current, field: "different"}
            with self.subTest(field=field), patch.object(jobs, "identity", return_value=changed), self.assertRaises(ValueError):
                jobs.restore_archive(self.repository, "root", "linux-x64", self.archive, self.output)
            self.assertFalse(self.binary.exists())

    def test_dependency_flags_sdk_and_runtime_facts_require_exact_compatibility(self):
        """Pins, build inputs and nested toolchain/runtime facts are mandatory exact identities."""
        self.current["runtime"]["xcode"] = {"version": "Xcode 26.1", "sdkVersion": "26.1", "sdkPath": "/fixture/SDK"}
        self.seal()
        original = self.archive.read_bytes()
        changes = {
            "dependency-pin": lambda receipt: receipt["compatibility"]["identity"]["dependencyPinsSHA256"].update({"Package.resolved": "d" * 64}),
            "new-pin": lambda receipt: receipt["compatibility"]["identity"]["dependencyPinsSHA256"].update({"New/Package.resolved": "d" * 64}),
            "unknown-build-flags": lambda receipt: receipt["compatibility"]["build"].update({"requiredNewFlag": "-unsafe"}),
            "compiler-argv": lambda receipt: receipt["compatibility"]["build"]["commands"][0].extend(["-Xswiftc", "-DCHANGED_FIXTURE"]),
            "build-configuration": lambda receipt: receipt["compatibility"]["build"].update(configurations=["release"]),
            "build-environment": lambda receipt: receipt["compatibility"]["identity"]["buildEnvironment"].update(CFLAGS="-DFIXTURE_CHANGED"),
            "sdk-version": lambda receipt: receipt["compatibility"]["identity"]["runtime"]["xcode"].update({"sdkVersion": "26.2"}),
            "sdk-path": lambda receipt: receipt["compatibility"]["identity"]["runtime"]["xcode"].update({"sdkPath": "/different/SDK"}),
            "os-runtime": lambda receipt: receipt["compatibility"]["identity"]["runtime"]["osRuntime"].update({"fixture": "changed"}),
            "image": lambda receipt: receipt["compatibility"]["identity"]["runtime"]["image"].update({"kind": "different"}),
            "boolean-runtime-version": lambda receipt: receipt["compatibility"]["identity"]["runtime"].update(policyVersion=True),
            "float-runtime-version": lambda receipt: receipt["compatibility"]["identity"]["runtime"].update(policyVersion=1.0),
        }
        for name, change in changes.items():
            self.archive.write_bytes(original)
            self.rewrite_metadata(change)
            with self.subTest(field=name), self.assertRaises(ValueError):
                self.restore()
            self.assertFalse(self.binary.exists())

    def test_receipt_schema_fails_closed_for_legacy_unknown_and_missing_required_fields(self):
        """Unknown schemas or identity requirements cannot silently degrade to permissive restore."""
        self.seal()
        original = self.archive.read_bytes()
        changes = {
            "legacy-v1": lambda receipt: receipt.update(formatVersion=1),
            "future-version": lambda receipt: receipt.update(formatVersion=3),
            "boolean-version": lambda receipt: receipt.update(formatVersion=True),
            "string-version": lambda receipt: receipt.update(formatVersion="2"),
            "missing-compatibility": lambda receipt: receipt.pop("compatibility"),
            "missing-source": lambda receipt: receipt["compatibility"]["identity"].pop("sourceSHA256"),
            "unknown-identity": lambda receipt: receipt["compatibility"]["identity"].update(requiredNewABI="unknown"),
            "unknown-compatibility": lambda receipt: receipt["compatibility"].update(requiredNewABI="unknown"),
            "unknown-producer": lambda receipt: receipt["producer"].update(requiredTrustPolicy="unknown"),
        }
        for name, change in changes.items():
            self.archive.write_bytes(original)
            self.rewrite_metadata(change)
            with self.subTest(case=name), self.assertRaises(ValueError) as error:
                self.restore()
            if name == "legacy-v1":
                self.assertRegex(str(error.exception).lower(), "regenerat")
            self.assertFalse(self.binary.exists())

    def test_producer_scope_success_inventory_and_timestamps_are_required(self):
        """A matching binary identity cannot excuse failed, foreign or malformed producer provenance."""
        self.seal()
        original = self.archive.read_bytes()
        changes = {
            "missing-producer": lambda receipt: receipt.pop("producer"),
            "failed-compilation": lambda receipt: receipt["producer"].update(compilation="failed"),
            "missing-discovery": lambda receipt: receipt["producer"].pop("discovery"),
            "failed-discovery": lambda receipt: receipt["producer"].update(discovery="failed"),
            "wrong-inventory-digest": lambda receipt: receipt["producer"].update(inventorySHA256="0" * 64),
            "inventory-changed": lambda receipt: receipt["tests"]["."]["CoreTests"].append("CoreTests.Suite/other()"),
            "foreign-repository": lambda receipt: receipt["producer"]["execution"].update(repository="foreign/repository"),
            "foreign-run": lambda receipt: receipt["producer"]["execution"].update(runID="other"),
            "earlier-attempt": lambda receipt: receipt["producer"]["execution"].update(runAttempt="earlier"),
            "foreign-workflow": lambda receipt: receipt["producer"]["execution"].update(workflowRef="foreign/workflow"),
            "foreign-event": lambda receipt: receipt["producer"]["execution"].update(event="pull_request_target"),
            "unknown-trust": lambda receipt: receipt["producer"]["execution"].update(scope="unknown"),
            "missing-job": lambda receipt: receipt["producer"]["execution"].pop("jobID"),
            "malformed-start": lambda receipt: receipt["producer"].update(startedAt="yesterday"),
            "reversed-time": lambda receipt: receipt["producer"].update(startedAt="2100-01-01T00:00:00Z", completedAt="2000-01-01T00:00:00Z"),
        }
        for name, change in changes.items():
            self.archive.write_bytes(original)
            self.rewrite_metadata(change)
            with self.subTest(case=name), self.assertRaises(ValueError):
                self.restore()
            self.assertFalse(self.binary.exists())

    def test_empty_duplicate_and_malformed_inventories_fail_even_with_matching_inventory_digest(self):
        """A self-consistent producer seal still needs nonempty, exact test leaf inventories."""
        self.seal()
        original = self.archive.read_bytes()
        inventories = ({}, {".": {"CoreTests": []}},
                       {".": {"CoreTests": ["CoreTests.Suite/test()", "CoreTests.Suite/test()"]}},
                       {".": {"CoreTests": "CoreTests.Suite/test()"}},
                       {".": {"CoreTests": ["OtherTests.Suite/test()"]}})
        for inventory in inventories:
            self.archive.write_bytes(original)

            def alter(receipt):
                receipt["tests"] = inventory
                receipt["producer"]["inventorySHA256"] = jobs.receipts.digest(inventory)

            self.rewrite_metadata(alter)
            with self.subTest(inventory=inventory), self.assertRaises(ValueError):
                self.restore()
            self.assertFalse(self.binary.exists())

    def test_corrupt_payload_is_rejected_before_extraction(self):
        """Repacking altered executable bytes cannot bypass the sealed payload digest."""
        self.seal()
        self.rewrite(lambda entries: [(member, b"tampered" if member.name.endswith(".xctest") else content)
                                      for member, content in entries])
        with self.assertRaisesRegex(ValueError, "payload digest"):
            self.restore()
        self.assertFalse(self.binary.exists())

    def test_permissions_and_internal_link_destinations_are_bound_by_payload_digest(self):
        """Executable and link metadata cannot change while retaining the producer's payload seal."""
        if os.name != "nt":
            (self.repository / ".build/debug").symlink_to("x86_64-unknown-linux-gnu/debug", target_is_directory=True)
        self.seal()
        original = self.archive.read_bytes()
        for field in ("mode", "linkname") if os.name != "nt" else ("mode",):
            self.archive.write_bytes(original)

            def alter(entries):
                for member, content in entries:
                    if field == "mode" and member.name.endswith(".xctest"):
                        member.mode = 0o644
                    elif field == "linkname" and member.name == ".build/debug":
                        member.linkname = "x86_64-unknown-linux-gnu"
                return entries

            self.rewrite(alter)
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "payload digest"):
                self.restore()
            self.assertFalse(self.binary.exists())

    def test_unsafe_links_special_absolute_and_duplicate_members_never_extract(self):
        """Reject unsafe types and paths before any otherwise valid executable is written."""
        self.seal()
        original = self.archive.read_bytes()
        fixtures = []
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
            member = tarfile.TarInfo(".build/escape")
            member.type, member.linkname = kind, "../../outside"
            fixtures.append((f"escaping-{kind!r}", member, None))
        absolute = tarfile.TarInfo(str(self.root / "outside"))
        fixtures.append(("absolute", absolute, b"x"))
        special = tarfile.TarInfo(".build/special")
        special.type = tarfile.FIFOTYPE
        fixtures.append(("fifo", special, None))
        duplicate = tarfile.TarInfo(str(self.binary.relative_to(self.repository)))
        fixtures.append(("duplicate-payload", duplicate, b"duplicate"))
        for name, member, content in fixtures:
            self.archive.write_bytes(original)
            self.rewrite(lambda entries: entries + [(member, content)])
            with self.subTest(case=name), self.assertRaises((ValueError, tarfile.FilterError)):
                self.restore()
            self.assertFalse(self.binary.exists())
            self.assertFalse((self.root / "outside").exists())

    def test_symlink_ancestor_cannot_redirect_extraction_into_source_or_another_payload_path(self):
        """Even a correctly sealed archive cannot traverse one of its own symlinks during extraction."""
        source = self.repository / "Sources/owned.swift"
        source.parent.mkdir()
        source.write_bytes(b"owned source remains")
        self.seal()
        original = self.archive.read_bytes()
        for target, leaf in (("../Sources", "owned.swift"), ("x86_64-unknown-linux-gnu/debug", "new.swift")):
            self.archive.write_bytes(original)
            link = tarfile.TarInfo(".build/redirect")
            link.type, link.linkname = tarfile.SYMTYPE, target
            redirected = tarfile.TarInfo(f".build/redirect/{leaf}")
            self.rewrite_sealed_payload(lambda entries: entries + [(link, None), (redirected, b"malicious")])
            with self.subTest(target=target), self.assertRaises((ValueError, tarfile.FilterError)):
                self.restore()
            self.assertEqual(source.read_bytes(), b"owned source remains")
            self.assertFalse(self.binary.exists())

    def test_noncanonical_duplicate_paths_and_dangling_hardlinks_are_rejected_with_valid_seals(self):
        """Equivalent path spellings and unresolvable link targets cannot defer failure to extraction."""
        self.seal()
        original = self.archive.read_bytes()
        for name in (str(self.binary.relative_to(self.repository)).replace(".build/", ".build//", 1),
                     str(self.binary.relative_to(self.repository)).replace(".build/", ".build/./", 1),
                     ".build/dangling"):
            self.archive.write_bytes(original)
            member = tarfile.TarInfo(name)
            content = b"replacement"
            if name.endswith("dangling"):
                member.type, member.linkname, content = tarfile.LNKTYPE, ".build/absent", None
            self.rewrite_sealed_payload(lambda entries: entries + [(member, content)])
            with self.subTest(path=name), self.assertRaises((ValueError, tarfile.FilterError)):
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
        deadlines = []

        def compiler(command, repository, log, *, stdout_log=None, deadline=None):
            emit_events(command)
            """Model split diagnostics while production discovery, planning and transport remain real."""
            calls.append(command.arguments)
            deadlines.append((command.name, deadline))
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
        test_deadlines = [deadline for name, deadline in deadlines if name in ("verify-discovery-0", "CoreTests-tests")]
        self.assertEqual(len(test_deadlines), 2)
        self.assertEqual(test_deadlines[0], test_deadlines[1])
        self.assertEqual(report["aggregateSeconds"], 480)
        self.assertEqual(report["compatibility"]["identity"], self.current)
        self.assertEqual(report["consumer"]["execution"], self.execution)
        self.assertEqual(report["consumer"]["selectedProducer"], metadata["producer"]["execution"])

    def test_final_compatibility_change_fails_after_successful_restored_tests(self):
        """Post-test checks still reject changed source, environment, SDK and semantic compiler flags."""
        self.seal()
        baseline_profile = jobs.build_profile("root")
        cases = []
        for field, value in (("sourceSHA256", "d" * 64), ("swiftVersion", "Swift version changed"),
                             ("buildEnvironment", {**self.current["buildEnvironment"], "CFLAGS": "-DCHANGED"}),
                             ("runtime", {**self.current["runtime"], "xcode": {"sdkVersion": "changed"}})):
            cases.append((field, {**self.current, field: value}, baseline_profile))
        for value in (True, 1.0):
            cases.append((f"runtime-version-{type(value).__name__}",
                          {**self.current, "runtime": {**self.current["runtime"], "policyVersion": value}}, baseline_profile))
        changed_profile = copy.deepcopy(baseline_profile)
        changed_profile["commands"][0].extend(["-Xswiftc", "-DCHANGED"])
        cases.append(("compiler-argv", self.current, changed_profile))

        def executor(command, repository, log, *, stdout_log=None, deadline=None):
            emit_events(command)
            log.write_text("passed\n")
            if stdout_log is not None:
                stdout_log.write_text("CoreTests.Suite/test()\n")

        for field, current_identity, current_profile in cases:
            output = self.output / field
            with (self.subTest(field=field),
                  patch.object(jobs, "identity", side_effect=[self.current, current_identity]),
                  patch.object(jobs, "build_profile", side_effect=[baseline_profile, current_profile]),
                  patch.object(jobs.linux_ci, "execute", side_effect=executor),
                  redirect_stdout(io.StringIO()), self.assertRaisesRegex(ValueError, "changed")):
                jobs.run_tests(self.repository, "root", "CoreTests", "linux-x64", 2, output, self.archive)
            report = json.loads((output / "commands.json").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertEqual([command["status"] for command in report["commands"]], ["passed", "passed"])
            self.assertEqual(report["compatibility"]["identity"], self.current)
            self.assertEqual(report["consumer"]["selectedProducer"], self.execution)
            self.assertEqual(report["consumer"]["status"], "failed")
            shutil.rmtree(self.repository / ".build")

    def test_partial_failed_test_rerun_reuses_successful_producer_without_compilation(self):
        """The next attempt reruns discovery and failed tests against the same immutable producer bytes."""
        producer = {"scope": "github", "repository": "aurum/DiscordKit", "repositoryID": "123",
                    "workflowRef": "aurum/DiscordKit/.github/workflows/native-platform.yml@refs/heads/main",
                    "workflowSHA": "a" * 40, "runID": "42", "runAttempt": "2", "jobID": "build",
                    "event": "push", "ref": "refs/heads/main", "headRef": "", "baseRef": ""}
        self.metadata["producer"] = jobs.receipts.producer_receipt(producer, self.metadata["tests"])
        metadata = self.seal()
        consumer = {**producer, "jobID": "test_CoreTests"}
        calls = []

        def executor(command, repository, log, *, stdout_log=None, deadline=None):
            emit_events(command)
            calls.append(command.arguments)
            self.assertEqual(command.arguments[:2], ("swift", "test"))
            self.assertIn("--skip-build", command.arguments)
            log.write_text("passed\n")
            if stdout_log is not None:
                stdout_log.write_text("CoreTests.Suite/test()\n")

        def failed_executor(command, repository, log, *, stdout_log=None, deadline=None):
            executor(command, repository, log, stdout_log=stdout_log, deadline=deadline)
            if stdout_log is None:
                raise subprocess.CalledProcessError(1, command.arguments)

        with (patch.object(jobs, "identity", return_value=self.current),
              patch.object(jobs.receipts, "execution_identity", return_value=consumer),
              patch.object(jobs.linux_ci, "execute", side_effect=failed_executor), redirect_stdout(io.StringIO()),
              self.assertRaises(subprocess.CalledProcessError)):
            jobs.run_tests(self.repository, "root", "CoreTests", "linux-x64", 2,
                           self.output / "failed-attempt", self.archive)
        failure = json.loads((self.output / "failed-attempt/consumer.json").read_text())
        self.assertEqual(failure["status"], "failed")
        shutil.rmtree(self.repository / ".build")
        consumer = {**consumer, "runAttempt": "3"}
        selection = self.selection(metadata, consumer)

        with (patch.object(jobs, "identity", return_value=self.current),
              patch.object(jobs.receipts, "execution_identity", return_value=consumer),
              patch.object(jobs.linux_ci, "execute", side_effect=executor), redirect_stdout(io.StringIO())):
            report = jobs.run_tests(self.repository, "root", "CoreTests", "linux-x64", 2,
                                    self.output, self.archive, selection=selection)
        self.assertEqual(report["status"], "passed")
        self.assertEqual(report["producer"]["execution"], producer)
        self.assertEqual(report["consumer"]["execution"], consumer)
        self.assertEqual(report["consumer"]["selectedProducer"], producer)
        self.assertEqual(report["consumer"]["artifact"]["id"], "9001")
        self.assertEqual(report["consumer"]["artifact"]["apiDigest"], "sha256:" + "f" * 64)
        self.assertEqual(report["consumer"]["artifact"]["archiveSHA256"], jobs.file_digest(self.archive))
        self.assertEqual(report["consumer"]["selection"]["producerAttempt"], "2")
        self.assertEqual(report["consumer"]["selection"]["consumerExecution"]["runAttempt"], "3")
        self.assertEqual(report["consumer"]["selectedProducerReceipt"], metadata["producer"])
        self.assertEqual(len(calls), 4)
        self.assertFalse(any(arguments[1] == "build" for arguments in calls))
        self.assertEqual(report["consumer"]["selectedScope"], {"component": "root", "suite": "CoreTests"})
        self.assertEqual(report["consumer"]["discovery"], "passed")
        self.assertEqual(report["consumer"]["status"], "passed")

    def test_invalid_selected_suite_retains_terminal_consumer_failure(self):
        """A rejected selection after restore cannot leave the consumer marked running or restored."""
        self.seal()
        with (patch.object(jobs, "identity", return_value=self.current),
              patch.object(jobs.linux_ci, "execute") as execute, redirect_stdout(io.StringIO()),
              self.assertRaises(ValueError)):
            jobs.run_tests(self.repository, "root", "MissingTests", "linux-x64", 2, self.output, self.archive)
        execute.assert_not_called()
        report = json.loads((self.output / "commands.json").read_text())
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["commands"], [])
        self.assertEqual(report["consumer"]["status"], "failed")
        self.assertEqual(report["consumer"]["selectedScope"], {"component": "root", "suite": "MissingTests"})
        self.assertEqual(report["consumer"]["selectedProducer"], self.execution)
        self.assertTrue(report["consumer"]["completedAt"])

    def test_caller_supplied_artifact_id_cannot_bypass_resolver_admission(self):
        """Even a valid integer ID cannot grant provenance without a complete verified index."""
        self.seal()
        for artifact_id in ("", "0", "-1", "mutable-name", "1.0", "9001"):
            with (self.subTest(artifact_id=artifact_id), patch.object(jobs, "identity", return_value=self.current),
                  patch.object(tarfile.TarFile, "extractall") as extract, self.assertRaises(TypeError)):
                jobs.restore_archive(self.repository, "root", "linux-x64", self.archive, self.output,
                                     artifact_id=artifact_id)
            extract.assert_not_called()
            self.assertFalse(self.binary.exists())
            self.assertFalse((self.output / "restored.json").exists())

    def test_invalid_complete_selection_is_rejected_before_extraction(self):
        """Immutable IDs do not excuse changed bytes, stale attempts, incomplete indices or altered receipts."""
        producer = {"scope": "github", "repository": "aurum/DiscordKit", "repositoryID": "123",
                    "workflowRef": "aurum/DiscordKit/.github/workflows/native-platform.yml@refs/heads/main",
                    "workflowSHA": "a" * 40, "runID": "42", "runAttempt": "2", "jobID": "build",
                    "event": "push", "ref": "refs/heads/main", "headRef": "", "baseRef": ""}
        self.metadata["producer"] = jobs.receipts.producer_receipt(producer, self.metadata["tests"])
        metadata = self.seal()
        consumer = {**producer, "jobID": "test", "runAttempt": "3"}
        baseline = self.selection(metadata, consumer)
        cases = {
            "wrong-archive": lambda index: index["components"]["root"].update(archiveSHA256="0" * 64),
            "unverified-id": lambda index: index["components"]["root"].update(artifactID="mutable-name"),
            "stale-index": lambda index: index["execution"].update(runAttempt="2"),
            "foreign-run": lambda index: index["execution"].update(runID="43"),
            "wrong-source": lambda index: index.update(sourceCommit="c" * 40),
            "incomplete": lambda index: index.update(expectedComponents=["macros", "root"]),
            "different-receipt": lambda index: index["components"]["root"]["metadata"]["producer"].update(
                startedAt="2001-01-01T00:00:00Z"),
        }
        for name, update in cases.items():
            selection = copy.deepcopy(baseline)
            update(selection)
            with (self.subTest(case=name), patch.object(jobs, "identity", return_value=self.current),
                  patch.object(jobs.receipts, "execution_identity", return_value=consumer),
                  patch.object(tarfile.TarFile, "extractall") as extract, self.assertRaises(ValueError)):
                jobs.restore_archive(self.repository, "root", "linux-x64", self.archive, self.output,
                                     selection=selection)
            extract.assert_not_called()
            self.assertFalse(self.binary.exists())
            self.assertFalse((self.output / "restored.json").exists())

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
        deadlines = {}
        generated = self.repository / ".build/out/symbolgraph/Library.symbols.json"

        def compiler(command, repository, log, *, stdout_log=None, deadline=None):
            emit_events(command)
            """Produce build outputs and documentation inputs at their actual archive locations."""
            calls.append(command.name)
            deadlines[command.name] = deadline
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
        self.assertEqual(deadlines["root"], deadlines["public-symbol-graphs"])
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

    def test_aggregate_timeout_stops_serial_commands_without_retry(self):
        """An aggregate deadline interrupts the next process despite its longer per-command limit."""
        sentinel = self.root / "must-not-run"
        commands = [jobs.linux_ci.Command("first", (sys.executable, "-c", "print('first passed')"), 5),
                    jobs.linux_ci.Command("stuck", (sys.executable, "-c", "import time; time.sleep(10)"), 5),
                    jobs.linux_ci.Command("never", (sys.executable, "-c",
                        "from pathlib import Path; Path(__import__('sys').argv[1]).touch()", str(sentinel)), 5)]
        report = {"status": "running", "commands": []}
        started = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired), redirect_stdout(io.StringIO()):
            jobs.execute_commands(commands, self.repository, self.output, report, deadline=started + 0.5)
        self.assertLess(time.monotonic() - started, 5)
        self.assertFalse(sentinel.exists())
        self.assertEqual([record["name"] for record in report["commands"]], ["first", "stuck"])
        self.assertEqual([record["status"] for record in report["commands"]], ["passed", "failed"])
        failed = report["commands"][-1]
        self.assertEqual(failed["timeoutCategory"], "aggregate")
        self.assertEqual(failed["execution"]["timeoutCategory"], "aggregate")
        self.assertIn("identity", failed["execution"])
        self.assertTrue((self.output / failed["executionReceipt"]).is_file())
        self.assertTrue((self.output / failed["diagnostics"]).is_file())

    def test_expired_aggregate_is_reported_without_starting_child(self):
        """A deadline exhausted between commands cannot admit another process or leave running status."""
        sentinel = self.root / "must-not-run"
        command = jobs.linux_ci.Command("never", (sys.executable, "-c",
            "from pathlib import Path; Path(__import__('sys').argv[1]).touch()", str(sentinel)), 5)
        report = {"status": "running", "commands": []}
        with self.assertRaises(subprocess.TimeoutExpired), redirect_stdout(io.StringIO()):
            jobs.execute_commands([command], self.repository, self.output, report, deadline=time.monotonic() - 1)
        self.assertFalse(sentinel.exists())
        retained = json.loads((self.output / "commands.json").read_text())
        self.assertEqual(retained["status"], "failed")
        self.assertEqual(retained["commands"][0]["timeoutCategory"], "aggregate")

    def test_group_console_failure_marks_failed_and_preserves_primary_error(self):
        """Workflow group markers cannot leave a running receipt or mask a child assertion failure."""
        command = jobs.linux_ci.Command("example", (sys.executable, "-c", "pass"), 5)
        report = {"status": "running", "commands": []}
        with patch.object(jobs.linux_ci, "_console_write", side_effect=OSError("console closed")), \
                patch.object(jobs.linux_ci, "execute") as execute, self.assertRaisesRegex(OSError, "console closed"):
            jobs.execute_commands([command], self.repository, self.output, report)
        execute.assert_not_called()
        self.assertEqual(report["commands"][0]["status"], "failed")
        primary = subprocess.CalledProcessError(7, command.arguments)
        with patch.object(jobs.linux_ci, "_console_write", side_effect=[None, OSError("closing marker failed")]), \
                patch.object(jobs.linux_ci, "execute", side_effect=primary), self.assertRaises(subprocess.CalledProcessError) as error:
            jobs.execute_commands([command], self.repository, self.output, report)
        self.assertIs(error.exception, primary)

    def test_compilation_rejects_required_runtime_type_drift_before_sealing(self):
        """Python's bool/int/float equality cannot conceal changed required facts at the producer boundary."""
        def compiler(command, repository, log, *, stdout_log=None, deadline=None):
            emit_events(command)
            log.write_text("passed\n")
            if stdout_log is not None:
                stdout_log.write_text("CoreTests.Suite/test()\n")

        for value in (True, 1.0):
            changed = {**self.current, "runtime": {**self.current["runtime"], "policyVersion": value}}
            output = self.output / type(value).__name__
            with (self.subTest(value=value), patch.object(jobs, "identity", side_effect=[self.current, changed]),
                  patch.object(jobs, "dump_targets", return_value=["CoreTests"]),
                  patch.object(jobs.linux_ci, "execute", side_effect=compiler), redirect_stdout(io.StringIO()),
                  self.assertRaisesRegex(ValueError, "changed")):
                jobs.compile_component(self.repository, "root", "linux-x64", 2, output, self.archive)
            self.assertFalse(self.archive.exists())
            self.assertEqual(json.loads((output / "commands.json").read_text())["status"], "failed")

    def test_empty_inventory_failure_preserves_failed_component_report(self):
        """A passing discovery process with no leaves fails the entire component and emits no archive."""
        def compiler(command, repository, log, *, stdout_log=None, deadline=None):
            emit_events(command)
            log.write_text("passed but no test leaves\n")
            if stdout_log is not None:
                stdout_log.write_text("")

        with patch.object(jobs, "identity", return_value=self.current), \
                patch.object(jobs, "dump_targets", return_value=["CoreTests"]), \
                patch.object(jobs.linux_ci, "execute", side_effect=compiler), redirect_stdout(io.StringIO()), \
                self.assertRaisesRegex(ValueError, "at least one test"):
            jobs.compile_component(self.repository, "root", "linux-x64", 2, self.output, self.archive)
        self.assertFalse(self.archive.exists())
        self.assertEqual(json.loads((self.output / "commands.json").read_text())["status"], "failed")


class NativeSourceTests(unittest.TestCase):
    """Use real Git metadata to distinguish HEAD identity from dirty compiled source bytes."""

    def test_binary_metadata_preserves_complete_bytes_and_receipts_without_console_inventory(self):
        payload = b"filename-\xff\n\0" * 20000
        script = "import sys; sys.stdout.buffer.write(b'filename-\\xff\\n\\0' * 20000)"
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            output = repository / "metadata"
            report = {"status": "running", "commands": []}
            with redirect_stdout(io.StringIO()) as console:
                actual = jobs.metadata_output([sys.executable, "-c", script], repository,
                                              output=output, report=report, binary=True)
            self.assertEqual(actual, payload)
            self.assertEqual(console.getvalue(), "")
            record = report["commands"][0]
            self.assertEqual((output / record["stdoutLog"]).read_bytes(), jobs.base64.b64encode(payload))
            self.assertTrue((output / record["log"]).is_file())
            receipt = json.loads((output / record["executionReceipt"]).read_text())
            self.assertEqual(receipt["status"], "passed")
            self.assertEqual(receipt["exitCode"], 0)
            self.assertFalse(any(item["truncated"] for item in receipt["outputs"]))

    def test_binary_metadata_failure_keeps_full_logs_and_bounded_actionable_console_diagnostics(self):
        script = ("import sys; sys.stdout.buffer.write(b'partial\\0inventory'); "
                  "sys.stderr.write('x' * 10000 + '\\nfatal: metadata fixture could not read source\\n'); "
                  "raise SystemExit(7)")
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            output = repository / "metadata"
            report = {"status": "running", "commands": []}
            with redirect_stdout(io.StringIO()) as console, redirect_stderr(io.StringIO()) as errors, \
                    self.assertRaises(subprocess.CalledProcessError) as raised:
                jobs.metadata_output([sys.executable, "-c", script], repository,
                                     output=output, report=report, binary=True)
            self.assertEqual(raised.exception.returncode, 7)
            self.assertEqual(console.getvalue(), "")
            self.assertIn("fatal: metadata fixture could not read source", errors.getvalue())
            self.assertLess(len(errors.getvalue()), 4600)
            record = report["commands"][0]
            self.assertEqual(record["status"], "failed")
            self.assertEqual((output / record["stdoutLog"]).read_bytes(), jobs.base64.b64encode(b"partial\0inventory"))
            retained = (output / record["log"]).read_text()
            self.assertGreater(len(retained), 10000)
            self.assertIn("fatal: metadata fixture could not read source", retained)
            self.assertEqual(json.loads((output / record["executionReceipt"]).read_text())["exitCode"], 7)

    def test_text_metadata_still_forwards_human_readable_output(self):
        with tempfile.TemporaryDirectory() as directory, redirect_stdout(io.StringIO()) as console:
            result = jobs.metadata_output([sys.executable, "-c", "print('visible metadata')"], Path(directory))
        self.assertEqual(result, "visible metadata\n")
        self.assertIn("visible metadata\n", console.getvalue())

    def test_dirty_tracked_source_changes_identity_even_when_commit_stays_equal(self):
        """Artifact reuse cannot trust only the unchanged commit name of a dirty checkout."""
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            subprocess.run(["git", "init", "--quiet", str(repository)], check=True)
            source = repository / "source.swift"
            source.write_text("original\n")
            pins = [repository / "Package.resolved", repository / "Tools/Fixture/Package.resolved"]
            for index, pin in enumerate(pins):
                pin.parent.mkdir(parents=True, exist_ok=True)
                pin.write_text(json.dumps({"pins": [f"dependency-{index}"]}))
            subprocess.run(["git", "-C", str(repository), "add", "source.swift", "Package.resolved",
                            "Tools/Fixture/Package.resolved"], check=True)
            subprocess.run(["git", "-C", str(repository), "-c", "user.name=CI Fixture", "-c", "user.email=fixture@example.invalid",
                            "commit", "--quiet", "-m", "fixture"], check=True)
            with patch.dict(os.environ, {}, clear=True), redirect_stdout(io.StringIO()):
                first = jobs.source_identity(repository)
                source.write_text("changed without committing\n")
                second = jobs.source_identity(repository)
                pins[1].write_text(json.dumps({"pins": ["changed-dependency"]}))
                third = jobs.source_identity(repository)
            self.assertEqual(first["commit"], second["commit"])
            self.assertEqual(first["commit"], third["commit"])
            self.assertNotEqual(first["sourceSHA256"], second["sourceSHA256"])
            self.assertNotEqual(second["sourceSHA256"], third["sourceSHA256"])
            self.assertEqual(set(first["dependencyPinsSHA256"]), {"Package.resolved", "Tools/Fixture/Package.resolved"})
            self.assertEqual(first["dependencyPinsSHA256"], second["dependencyPinsSHA256"])
            self.assertEqual(second["dependencyPinsSHA256"]["Package.resolved"], jobs.file_digest(pins[0]))
            self.assertNotEqual(second["dependencyPinsSHA256"]["Tools/Fixture/Package.resolved"],
                                third["dependencyPinsSHA256"]["Tools/Fixture/Package.resolved"])

    def test_build_environment_binds_semantic_overrides_without_copying_unrelated_secrets(self):
        """Compiler input drift is visible while unrelated host credentials stay outside receipts."""
        environment = {"CFLAGS": "-DFIXTURE", "SWIFT_BUILD_FLAGS": "--fixture-flag", "GITHUB_TOKEN": "fixture-secret"}
        with patch.dict(os.environ, environment, clear=True):
            recorded = jobs.build_environment()
        self.assertEqual(recorded["CFLAGS"], "-DFIXTURE")
        self.assertEqual(recorded["SWIFT_BUILD_FLAGS"], "--fixture-flag")
        self.assertNotIn("GITHUB_TOKEN", recorded)
        self.assertNotIn("fixture-secret", json.dumps(recorded))

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
                target_info = {"compilerVersion": "Swift version 6.4.1", "target": {
                    "triple": target, "unversionedTriple": target, "moduleTriple": target}, "paths": {
                    "runtimeLibraryPaths": ["/fixture/swift/linux"],
                    "runtimeLibraryImportPaths": ["/fixture/swift/linux"],
                    "runtimeResourcePath": "/fixture/swift"}}

                def query(arguments, *args, **kwargs):
                    if arguments == ["swift", "--version"]:
                        return "Swift version 6.4.1"
                    if arguments == ["swift", "-print-target-info"]:
                        return json.dumps(target_info)
                    if arguments == ["ldd", "--version"]:
                        return "ldd (Ubuntu GLIBC 2.39) 2.39\n"
                    raise AssertionError(f"unexpected identity query: {arguments!r}")

                stack.enter_context(patch.object(jobs, "metadata_output", side_effect=query))
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
