#!/usr/bin/env python3
# File: Tools/ci/native_jobs.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Compile native graphs once and run independent suites from exact-attempt artifacts.

SwiftPM embeds absolute source and build paths. Artifact consumers therefore require
the same checkout path, native platform, Swift toolchain, source bytes and workflow
attempt as the producer. Tests always use --skip-build; a missing executable or an
empty module selection is a failure rather than an invitation to rebuild.
"""

from contextlib import contextmanager, suppress
import argparse
import base64
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

import linux_ci


PLATFORMS = linux_ci.PLATFORMS
TIMING_PACKAGES = {"timing-support": "Tools/DiscordBenchmarkSupport",
                   "timing": "Tools/DiscordTimingBenchmarks",
                   "foundation": "Tools/DiscordFoundationBenchmarks", "media": "Tools/DiscordMediaBenchmarks"}
TIMING_PRODUCTS = {"load": "DiscordKitLoadTests", "timing": "DiscordTimingBenchmarks",
                   "foundation": "DiscordFoundationBenchmarks", "media": "DiscordMediaBenchmarks"}
COMPONENTS = ("root", "macros", "extensions", "tooling", "load", "benchmarks", *TIMING_PACKAGES, "consumers", "release")
PACKAGES = {"root": ".", "macros": "Packages/DiscordDSLMacros",
            "extensions": "Packages/DiscordDSLExtensions", "tooling": "Tools/DiscordKitTools",
            "load": "Tools/DiscordKitLoadTests", "benchmarks": "Tools/DiscordDSLBenchmarks", **TIMING_PACKAGES}
CONSUMER_TESTS = ("LoggingApp", "CommandsApp", "DSLCommands", "DSLEvents", "DSLBot", "ActivityHost")
CONSUMER_SMOKES = ("LoggingApp", "CommandsApp", "DSLCommands", "DSLEvents", "DSLBot", "VoiceBot", "SocialApp")
CONSUMER_SUITES = tuple(sorted(set(CONSUMER_TESTS) | set(CONSUMER_SMOKES)))
METADATA = "native-build.json"
MAX_METADATA_BYTES = 16 * 1024 * 1024
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
BUILD_JOB_SECONDS = 120 * 60
TEST_JOB_SECONDS = 60 * 60
AUDIT_JOB_SECONDS = 30 * 60
PACKAGING_IDENTITY_SECONDS = 600


def execution_policy():
    """Load the shared limits lazily because source-policy validation imports this planner."""
    import scheduling_policy
    return scheduling_policy.load_policy()


def remaining_seconds(deadline, maximum, arguments=()):
    """Do not admit metadata queries after their enclosing command group expires."""
    remaining = maximum if deadline is None else min(maximum, deadline - time.monotonic())
    if remaining <= 0:
        raise subprocess.TimeoutExpired(arguments, maximum)
    return remaining


def compilation_budget(component, policy=None):
    """Include each exact package inventory in the component's finite elapsed budget."""
    policy = policy or execution_policy()
    return (policy["componentCompileSeconds"][component]
            + len(package_tests(component)) * policy["deadlinesSeconds"]["discovery"])


def validate_enclosing_budget(seconds, enclosing, *, packaging=False, policy=None):
    """Reject group limits that consume setup, diagnosis, cleanup or evidence-upload time."""
    policy = policy or execution_policy()
    required = seconds + sum(policy["reservesSeconds"].values())
    if packaging:
        required += PACKAGING_IDENTITY_SECONDS
    if required > enclosing:
        raise ValueError("command aggregate and reserves exceed the enclosing workflow deadline")
    return required


def write_json(path, value):
    """Atomically retain progress without requiring an existing output directory."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


@contextmanager
def execution_report(output, report):
    """Retain inventory, identity and aggregate failures as well as failed child commands."""
    started = time.monotonic()
    write_json(output / "commands.json", report)
    try:
        yield
    except BaseException as error:
        report.update(status="failed", error=str(error))
        raise
    else:
        report["status"] = "passed"
    finally:
        report["seconds"] = round(time.monotonic() - started, 3)
        write_json(output / "commands.json", report)


def dump_targets(repository, package=".", *, output=None, report=None, deadline=None):
    """Read SwiftPM's evaluated test-target inventory without resolving or building dependencies."""
    if output is None:
        with tempfile.TemporaryDirectory(prefix="discordkit-targets-") as directory:
            return dump_targets(repository, package, output=Path(directory), deadline=deadline)
    report = report if report is not None else {"status": "running", "commands": []}
    command = linux_ci.Command("manifest-targets", ("swift", "package", "--package-path", package, "dump-package"),
                               execution_policy()["deadlinesSeconds"]["discovery"], operation="discovery")
    log = execute_commands([command], repository, output, report, capture_stdout=True, deadline=deadline)[0]
    document = json.loads(log.read_text())
    targets = [target["name"] for target in document["targets"] if target.get("type") == "test"]
    if len(targets) != len(set(targets)) or any(not IDENTIFIER.fullmatch(name) for name in targets):
        raise ValueError("SwiftPM test targets must have unique supported module names")
    return sorted(targets)


