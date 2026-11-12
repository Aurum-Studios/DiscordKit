#!/usr/bin/env python3
# File: Tools/ci/linux_ci.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Run native offline gates with pinned resolution, bounded jobs and durable logs."""

import argparse
import codecs
from collections import deque
from contextlib import ExitStack, suppress
from dataclasses import dataclass
from datetime import datetime, timezone
import io
import json
import math
import os
from pathlib import Path
import platform
import re
import selectors
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid


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
    operation: str = "command"
    stage: str | None = None


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

    def add(name, *arguments, timeout=300, operation="localHelperCheck"):
        """Append one bounded command with literal argument boundaries."""
        planned.append(Command(name, tuple(map(str, arguments)), timeout, operation, stage))

    def swift(name, verb, package=".", *arguments, scratch=None):
        """Apply the shared resource and dependency policy to a SwiftPM invocation."""
        add(name, "swift", verb, "--build-system", "native", "--package-path", package, "--jobs", jobs,
            "--force-resolved-versions", "--disable-experimental-prebuilts",
            *(["--scratch-path", scratch] if scratch else []), *arguments,
            timeout=1200, operation="coldCompileCommand")

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


def metadata_query(arguments, repository, output, name):
    """Retain metadata stdout under the same process and inherited-pipe deadline."""
    output.mkdir(parents=True, exist_ok=True)
    log = output / f"metadata-{name}.log"
    stdout = output / f"metadata-{name}.stdout"
    execute(Command(name, tuple(arguments), 30, operation="metadata", stage="preflight"),
            repository, log, stdout_log=stdout)
    return stdout.read_text(encoding="utf-8", errors="replace")


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
    host["revision"] = metadata_query(["git", "rev-parse", "HEAD"], repository, output, "revision").strip()
    (output / "host.json").write_text(json.dumps(host, indent=2) + "\n")
    if host["osRelease"].get("ID") != "ubuntu" or host["osRelease"].get("VERSION_ID") != "24.04":
        raise ValueError("Ubuntu validation requires Ubuntu 24.04")
    for executable in ("swift", "swiftc", "clang", "git", "python3"):
        if not shutil.which(executable):
            raise ValueError(f"required executable is missing: {executable}")
    version = metadata_query(["swift", "--version"], repository, output, "swift-version")
    target = json.loads(metadata_query(["swift", "-print-target-info"], repository, output, "swift-target"))
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
            host["revision"] = metadata_query(["git", "rev-parse", "HEAD"], repository, output, "revision").strip()
            (output / "host.json").write_text(json.dumps(host, indent=2) + "\n")
            version = metadata_query(["swift", "--version"], repository, output, "swift-version")
            compiler = json.loads(metadata_query(["swift", "-print-target-info"], repository, output, "swift-target"))
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


HEARTBEAT_SECONDS = 30.0
PROBE_SECONDS = 5.0
CLEANUP_GRACE_SECONDS = 5.0
CLEANUP_REAP_SECONDS = 1.0
CLEANUP_ALLOWANCE_SECONDS = 8.0
OUTPUT_LIMIT_BYTES = 8 * 1024 * 1024
DIAGNOSTIC_LIMIT_BYTES = 512 * 1024
SNAPSHOT_LIMIT_BYTES = 32 * 1024
MAX_STACK_TARGETS = 3


class CommandInterrupted(subprocess.SubprocessError):
    """An external supervisor signal interrupted an admitted command."""

    def __init__(self, signum):
        self.signum = signum
        super().__init__(f"supervisor interrupted by signal {signum}")


