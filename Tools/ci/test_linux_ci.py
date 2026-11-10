# File: Tools/ci/test_linux_ci.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Native offline gate contracts, durable failure reports and real process cleanup."""

from contextlib import ExitStack, redirect_stderr, redirect_stdout, suppress
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import MagicMock, call, patch

import linux_ci


class LinuxCommandTests(unittest.TestCase):
    """Protect package coverage, dependency pins and argument boundaries without compiling."""

    def setUp(self):
        """Use an actual temporary checkout path containing shell-significant characters."""
        self.temporary = tempfile.TemporaryDirectory(prefix="Ubuntu gates $ literal ")
        self.addCleanup(self.temporary.cleanup)
        self.repository = Path(self.temporary.name).resolve()
        browser = self.repository / "Browser/DiscordActivityBridge"
        browser.mkdir(parents=True)
        (browser / "bridge.test.mjs").touch()

    def plan(self, stage):
        """Plan one stage with a distinguishable nondefault compiler job budget."""
        return linux_ci.commands(stage, self.repository, 3)

    def test_every_swift_invocation_requires_pins_and_bounded_jobs(self):
        """All packages inherit the same dependency and memory policy, including executable runs."""
        stages = ("root", "authoring", "tooling", "benchmarks", "helpers", "audit", "consumers", "release")
        self.assertEqual(linux_ci.STAGES, stages)
        for stage in stages:
            for command in self.plan(stage):
                with self.subTest(stage=stage, command=command.name):
                    self.assertGreater(command.timeout, 0)
                    self.assertTrue(all(isinstance(argument, str) for argument in command.arguments))
                    if command.arguments[0] != "swift":
                        continue
                    arguments = command.arguments
                    self.assertIn(arguments[1], ("build", "test", "run"))
                    self.assertEqual(arguments.count("--jobs"), 1)
                    self.assertEqual(arguments[arguments.index("--jobs") + 1], "3")
                    self.assertEqual(arguments.count("--force-resolved-versions"), 1)
                    self.assertEqual(arguments[arguments.index("--build-system") + 1], "native")
                    self.assertIn("--disable-experimental-prebuilts", arguments)
                    self.assertIn("--package-path", arguments)

    def test_run_options_precede_executable_and_program_arguments_follow(self):
        """SwiftPM flags cannot accidentally reach an example or audit program as its own options."""
        for stage in ("benchmarks", "audit", "consumers"):
            for command in self.plan(stage):
                if command.arguments[:2] != ("swift", "run"):
                    continue
                arguments = command.arguments
                executable = ("DiscordDSLBenchmarks" if stage == "benchmarks" else
                              "DiscordKitTools" if stage == "audit" else command.name.removeprefix("run-"))
                executable_index = arguments.index(executable)
                for flag in ("--package-path", "--jobs", "--force-resolved-versions"):
                    self.assertLess(arguments.index(flag), executable_index)
                if stage == "benchmarks":
                    self.assertLess(arguments.index("--configuration"), executable_index)
                    self.assertGreater(arguments.index("--invocations"), executable_index)
                if stage == "audit":
                    self.assertGreater(arguments.index("--repository"), executable_index)
                if command.name == "run-DSLCommands":
                    self.assertEqual(arguments[executable_index + 1:], ("--offline",))
                if "--scratch-path" in arguments:
                    self.assertLess(arguments.index("--scratch-path"), executable_index)

    def test_root_and_optimized_package_graphs_are_independent_gates(self):
        """A debug build alone cannot satisfy root runtime tests or optimized library/macro builds."""
        root = self.plan("root")
        self.assertEqual([command.arguments[1] for command in root], ["build", "test"])
        self.assertTrue(all(command.arguments[command.arguments.index("--package-path") + 1] == "."
                            for command in root))
        release = self.plan("release")
        self.assertEqual({command.arguments[command.arguments.index("--package-path") + 1] for command in release},
                         {".", "Packages/DiscordDSLMacros", "Packages/DiscordDSLExtensions"})
        for command in release:
            self.assertEqual(command.arguments[1], "build")
            self.assertEqual(command.arguments[command.arguments.index("--configuration") + 1], "release")

    def test_independent_consumer_builds_tests_and_offline_runs_are_retained(self):
        """Each consumer graph builds; selected application assertions and synthetic runs also execute."""
        examples = {"RESTOnly", "GatewayBot", "HTTPApp", "CommandsApp", "DSLCommands", "DSLEvents", "DSLBot",
                    "OAuthApp", "VoiceBot", "RPCApp", "ActivityHost", "SocialApp", "LoggingApp"}
        tests = {"LoggingApp", "CommandsApp", "DSLCommands", "DSLEvents", "DSLBot", "ActivityHost"}
        runs = {"LoggingApp", "CommandsApp", "DSLCommands", "DSLEvents", "DSLBot", "VoiceBot", "SocialApp"}
        planned = self.plan("consumers")
        self.assertEqual({command.name.removeprefix("build-") for command in planned
                          if command.arguments[1] == "build"}, examples)
        self.assertEqual({command.name.removeprefix("test-") for command in planned
                          if command.arguments[1] == "test"}, tests)
        self.assertEqual({command.name.removeprefix("run-") for command in planned
                          if command.arguments[1] == "run"}, runs)
        for command in planned:
            self.assertEqual(command.arguments[command.arguments.index("--scratch-path") + 1],
                             str(self.repository / ".build/consumers"))
            if command.arguments[1] == "build":
                self.assertEqual(command.arguments[command.arguments.index("--explicit-target-dependency-import-check") + 1],
                                 "error")

    def test_authoring_compilation_passes_fixture_resource_limits(self):
        """Negative compilation retains a longer cold-build timeout and the same job budget."""
        planned = self.plan("authoring")
        self.assertEqual([command.name for command in planned],
                         ["DiscordDSLMacros", "dsl_compile_fixtures.py",
                          "DiscordDSLExtensions", "dsl_extension_fixtures.py"])
        for command in planned:
            arguments = command.arguments
            if arguments[0] == "swift":
                self.assertEqual(arguments[arguments.index("--explicit-target-dependency-import-check") + 1], "error")
            else:
                self.assertEqual(arguments[0], sys.executable)
                self.assertEqual(arguments[arguments.index("--repository") + 1], str(self.repository))
                self.assertEqual(arguments[arguments.index("--jobs") + 1], "3")
                self.assertGreaterEqual(int(arguments[arguments.index("--timeout") + 1]), 1200)
                self.assertGreater(command.timeout, int(arguments[arguments.index("--timeout") + 1]))

    def test_browser_discovery_is_sorted_and_preserves_literal_paths(self):
        """Browser tests are explicit file arguments and never require shell wildcard expansion."""
        directory = self.repository / "Browser/DiscordActivityBridge"
        (directory / "bridge.test.mjs").unlink()
        for name in ("z.test.mjs", "a test.test.mjs", "bridge.mjs"):
            (directory / name).touch()
        browser, = [command for command in self.plan("helpers") if command.name == "browser"]
        self.assertEqual(browser.arguments, ("node", "--test", "Browser/DiscordActivityBridge/a test.test.mjs",
                                             "Browser/DiscordActivityBridge/z.test.mjs"))

    def test_missing_browser_fixtures_cannot_fall_back_to_node_discovery(self):
        """A missing suite must fail planning rather than let Node choose unrelated tests."""
        (self.repository / "Browser/DiscordActivityBridge/bridge.test.mjs").unlink()
        with self.assertRaisesRegex(ValueError, "browser"):
            self.plan("helpers")

    def test_helpers_are_independent_from_swift_compilation_stages(self):
        """Shared Python and browser suites run once without rebuilding any platform graph."""
        helpers = self.plan("helpers")
        self.assertEqual({command.arguments[command.arguments.index("-s") + 1] for command in helpers
                          if command.arguments[0] == sys.executable},
                         {"Tools/DiscordKitTools/scripts", "Tools/DiscordKitLoadTests/scripts",
                          "Tools/DiscordDSLBenchmarks/scripts", "Tools/ci"})
        self.assertEqual(sum(command.arguments[0] == "node" for command in helpers), 1)
        self.assertNotIn("swift", {command.arguments[0] for command in helpers})
        for stage in ("tooling", "benchmarks"):
            self.assertTrue(all(command.arguments[0] == "swift" for command in self.plan(stage)))

    def test_plans_do_not_include_credentials_or_live_mutations(self):
        """The CI plan cannot start the qualification client, publish a package or sync Discord commands."""
        forbidden = ("live_rest_smoke", "VoiceSessionQualification", "DISCORD_TOKEN", "BOT_TOKEN",
                     "--token", "publish", "deploy", "sync-commands", "curl", "wget", "sudo")
        for stage in linux_ci.STAGES:
            for command in self.plan(stage):
                self.assertIn(command.arguments[0], ("swift", "node", sys.executable))
                for argument in command.arguments:
                    self.assertTrue(all(word not in argument for word in forbidden), (stage, argument))

    def test_invalid_stage_and_job_budgets_fail_before_execution(self):
        """Typos, booleans and nonpositive limits cannot silently remove the compiler cap."""
        with self.assertRaises(ValueError):
            self.plan("ubunty")
        for jobs in (0, -1, True, 1.5, "4", None):
            with self.subTest(jobs=jobs), self.assertRaises(ValueError):
                linux_ci.commands("root", self.repository, jobs)