def metadata_output(arguments, repository, *, output=None, report=None, deadline=None, binary=False):
    """Supervise metadata children too, preserving binary Git filenames through text forwarding."""
    if output is None:
        with tempfile.TemporaryDirectory(prefix="discordkit-identity-") as directory:
            return metadata_output(arguments, repository, output=Path(directory), deadline=deadline, binary=binary)
    report = report if report is not None else {"status": "running", "commands": []}
    argv = tuple(arguments)
    if binary:
        # The wrapper and Git inherit the same supervised process group. Base64 keeps
        # arbitrary tracked filename bytes intact through the UTF-8 diagnostic reader.
        script = ("import base64,subprocess,sys; "
                  "result=subprocess.run(sys.argv[1:], stdout=subprocess.PIPE); "
                  "sys.stdout.buffer.write(base64.b64encode(result.stdout)); sys.stdout.flush(); "
                  "raise SystemExit(result.returncode)")
        argv = (sys.executable, "-c", script, *argv)
    command = linux_ci.Command("identity-query", argv, 30, operation="metadata")
    log = execute_commands([command], repository, output, report, capture_stdout=True, deadline=deadline)[0]
    return base64.b64decode(log.read_bytes(), validate=True) if binary else log.read_text()


def active_targets(targets, native_platform):
    """Omit targets whose entire test sources are unavailable on the selected platform."""
    return [target for target in targets
            if not (native_platform == "windows-x64" and target == "DiscordUnixPlatformTests")
            and not (native_platform != "macos-arm64" and target == "DiscordFoundationTransportTests")]


def runner_entry(native_platform, large):
    """Select the configured native pool; the available macOS pool has five cores."""
    if native_platform == "macos-arm64":
        return {"platform": native_platform, "group": "MacOS-26-5", "jobs": 5, "shell": "bash"}
    if native_platform not in PLATFORMS:
        raise ValueError("unsupported native platform")
    windows = native_platform == "windows-x64"
    size = 64 if large else 8
    return {"platform": native_platform, "group": f"{'Windows' if windows else 'Linux'}-x64-{size}",
            "jobs": size, "shell": "pwsh" if windows else "bash"}


def matrices(root_targets, native_platform=None):
    """Partition all platforms or one selected platform into independent native jobs."""
    if native_platform is not None and native_platform not in PLATFORMS:
        raise ValueError("unsupported native platform")
    if not root_targets or len(root_targets) != len(set(root_targets)):
        raise ValueError("a nonempty unique root test-target inventory is required")
    if any(not IDENTIFIER.fullmatch(name) for name in root_targets):
        raise ValueError("unsupported root test-target name")
    builds, tests = [], []
    for native_platform in PLATFORMS if native_platform is None else (native_platform,):
        # These development probes implement Darwin/Glibc only. Windows remains
        # excluded by the current CI callers and gains no timing qualification.
        timing_components = () if native_platform == "windows-x64" else tuple(TIMING_PACKAGES)
        for component in COMPONENTS:
            if component in TIMING_PACKAGES and component not in timing_components:
                continue
            builds.append({**runner_entry(native_platform, True), "component": component})
        for suite in active_targets(sorted(root_targets), native_platform):
            tests.append({**runner_entry(native_platform, False), "component": "root", "suite": suite})
        for component in ("macros", "extensions", "tooling", "load", "benchmarks", *timing_components):
            tests.append({**runner_entry(native_platform, False), "component": component, "suite": component})
        for suite in CONSUMER_SUITES:
            tests.append({**runner_entry(native_platform, False), "component": "consumers", "suite": suite})
    if len(builds) > 256 or len(tests) > 256:
        raise ValueError("native scheduling exceeds GitHub's matrix limit; partition the workflow")
    return {"include": builds}, {"include": tests}


def source_identity(repository, *, deadline=None, output=None, report=None):
    """Bind committed identity and current tracked file contents, including dirty changes."""
    revision = metadata_output(["git", "rev-parse", "HEAD"], repository,
                               deadline=deadline, output=output, report=report).strip()
    names = metadata_output(["git", "ls-files", "-z"], repository, binary=True,
                            deadline=deadline, output=output, report=report).split(b"\0")
    digest = hashlib.sha256()
    for name in sorted(set(name for name in names if name)):
        remaining_seconds(deadline, 30)
        path = repository / os.fsdecode(name)
        digest.update(name + b"\0")
        if path.is_symlink():
            digest.update(b"link\0" + os.fsencode(os.readlink(path)))
        elif path.is_file():
            digest.update(b"file\0" + bytes.fromhex(file_digest(path)))
        elif not path.exists():
            digest.update(b"deleted")
        else:
            raise ValueError("tracked source must be a regular file or symbolic link")
        digest.update(b"\0")
    assigned = os.environ.get("GITHUB_SHA")
    if assigned and assigned != revision:
        raise ValueError("checkout does not match the executing GitHub SHA")
    return {"commit": revision, "sourceSHA256": digest.hexdigest()}