class BoundedOutput:
    """Keep a finite prefix, with explicit truncation and fail-closed discovery."""

    def __init__(self, path, limit, *, exact=False, ring=False):
        self.path, self.limit, self.exact = path, limit, exact
        self.file = path.open("wb")
        self.observed = self.retained = 0
        self.truncated = False
        self.ring = deque() if ring else None

    def write(self, data):
        self.observed += len(data)
        if self.ring is not None:
            if len(data) > self.limit:
                raise OSError("diagnostic snapshot exceeded its finite record limit")
            self.ring.append(data)
            self.retained += len(data)
            while self.retained > self.limit:
                self.retained -= len(self.ring.popleft())
                self.truncated = True
            self.file.seek(0)
            self.file.truncate()
            self.file.write(b"".join(self.ring))
            self.file.flush()
            return
        remaining = max(0, self.limit - self.retained)
        piece = data[:remaining]
        self.file.write(piece)
        self.file.flush()
        self.retained += len(piece)
        if len(piece) != len(data):
            self.truncated = True
            if self.exact:
                raise OSError("machine-readable stdout exceeded its finite output limit")

    def close(self):
        self.file.close()


def stop_process_group(process):
    """TERM/grace/KILL and bounded reaping, including exited parents' descendants."""
    if WINDOWS_HOST:
        with suppress(OSError, subprocess.TimeoutExpired):
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10, check=False)
        if process.poll() is None:
            process.kill()
        process.wait(timeout=5)
        return {"status": "best-effort", "platform": "windows"}
    if sys.platform.startswith("linux"):
        return _stop_linux_session(process)
    started = time.monotonic()
    cleanup = {"status": "running", "signals": [], "parentReaped": False,
               "allowanceSeconds": CLEANUP_ALLOWANCE_SECONDS}
    try:
        os.killpg(process.pid, signal.SIGTERM)
        cleanup["signals"].append("SIGTERM")
    except ProcessLookupError:
        pass
    # Waiting for the parent does not wait for orphaned descendants. KILL is
    # always sent afterwards, even when SwiftPM has already exited successfully.
    try:
        process.wait(timeout=CLEANUP_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
        cleanup["signals"].append("SIGKILL")
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=CLEANUP_REAP_SECONDS)
        cleanup["parentReaped"] = True
    except subprocess.TimeoutExpired:
        cleanup["status"] = "parent-reap-timeout"
    if cleanup["status"] == "running":
        cleanup["status"] = "group-signalled"
    cleanup["seconds"] = round(time.monotonic() - started, 3)
    return cleanup


def _stop_linux_session(process):
    """Clean SwiftPM/Foundation groups in the command's uniquely admitted session."""
    started = time.monotonic()
    # Reserve the final second of the existing allowance for execute's verification.
    deadline = started + CLEANUP_ALLOWANCE_SECONDS - 1.0
    groups = {process.pid}
    cleanup = {"status": "running", "signals": [], "groupSignals": [],
               "parentReaped": False, "session": process.pid,
               "allowanceSeconds": CLEANUP_ALLOWANCE_SECONDS}

    def discover():
        """Select only the owned session; unrelated sibling sessions stay outside it."""
        tree = _process_tree(process.pid, min(deadline - CLEANUP_REAP_SECONDS,
                                              time.monotonic() + .5))
        groups.update(row["group"] for row in tree["processes"])
        return tree

    def send(targets, signum):
        """Signal child groups before the admitted leader, without touching our group."""
        for group in sorted(targets, key=lambda value: (value == process.pid, value)):
            if group <= 1 or group == os.getpgrp():
                raise OSError("refusing to signal a group outside the admitted Linux session")
            try:
                os.killpg(group, signum)
                name = signal.Signals(signum).name
                if name not in cleanup["signals"]:
                    cleanup["signals"].append(name)
                cleanup["groupSignals"].append({"group": group, "signal": name})
            except ProcessLookupError:
                pass

    tree = discover()
    cleanup["discovery"] = {"status": tree["status"], "truncated": tree["truncated"]}
    send(groups, signal.SIGTERM)
    terminated_groups = set(groups)
    grace = min(deadline - CLEANUP_REAP_SECONDS - .5, time.monotonic() + CLEANUP_GRACE_SECONDS)
    try:
        process.wait(timeout=max(.001, grace - time.monotonic()))
    except subprocess.TimeoutExpired:
        pass
    # Parent exit does not end the grace period for independently grouped children.
    tree = discover()
    if (tree["status"] != "available" or tree["truncated"] or
            any(not row["state"].startswith("Z") for row in tree["processes"])):
        remaining = grace - time.monotonic()
        if remaining > 0:
            time.sleep(remaining)
        tree = discover()
    targets = {row["group"] for row in tree["processes"]}
    if tree["status"] != "available" or tree["truncated"]:
        # Revalidate leader membership before using an older observation.
        for group in groups:
            with suppress(ProcessLookupError):
                if os.getsid(group) == process.pid:
                    targets.add(group)
    if process.poll() is None:
        targets.add(process.pid)
    send(targets - terminated_groups, signal.SIGTERM)
    send(targets, signal.SIGKILL)
    try:
        process.wait(timeout=max(.001, min(CLEANUP_REAP_SECONDS, deadline - time.monotonic())))
        cleanup["parentReaped"] = True
    except subprocess.TimeoutExpired:
        cleanup["status"] = "parent-reap-timeout"
    cleanup["groups"] = sorted(groups | targets)
    if cleanup["status"] == "running":
        cleanup["status"] = "session-signalled"
    cleanup["seconds"] = round(time.monotonic() - started, 3)
    return cleanup


