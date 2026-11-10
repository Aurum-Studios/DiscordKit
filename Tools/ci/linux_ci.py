#!/usr/bin/env python3
# File: Tools/ci/linux_ci.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Run native offline gates with pinned resolution, bounded jobs and durable logs."""

import argparse
import codecs
from contextlib import ExitStack, suppress
from dataclasses import dataclass
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time


SWIFT_VERSION = "6.4.1"
STAGES = ("root", "authoring", "tooling", "benchmarks", "helpers", "audit", "consumers", "release")
PLATFORMS = ("linux-x64", "macos-arm64", "windows-x64")
WINDOWS_HOST = sys.platform == "win32"
EXAMPLES = ("RESTOnly", "GatewayBot", "HTTPApp", "CommandsApp", "DSLCommands", "DSLEvents",
            "DSLBot", "OAuthApp", "VoiceBot", "RPCApp", "ActivityHost", "SocialApp", "LoggingApp")


@dataclass(frozen=True)
class Command:
    """One shell-free command with a finite parent timeout and platform-specific cleanup."""

    name: str
    arguments: tuple[str, ...]
    timeout: float = 1800


def commands(stage, repository, jobs):
    """Plan a serial gate without writing sources or changing package resolution.

    Every Swift build, test and run receives the same positive job limit and
    requires committed pins. Consumer graphs share scratch space sequentially;
    macros, tooling and fixtures retain separate scratch directories.
    """
    if stage not in STAGES:
        raise ValueError(f"unknown CI stage: {stage}")
    if type(jobs) is not int or jobs <= 0:
        raise ValueError("jobs must be a positive integer")
    repository = repository.resolve()
    python = sys.executable
    planned = []

    def add(name, *arguments, timeout=1800):
        """Append one bounded command with literal argument boundaries."""
        planned.append(Command(name, tuple(map(str, arguments)), timeout))

    def swift(name, verb, package=".", *arguments, scratch=None):
        """Apply the shared resource and dependency policy to a SwiftPM invocation."""
        add(name, "swift", verb, "--build-system", "native", "--package-path", package, "--jobs", jobs,
            "--force-resolved-versions", "--disable-experimental-prebuilts",
            *(["--scratch-path", scratch] if scratch else []), *arguments)

    def tests(name, directory):
        """Run deterministic Python helpers with the selected interpreter."""
        add(name, python, "-m", "unittest", "discover", "-s", directory, "-p", "test_*.py")

    if stage == "root":
        swift("build", "build")
        swift("test", "test")
    elif stage == "authoring":
        for package, helper in (("DiscordDSLMacros", "dsl_compile_fixtures.py"),
                                ("DiscordDSLExtensions", "dsl_extension_fixtures.py")):
            swift(package, "test", f"Packages/{package}", "--explicit-target-dependency-import-check", "error")
            # Cold SwiftSyntax builds can exceed the old ten-minute fixture limit.
            add(helper, python, f"Tools/ci/{helper}", "--repository", repository,
                "--jobs", jobs, "--timeout", "1200", timeout=2400)
    elif stage == "tooling":
        for package in ("DiscordKitTools", "DiscordKitLoadTests"):
            swift(package, "test", f"Tools/{package}")
    elif stage == "helpers":
        for package in ("DiscordKitTools", "DiscordKitLoadTests", "DiscordDSLBenchmarks"):
            tests(f"{package}-python", f"Tools/{package}/scripts")
        tests("ci-python", "Tools/ci")
        browser_tests = sorted(str(path.relative_to(repository)) for path in
                               (repository / "Browser/DiscordActivityBridge").glob("*.test.mjs"))
        if not browser_tests:
            raise ValueError("browser bridge tests are missing")
        add("browser", "node", "--test", *browser_tests)
    elif stage == "benchmarks":
        swift("test", "test", "Tools/DiscordDSLBenchmarks", "--explicit-target-dependency-import-check", "error")
        swift("smoke", "run", "Tools/DiscordDSLBenchmarks", "--configuration", "release",
              "DiscordDSLBenchmarks", "--invocations", "1000", "--output", ".build/dsl-measurements/runtime-smoke.json")
    elif stage == "audit":
        for operation in (("documentation", "audit"), ("inventory", "validate"),
                          ("generate", "--check"), ("parity", "check")):
            swift(operation[0], "run", "Tools/DiscordKitTools", "DiscordKitTools", *operation, "--repository", ".")
        add("social-catalog", python, "Tools/DiscordKitTools/scripts/verify_social_catalog.py")
        script = "Tools/DiscordKitTools/scripts/release_check.py"
        add("graph", python, script, "graph", "--repository", ".")
        for report in ("release-report-0.14.0", "release-report-0.15.0", "release-report-0.15.0-final",
                       "semantic-logging-report", "publication-report"):
            add(report, python, script, "report", "--repository", ".", "--report", f"Docs/Release/{report}.json")
    elif stage == "consumers":
        scratch = str(repository / ".build/consumers")
        for example in EXAMPLES:
            swift(f"build-{example}", "build", f"Examples/{example}", "--explicit-target-dependency-import-check", "error", scratch=scratch)
        for example in ("LoggingApp", "CommandsApp", "DSLCommands", "DSLEvents", "DSLBot", "ActivityHost"):
            swift(f"test-{example}", "test", f"Examples/{example}", scratch=scratch)
        for example in ("LoggingApp", "CommandsApp", "DSLCommands", "DSLEvents", "DSLBot", "VoiceBot", "SocialApp"):
            swift(f"run-{example}", "run", f"Examples/{example}", example,
                  *(["--offline"] if example == "DSLCommands" else []), scratch=scratch)
    elif stage == "release":
        for name, package in (("root", "."), ("macros", "Packages/DiscordDSLMacros"),
                              ("extensions", "Packages/DiscordDSLExtensions")):
            swift(name, "build", package, "--configuration", "release")
    return planned