def file_digest(path):
    """Hash one file incrementally so large native artifacts stay outside Python memory."""
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def identity(repository, native_platform, *, deadline=None, output=None, report=None):
    """Reject incompatible hosts and snapshot exact source, compiler and workflow-attempt facts."""
    if report is None:
        if output is None:
            with tempfile.TemporaryDirectory(prefix="discordkit-identity-") as directory:
                return identity(repository, native_platform, deadline=deadline, output=Path(directory))
        report = {"status": "running", "platform": native_platform, "commands": []}
        with execution_report(output, report):
            return identity(repository, native_platform, deadline=deadline, output=output, report=report)
    expected_system, expected_machines = {
        "linux-x64": ("Linux", ("x86_64", "amd64")),
        "macos-arm64": ("Darwin", ("arm64", "aarch64")),
        "windows-x64": ("Windows", ("x86_64", "amd64")),
    }[native_platform]
    system, machine = platform.system(), platform.machine().lower()
    if system != expected_system or machine not in expected_machines:
        raise ValueError("actual host does not match the selected native platform")
    version = metadata_output(["swift", "--version"], repository, deadline=deadline, output=output, report=report).strip()
    if not re.search(rf"\bSwift version {re.escape(linux_ci.SWIFT_VERSION)}(?:\s|$)", version):
        raise ValueError(f"expected Swift {linux_ci.SWIFT_VERSION}")
    target = json.loads(metadata_output(["swift", "-print-target-info"], repository,
                                       deadline=deadline, output=output, report=report))["target"]["triple"]
    expected_os = {"linux-x64": "Linux", "macos-arm64": "macOS", "windows-x64": "Windows"}[native_platform]
    expected_architecture = "ARM64" if native_platform == "macos-arm64" else "X64"
    for variable, expected in (("RUNNER_OS", expected_os), ("RUNNER_ARCH", expected_architecture)):
        if variable in os.environ and os.environ[variable] != expected:
            raise ValueError(f"assigned {variable} does not match the selected native platform")
    target_parts = target.lower().split("-")
    target_architecture = target_parts[0]
    target_family = {"linux-x64": "linux", "macos-arm64": "macosx", "windows-x64": "windows"}[native_platform]
    if (target_architecture not in expected_machines
            or not any(part.startswith(target_family) for part in target_parts)):
        raise ValueError("Swift target does not match the selected native platform")
    if native_platform == "linux-x64":
        release = platform.freedesktop_os_release()
        if release.get("ID") != "ubuntu" or release.get("VERSION_ID") != "24.04":
            raise ValueError("native Linux artifacts require Ubuntu 24.04")
    return {**source_identity(repository, deadline=deadline, output=output, report=report),
            "repository": str(repository.resolve()), "platform": native_platform,
            "system": system, "machine": "arm64" if machine in ("arm64", "aarch64") else "x64",
            "swiftVersion": version, "swiftTarget": target, "buildSystem": "native",
            "runID": os.environ.get("GITHUB_RUN_ID", "local"),
            "runAttempt": os.environ.get("GITHUB_RUN_ATTEMPT", "local")}


def bounded_jobs(requested):
    """Cap a positive job request at CPUs visible to this process, respecting Linux affinity."""
    if type(requested) is not int or requested <= 0:
        raise ValueError("jobs must be a positive integer")
    available = os.cpu_count() or 1
    if hasattr(os, "sched_getaffinity"):
        with suppress(OSError):
            available = len(os.sched_getaffinity(0))
    return max(1, min(requested, available))


def swift_command(name, verb, package, jobs, *arguments, operation=None):
    """Keep pins, native build layout and finite compiler resources consistent across stages."""
    # Source-built SwiftSyntax keeps strict direct-import checks valid for macros.
    # SwiftPM's prebuilt dependency graph can report declared imports as missing.
    operation = operation or ("coldCompileCommand" if verb == "build" else
                             "discovery" if verb == "test" and "list" in arguments else
                             "wholeLoadPackage" if verb == "test" and package == PACKAGES["load"] else
                             "suite" if verb == "test" else "timingSmoke")
    return linux_ci.Command(name, tuple(map(str, ("swift", verb, "--package-path", package,
        "--jobs", jobs, "--force-resolved-versions", "--build-system", "native",
        "--disable-experimental-prebuilts", *arguments))), execution_policy()["deadlinesSeconds"][operation],
        operation=operation)


def compile_commands(component, jobs):
    """Build each graph and its tests once; optimized library products remain a separate graph."""
    if component not in COMPONENTS:
        raise ValueError("unknown native component")
    if component == "release":
        return [swift_command(name, "build", PACKAGES[name], jobs, "--configuration", "release")
                for name in ("root", "macros", "extensions")]
    packages = [(example, f"Examples/{example}") for example in linux_ci.EXAMPLES] if component == "consumers" else [(component, PACKAGES[component])]
    commands = []
    for name, package in packages:
        has_tests = component != "consumers" or name in CONSUMER_TESTS
        flags = ["--build-tests"] if has_tests else []
        if component in ("macros", "extensions", "benchmarks", "consumers"):
            flags += ["--explicit-target-dependency-import-check", "error"]
        commands.append(swift_command(name, "build", package, jobs, *flags))
    if component == "benchmarks":
        commands.append(swift_command("optimized-benchmark", "build", PACKAGES[component], jobs,
                                      "--configuration", "release", "--product", "DiscordDSLBenchmarks"))
    if component in TIMING_PRODUCTS:
        commands.append(swift_command("optimized-timing", "build", PACKAGES[component], jobs,
                                      "--configuration", "release", "--product", TIMING_PRODUCTS[component]))
    return commands