def _probe(arguments, deadline):
    """Run one finite, shell-free diagnostic; bound bytes, pipes and its own group."""
    cutoff = min(deadline, time.monotonic() + PROBE_SECONDS)
    record = {"arguments": list(arguments), "status": "unavailable", "output": ""}
    if cutoff - time.monotonic() <= 0.02:
        record["reason"] = "diagnostic budget exhausted"
        return record
    process = None
    collected = bytearray()
    observed = 0
    started = time.monotonic()
    try:
        process = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        os.set_blocking(process.stdout.fileno(), False)
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map():
                remaining = cutoff - time.monotonic()
                if remaining <= 0.02:
                    record["status"] = "timeout"
                    break
                for key, _ in selector.select(min(0.05, remaining - 0.01)):
                    chunk = os.read(key.fd, 8192)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    observed += len(chunk)
                    collected.extend(chunk[:max(0, SNAPSHOT_LIMIT_BYTES - len(collected))])
            if record["status"] != "timeout":
                if process.poll() is None:
                    try:
                        process.wait(timeout=max(0.001, cutoff - time.monotonic() - 0.01))
                    except subprocess.TimeoutExpired:
                        record["status"] = "timeout"
                if record["status"] != "timeout":
                    record["status"] = "available" if process.returncode == 0 else "failed"
        record["exitCode"] = process.poll()
    except OSError as error:
        record.update(status="unavailable", reason=str(error))
    finally:
        if process is not None:
            # A successful probe parent can also leave an inherited stdout pipe.
            with suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            with suppress(subprocess.TimeoutExpired):
                process.wait(timeout=max(0.001, cutoff - time.monotonic()))
            if process.stdout is not None:
                process.stdout.close()
    record["output"] = collected.decode("utf-8", errors="replace")
    record["truncated"] = observed > len(collected)
    record["seconds"] = round(time.monotonic() - started, 3)
    if re.search(r"operation not permitted|permission denied|ptrace.*(?:denied|not permitted)",
                 record["output"], re.IGNORECASE):
        record["status"] = "denied"
    return record