class LinuxExecutionTests(unittest.TestCase):
    """Verify durable outcomes and bounded process ownership using harmless local Python children."""

    def test_failed_command_is_durable_and_stops_later_commands(self):
        """Inspect the saved running state before execution and preserve each earlier successful result."""
        with tempfile.TemporaryDirectory() as temporary, redirect_stdout(io.StringIO()):
            repository = Path(temporary)
            output = repository / "reports"
            planned = [linux_ci.Command(name, ("fixture", name)) for name in ("first", "failure", "never")]
            seen = []

            def execute(command, checkout, log):
                """Observe persisted admission and fail on the second command without invoking a compiler."""
                self.assertEqual(checkout, repository)
                report = json.loads((output / "root.json").read_text())
                self.assertEqual(report["status"], "running")
                self.assertEqual(report["commands"][-1]["status"], "running")
                self.assertEqual(report["commands"][-1]["name"], command.name)
                if seen:
                    self.assertEqual(report["commands"][0]["status"], "passed")
                seen.append(command.name)
                log.write_text(command.name + " output\n")
                if command.name == "failure":
                    raise subprocess.CalledProcessError(7, command.arguments)

            with patch.object(linux_ci, "commands", return_value=planned), patch.object(linux_ci, "execute", execute):
                with self.assertRaises(subprocess.CalledProcessError):
                    linux_ci.run_stage("root", repository, output, 3)
            report = json.loads((output / "root.json").read_text())
            self.assertEqual(seen, ["first", "failure"])
            self.assertEqual(report["status"], "failed")
            self.assertEqual([command["status"] for command in report["commands"]], ["passed", "failed"])
            self.assertIn("7", report["commands"][-1]["error"])
            self.assertTrue(all(isinstance(command["seconds"], (int, float)) for command in report["commands"]))
            self.assertFalse((output / "root.tmp").exists())
            self.assertTrue(all((output / command["log"]).is_file() for command in report["commands"]))

    def test_successful_stage_finishes_with_all_commands_passed(self):
        """Only completion of every command writes the terminal passed result."""
        with tempfile.TemporaryDirectory() as temporary, redirect_stdout(io.StringIO()):
            repository = Path(temporary)
            command = linux_ci.Command("local", (sys.executable, "-c", "print('offline passed')"))
            with patch.object(linux_ci, "commands", return_value=[command]):
                linux_ci.run_stage("root", repository, repository / "reports", 3)
            report = json.loads((repository / "reports/root.json").read_text())
            self.assertEqual(report["status"], "passed")
            self.assertEqual(report["commands"][0]["status"], "passed")
            self.assertIn("offline passed", (repository / "reports" / report["commands"][0]["log"]).read_text())

    def test_benchmark_stage_creates_output_directory_on_a_cold_checkout(self):
        """The smoke executable's output path works without a prior local benchmark run."""
        with tempfile.TemporaryDirectory() as temporary, redirect_stdout(io.StringIO()):
            repository = Path(temporary)
            destination = repository / ".build/dsl-measurements"
            self.assertFalse(destination.exists())
            seen = []

            def execute(command, checkout, log):
                """Check the actual smoke program's destination before any stage command runs."""
                self.assertTrue(destination.is_dir())
                self.assertEqual(checkout, repository)
                seen.append(command.name)

            with patch.object(linux_ci, "execute", execute):
                linux_ci.run_stage("benchmarks", repository, repository / "reports", 3)
            self.assertIn("smoke", seen)

    def test_real_subprocess_failure_streams_both_outputs_and_strict_environment(self):
        """A nonzero child retains stdout, stderr, working-directory and strict-mode evidence in its log."""
        with tempfile.TemporaryDirectory(prefix="Ubuntu process $ literal ") as temporary:
            repository = Path(temporary)
            code = ("import os, sys; print('stdout fixture', flush=True); "
                    "print('stderr fixture', file=sys.stderr, flush=True); "
                    "print('strict=' + os.environ['SWIFTNIO_STRICT']); "
                    "print('unbuffered=' + os.environ['PYTHONUNBUFFERED']); "
                    "print('cwd=' + os.getcwd()); sys.exit(7)")
            command = linux_ci.Command("failure", (sys.executable, "-c", code), timeout=5)
            console = io.StringIO()
            with redirect_stdout(console), self.assertRaises(subprocess.CalledProcessError) as caught:
                linux_ci.execute(command, repository, repository / "failure.log")
            self.assertEqual(caught.exception.returncode, 7)
            log = (repository / "failure.log").read_text()
            for expected in ("stdout fixture", "stderr fixture", "strict=1", "unbuffered=1",
                             "cwd=" + str(repository.resolve())):
                self.assertIn(expected, log)
                self.assertIn(expected, console.getvalue())

    def test_output_forwarding_failure_cannot_be_reported_as_success(self):
        """A successful child still fails qualification if its output cannot reach the console sink."""
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            command = linux_ci.Command("logging", (sys.executable, "-c", "print('offline output')"), timeout=5)
            with patch.object(linux_ci, "print", side_effect=BrokenPipeError("console sink failed"), create=True):
                with self.assertRaisesRegex(OSError, "could not preserve command output"):
                    linux_ci.execute(command, repository, repository / "logging.log")
            self.assertIn("offline output", (repository / "logging.log").read_text())

    def test_discovery_stdout_stays_separate_on_success_and_failure_on_both_executors(self):
        """A warning emitted between partial identifier writes cannot corrupt captured discovery text."""
        original_popen = subprocess.Popen

        def start(*arguments, **options):
            """Run the Windows regular-file path on the local host without Windows creation flags."""
            options.pop("creationflags", None)
            return original_popen(*arguments, **options)

        for windows in (False, True):
            for result in (0, 7):
                with self.subTest(windows=windows, result=result), tempfile.TemporaryDirectory() as temporary, \
                        redirect_stdout(io.StringIO()) as console:
                    repository = Path(temporary)
                    stdout_log, log = repository / "discovery.stdout", repository / "discovery.log"
                    warning = "warning: native build engine is deprecated\nBogusTests/diagnosticOnly()\n"
                    code = ("import os, sys; os.write(1, b'DiscordVoiceTests.VoiceMan'); "
                            f"os.write(2, {warning.encode()!r}); "
                            "os.write(1, b'agerTests/automaticReplacementSupersedesPendingFactory()\\n'); "
                            f"sys.exit({result})")
                    command = linux_ci.Command("discovery", (sys.executable, "-c", code), timeout=5)
                    with patch.object(linux_ci, "WINDOWS_HOST", windows), \
                            patch.object(linux_ci.subprocess, "CREATE_NEW_PROCESS_GROUP", 512, create=True), \
                            patch.object(linux_ci.subprocess, "Popen", side_effect=start):
                        if result:
                            with self.assertRaises(subprocess.CalledProcessError) as caught:
                                linux_ci.execute(command, repository, log, stdout_log=stdout_log)
                            self.assertEqual(caught.exception.returncode, result)
                        else:
                            linux_ci.execute(command, repository, log, stdout_log=stdout_log)
                    expected = "DiscordVoiceTests.VoiceManagerTests/automaticReplacementSupersedesPendingFactory()\n"
                    self.assertEqual(stdout_log.read_text(), expected)
                    diagnostics = log.read_text()
                    self.assertIn(warning, diagnostics)
                    self.assertNotIn(expected, diagnostics)
                    self.assertIn(expected, console.getvalue())
                    for line in warning.splitlines():
                        self.assertIn(line + "\n", console.getvalue())

    def test_separate_output_drains_both_full_pipes_without_losing_diagnostics(self):
        """Simultaneous large stdout and stderr complete within one deadline and retain all output."""
        with tempfile.TemporaryDirectory() as temporary, redirect_stdout(io.StringIO()):
            repository = Path(temporary)
            code = ("import os\n"
                    "for index in range(64):\n"
                    "    os.write(1, b'o' * 8191 + b'\\n')\n"
                    "    os.write(2, b'e' * 8191 + b'\\n')\n")
            command = linux_ci.Command("streams", (sys.executable, "-c", code), timeout=5)
            stdout_log, log = repository / "streams.stdout", repository / "streams.log"
            linux_ci.execute(command, repository, log, stdout_log=stdout_log)
            self.assertEqual(stdout_log.read_text(), ("o" * 8191 + "\n") * 64)
            self.assertTrue(log.read_text().endswith(("e" * 8191 + "\n") * 64))

    def test_windows_execution_redirects_to_regular_log_and_replays_output(self):
        """Windows avoids an inherited output pipe and retains the completed parent's log."""
        with tempfile.TemporaryDirectory() as temporary, redirect_stdout(io.StringIO()):
            repository = Path(temporary)
            process = MagicMock()
            process.wait.return_value = 0
            command = linux_ci.Command("windows", ("fixture.exe",))

            def start(*arguments, **options):
                """Model direct child writes through the actual regular-file handle."""
                destination = options["stdout"]
                self.assertEqual(Path(destination.name), repository / "windows.log")
                destination.write("windows fixture\n")
                destination.flush()
                return process

            with patch.object(linux_ci, "WINDOWS_HOST", True), \
                    patch.object(linux_ci.subprocess, "CREATE_NEW_PROCESS_GROUP", 512, create=True), \
                    patch.object(linux_ci.subprocess, "Popen", side_effect=start) as spawn:
                linux_ci.execute(command, repository, repository / "windows.log")
            self.assertEqual(spawn.call_args.kwargs["creationflags"], 512)
            self.assertNotIn("start_new_session", spawn.call_args.kwargs)
            self.assertNotEqual(spawn.call_args.kwargs["stdout"], subprocess.PIPE)
            self.assertEqual(spawn.call_args.kwargs["stderr"], subprocess.STDOUT)
            process.__enter__.assert_not_called()
            self.assertIn("windows fixture", (repository / "windows.log").read_text())

    def test_windows_parent_timeout_attempts_cleanup_and_has_bounded_waits(self):
        """A timed-out parent fails and replays its available log without any pipe drain."""
        with tempfile.TemporaryDirectory() as temporary, redirect_stdout(io.StringIO()) as console:
            repository = Path(temporary)
            process = MagicMock(pid=1234)
            process.wait.side_effect = [subprocess.TimeoutExpired("fixture.exe", 0.1), 7]
            process.poll.return_value = 7
            command = linux_ci.Command("windows", ("fixture.exe",), timeout=0.1)
            started = time.monotonic()
            with patch.object(linux_ci, "WINDOWS_HOST", True), \
                    patch.object(linux_ci.subprocess, "CREATE_NEW_PROCESS_GROUP", 512, create=True), \
                    patch.object(linux_ci.subprocess, "Popen", return_value=process), \
                    patch.object(linux_ci.subprocess, "run") as terminate, \
                    self.assertRaises(subprocess.TimeoutExpired):
                linux_ci.execute(command, repository, repository / "windows.log")
            self.assertLess(time.monotonic() - started, 1)
            self.assertEqual(process.wait.call_args_list, [call(timeout=0.1), call(timeout=5)])
            terminate.assert_called_once()
            self.assertIn("fixture.exe", console.getvalue())

    def test_windows_regular_log_does_not_wait_for_an_exited_parents_descendant(self):
        """A real child retaining the log handle cannot keep the parent's command admission open."""
        with tempfile.TemporaryDirectory() as temporary, redirect_stdout(io.StringIO()):
            repository = Path(temporary)
            pid_file = repository / "descendant.pid"
            child = ("import os, pathlib, time; "
                     f"pathlib.Path({str(pid_file)!r}).write_text(str(os.getpid())); "
                     "print('descendant owns regular log', flush=True); time.sleep(60)")
            parent = ("import pathlib, subprocess, sys, time; "
                      f"process = subprocess.Popen([sys.executable, '-c', {child!r}]); "
                      f"pid_file = pathlib.Path({str(pid_file)!r}); "
                      "exec('while not pid_file.exists(): time.sleep(0.01)'); "
                      "print('parent completed', flush=True)")
            command = linux_ci.Command("windows", (sys.executable, "-c", parent), timeout=5)
            original_popen = subprocess.Popen

            def start(*arguments, **options):
                """Exercise actual regular-file inheritance on this test host without Windows creation flags."""
                options.pop("creationflags")
                return original_popen(*arguments, **options)

            started = time.monotonic()
            try:
                with patch.object(linux_ci, "WINDOWS_HOST", True), \
                        patch.object(linux_ci.subprocess, "CREATE_NEW_PROCESS_GROUP", 512, create=True), \
                        patch.object(linux_ci.subprocess, "Popen", side_effect=start):
                    linux_ci.execute(command, repository, repository / "windows.log")
                self.assertLess(time.monotonic() - started, 3)
                self.assertTrue(pid_file.is_file())
                self.assertIn("parent completed", (repository / "windows.log").read_text())
            finally:
                if pid_file.exists():
                    with suppress(ProcessLookupError):
                        os.kill(int(pid_file.read_text()), signal.SIGTERM)

    def test_windows_cleanup_attempts_tree_termination_and_reaps_the_parent(self):
        """Taskkill requests tree termination; orphaned Windows children remain a workflow boundary."""
        process = MagicMock(pid=1234)
        process.poll.return_value = 7
        with patch.object(linux_ci, "WINDOWS_HOST", True), \
                patch.object(linux_ci.subprocess, "run") as terminate:
            linux_ci.stop_process_group(process)
        terminate.assert_called_once_with(["taskkill", "/PID", "1234", "/T", "/F"],
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                         timeout=10, check=False)
        process.kill.assert_not_called()
        process.wait.assert_called_once_with(timeout=5)

    def test_windows_cleanup_reaps_parent_if_taskkill_itself_times_out(self):
        """Cleanup stays bounded and still kills the admitted parent when the system utility fails."""
        process = MagicMock(pid=1234)
        process.poll.return_value = None
        with patch.object(linux_ci, "WINDOWS_HOST", True), \
                patch.object(linux_ci.subprocess, "run", side_effect=subprocess.TimeoutExpired("taskkill", 10)):
            linux_ci.stop_process_group(process)
        process.kill.assert_called_once_with()
        process.wait.assert_called_once_with(timeout=5)

    @unittest.skipUnless(os.name == "posix", "process-group cleanup is a POSIX contract")
    def test_timeout_terminates_parent_and_sigterm_resistant_descendant(self):
        """A timed-out compiler tree cannot leave a plugin alive after its group leader is reaped."""
        self.assert_descendant_timeout(parent_waits=True)

    @unittest.skipUnless(os.name == "posix", "process-group cleanup is a POSIX contract")
    def test_timeout_includes_descendants_after_successful_parent_exit(self):
        """A successful SwiftPM exit cannot pass while its child still owns the command output pipe."""
        self.assert_descendant_timeout(parent_waits=False)

    @unittest.skipUnless(os.name == "posix", "process-group cleanup is a POSIX contract")
    def test_timeout_includes_each_separate_stream_after_successful_parent_exit(self):
        """Splitting discovery streams cannot hide a descendant retaining only one output pipe."""
        for stderr in (False, True):
            with self.subTest(stderr=stderr):
                self.assert_descendant_timeout(parent_waits=False, capture_stdout=True, descendant_stderr=stderr)

    def assert_descendant_timeout(self, parent_waits, capture_stdout=False, descendant_stderr=False):
        """Run a synthetic child tree with an observable PID and always clean it on assertion failure."""
        with tempfile.TemporaryDirectory() as temporary, redirect_stdout(io.StringIO()):
            repository = Path(temporary)
            pid_file = repository / "descendant.pid"
            child = ("import os, pathlib, signal, sys, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                     f"pathlib.Path({str(pid_file)!r}).write_text(str(os.getpid())); "
                     f"print('descendant started', file=sys.{'stderr' if descendant_stderr else 'stdout'}, flush=True); time.sleep(60)")
            redirection = (", stdout=subprocess.DEVNULL" if descendant_stderr else ", stderr=subprocess.DEVNULL") if capture_stdout else ""
            parent = (f"import subprocess, sys; process = subprocess.Popen([sys.executable, '-c', {child!r}]{redirection}); "
                      + ("process.wait()" if parent_waits else "sys.exit(0)"))
            command = linux_ci.Command("timeout", (sys.executable, "-c", parent), timeout=1.5)
            started = time.monotonic()
            try:
                with self.assertRaises(subprocess.TimeoutExpired):
                    linux_ci.execute(command, repository, repository / "timeout.log",
                                     stdout_log=repository / "timeout.stdout" if capture_stdout else None)
                self.assertLess(time.monotonic() - started, 8)
                self.assertTrue(pid_file.is_file(), "the descendant must start to exercise cleanup")
                pid = int(pid_file.read_text())
                deadline = time.monotonic() + 2
                while self.process_is_running(pid) and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertFalse(self.process_is_running(pid), "timed-out descendant is still running")
                retained = "timeout.stdout" if capture_stdout and not descendant_stderr else "timeout.log"
                self.assertIn("descendant started", (repository / retained).read_text())
            finally:
                if pid_file.exists():
                    with suppress(ProcessLookupError):
                        os.kill(int(pid_file.read_text()), signal.SIGKILL)

    @staticmethod
    def process_is_running(pid):
        """Count unreaped Linux zombies as terminated, independently of a container's init process."""
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        stat = Path(f"/proc/{pid}/stat")
        if sys.platform.startswith("linux"):
            try:
                return stat.read_text().rsplit(")", 1)[1].split()[0] != "Z"
            except FileNotFoundError:
                return False
        return True