def package_tests(component):
    """Return the package graphs whose test inventories belong to one compilation."""
    if component in ("release",):
        return []
    if component == "consumers":
        return [f"Examples/{example}" for example in CONSUMER_TESTS]
    return [PACKAGES[component]]


def build_roots(component):
    """Keep consumer build metadata isolated per package and transport only its graph's outputs."""
    if component == "release":
        packages = [PACKAGES[name] for name in ("root", "macros", "extensions")]
    elif component == "consumers":
        packages = [f"Examples/{example}" for example in linux_ci.EXAMPLES]
    else:
        packages = [PACKAGES[component]]
    return [str(PurePosixPath(package) / ".build") for package in packages]


def discovered_tests(output, expected_modules):
    """Require a nonempty exact partition of SwiftPM's discovered XCTest and Swift Testing leaves."""
    tests = {module: [] for module in expected_modules}
    seen = set()
    for line in output.splitlines():
        match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)[./](\S.*)", line.strip())
        if not match:
            continue
        module = match.group(1)
        if module not in tests:
            raise ValueError(f"discovered an unscheduled test module: {module}")
        test = line.strip()
        if test in seen:
            raise ValueError("discovered a duplicate test identifier")
        seen.add(test)
        tests[module].append(test)
    missing = sorted(module for module, names in tests.items() if not names)
    if not tests or missing:
        detail = ": " + ", ".join(missing) if missing else " (no modules scheduled)"
        raise ValueError("every scheduled test module must discover at least one test" + detail)
    return {module: sorted(names) for module, names in sorted(tests.items())}


def execute_commands(commands, repository, output, report, *, capture_stdout=False, deadline=None):
    """Retain diagnostics and optionally separate machine-readable stdout from child warnings."""
    output.mkdir(parents=True, exist_ok=True)
    report_path = output / "commands.json"
    for command in commands:
        index = len(report.setdefault("commands", []))
        log = output / f"{index:02d}-{command.name}.log"
        record = {"name": command.name, "arguments": list(command.arguments), "status": "running", "log": log.name,
                  "timeoutSeconds": command.timeout, "operation": command.operation,
                  "executionReceipt": log.with_suffix(".receipt.json").name,
                  "diagnostics": log.with_suffix(".diagnostics.jsonl").name}
        if capture_stdout:
            stdout_log = log.with_suffix(".stdout")
            record["stdoutLog"] = stdout_log.name
        report["commands"].append(record)
        write_json(report_path, report)
        started = time.monotonic()
        primary_error = None
        try:
            linux_ci._console_write(f"::group::{command.name}\n{shlex.join(command.arguments)}\n")
            if capture_stdout:
                receipt = linux_ci.execute(command, repository, log, stdout_log=stdout_log, deadline=deadline)
            else:
                receipt = linux_ci.execute(command, repository, log, deadline=deadline)
        except BaseException as error:
            primary_error = error
            record.update(status="failed", error=str(error), seconds=round(time.monotonic() - started, 3))
            with suppress(OSError, ValueError):
                receipt = json.loads(log.with_suffix(".receipt.json").read_text())
                if isinstance(receipt, dict):
                    record["execution"] = receipt
            if isinstance(error, subprocess.TimeoutExpired):
                record["timeoutCategory"] = (record.get("execution", {}).get("timeoutCategory")
                    or ("aggregate" if deadline is not None and time.monotonic() >= deadline else "operation"))
            report["status"] = "failed"
            write_json(report_path, report)
            raise
        else:
            record.update(status="passed", seconds=round(time.monotonic() - started, 3))
            if isinstance(receipt, dict):
                record["execution"] = receipt
            write_json(report_path, report)
        finally:
            try:
                linux_ci._console_write("::endgroup::\n")
            except BaseException as error:
                if primary_error is None:
                    record.update(status="failed", error=str(error), seconds=round(time.monotonic() - started, 3))
                    report["status"] = "failed"
                    write_json(report_path, report)
                    raise
    key = "stdoutLog" if capture_stdout else "log"
    return [output / record[key] for record in report["commands"][-len(commands):]] if commands else []


def member_digest(digest, member, stream=None):
    """Bind archive paths, types, permissions, link destinations and each regular file's bytes."""
    header = [member.name, member.type.decode("ascii"), member.mode & 0o7777, member.size, member.linkname]
    digest.update(json.dumps(header, separators=(",", ":")).encode() + b"\0")
    if member.isfile():
        digest.update(hashlib.file_digest(stream, "sha256").digest())