def _process_tree(group, deadline):
    """Read numeric process/resource columns and executable names, never argv/env."""
    linux = sys.platform.startswith("linux")
    columns = "pid=,ppid=,pgid=,sid=,stat=,pcpu=,rss=,comm=" if linux else "pid=,ppid=,pgid=,stat=,pcpu=,rss=,comm="
    probe = _probe(("ps", "-s" if linux else "-g", str(group), "-o", columns), deadline)
    rows = []
    malformed = 0
    # ps exits 1 for an empty selected group on both supported POSIX hosts.
    if probe.get("exitCode") == 1 and not probe["output"].strip():
        probe["status"] = "available"
    if probe["status"] == "available":
        for line in probe["output"].splitlines():
            if not line.strip():
                continue
            fields = line.split(None, 7 if linux else 6)
            if len(fields) != (8 if linux else 7):
                malformed += int(linux)
                continue
            try:
                pid, parent, pgid = map(int, fields[:3])
                session = int(fields.pop(3)) if linux else None
                state, cpu, rss = fields[3], float(fields[4]), int(fields[5])
                if linux and (pid <= 0 or parent < 0 or pgid <= 0 or session != group or
                              not re.fullmatch(r"[RSDZTtWXxKIP][<NLsl+]*", state) or
                              not math.isfinite(cpu) or cpu < 0 or rss < 0):
                    raise ValueError("invalid Linux session row")
                if (session == group if linux else pgid == group):
                    rows.append({"pid": pid, "parent": parent, "group": pgid,
                                 "state": state, "cpuPercent": cpu,
                                 "rssKiB": rss, "executable": fields[6][:256]})
                    if linux:
                        rows[-1]["session"] = session
            except ValueError:
                malformed += int(linux)
                continue
    return {"status": "malformed" if malformed else probe["status"], "processes": rows[:64],
            "truncated": probe.get("truncated", False) or len(rows) > 64,
            "malformedRows": malformed,
            "reason": "process listing contained malformed session rows" if malformed else probe.get("reason"),
            "probeSeconds": probe.get("seconds", 0)}


def _stacks(pid, deadline):
    """Collect all-thread symbol stacks without arguments, locals or core dumps."""
    if platform.system() == "Darwin" and shutil.which("sample"):
        arguments = ("sample", str(pid), "1", "1", "-file", "/dev/stdout")
    elif shutil.which("gdb"):
        arguments = ("gdb", "--batch", "--quiet", "-nx", "-ex", "set auto-load off",
                     "-ex", "set print frame-arguments none", "-ex", "set pagination off",
                     "-ex", f"attach {pid}", "-ex", "thread apply all bt", "-ex", "detach")
    elif shutil.which("lldb"):
        frame = "frame #${frame.index}: ${frame.pc} ${module.file.basename} ${function.name-without-args}\n"
        arguments = ("lldb", "--batch", "--no-lldbinit", "-o", f"settings set frame-format '{frame}'",
                     "-o", f"process attach --pid {pid}", "-o", "thread backtrace all", "-o", "process detach")
    else:
        return {"pid": pid, "status": "unavailable", "reason": "no sample, gdb or lldb executable"}
    return dict(_probe(arguments, deadline), pid=pid)