def preflight(repository, output):
    """Record nonsecret host evidence and reject the wrong OS, compiler or target.

    The workflow installs the compiler and Ubuntu dependencies before this check.
    Nothing is installed here, and the helper never changes the caller's toolchain
    or PATH.
    """
    output.mkdir(parents=True, exist_ok=True)
    host = {"system": platform.system(), "machine": platform.machine(),
            "python": platform.python_version(), "disk": shutil.disk_usage(repository)._asdict()}
    if platform.system() != "Linux":
        raise ValueError("Ubuntu validation requires a native Linux host or container")
    host["osRelease"] = platform.freedesktop_os_release()
    host["memory"] = Path("/proc/meminfo").read_text()
    host["revision"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository,
                                              text=True, timeout=30).strip()
    (output / "host.json").write_text(json.dumps(host, indent=2) + "\n")
    if host["osRelease"].get("ID") != "ubuntu" or host["osRelease"].get("VERSION_ID") != "24.04":
        raise ValueError("Ubuntu validation requires Ubuntu 24.04")
    for executable in ("swift", "swiftc", "clang", "git", "node", "python3"):
        if not shutil.which(executable):
            raise ValueError(f"required executable is missing: {executable}")
    version = subprocess.check_output(["swift", "--version"], text=True, timeout=30)
    target = json.loads(subprocess.check_output(["swift", "-print-target-info"], text=True, timeout=30))
    (output / "swift-version.txt").write_text(version)
    (output / "target.json").write_text(json.dumps(target, indent=2) + "\n")
    if not re.search(rf"\bSwift version {re.escape(SWIFT_VERSION)}(?:\s|$)", version):
        raise ValueError(f"expected Swift {SWIFT_VERSION}: {version.strip()}")
    if "linux" not in target["target"]["triple"].split("-"):
        raise ValueError("expected a native Linux Swift target")
    print(json.dumps(host, indent=2), version, flush=True)