def create_archive(repository, component, archive, metadata, excluded=()):
    """Transport native artifacts with executable permissions while excluding diagnostics and caches."""
    if archive.exists():
        raise ValueError("compiled archive must be a new file")
    archive.parent.mkdir(parents=True, exist_ok=True)
    roots = build_roots(component)
    if any(not (repository / root).is_dir() or (repository / root).is_symlink() for root in roots):
        raise ValueError("every compiled graph must have a regular build directory")
    payload = hashlib.sha256()
    omitted = [path.resolve() for path in (*excluded, archive)]

    def include(member):
        """Exclude recursive artifacts, index stores and nested dependency build outputs."""
        relative = PurePosixPath(member.name)
        path = repository / Path(*relative.parts)
        absolute = path.absolute()
        if any(absolute == excluded_path or excluded_path in absolute.parents for excluded_path in omitted):
            return None
        root = next(root for root in roots if relative == PurePosixPath(root) or PurePosixPath(root) in relative.parents)
        parts = relative.relative_to(root).parts
        if (any(part in ("ci", "native-ci", "linux-ci", "index", "Index.noindex", "ModuleCache", "ModuleCache.noindex") for part in parts)
                or any(part.endswith(".build") for part in parts)
                or (parts and PurePosixPath(parts[-1]).suffix in (".o", ".obj", ".pch", ".d", ".dia", ".swiftdeps"))):
            return None
        if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
            raise ValueError("native artifact contains an unsupported special file")
        with path.open("rb") if member.isfile() else suppress() as stream:
            member_digest(payload, member, stream)
        return member

    try:
        with tarfile.open(archive, "w:gz", compresslevel=1, dereference=False) as transport:
            for root in roots:
                transport.add(repository / root, arcname=root, filter=include)
            metadata = {**metadata, "buildRoots": roots, "payloadSHA256": payload.hexdigest()}
            import io
            data = json.dumps(metadata, sort_keys=True).encode()
            member = tarfile.TarInfo(METADATA)
            member.size, member.mode = len(data), 0o644
            transport.addfile(member, io.BytesIO(data))
    except BaseException:
        archive.unlink(missing_ok=True)
        raise
    return metadata


def restore_archive(repository, component, native_platform, archive, output, *, deadline=None):
    """Validate the whole transport before extracting into an identical clean native checkout."""
    restore_seconds = execution_policy()["reservesSeconds"]["setup"]
    deadline = deadline if deadline is not None else time.monotonic() + restore_seconds
    current = identity(repository, native_platform, output=output / "identity", deadline=deadline)
    with tarfile.open(archive, "r:gz") as transport:
        members = transport.getmembers()
        manifests = [member for member in members if member.name == METADATA]
        if len(manifests) != 1 or not manifests[0].isfile() or not 0 < manifests[0].size <= MAX_METADATA_BYTES:
            raise ValueError("native artifact must contain exactly one bounded compilation receipt")
        metadata = json.load(transport.extractfile(manifests[0]))
        roots = build_roots(component)
        if (metadata.get("formatVersion") != 1 or metadata.get("component") != component
                or metadata.get("status") != "passed" or metadata.get("identity") != current
                or metadata.get("buildRoots") != roots):
            raise ValueError("native artifact differs from this source, checkout path, toolchain or workflow attempt")
        payload, seen = hashlib.sha256(), set()
        for member in members:
            remaining_seconds(deadline, restore_seconds)
            if member.name == METADATA:
                continue
            relative = PurePosixPath(member.name)
            if (relative.is_absolute() or ".." in relative.parts or member.name in seen
                    or not any(relative == PurePosixPath(root) or PurePosixPath(root) in relative.parents for root in roots)
                    or not (member.isfile() or member.isdir() or member.issym() or member.islnk())):
                raise ValueError("native artifact contains an unexpected or unsafe member")
            seen.add(member.name)
            tarfile.data_filter(member, repository)
            destination = repository / Path(*relative.parts)
            if destination.is_symlink() or (destination.exists() and not (destination.is_dir() and member.isdir())):
                raise ValueError("native artifact would overwrite an existing build output")
            with transport.extractfile(member) if member.isfile() else suppress() as stream:
                member_digest(payload, member, stream)
        if payload.hexdigest() != metadata.get("payloadSHA256"):
            raise ValueError("native artifact payload digest differs from its compilation receipt")
        remaining_seconds(deadline, restore_seconds)
        transport.extractall(repository, members=[member for member in members if member.name != METADATA], filter="data")
    remaining_seconds(deadline, restore_seconds)
    archive_digest = file_digest(archive)
    remaining_seconds(deadline, restore_seconds)
    write_json(output / "restored.json", {"status": "passed", "archiveSHA256": archive_digest, **metadata})
    return metadata