class LinuxPreflightTests(unittest.TestCase):
    """Reject misleading host/toolchain combinations while recording nonsecret diagnostics."""

    def test_macos_is_rejected_before_any_compiler_process(self):
        """The unchanged working macOS installation cannot accidentally qualify as Ubuntu."""
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            with patch.object(linux_ci.platform, "system", return_value="Darwin"), \
                    patch.object(linux_ci.subprocess, "check_output") as compiler:
                with self.assertRaisesRegex(ValueError, "native Linux"):
                    linux_ci.preflight(repository, repository / "reports")
                compiler.assert_not_called()

    def test_wrong_distribution_and_missing_executables_fail_before_compilation(self):
        """Linux alone is insufficient, and missing build tools cannot become a later opaque failure."""
        for release, missing, message in (({"ID": "debian", "VERSION_ID": "12"}, None, "Ubuntu 24.04"),
                                          ({"ID": "ubuntu", "VERSION_ID": "24.04"}, "clang", "missing: clang")):
            with self.subTest(release=release, missing=missing), tempfile.TemporaryDirectory() as temporary:
                repository = Path(temporary)
                with self.host_mocks(release), \
                        patch.object(linux_ci.shutil, "which", side_effect=lambda name: None if name == missing else "/fixture/" + name), \
                        patch.object(linux_ci.subprocess, "check_output", return_value="fixture-revision\n") as queries:
                    with self.assertRaisesRegex(ValueError, message):
                        linux_ci.preflight(repository, repository / "reports")
                    self.assertEqual([call.args[0] for call in queries.call_args_list], [["git", "rev-parse", "HEAD"]])
                    host = json.loads((repository / "reports/host.json").read_text())
                    self.assertEqual(host["osRelease"], release)
                    self.assertEqual(host["revision"], "fixture-revision")

    def test_wrong_swift_version_and_nonlinux_target_are_rejected(self):
        """Installed-command success cannot qualify a mismatched compiler or Apple cross target."""
        for version, triple, message in (("Swift version 6.4.0\n", "x86_64-unknown-linux-gnu", "expected Swift 6.4.1"),
                                         ("Swift version 6.4.1\n", "arm64-apple-macosx", "native Linux Swift target")):
            with self.subTest(version=version, triple=triple), tempfile.TemporaryDirectory() as temporary:
                repository = Path(temporary)
                target = {"target": {"triple": triple}}
                with self.host_mocks(), patch.object(linux_ci.shutil, "which", return_value="/fixture/tool"), \
                        patch.object(linux_ci.subprocess, "check_output", side_effect=["fixture-revision\n", version, json.dumps(target)]):
                    with self.assertRaisesRegex(ValueError, message):
                        linux_ci.preflight(repository, repository / "reports")
                self.assertEqual((repository / "reports/swift-version.txt").read_text(), version)
                self.assertEqual(json.loads((repository / "reports/target.json").read_text()), target)

    def test_matching_ubuntu_and_swift_record_evidence_without_installing_tools(self):
        """The approved host/compiler pair passes using read-only, explicitly bounded compiler queries."""
        with tempfile.TemporaryDirectory() as temporary, redirect_stdout(io.StringIO()):
            repository = Path(temporary)
            version = "Swift version 6.4.1 (swift-6.4.1-RELEASE)\nTarget: x86_64-unknown-linux-gnu\n"
            target = {"target": {"triple": "x86_64-unknown-linux-gnu"}}
            with self.host_mocks(), patch.object(linux_ci.shutil, "which", return_value="/fixture/tool"), \
                    patch.object(linux_ci.subprocess, "check_output", side_effect=["fixture-revision\n", version, json.dumps(target)]) as compiler:
                linux_ci.preflight(repository, repository / "reports")
            self.assertEqual([call.args[0] for call in compiler.call_args_list],
                             [["git", "rev-parse", "HEAD"], ["swift", "--version"], ["swift", "-print-target-info"]])
            self.assertTrue(all(call.kwargs["timeout"] == 30 for call in compiler.call_args_list))
            self.assertTrue((repository / "reports/host.json").is_file())

    @staticmethod
    def host_mocks(release=None):
        """Replace Linux-only metadata reads while retaining real report writes on either test host."""
        stack = ExitStack()
        stack.enter_context(patch.object(linux_ci.platform, "system", return_value="Linux"))
        stack.enter_context(patch.object(linux_ci.platform, "freedesktop_os_release", create=True,
                                       return_value=release or {"ID": "ubuntu", "VERSION_ID": "24.04"}))
        original = Path.read_text

        def read_text(path, *arguments, **options):
            """Supply only the missing procfs fixture; all report reads use the real filesystem."""
            return "MemTotal: 123456 kB\n" if str(path) == "/proc/meminfo" else original(path, *arguments, **options)

        stack.enter_context(patch.object(Path, "read_text", read_text))
        return stack