def _snapshot(process, repository, command, started, deadline, last_output, last_test, reason):
    """Use one five-second total snapshot budget, always inside the command cutoff."""
    now = time.monotonic()
    cutoff = min(deadline - 0.01, now + PROBE_SECONDS)
    tree = _process_tree(process.pid, cutoff)
    disk = shutil.disk_usage(repository)
    memory = {"status": "unavailable", "reason": "available memory probe unsupported"}
    try:
        with Path("/proc/meminfo").open() as source:
            text = source.read(4096)
        available = re.search(r"^MemAvailable:\s+(\d+) kB", text, re.MULTILINE)
        if available:
            memory = {"status": "available", "availableBytes": int(available[1]) * 1024}
    except OSError:
        if platform.system() == "Darwin":
            probe = _probe(("vm_stat",), cutoff)
            free = re.search(r"Pages free:\s+(\d+)", probe["output"])
            page_size = re.search(r"page size of (\d+) bytes", probe["output"])
            if probe["status"] == "available" and free and page_size:
                memory = {"status": "available", "freeBytes": int(free[1]) * int(page_size[1]),
                          "measurement": "free pages; excludes reclaimable pages"}
            else:
                memory = {"status": probe["status"], "reason": "vm_stat unavailable or unreadable"}
    rows = tree["processes"]
    result = {"kind": "snapshot", "reason": reason, "stage": command.stage or command.name,
              "operation": command.operation, "elapsedSeconds": round(now - started, 3),
              "deadlineMonotonic": deadline, "remainingSeconds": max(0, round(deadline - now, 3)),
              "lastOutputAgeSeconds": round(now - last_output, 3), "pid": process.pid,
              "group": process.pid, "lastObservedTest": last_test,
              "cpuPercent": sum(row["cpuPercent"] for row in rows) if rows else None,
              "rssKiB": sum(row["rssKiB"] for row in rows) if rows else None,
              "memory": memory, "diskAvailableBytes": disk.free, "children": tree}
    # A focused reproduction diagnoses at both heartbeat boundaries. Other
    # commands diagnose silence and the final predeadline snapshot.
    if reason == "before-timeout" or command.operation == "focusedTest" or now - last_output >= HEARTBEAT_SECONDS:
        targets = [row["pid"] for row in rows if row["pid"] != process.pid and not row["state"].startswith("Z")]
        targets.append(process.pid)
        result["stacks"] = [_stacks(pid, cutoff) for pid in targets[:MAX_STACK_TARGETS]]
        result["omittedStackTargets"] = max(0, len(targets) - MAX_STACK_TARGETS)
    return result


def _console_write(text):
    """Fail promptly on a saturated console pipe instead of extending a deadline."""
    try:
        descriptor = sys.stdout.fileno()
    except (AttributeError, io.UnsupportedOperation):
        print(text, end="", flush=True)
        return
    blocking = os.get_blocking(descriptor)
    try:
        os.set_blocking(descriptor, False)
        data = text.encode("utf-8", errors="replace")
        while data:
            written = os.write(descriptor, data[:4096])
            if written <= 0:
                raise BrokenPipeError("console sink accepted zero bytes")
            data = data[written:]
    finally:
        os.set_blocking(descriptor, blocking)


# Shared wrappers must use the same bounded console sink before/after execution.
console_write = _console_write


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