def compile_component(repository, component, native_platform, jobs, output, archive):
    """Compile and seal inventories within one shared elapsed budget, without retrying."""
    jobs = bounded_jobs(jobs)
    policy = execution_policy()
    budget = compilation_budget(component, policy)
    validate_enclosing_budget(budget, BUILD_JOB_SECONDS, packaging=True, policy=policy)
    started = time.monotonic()
    deadline = started + budget
    compile_deadline = started + policy["componentCompileSeconds"][component]
    report = {"status": "running", "component": component, "jobs": jobs, "commands": [],
              "aggregateSeconds": budget, "compileAggregateSeconds": policy["componentCompileSeconds"][component],
              "policyID": policy["policyID"], "aggregateScope": "compilation, inventory, identity and archive boundary checks"}
    archive_created = False
    with execution_report(output, report):
        try:
            original = identity(repository, native_platform, deadline=compile_deadline, output=output, report=report)
            report["identity"] = original
            execute_commands(compile_commands(component, jobs), repository, output, report, deadline=compile_deadline)
            if native_platform == "macos-arm64" and component in ("root", "macros", "extensions"):
                # Symbol emission can compile again and shares the component compilation budget.
                emitter = linux_ci.Command("public-symbol-graphs", (sys.executable,
                    str(repository / "Tools/ci/emit_symbol_graphs.py"), "--repository",
                    str((repository / PACKAGES[component]).resolve()), "--jobs", str(jobs)),
                    policy["deadlinesSeconds"]["coldCompileCommand"], operation="coldCompileCommand")
                execute_commands([emitter], repository, output, report, deadline=compile_deadline)
            inventories = {}
            for index, package in enumerate(package_tests(component)):
                # Evaluated target names and test leaves share one 60-second inventory boundary.
                discovery_deadline = min(deadline, time.monotonic() + policy["deadlinesSeconds"]["discovery"])
                expected = active_targets(dump_targets(repository, package, output=output, report=report,
                                                       deadline=discovery_deadline), native_platform)
                command = swift_command(f"discovery-{index}", "test", package, jobs, "list", "--skip-build")
                log = execute_commands([command], repository, output, report, capture_stdout=True,
                                       deadline=discovery_deadline)[0]
                inventories[package] = discovered_tests(log.read_text(errors="replace"), expected)
            if identity(repository, native_platform, deadline=deadline, output=output, report=report) != original:
                raise ValueError("source or compiler identity changed during compilation")
            metadata = {"formatVersion": 1, "status": "passed", "component": component,
                        "identity": original, "tests": inventories}
            remaining_seconds(deadline, budget)
            metadata = create_archive(repository, component, archive, metadata, excluded=(output,))
            archive_created = True
            remaining_seconds(deadline, budget)
            report.update(archiveSHA256=file_digest(archive), payloadSHA256=metadata["payloadSHA256"])
            remaining_seconds(deadline, budget)
            write_json(output / "compilation.json", metadata)
        except BaseException:
            if archive_created:
                archive.unlink(missing_ok=True)
            raise
    return metadata


def test_commands(component, suite, jobs, metadata):
    """Plan only existing compiled test executables and offline consumer/benchmark runs."""
    if component == "tooling" and suite == "audit":
        commands = linux_ci.commands("audit", Path(metadata["identity"]["repository"]), jobs)
        return [linux_ci.Command(command.name, (*command.arguments[:2], "--skip-build",
                    *(("--build-system", "native") if "--build-system" not in command.arguments else ()), *command.arguments[2:]),
                    execution_policy()["deadlinesSeconds"]["timingSmoke"], operation="timingSmoke")
                if command.arguments[:2] == ("swift", "run") else
                linux_ci.Command(command.name, command.arguments,
                    execution_policy()["deadlinesSeconds"]["localHelperCheck"], operation="localHelperCheck")
                for command in commands]
    if component == "release":
        raise ValueError("release is a compilation gate, not a test suite")
    package = f"Examples/{suite}" if component == "consumers" else PACKAGES[component]
    if (component == "consumers" and suite not in CONSUMER_SUITES) or (component not in ("root", "consumers") and suite != component):
        raise ValueError("unknown suite for this compiled component")
    inventory = metadata.get("tests", {}).get(package, {})
    commands = []
    if component != "consumers" or suite in CONSUMER_TESTS:
        if not inventory or any(not tests for tests in inventory.values()):
            raise ValueError("compiled test inventory is missing or empty")
        filters = []
        if component == "root":
            if suite not in inventory:
                raise ValueError("root suite does not belong to the compiled inventory")
            filters = ["--filter", f"^{re.escape(suite)}[./]"]
        commands.append(swift_command("tests", "test", package, jobs, "--skip-build", "--no-parallel", *filters))
    if component == "consumers" and suite in CONSUMER_SMOKES:
        commands.append(swift_command("offline-smoke", "run", package, jobs, "--skip-build", suite,
                                      *(["--offline"] if suite == "DSLCommands" else [])))
    if component == "benchmarks":
        commands.append(swift_command("runtime-smoke", "run", package, jobs, "--skip-build", "--configuration", "release",
            "DiscordDSLBenchmarks", "--invocations", "1000", "--output", ".build/dsl-measurements/runtime-smoke.json"))
    commands.extend(timing_smoke_commands(component, jobs))
    return commands