def native_preflight(repository, output, target):
    """Validate one requested native OS/architecture and record its actual evidence.

    The Ubuntu path retains its distribution and dependency checks. Other native
    hosts record their own metadata without reading Linux-only files. A failed
    check remains failed in the report, even if compiler metadata was collected.
    """
    if target not in PLATFORMS:
        raise ValueError(f"unknown native platform: {target}")
    output.mkdir(parents=True, exist_ok=True)
    report = {"platform": target, "status": "running"}
    report_path = output / "preflight.json"

    def save():
        """Keep the last complete validation state available after interruption."""
        temporary = report_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(report, indent=2) + "\n")
        temporary.replace(report_path)

    save()
    try:
        if target == "linux-x64":
            preflight(repository, output)
            host = json.loads((output / "host.json").read_text())
            compiler = json.loads((output / "target.json").read_text())
        else:
            host = {"system": platform.system(), "machine": platform.machine(),
                    "release": platform.release(), "python": platform.python_version(),
                    "disk": shutil.disk_usage(repository)._asdict()}
            (output / "host.json").write_text(json.dumps(host, indent=2) + "\n")
            expected_system = "Darwin" if target == "macos-arm64" else "Windows"
            if host["system"] != expected_system:
                raise ValueError(f"{target} validation requires a native {expected_system} host")
            for executable in ("swift", "swiftc", "clang", "git"):
                if not shutil.which(executable):
                    raise ValueError(f"required executable is missing: {executable}")
            host["revision"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository,
                                                      text=True, timeout=30).strip()
            (output / "host.json").write_text(json.dumps(host, indent=2) + "\n")
            version = subprocess.check_output(["swift", "--version"], text=True, timeout=30)
            compiler = json.loads(subprocess.check_output(["swift", "-print-target-info"], text=True, timeout=30))
            (output / "swift-version.txt").write_text(version)
            (output / "target.json").write_text(json.dumps(compiler, indent=2) + "\n")
            if not re.search(rf"\bSwift version {re.escape(SWIFT_VERSION)}(?:\s|$)", version):
                raise ValueError(f"expected Swift {SWIFT_VERSION}: {version.strip()}")
        architectures = ("arm64", "aarch64") if target == "macos-arm64" else ("x86_64", "amd64")
        if host["machine"].lower() not in architectures:
            raise ValueError(f"expected a native {target} host architecture: {host['machine']}")
        triple = compiler["target"]["triple"].lower()
        components = triple.split("-")
        if target == "linux-x64":
            native_family = "linux" in components
        elif target == "macos-arm64":
            native_family = "apple" in components and any(part.startswith("macosx") for part in components)
        else:
            native_family = "windows" in components and "msvc" in components
        native_target = components[0] in architectures and native_family
        if not native_target:
            raise ValueError(f"expected a native {target} Swift target: {triple}")
    except BaseException as error:
        report.update(status="failed", error=str(error))
        save()
        raise
    report["status"] = "passed"
    save()


def stop_process_group(process):
    """Reap the parent after group cleanup; Windows tree cleanup is best-effort."""
    if WINDOWS_HOST:
        # /T includes descendants while the parent can still be found. An exited
        # parent may leave descendants for the workflow's final timeout cleanup.
        with suppress(OSError, subprocess.TimeoutExpired):
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, check=False)
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
        return
    with suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    # The parent can exit before a compiler child; always clean the whole group.
    with suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGKILL)
    process.wait()


def execute_windows(command, repository, log, environment, *, stdout_log=None):
    """Bound the Windows parent wait without a pipe held open by descendants.

    Children write directly to regular files, with stdout separated from diagnostic
    stderr when stdout_log is supplied for machine parsing. Replay each current snapshot
    after the parent completes; later descendant output cannot extend the replay.
    Workflow timeout remains the final boundary for orphaned Windows processes.
    """
    try:
        with ExitStack() as stack:
            destination = stack.enter_context(log.open("w", encoding="utf-8"))
            stdout_destination = (stack.enter_context(stdout_log.open("w", encoding="utf-8"))
                                  if stdout_log is not None else destination)
            destination.write(shlex.join(command.arguments) + "\n")
            destination.flush()
            process = subprocess.Popen(command.arguments, cwd=repository, env=environment,
                                       creationflags=subprocess.CREATE_NEW_PROCESS_GROUP,
                                       stdout=stdout_destination,
                                       stderr=destination if stdout_log is not None else subprocess.STDOUT)
            try:
                result = process.wait(timeout=command.timeout)
            except BaseException:
                stop_process_group(process)
                raise
            if result:
                stop_process_group(process)
                raise subprocess.CalledProcessError(result, command.arguments)
    finally:
        # Read no more than the file size at admission, even if an orphan keeps
        # appending. Regular-file reads cannot wait for an inherited pipe's EOF.
        for path in (log, stdout_log) if stdout_log is not None else (log,):
            if not path.exists():
                continue
            with path.open("rb") as source:
                remaining = os.fstat(source.fileno()).st_size
                decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
                while remaining:
                    chunk = source.read(min(65536, remaining))
                    if not chunk:
                        break
                    remaining -= len(chunk)
                    print(decoder.decode(chunk), end="", flush=True)
                print(decoder.decode(b"", final=True), end="", flush=True)