def execute(command, repository, log, *, stdout_log=None, deadline=None):
    """Supervise one shell-free command, durable finite evidence and group cleanup.

    An optional absolute monotonic deadline also bounds aggregate component work.
    Separate discovery stdout is exact: exceeding its cap fails the command.
    POSIX uses nonblocking pipe readers, with no reader threads or EOF-only waits.
    Windows retains its regular-file, best-effort process-tree cleanup contract.
    """
    if not math.isfinite(command.timeout) or command.timeout <= 0:
        raise ValueError("command timeout must be finite and positive")
    if deadline is not None and not math.isfinite(deadline):
        raise ValueError("aggregate deadline must be finite")
    started = time.monotonic()
    cutoff = min(started + command.timeout, deadline if deadline is not None else float("inf"))
    receipt_path = log.with_suffix(".receipt.json")
    diagnostic_path = log.with_suffix(".diagnostics.jsonl")
    receipt = {"schemaVersion": 1, "status": "running", "name": command.name,
               "stage": command.stage or command.name, "operation": command.operation,
               "arguments": list(command.arguments), "start": datetime.now(timezone.utc).isoformat(),
               "startMonotonic": started, "deadlineMonotonic": cutoff,
               "executionLimitSeconds": command.timeout, "cleanupAllowanceSeconds": 15 if WINDOWS_HOST else CLEANUP_ALLOWANCE_SECONDS,
               "deadlineSource": "aggregate" if deadline is not None and deadline < started + command.timeout else "operation",
               "paths": {"output": str(log), "stdout": str(stdout_log) if stdout_log else None,
                         "diagnostics": str(diagnostic_path), "receipt": str(receipt_path)},
               "identity": {"executionID": str(uuid.uuid4()), "supervisorPID": os.getpid(),
                            "host": platform.node(), "system": platform.system(),
                            "repository": str(repository)},
               "exitCode": None, "signal": None, "timeoutCategory": None}
    # Deliberate allowlist, never a dump of the environment.
    receipt["identity"].update({key: os.environ[key] for key in
                               ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_JOB", "GITHUB_SHA",
                                "RUNNER_OS", "RUNNER_ARCH") if key in os.environ})

    def save():
        temporary = receipt_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(receipt, indent=2) + "\n")
        temporary.replace(receipt_path)

    save()
    environment = dict(os.environ, SWIFTNIO_STRICT="1", PYTHONUNBUFFERED="1")
    process = None
    destinations = []
    old_handlers = {}
    selector = None
    error = None
    diagnostics = None
    console_buffers = {}
    last_output, last_test = started, None
    next_heartbeat = started + HEARTBEAT_SECONDS
    pretimeout = cutoff - min(PROBE_SECONDS, max(0.05, command.timeout * 0.2))
    diagnosed_timeout = False

    def interrupt(signum, _frame):
        raise CommandInterrupted(signum)

    def console(stream_id, text, *, final=False):
        nonlocal last_test
        pending = console_buffers.get(stream_id, "") + text
        # Fixed-size partial lines also bound children emitting no newline.
        while "\n" in pending or len(pending) >= 8192 or (final and pending):
            newline = pending.find("\n")
            length = min(newline + 1 if newline >= 0 else len(pending), 8192)
            line, pending = pending[:length], pending[length:]
            match = re.search(r"Test (?:Case|Suite) '([A-Za-z0-9_.$/()+ :\[\]-]+)'|[◇✔✘] Test ([A-Za-z0-9_.$/()+-]+)", line)
            if match:
                last_test = (match[1] or match[2])[:256]
            _console_write(line)
        console_buffers[stream_id] = pending

    try:
        if cutoff <= time.monotonic():
            receipt["timeoutCategory"] = "aggregate"
            raise subprocess.TimeoutExpired(command.arguments, command.timeout)
        if WINDOWS_HOST:
            # Use the same absolute cutoff when an aggregate budget is supplied.
            remaining = cutoff - time.monotonic()
            effective = (Command(command.name, command.arguments, min(command.timeout, remaining),
                                 command.operation, command.stage) if deadline is not None else command)
            execute_windows(effective, repository, log, environment, stdout_log=stdout_log)
            receipt.update(status="passed", exitCode=0,
                           cleanup={"status": "best-effort", "platform": "windows"})
        else:
            if threading.current_thread() is threading.main_thread():
                for signum in (signal.SIGTERM, signal.SIGINT):
                    old_handlers[signum] = signal.signal(signum, interrupt)
            diagnostics = BoundedOutput(diagnostic_path, DIAGNOSTIC_LIMIT_BYTES, ring=True)
            destination = BoundedOutput(log, OUTPUT_LIMIT_BYTES)
            destinations.append(destination)
            stdout_destination = BoundedOutput(stdout_log, OUTPUT_LIMIT_BYTES, exact=True) if stdout_log else destination
            if stdout_log:
                destinations.append(stdout_destination)
            destination.write((shlex.join(command.arguments) + "\n").encode())
            process = subprocess.Popen(command.arguments, cwd=repository, env=environment,
                                       start_new_session=True, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE if stdout_log else subprocess.STDOUT)
            receipt.update(pid=process.pid, group=process.pid)
            save()
            selector = selectors.DefaultSelector()
            for stream, target in ((process.stdout, stdout_destination), (process.stderr, destination)):
                if stream is not None:
                    os.set_blocking(stream.fileno(), False)
                    selector.register(stream, selectors.EVENT_READ, (target, codecs.getincrementaldecoder("utf-8")("replace")))
            while process.poll() is None or selector.get_map():
                now = time.monotonic()
                if now >= cutoff:
                    receipt["timeoutCategory"] = ("inherited-output" if process.poll() is not None else
                                                  "aggregate" if deadline is not None and deadline < started + command.timeout else
                                                  "execution")
                    raise subprocess.TimeoutExpired(command.arguments, round(cutoff - started, 3))
                if now >= next_heartbeat or (now >= pretimeout and not diagnosed_timeout):
                    reason = "before-timeout" if now >= pretimeout and not diagnosed_timeout else "heartbeat"
                    snapshot = _snapshot(process, repository, command, started, cutoff, last_output, last_test, reason)
                    diagnostics.write((json.dumps(snapshot, ensure_ascii=False) + "\n").encode())
                    heartbeat = dict(snapshot)
                    heartbeat.pop("stacks", None)
                    heartbeat.pop("children", None)
                    console("heartbeat", "[ci heartbeat] " + json.dumps(heartbeat) + "\n")
                    next_heartbeat += HEARTBEAT_SECONDS if now >= next_heartbeat else 0
                    diagnosed_timeout = diagnosed_timeout or reason == "before-timeout"
                    continue
                wait = min(0.05, cutoff - now, next_heartbeat - now,
                           max(0.001, pretimeout - now) if not diagnosed_timeout else 0.05)
                for key, _ in selector.select(max(0, wait)):
                    target, decoder = key.data
                    chunk = os.read(key.fd, 8192)
                    if chunk:
                        last_output = time.monotonic()
                        target.write(chunk)
                        console(key.fd, decoder.decode(chunk))
                    else:
                        console(key.fd, decoder.decode(b"", final=True), final=True)
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
            result = process.poll()
            if result:
                raise subprocess.CalledProcessError(result, command.arguments)
            receipt.update(status="passed", exitCode=0)
    except BaseException as caught:
        error = caught
        receipt.update(status="failed", error=str(caught), errorType=type(caught).__name__)
        if isinstance(caught, (CommandInterrupted, KeyboardInterrupt)):
            receipt.update(status="interrupted", interruptSignal=getattr(caught, "signum", signal.SIGINT))
        if isinstance(caught, subprocess.TimeoutExpired) and receipt["timeoutCategory"] is None:
            receipt["timeoutCategory"] = "aggregate" if deadline is not None and cutoff < started + command.timeout else "execution"
        if isinstance(caught, subprocess.CalledProcessError):
            receipt["exitCode"] = caught.returncode
        if isinstance(caught, OSError) and not isinstance(caught, CommandInterrupted):
            error = OSError(f"could not preserve command output: {caught}")
        raise error
    finally:
        # Restore handlers and close every sink even if cleanup/probes fail.
        cleanup_started = time.monotonic()
        finalization_errors = []
        try:
            for signum in old_handlers:
                signal.signal(signum, signal.SIG_IGN)
            if process is not None:
                try:
                    receipt["cleanup"] = stop_process_group(process)
                except BaseException as cleanup_error:
                    finalization_errors.append(f"group cleanup failed: {cleanup_error}")
                    receipt["cleanup"] = {"status": "failed", "error": str(cleanup_error)}
                    with suppress(OSError):
                        os.killpg(process.pid, signal.SIGKILL)
                    with suppress(subprocess.TimeoutExpired):
                        process.wait(timeout=CLEANUP_REAP_SECONDS)
                try:
                    cleanup_deadline = cleanup_started + CLEANUP_ALLOWANCE_SECONDS
                    tree = _process_tree(process.pid, min(cleanup_deadline, time.monotonic() + 1.0))
                    alive = [row for row in tree["processes"] if not row["state"].startswith("Z")]
                    verified = tree["status"] == "available" and not tree["truncated"] and not tree.get("malformedRows", 0)
                    receipt["cleanup"].update(groupState=("unknown" if not verified else
                                                          "alive" if alive else "zombies-only" if tree["processes"] else "gone"),
                                              remainingProcesses=tree["processes"],
                                              verification=tree["status"], verificationTruncated=tree["truncated"],
                                              verificationMalformedRows=tree.get("malformedRows", 0),
                                              boundary=("admitted Linux session; escaped sessions cannot be guaranteed"
                                                        if sys.platform.startswith("linux") else
                                                        "admitted POSIX process group; escaped sessions cannot be guaranteed"))
                    if alive:
                        finalization_errors.append("command cleanup still contains live descendants")
                    if sys.platform.startswith("linux") and not verified:
                        finalization_errors.append("could not verify admitted Linux session")
                except BaseException as cleanup_error:
                    finalization_errors.append(f"cleanup verification failed: {cleanup_error}")
                    receipt["cleanup"].update(groupState="unknown", verificationError=str(cleanup_error))
                receipt["cleanup"].update(seconds=round(time.monotonic() - cleanup_started, 3),
                                          allowanceSeconds=CLEANUP_ALLOWANCE_SECONDS)
                receipt["exitCode"] = process.poll()
                if process.returncode is not None and process.returncode < 0:
                    receipt["signal"] = -process.returncode
            if selector is not None:
                for key in list(selector.get_map().values()):
                    with suppress(OSError):
                        key.fileobj.close()
                selector.close()
            for destination in destinations:
                try:
                    destination.close()
                except OSError as close_error:
                    finalization_errors.append(f"output close failed: {close_error}")
            receipt["outputs"] = [{"path": str(destination.path), "retainedBytes": destination.retained,
                                    "observedBytes": destination.observed, "truncated": destination.truncated}
                                   for destination in destinations]
            if diagnostics is not None:
                receipt["diagnosticsTruncated"] = diagnostics.truncated
                try:
                    diagnostics.close()
                except OSError as close_error:
                    finalization_errors.append(f"diagnostic close failed: {close_error}")
            if finalization_errors:
                receipt.update(status="failed", finalizationErrors=finalization_errors)
                if error is None:
                    error = OSError("; ".join(finalization_errors))
            receipt.update(end=datetime.now(timezone.utc).isoformat(), endMonotonic=time.monotonic(),
                           elapsedSeconds=round(time.monotonic() - started, 3),
                           lastObservedTest=last_test, readerThreads=0)
            save()
        finally:
            for signum, handler in old_handlers.items():
                signal.signal(signum, handler)
    if error is not None:
        raise error
    return receipt