def timing_smoke_commands(component, jobs):
    """Run finite offline correctness smokes; shared-runner timing numbers never gate budgets."""
    if component not in TIMING_PRODUCTS:
        return []
    cases = {
        "timing": [(mode, ["--mode", mode, "--iterations", "128", "--warmup-iterations", "16", "--concurrency", "2"])
                   for mode in ("disabled", "aggregate", "scalarAggregate")],
        "foundation": [("json", ["--case", "json.parse.1024.depth1.ascii", "--batches", "16", "--batch-size", "4", "--warmup-batches", "2"])],
        "media": [("rtp", ["--case", "rtp.packetize.roundtrip", "--batches", "16", "--batch-size", "4", "--warmup-batches", "2"])],
        "load": [("rest", ["timing", "--case", "rest.cacheFresh", "--adapter", "scripted", "--requests", "16", "--warmup-requests", "2", "--concurrency", "2"]),
                 ("loopback", ["timing", "--case", "transport.smallBody", "--adapter", "nio", "--requests", "16", "--warmup-requests", "2", "--concurrency", "2"])],
    }[component]
    result = []
    for name, arguments in cases:
        destination = f".build/timing-smoke/{component}/{name}"
        command = swift_command(f"timing-smoke-{name}", "run", PACKAGES[component], jobs,
            "--skip-build", "--configuration", "release", TIMING_PRODUCTS[component], *arguments,
            "--profile", "smoke", "--seed", "1", "--duration-seconds", "3", "--warmup-seconds", "1",
            "--output", destination + ".json", "--common-report", destination + "-common.json")
        result.append(command)
    return result


def verify_timing_smokes(repository, commands):
    """Require readable nonempty completed reports and joined cleanup, without numerical thresholds."""
    for command in commands:
        if not command.name.startswith("timing-smoke-"):
            continue
        documents = []
        for option in ("--output", "--common-report"):
            path = repository / command.arguments[command.arguments.index(option) + 1]
            if not 0 < path.stat().st_size <= 32 * 1024 * 1024:
                raise ValueError("timing smoke report is empty or exceeds the report ceiling")
            documents.append(read_timing_json(path))
        native, common = documents
        if not isinstance(native, dict) or not isinstance(common, dict) or native.get("common") != common:
            raise ValueError("timing smoke requires matching completed reports, observations and zero-owner cleanup")
        verify_common_smoke(common)


def read_timing_json(path):
    """Reject nonfinite JSON numbers instead of accepting Python's permissive NaN extension."""
    def finite(value):
        result = float(value)
        if not math.isfinite(result):
            raise ValueError("nonfinite timing report number")
        return result

    def invalid(_):
        raise ValueError("nonstandard timing report number")

    return json.loads(path.read_bytes(), parse_float=finite, parse_constant=invalid)


def verify_common_smoke(common):
    """Check this success-only smoke's population and loss accounting without latency budgets.

    Counted underflow/overflow and sparse p99 are retained informational evidence.
    Unknown loss, counter overflow and malformed histogram populations cannot pass.
    The producer's validatedData additionally validates the full shared schema.
    """
    def natural(value):
        return type(value) is int and value >= 0

    if not isinstance(common, dict):
        raise ValueError("timing smoke requires a structured common report")
    counts = common.get("counts", {})
    if not isinstance(counts, dict) or not isinstance(counts.get("outcomes"), dict) or not isinstance(common.get("cleanup"), dict):
        raise ValueError("timing smoke requires structured population and cleanup accounting")
    completed = counts.get("completed")
    outcomes = counts.get("outcomes", {})
    if (common.get("format") != "DiscordBenchmarkReport" or type(common.get("schemaVersion")) is not int
            or common["schemaVersion"] != 1 or common.get("status") != "completed"
            or not natural(completed) or completed == 0
            or any(not natural(counts.get(key)) or counts[key] != completed for key in ("offered", "admitted"))
            or counts.get("deadlineMisses") != 0 or type(counts.get("deadlineMisses")) is not int
            or set(outcomes) != {"success", "failure", "timedOut", "cancelled", "rejected", "uncertain"}
            or any(not natural(value) or value != (completed if key == "success" else 0) for key, value in outcomes.items())
            or not isinstance(common.get("metrics"), list) or not common["metrics"]
            or common.get("cleanup", {}).get("completed") is not True
            or common.get("cleanup", {}).get("remainingOwners") != 0
            or type(common.get("cleanup", {}).get("remainingOwners")) is not int):
        raise ValueError("timing smoke requires completed successful observations and zero-owner cleanup")
    for metric in common["metrics"]:
        if not isinstance(metric, dict) or not isinstance(metric.get("distribution"), dict):
            raise ValueError("timing smoke requires a structured metric distribution")
        distribution = metric.get("distribution", {})
        population = ("observedCount", "inRangeCount", "underflowCount", "overflowCount", "droppedCount")
        cells = distribution.get("bucketCounts", [])
        configuration = distribution.get("configuration", {})
        if not isinstance(configuration, dict) or not isinstance(cells, list):
            raise ValueError("timing smoke requires a structured finite histogram")
        lower, upper, width = (configuration.get(key) for key in
                              ("lowerBoundNanoseconds", "upperBoundNanoseconds", "bucketWidthNanoseconds"))
        if (metric.get("outcome") != "success" or not metric.get("id")
                or any(not natural(distribution.get(key)) for key in population)
                or distribution["observedCount"] != completed
                or distribution.get("counterOverflow") is not False or distribution["droppedCount"] != 0
                or not cells or any(not natural(value) for value in cells)
                or any(not natural(value) for value in (lower, upper, width)) or width == 0 or upper < lower
                or len(cells) != (upper - lower) // width + 1
                or sum(cells) != distribution["inRangeCount"]
                or sum(distribution[key] for key in population[1:]) != distribution["observedCount"]):
            raise ValueError("timing smoke histogram has missing observations, loss or inconsistent accounting")