def execute(command, repository, log, *, stdout_log=None):
    """Stream output durably; optionally separate stdout for machine parsing.

    Without stdout_log, log contains the command and merged stdout/stderr. With
    stdout_log, that file contains only child stdout and log contains the command
    and stderr diagnostics. Both streams still reach the console. Separate pipes
    prevent diagnostic writes from splitting identifiers in a test inventory.
    POSIX commands own a process group, including compiler/plugin descendants.
    Windows writes directly to regular files and replays them after the bounded parent wait.
    Failed commands are never retried; Windows tree cleanup is best-effort.
    """
    environment = dict(os.environ, SWIFTNIO_STRICT="1", PYTHONUNBUFFERED="1")
    if WINDOWS_HOST:
        return execute_windows(command, repository, log, environment, stdout_log=stdout_log)
    with ExitStack() as stack:
        destination = stack.enter_context(log.open("w", encoding="utf-8"))
        stdout_destination = (stack.enter_context(stdout_log.open("w", encoding="utf-8"))
                              if stdout_log is not None else destination)
        destination.write(shlex.join(command.arguments) + "\n")
        destination.flush()
        with subprocess.Popen(command.arguments, cwd=repository, env=environment, start_new_session=True,
                              stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE if stdout_log is not None else subprocess.STDOUT,
                              text=True, encoding="utf-8", errors="replace") as process:
            console_lock = threading.Lock()

            def forward(stream, target):
                """Drain one stream to its own file and serialize complete console lines."""
                try:
                    for line in stream:
                        target.write(line)
                        target.flush()
                        with console_lock:
                            print(line, end="", flush=True)
                except Exception as error:
                    forwarding_errors.append(error)
            forwarding_errors = []
            workers = [threading.Thread(target=forward, args=(process.stdout, stdout_destination), daemon=True)]
            if stdout_log is not None:
                workers.append(threading.Thread(target=forward, args=(process.stderr, destination), daemon=True))
            deadline = time.monotonic() + command.timeout
            for worker in workers:
                worker.start()
            try:
                result = process.wait(timeout=command.timeout)
                # A compiler child can outlive SwiftPM while retaining stdout.
                # The same deadline covers both parent exit and output draining.
                for worker in workers:
                    worker.join(timeout=max(0, deadline - time.monotonic()))
                if any(worker.is_alive() for worker in workers):
                    raise subprocess.TimeoutExpired(command.arguments, command.timeout)
                if forwarding_errors:
                    raise OSError(f"could not preserve command output: {forwarding_errors[0]}")
            except BaseException:
                stop_process_group(process)
                for worker in workers:
                    worker.join(timeout=5)
                raise
            if result:
                stop_process_group(process)
                raise subprocess.CalledProcessError(result, command.arguments)


def run_stage(stage, repository, output, jobs):
    """Persist each command's state before execution and stop at the first failure.

    The initial running state survives cancellation; only a fully completed stage
    records passed. Reports and full logs are safe to upload on failed offline runs.
    """
    planned = commands(stage, repository, jobs)
    output.mkdir(parents=True, exist_ok=True)
    if stage == "benchmarks":
        (repository / ".build/dsl-measurements").mkdir(parents=True, exist_ok=True)
    report = {"stage": stage, "status": "running", "jobs": jobs, "commands": []}
    report_path = output / f"{stage}.json"

    def save():
        """Atomically replace the progress report after every state transition."""
        temporary = report_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(report, indent=2) + "\n")
        temporary.replace(report_path)

    save()
    for index, command in enumerate(planned):
        log = output / f"{stage}-{index:02d}-{command.name}.log"
        record = {"name": command.name, "arguments": command.arguments,
                  "log": log.name, "status": "running"}
        report["commands"].append(record)
        save()
        print(f"::group::{stage}: {command.name}\n{shlex.join(command.arguments)}", flush=True)
        started = time.monotonic()
        try:
            execute(command, repository, log)
        except BaseException as error:
            record.update(status="failed", error=str(error), seconds=round(time.monotonic() - started, 3))
            report["status"] = "failed"
            save()
            raise
        else:
            record.update(status="passed", seconds=round(time.monotonic() - started, 3))
            save()
        finally:
            print("::endgroup::", flush=True)
    report["status"] = "passed"
    save()


def main():
    """Validate a native target once, then run the selected bounded stages."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--platform", choices=PLATFORMS, default="linux-x64")
    parser.add_argument("--stage", choices=("preflight", *STAGES, "all"), action="append")
    parser.add_argument("--skip-preflight", action="store_true",
                        help="run only shared audit/helper stages without platform validation")
    arguments = parser.parse_args()
    if arguments.jobs <= 0:
        parser.error("jobs must be a positive integer")
    selected = arguments.stage or ["all"]
    stages = tuple(dict.fromkeys(stage for selection in selected
                                for stage in (STAGES if selection == "all" else
                                              () if selection == "preflight" else (selection,))))
    if arguments.skip_preflight and (not stages or "preflight" in selected or
                                     any(stage not in ("audit", "helpers") for stage in stages)):
        parser.error("--skip-preflight is restricted to audit and helpers stages")
    repository = arguments.repository.resolve()
    output = arguments.output or repository / ".build/linux-ci"
    try:
        if not arguments.skip_preflight:
            native_preflight(repository, output, arguments.platform)
        for stage in stages:
            run_stage(stage, repository, output, arguments.jobs)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Offline validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