def run_stage(stage, repository, output, jobs):
    """Persist each command's state before execution and stop at the first failure.

    The initial running state survives cancellation; only a fully completed stage
    records passed. Reports and full logs are safe to upload on failed offline runs.
    """
    planned = commands(stage, repository, jobs)
    output.mkdir(parents=True, exist_ok=True)
    if stage == "benchmarks":
        (repository / ".build/dsl-measurements").mkdir(parents=True, exist_ok=True)
    aggregate = min(sum(command.timeout for command in planned), 300) if stage in ("helpers", "audit") else sum(command.timeout for command in planned)
    deadline = time.monotonic() + aggregate
    report = {"stage": stage, "status": "running", "jobs": jobs, "commands": [],
              "aggregateSeconds": aggregate, "deadlineMonotonic": deadline}
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
        started = time.monotonic()
        try:
            _console_write(f"::group::{stage}: {command.name}\n{shlex.join(command.arguments)}\n")
            receipt = execute(command, repository, log, deadline=deadline)
            if receipt is not None:
                record["supervisor"] = receipt
        except BaseException as error:
            record.update(status="failed", error=str(error), seconds=round(time.monotonic() - started, 3))
            report["status"] = "failed"
            save()
            raise
        else:
            record.update(status="passed", seconds=round(time.monotonic() - started, 3))
            save()
        finally:
            # A closed console must not erase the original command failure.
            with suppress(OSError):
                _console_write("::endgroup::\n")
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