def run_tests(repository, component, suite, native_platform, jobs, output, archive):
    """Restore an exact compilation and verify/execute one aggregate without rebuilding."""
    jobs = bounded_jobs(jobs)
    metadata = restore_archive(repository, component, native_platform, archive, output)
    policy = execution_policy()
    commands = test_commands(component, suite, jobs, metadata)
    needs_discovery = suite != "audit" and (component != "consumers" or suite in CONSUMER_TESTS)
    budget = (sum(command.timeout for command in commands)
              + (policy["deadlinesSeconds"]["discovery"] if needs_discovery else 0))
    if suite == "audit":
        # Many short source checks share one helper-check budget, not one per report.
        budget = policy["deadlinesSeconds"]["localHelperCheck"]
    validate_enclosing_budget(budget, AUDIT_JOB_SECONDS if suite == "audit" else TEST_JOB_SECONDS, policy=policy)
    deadline = time.monotonic() + budget
    report = {"status": "running", "component": component, "suite": suite, "jobs": jobs, "commands": [],
              "aggregateSeconds": budget, "identity": metadata["identity"], "policyID": policy["policyID"],
              "aggregateScope": "post-restore discovery, tests, smokes and final identity"}
    with execution_report(output, report):
        if needs_discovery:
            package = f"Examples/{suite}" if component == "consumers" else PACKAGES[component]
            discovery = swift_command("verify-discovery", "test", package, jobs, "list", "--skip-build")
            log = execute_commands([discovery], repository, output, report, capture_stdout=True, deadline=deadline)[0]
            inventory = metadata["tests"][package]
            if discovered_tests(log.read_text(errors="replace"), sorted(inventory)) != inventory:
                raise ValueError("restored tests differ from the compiled test inventory")
        if component == "benchmarks":
            (repository / ".build/dsl-measurements").mkdir(parents=True, exist_ok=True)
        if component in TIMING_PRODUCTS:
            (repository / ".build/timing-smoke" / component).mkdir(parents=True, exist_ok=True)
            report["numericalQualification"] = "informational shared-runner smoke; no baseline comparison or product SLO"
        execute_commands(commands, repository, output, report, deadline=deadline)
        verify_timing_smokes(repository, commands)
        if identity(repository, native_platform, deadline=deadline, output=output, report=report) != metadata["identity"]:
            raise ValueError("tracked source or compiler changed during test execution")
        remaining_seconds(deadline, budget)
    return report


def main():
    """Expose matrix planning, fresh compilation, verified restore and independent suite execution."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("plan", "compile", "restore", "test"))
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--component", choices=COMPONENTS)
    parser.add_argument("--platform", choices=PLATFORMS)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--suite")
    parser.add_argument("--archive", type=Path)
    arguments = parser.parse_args()
    if arguments.operation != "plan" and (not arguments.component or not arguments.platform or not arguments.archive):
        parser.error("compile, restore and test require --component, --platform and --archive")
    if arguments.operation == "test" and not arguments.suite:
        parser.error("test requires --suite")
    repository, output = arguments.repository.resolve(), arguments.output.resolve()
    try:
        if arguments.operation == "plan":
            report = {"status": "running", "operation": "plan", "commands": []}
            with execution_report(output, report):
                builds, tests = matrices(dump_targets(repository, output=output, report=report), arguments.platform)
            write_json(output / "build-matrix.json", builds)
            write_json(output / "test-matrix.json", tests)
        elif arguments.operation == "compile":
            compile_component(repository, arguments.component, arguments.platform, arguments.jobs, output, arguments.archive.resolve())
        elif arguments.operation == "restore":
            restore_archive(repository, arguments.component, arguments.platform, arguments.archive.resolve(), output)
        else:
            run_tests(repository, arguments.component, arguments.suite, arguments.platform, arguments.jobs, output, arguments.archive.resolve())
    except (ValueError, OSError, KeyError, TypeError, AttributeError, RecursionError, tarfile.TarError, subprocess.SubprocessError) as error:
        write_json(output / "failure.json", {"status": "failed", "operation": arguments.operation, "error": str(error)})
        print(f"Native job failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