class NativePreflightTests(unittest.TestCase):
    """The selected OS and architecture must match both the host and Swift target."""

    def test_native_macos_and_windows_record_host_compiler_and_terminal_status(self):
        """A compiler version alone cannot replace native architecture and target evidence."""
        for target, system, machine, triple in (
                ("macos-arm64", "Darwin", "arm64", "arm64-apple-macosx13.0"),
                ("windows-x64", "Windows", "AMD64", "x86_64-unknown-windows-msvc")):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temporary:
                repository = Path(temporary)
                output = repository / "reports"
                with self.host_mocks(system, machine, triple):
                    linux_ci.native_preflight(repository, output, target)
                self.assertEqual(json.loads((output / "preflight.json").read_text()),
                                 {"platform": target, "status": "passed"})
                host = json.loads((output / "host.json").read_text())
                self.assertEqual(host["system"], system)
                self.assertEqual(host["machine"], machine)
                self.assertEqual(host["revision"], "fixture-revision")
                self.assertEqual(json.loads((output / "target.json").read_text())["target"]["triple"], triple)
                self.assertIn(linux_ci.SWIFT_VERSION, (output / "swift-version.txt").read_text())

    def test_linux_adds_x64_host_and_target_checks_to_existing_ubuntu_gate(self):
        """An ARM Ubuntu host or a cross target cannot qualify the Linux x64 lane."""
        for machine, triple, status in (("x86_64", "x86_64-unknown-linux-gnu", "passed"),
                                        ("aarch64", "x86_64-unknown-linux-gnu", "failed"),
                                        ("x86_64", "aarch64-unknown-linux-gnu", "failed")):
            with self.subTest(machine=machine, triple=triple), tempfile.TemporaryDirectory() as temporary, \
                    redirect_stdout(io.StringIO()):
                repository = Path(temporary)
                output = repository / "reports"
                with LinuxPreflightTests.host_mocks(), self.host_mocks("Linux", machine, triple):
                    if status == "failed":
                        with self.assertRaisesRegex(ValueError, "native linux-x64"):
                            linux_ci.native_preflight(repository, output, "linux-x64")
                    else:
                        linux_ci.native_preflight(repository, output, "linux-x64")
                self.assertEqual(json.loads((output / "preflight.json").read_text())["status"], status)

    def test_wrong_native_os_fails_before_any_compiler_query(self):
        """A runner label cannot qualify Windows when the actual host is macOS."""
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            output = repository / "reports"
            with patch.object(linux_ci.platform, "system", return_value="Darwin"), \
                    patch.object(linux_ci.subprocess, "check_output") as compiler:
                with self.assertRaisesRegex(ValueError, "native Windows"):
                    linux_ci.native_preflight(repository, output, "windows-x64")
            compiler.assert_not_called()
            self.assertEqual(json.loads((output / "preflight.json").read_text())["status"], "failed")

    def test_wrong_architecture_compiler_version_and_target_remain_failed(self):
        """Rejected evidence remains available and cannot leave a terminal passed report."""
        for target, system, machine, triple, version, message in (
                ("macos-arm64", "Darwin", "x86_64", "arm64-apple-macosx13.0", "6.4.1", "host architecture"),
                ("macos-arm64", "Darwin", "arm64", "x86_64-apple-macosx13.0", "6.4.1", "Swift target"),
                ("windows-x64", "Windows", "ARM64", "x86_64-unknown-windows-msvc", "6.4.1", "host architecture"),
                ("windows-x64", "Windows", "AMD64", "x86_64-unknown-linux-gnu", "6.4.1", "Swift target"),
                ("windows-x64", "Windows", "AMD64", "x86_64-unknown-windows-msvc", "6.4.10", "expected Swift")):
            with self.subTest(target=target, machine=machine, triple=triple, version=version), \
                    tempfile.TemporaryDirectory() as temporary:
                repository = Path(temporary)
                output = repository / "reports"
                with self.host_mocks(system, machine, triple, version), self.assertRaisesRegex(ValueError, message):
                    linux_ci.native_preflight(repository, output, target)
                report = json.loads((output / "preflight.json").read_text())
                self.assertEqual(report["status"], "failed")
                self.assertIn(message, report["error"])
                self.assertTrue((output / "target.json").is_file())

    @staticmethod
    def host_mocks(system, machine, triple, version="6.4.1"):
        """Model one native host without starting a compiler or reading another OS's files."""
        stack = ExitStack()
        stack.enter_context(patch.object(linux_ci.platform, "system", return_value=system))
        stack.enter_context(patch.object(linux_ci.platform, "machine", return_value=machine))
        stack.enter_context(patch.object(linux_ci.shutil, "which", return_value="/fixture/tool"))
        stack.enter_context(patch.object(linux_ci.subprocess, "check_output",
                                       side_effect=["fixture-revision\n", f"Swift version {version}\n",
                                                    json.dumps({"target": {"triple": triple}})]))
        return stack


class NativeCLITests(unittest.TestCase):
    """A workflow invocation validates its platform once and runs each selected stage once."""

    def test_repeated_stage_options_validate_once_and_preserve_selected_order(self):
        """Heavy stages can share one host validation without a runner-size matrix."""
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary).resolve()
            argv = ["linux_ci.py", "--repository", str(repository), "--platform", "windows-x64", "--jobs", "64",
                    "--stage", "preflight", "--stage", "root", "--stage", "authoring", "--stage", "root"]
            with patch.object(sys, "argv", argv), patch.object(linux_ci, "native_preflight") as preflight, \
                    patch.object(linux_ci, "run_stage") as run:
                self.assertEqual(linux_ci.main(), 0)
            output = repository / ".build/linux-ci"
            preflight.assert_called_once_with(repository, output, "windows-x64")
            self.assertEqual(run.call_args_list, [call("root", repository, output, 64),
                                                 call("authoring", repository, output, 64)])

    def test_default_all_keeps_every_stage_and_one_preflight(self):
        """Local default invocation preserves coverage after splitting shared helper checks."""
        with patch.object(sys, "argv", ["linux_ci.py"]), \
                patch.object(linux_ci, "native_preflight") as preflight, patch.object(linux_ci, "run_stage") as run:
            self.assertEqual(linux_ci.main(), 0)
        preflight.assert_called_once()
        self.assertEqual([entry.args[0] for entry in run.call_args_list], list(linux_ci.STAGES))

    def test_shared_checks_can_skip_platform_validation(self):
        """The small shared-check runner cannot add another platform qualification pass."""
        with patch.object(sys, "argv", ["linux_ci.py", "--skip-preflight", "--stage", "helpers", "--stage", "audit"]), \
                patch.object(linux_ci, "native_preflight") as preflight, patch.object(linux_ci, "run_stage") as run:
            self.assertEqual(linux_ci.main(), 0)
        preflight.assert_not_called()
        self.assertEqual([entry.args[0] for entry in run.call_args_list], ["helpers", "audit"])

    def test_platform_stages_cannot_skip_preflight(self):
        """The lightweight escape hatch cannot admit root compilation or an unvalidated default run."""
        for selection in ([], ["root"], ["preflight"], ["helpers", "release"], ["all"]):
            argv = ["linux_ci.py", "--skip-preflight"]
            for stage in selection:
                argv += ["--stage", stage]
            with self.subTest(selection=selection), patch.object(sys, "argv", argv), \
                    redirect_stderr(io.StringIO()), patch.object(linux_ci, "native_preflight") as preflight, \
                    patch.object(linux_ci, "run_stage") as run, self.assertRaises(SystemExit) as caught:
                linux_ci.main()
            self.assertEqual(caught.exception.code, 2)
            preflight.assert_not_called()
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
