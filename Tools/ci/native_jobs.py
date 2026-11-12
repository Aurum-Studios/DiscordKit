#!/usr/bin/env python3
# File: Tools/ci/native_jobs.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Compile native graphs once and consume versioned compatibility/provenance receipts.

SwiftPM requires exact source, pins, flags, paths and native runtime identity.
Producer and consumer execution records are separate. Earlier same-run producers
require a verified immutable index. Tests use --skip-build and exact inventories.
"""

from contextlib import contextmanager, redirect_stdout, suppress
import argparse
import base64
import hashlib
import io
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
import native_receipts as receipts
import platform_probe
import native_resources
import suite_groups
import test_results


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
MAX_SELECTION_BYTES = 64 * 1024 * 1024
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
BUILD_JOB_SECONDS = 150 * 60
TEST_JOB_SECONDS = 105 * 60
AUDIT_JOB_SECONDS = 60 * 60
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
        if "consumer" in report:
            consumer = report["consumer"]
            consumer.update(status=report["status"], completedAt=receipts.utc_now(), executionResults=report["commands"])
            if consumer["discovery"] == "running":
                consumer["discovery"] = "failed"
            if "error" in report:
                consumer["error"] = report["error"]
            write_json(output / "consumer.json", consumer)
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
    """Supervise exact metadata; retain encoded filename bytes outside the console."""
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
    if not binary:
        log = execute_commands([command], repository, output, report, capture_stdout=True, deadline=deadline)[0]
        return log.read_text()
    try:
        # Large newline-free base64 records delayed hosted log processing. The
        # supervisor still saves complete stdout, stderr, deadlines and receipts;
        # only its console copy of this binary transport is suppressed.
        with redirect_stdout(io.StringIO()):
            log = execute_commands([command], repository, output, report, capture_stdout=True, deadline=deadline)[0]
        return base64.b64decode(log.read_bytes(), validate=True)
    except BaseException:
        diagnostic = output / report["commands"][-1]["log"] if report.get("commands") else None
        detail = ""
        if diagnostic is not None:
            with suppress(OSError):
                with diagnostic.open("rb") as stream:
                    stream.seek(0, os.SEEK_END)
                    stream.seek(max(0, stream.tell() - 4096))
                    detail = stream.read(4096).decode("utf8", errors="replace")
        with suppress(OSError, ValueError):
            print(f"Binary metadata query failed; complete diagnostics retained in {output}.\n{detail}", file=sys.stderr)
        raise


def active_targets(targets, native_platform):
    """Omit targets whose entire test sources are unavailable on the selected platform."""
    return [target for target in targets
            if not (native_platform == "windows-x64" and target == "DiscordUnixPlatformTests")
            and not (native_platform != "macos-arm64" and target == "DiscordFoundationTransportTests")]


def runner_entry(native_platform, large):
    """Select the configured native pool; the available macOS pool has five cores."""
    if native_platform == "macos-arm64":
        return {"platform": native_platform, "group": "MacOS-26-5", "jobs": 2, "shell": "bash"}
    if native_platform not in PLATFORMS:
        raise ValueError("unsupported native platform")
    windows = native_platform == "windows-x64"
    size = 64 if large else 8
    return {"platform": native_platform, "group": f"{'Windows' if windows else 'Linux'}-x64-{size}",
            "jobs": 2, "shell": "pwsh" if windows else "bash"}


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
            # Retained compile steps for tooling/timing-support are lightweight;
            # qualify this smaller existing Linux pool separately before rollout.
            large = component not in ("tooling", "timing-support")
            builds.append({**runner_entry(native_platform, large), "component": component})
        for group in suite_groups.root_groups(active_targets(sorted(root_targets), native_platform), native_platform):
            if not group["suites"]:
                continue
            tests.append({**runner_entry(native_platform, False), "component": "root",
                          "suite": group["suite"], "suites": group["suites"]})
        for component in ("macros", "extensions", "tooling", "load", "benchmarks", *timing_components):
            tests.append({**runner_entry(native_platform, False), "component": component, "suite": component, "suites": [component]})
        tests.append({**runner_entry(native_platform, False), "component": "consumers",
                      "suite": "consumers", "suites": list(CONSUMER_SUITES)})
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
    pins = {}
    for name in sorted(set(name for name in names if name)):
        remaining_seconds(deadline, 30)
        path = repository / os.fsdecode(name)
        digest.update(name + b"\0")
        if path.is_symlink():
            digest.update(b"link\0" + os.fsencode(os.readlink(path)))
        elif path.is_file():
            file_hash = file_digest(path)
            digest.update(b"file\0" + bytes.fromhex(file_hash))
            if path.name == "Package.resolved":
                pins[os.fsdecode(name)] = file_hash
        elif not path.exists():
            digest.update(b"deleted")
        else:
            raise ValueError("tracked source must be a regular file or symbolic link")
        digest.update(b"\0")
    assigned = os.environ.get("GITHUB_SHA")
    if assigned and assigned != revision:
        raise ValueError("checkout does not match the executing GitHub SHA")
    return {"commit": revision, "sourceSHA256": digest.hexdigest(), "dependencyPinsSHA256": pins}


def file_digest(path):
    """Hash one file incrementally so large native artifacts stay outside Python memory."""
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def identity(repository, native_platform, *, deadline=None, output=None, report=None):
    """Reject incompatible hosts and snapshot exact source, pins, compiler and runtime facts."""
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
    expected_os = {"linux-x64": "Linux", "macos-arm64": "macOS", "windows-x64": "Windows"}[native_platform]
    expected_architecture = "ARM64" if native_platform == "macos-arm64" else "X64"
    for variable, expected in (("RUNNER_OS", expected_os), ("RUNNER_ARCH", expected_architecture)):
        if variable in os.environ and os.environ[variable] != expected:
            raise ValueError(f"assigned {variable} does not match the selected native platform")
    facts = platform_probe.build_compatibility_facts(repository, native_platform,
        query=lambda arguments: metadata_output(arguments, repository, deadline=deadline, output=output, report=report))
    report["informationalBuildFacts"] = facts["informational"]
    return {**source_identity(repository, deadline=deadline, output=output, report=report),
            "repository": str(repository.resolve()), "platform": native_platform,
            "system": system, "machine": "arm64" if machine in ("arm64", "aarch64") else "x64",
            "swiftVersion": facts["exact"]["swiftVersion"], "swiftTarget": facts["exact"]["swiftTarget"],
            "buildSystem": "native", "runtime": facts["exact"], "buildEnvironment": build_environment()}


def build_environment():
    """Record supported build-affecting overrides exactly; never dump arbitrary environment values."""
    return {name: os.environ.get(name) for name in (
        "SWIFTNIO_STRICT", "SWIFT_EXEC", "SWIFT_EXEC_MANIFEST", "SWIFT_FLAGS", "SWIFTC_FLAGS",
        "SWIFT_BUILD_FLAGS", "SWIFTPM_BUILD_FLAGS", "TOOLCHAINS", "SDKROOT", "DEVELOPER_DIR",
        "MACOSX_DEPLOYMENT_TARGET", "CC", "CXX", "CFLAGS", "CPPFLAGS", "CXXFLAGS", "LDFLAGS",
        "PKG_CONFIG_PATH", "LIBRARY_PATH", "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH")}


def build_profile(component):
    """Bind semantic commands/configurations while normalizing only the CPU resource count."""
    commands = [list(command.arguments) for command in compile_commands(component, 1)]
    configurations = sorted({command[command.index("--configuration") + 1]
                             if "--configuration" in command else "debug" for command in commands})
    return {"component": component, "packages": sorted({command[command.index("--package-path") + 1]
                                                       for command in commands}),
            "testPackages": package_tests(component), "configurations": configurations, "commands": commands,
            "testExclusions": {".": {"DiscordMLSTests.MLSNativeDAVEInteropTests/initialCandidateAcceptedByMLSpp(_:)":
                "Opt-in MLS++ oracle requires DISCORDKIT_DAVE_INTEROP_EXECUTABLE; separate native qualification."}}
                if component == "root" else {}}


def compatibility_identity(repository, component, native_platform, **options):
    """Keep execution provenance out of every compatibility comparison, including final checks."""
    return {"identity": identity(repository, native_platform, **options), "build": build_profile(component)}


def bounded_jobs(requested):
    """Admit compiler processes using policy, CPU affinity and available memory."""
    return native_resources.compiler_admission(requested,
        policy_cap=execution_policy()["concurrency"]["compilerJobsPerProcess"])["jobs"]


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


def restore_archive(repository, component, native_platform, archive, output, *, deadline=None, selection=None):
    """Validate the whole transport before extracting into an identical clean native checkout."""
    restore_seconds = execution_policy()["reservesSeconds"]["setup"]
    deadline = deadline if deadline is not None else time.monotonic() + restore_seconds
    current = compatibility_identity(repository, component, native_platform, output=output / "identity" / component, deadline=deadline)
    execution = receipts.execution_identity(repository)
    archive_digest = file_digest(archive)
    remaining_seconds(deadline, restore_seconds)
    with tarfile.open(archive, "r:gz") as transport:
        members = transport.getmembers()
        manifests = [member for member in members if member.name == METADATA]
        if len(manifests) != 1 or not manifests[0].isfile() or not 0 < manifests[0].size <= MAX_METADATA_BYTES:
            raise ValueError("native artifact must contain exactly one bounded compilation receipt")
        metadata = receipts.read_json(transport.extractfile(manifests[0]))
        roots = build_roots(component)
        receipts.validate_metadata(metadata, current, execution, component, roots,
                                   selection=selection, archive_sha256=archive_digest)
        consumer = receipts.consumer_receipt(execution, metadata["producer"], archive_digest,
                                             selection=selection, metadata=metadata)
        payload, seen = hashlib.sha256(), set()
        links = {member.name for member in members if member.issym() or member.islnk()}
        regular = {member.name for member in members if member.isfile()}

        def admitted(path):
            return any(path == PurePosixPath(root) or PurePosixPath(root) in path.parents for root in roots)

        for member in members:
            remaining_seconds(deadline, restore_seconds)
            if member.name == METADATA:
                continue
            relative = PurePosixPath(member.name)
            if (relative.is_absolute() or ".." in relative.parts or member.name != relative.as_posix() or member.name in seen
                    or any(parent.as_posix() in links for parent in relative.parents)
                    or not admitted(relative)
                    or not (member.isfile() or member.isdir() or member.issym() or member.islnk())):
                raise ValueError("native artifact contains an unexpected or unsafe member")
            seen.add(member.name)
            if member.issym() or member.islnk():
                # Resolve lexically without following links from the archive. Link ancestors
                # are forbidden, so extraction order cannot redirect a previously safe path.
                target = PurePosixPath(member.linkname)
                if target.is_absolute():
                    raise ValueError("native artifact contains an unsafe link")
                target = relative.parent / target if member.issym() else target
                parts = []
                for part in target.parts:
                    if part == "..":
                        if not parts:
                            raise ValueError("native artifact contains an unsafe link")
                        parts.pop()
                    elif part != ".":
                        parts.append(part)
                target = PurePosixPath(*parts)
                if (not admitted(target) or any(parent.as_posix() in links for parent in target.parents)
                        or target.as_posix() in links
                        or (member.islnk() and target.as_posix() not in regular)):
                    raise ValueError("native artifact contains an unsafe or dangling link")
            tarfile.data_filter(member, repository)
            destination = repository / Path(*relative.parts)
            if any(parent.is_symlink() for parent in (destination, *destination.parents)
                   if parent == repository or repository in parent.parents) or (destination.exists() and not (destination.is_dir() and member.isdir())):
                raise ValueError("native artifact would overwrite an existing build output")
            with transport.extractfile(member) if member.isfile() else suppress() as stream:
                member_digest(payload, member, stream)
        if payload.hexdigest() != metadata.get("payloadSHA256"):
            raise ValueError("native artifact payload digest differs from its compilation receipt")
        remaining_seconds(deadline, restore_seconds)
        transport.extractall(repository, members=[member for member in members if member.name != METADATA], filter="data")
    remaining_seconds(deadline, restore_seconds)
    restored = {**metadata, "archiveSHA256": archive_digest, "consumer": consumer}
    write_json(output / f"restored-{component}.json", restored)
    write_json(output / "restored.json", restored)
    return metadata


def compile_component(repository, component, native_platform, jobs, output, archive):
    """Compile and seal inventories within one shared elapsed budget, without retrying."""
    policy = execution_policy()
    admission = native_resources.compiler_admission(jobs,
        policy_cap=policy["concurrency"]["compilerJobsPerProcess"])
    jobs = admission["jobs"]
    budget = compilation_budget(component, policy)
    validate_enclosing_budget(budget, BUILD_JOB_SECONDS, packaging=True, policy=policy)
    started = time.monotonic()
    deadline = started + budget
    compile_deadline = started + policy["componentCompileSeconds"][component]
    report = {"status": "running", "component": component, "jobs": jobs, "resourceAdmission": admission, "commands": [],
              "aggregateSeconds": budget, "compileAggregateSeconds": policy["componentCompileSeconds"][component],
              "policyID": policy["policyID"], "aggregateScope": "compilation, inventory, identity and archive boundary checks"}
    archive_created = False
    started_at = receipts.utc_now()
    with execution_report(output, report):
        try:
            original = compatibility_identity(repository, component, native_platform, deadline=compile_deadline, output=output, report=report)
            execution = receipts.execution_identity(repository)
            report.update(compatibility=original, execution=execution)
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
            if receipts.digest(compatibility_identity(repository, component, native_platform, deadline=deadline, output=output, report=report)) != receipts.digest(original):
                raise ValueError("source or compiler identity changed during compilation")
            if receipts.execution_identity(repository) != execution:
                raise ValueError("producer execution identity changed during compilation")
            metadata = {"formatVersion": receipts.VERSION, "status": "passed", "component": component,
                        "compatibility": original, "producer": receipts.producer_receipt(execution, inventories, started_at),
                        "tests": inventories}
            remaining_seconds(deadline, budget)
            metadata = create_archive(repository, component, archive, metadata, excluded=(output,))
            archive_created = True
            remaining_seconds(deadline, budget)
            report.update(archiveSHA256=file_digest(archive), payloadSHA256=metadata["payloadSHA256"])
            remaining_seconds(deadline, budget)
            receipts.validate_metadata(metadata, original, execution, component, build_roots(component))
            write_json(output / "compilation.json", {**metadata, "archiveSHA256": report["archiveSHA256"]})
        except BaseException:
            if archive_created:
                archive.unlink(missing_ok=True)
            raise
    return metadata


def test_commands(component, suite, jobs, metadata):
    """Plan only existing compiled test executables and offline consumer/benchmark runs."""
    if component == "tooling" and suite == "audit":
        commands = linux_ci.commands("audit", Path(metadata["compatibility"]["identity"]["repository"]), jobs)
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


def selected_suites(component, suite, metadata, native_platform, suites=None):
    """Bind group membership to the deterministic planner; diagnostics select one whole suite."""
    if component == "root":
        inventory = metadata.get("tests", {}).get(".", {})
        known = {row["suite"]: row["suites"] for row in suite_groups.root_groups(sorted(inventory), native_platform)}
        expected = known.get(suite, [suite] if suite in inventory else None)
    elif component == "consumers":
        expected = list(CONSUMER_SUITES) if suite == "consumers" else [suite] if suite in CONSUMER_SUITES else None
    else:
        expected = [suite] if suite == component or (component == "tooling" and suite == "audit") else None
    if not expected or (suites is not None and suites != expected):
        raise ValueError("suite group does not match its exact compiled/planned selection")
    return expected


def suite_inventory(metadata, component, suite):
    """Return package-qualified leaves and predeclared exclusions for one whole suite."""
    package = f"Examples/{suite}" if component == "consumers" else PACKAGES[component]
    inventory = metadata.get("tests", {}).get(package, {})
    leaves = inventory.get(suite, []) if component == "root" else [leaf for names in inventory.values() for leaf in names]
    if suite == "audit" or component == "consumers" and suite not in CONSUMER_TESTS:
        leaves = []
    declared = metadata["compatibility"]["build"].get("testExclusions", {}).get(package, {})
    exclusions = {leaf: reason for leaf, reason in declared.items() if leaf in leaves}
    return package, sorted(leaves), exclusions


def run_tests(repository, component, suite, native_platform, jobs, output, archive, *, selection=None, suites=None):
    """Restore once; discover each graph once; execute bounded whole suites and seal leaf coverage."""
    admission = native_resources.compiler_admission(jobs,
        policy_cap=execution_policy()["concurrency"]["compilerJobsPerProcess"])
    jobs = admission["jobs"]
    write_json(output / "group-coverage.json", {"formatVersion": 1, "status": "failed",
        "component": component, "suite": suite, "failureStage": "restore",
        "suiteResults": [{"suite": name, "status": "not-run"} for name in suites or [suite]]})
    metadata = restore_archive(repository, component, native_platform, archive, output, selection=selection)
    with (output / "restored.json").open() as stream:
        restored = receipts.read_json(stream)
    consumer = restored["consumer"]
    consumer.update(selectedScope={"component": component, "suite": suite}, status="running")
    report = {"status": "running", "component": component, "suite": suite, "jobs": jobs,
              "resourceAdmission": admission, "commands": [], "compatibility": metadata["compatibility"],
              "producer": metadata["producer"], "consumer": consumer,
              "aggregateScope": "post-restore discovery, whole suites, smokes and final identity"}
    coverage = {"formatVersion": 1, "status": "failed", "component": component, "suite": suite,
        "suites": [], "platform": native_platform, "sourceCommit": metadata["compatibility"]["identity"]["commit"],
        "execution": consumer["execution"], "producer": metadata["producer"],
        "compatibility": metadata["compatibility"], "inventory": metadata["tests"],
        "inventorySHA256": receipts.digest(metadata["tests"]), "expectedLeaves": [],
        "executedLeaves": [], "excludedLeaves": {}, "suiteResults": []}
    try:
        with execution_report(output, report):
            policy = execution_policy()
            report["policyID"] = policy["policyID"]
            names = selected_suites(component, suite, metadata, native_platform, suites)
            coverage["suites"] = names
            planned = []
            packages = {}
            for name in names:
                package, leaves, exclusions = suite_inventory(metadata, component, name)
                row = {"suite": name, "status": "not-run", "expectedLeaves": [package + "::" + leaf for leaf in leaves],
                       "executedLeaves": [], "excludedLeaves": {package + "::" + leaf: reason for leaf, reason in exclusions.items()},
                       "result": None}
                coverage["suiteResults"].append(row)
                coverage["expectedLeaves"].extend(row["expectedLeaves"])
                coverage["excludedLeaves"].update(row["excludedLeaves"])
                commands = test_commands(component, name, jobs, metadata)
                if leaves:
                    packages[package] = metadata["tests"][package]
                planned.append((name, package, leaves, exclusions, commands, row))
            coverage["expectedLeaves"].sort()
            if len(coverage["expectedLeaves"]) != len(set(coverage["expectedLeaves"])):
                raise ValueError("duplicate selected test leaf across group suites")
            budget = sum(command.timeout for *_, commands, row in planned for command in commands)
            budget += len(packages) * policy["deadlinesSeconds"]["discovery"] + 120
            if suite == "audit":
                budget = policy["deadlinesSeconds"]["localHelperCheck"]
            report["aggregateSeconds"] = budget
            enclosing = AUDIT_JOB_SECONDS if suite == "audit" else TEST_JOB_SECONDS
            validate_enclosing_budget(budget, enclosing, policy=policy)
            # Resolve + archive download + diagnostics + dedicated leaf receipt.
            transfers = 3 if suite == "audit" else 4
            reserve = (policy["reservesSeconds"]["setup"] * 2
                       + policy["reservesSeconds"]["diagnostics"] + policy["reservesSeconds"]["cleanup"]
                       + transfers * policy["deadlinesSeconds"]["transportTotal"])
            report["workflowReserveSeconds"] = reserve
            if budget + reserve > enclosing:
                raise ValueError("whole-suite group and transport/restore reserves exceed workflow deadline")
            deadline = time.monotonic() + budget
            consumer["discovery"] = "running" if packages else "not-applicable"
            for index, (package, inventory) in enumerate(packages.items()):
                discovery = swift_command(f"verify-discovery-{index}", "test", package, jobs, "list", "--skip-build")
                log = execute_commands([discovery], repository, output, report, capture_stdout=True, deadline=deadline)[0]
                if discovered_tests(log.read_text(errors="replace"), sorted(inventory)) != inventory:
                    consumer["discovery"] = "failed"
                    raise ValueError("restored tests differ from the compiled test inventory")
            if packages:
                consumer.update(discovery="passed", inventorySHA256=receipts.digest(packages))
            if component == "benchmarks":
                (repository / ".build/dsl-measurements").mkdir(parents=True, exist_ok=True)
            if component in TIMING_PRODUCTS:
                (repository / ".build/timing-smoke" / component).mkdir(parents=True, exist_ok=True)
                report["numericalQualification"] = "informational shared-runner smoke; no baseline comparison or product SLO"
            for index, (name, package, leaves, exclusions, commands, row) in enumerate(planned):
                row["status"] = "running"
                write_json(output / "group-coverage.json", coverage)
                try:
                    for command in commands:
                        if command.arguments[:2] == ("swift", "test"):
                            event_path = (output / f"{index:02d}-{name}.events.jsonl").resolve()
                            event_path.unlink(missing_ok=True)
                            flags = ("--event-stream-version", "6.4", "--event-stream-output-path", str(event_path))
                            command = linux_ci.Command(f"{name}-{command.name}", (*command.arguments, *flags),
                                                       command.timeout, operation=command.operation)
                            execute_commands([command], repository, output, report, deadline=deadline)
                            row["result"] = test_results.reconcile(leaves, event_path, exclusions=exclusions)
                            row["executedLeaves"] = [package + "::" + leaf for leaf in row["result"]["executedLeaves"]]
                            coverage["executedLeaves"].extend(row["executedLeaves"])
                        else:
                            execute_commands([command], repository, output, report, deadline=deadline)
                    verify_timing_smokes(repository, commands)
                    row["status"] = "passed"
                except BaseException:
                    row["status"] = "failed"
                    raise
            coverage["executedLeaves"].sort()
            if set(coverage["executedLeaves"]) | set(coverage["excludedLeaves"]) != set(coverage["expectedLeaves"]):
                raise ValueError("executed leaf coverage differs from selected inventory")
            if receipts.digest(compatibility_identity(repository, component, native_platform, deadline=deadline, output=output, report=report)) != receipts.digest(metadata["compatibility"]):
                raise ValueError("tracked source or compiler changed during test execution")
            if receipts.execution_identity(repository) != consumer["execution"]:
                raise ValueError("consumer execution identity changed during tests")
            remaining_seconds(deadline, budget)
        coverage["status"] = "passed"
    finally:
        write_json(output / "group-coverage.json", coverage)
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
    parser.add_argument("--suites-json", help="exact planned whole-suite group membership")
    parser.add_argument("--mode", choices=("full", "diagnostic"), help="scoped workflow plan")
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--selection", type=Path, help="complete immutable artifact resolver index")
    arguments = parser.parse_args()
    if arguments.operation != "plan" and (not arguments.component or not arguments.platform or not arguments.archive):
        parser.error("compile, restore and test require --component, --platform and --archive")
    if arguments.operation == "test" and not arguments.suite:
        parser.error("test requires --suite")
    repository, output = arguments.repository.resolve(), arguments.output.resolve()
    try:
        selection = None
        if arguments.selection is not None:
            if arguments.operation not in ("restore", "test"):
                raise ValueError("artifact selection is only valid for restore or test")
            if not 0 < arguments.selection.stat().st_size <= MAX_SELECTION_BYTES:
                raise ValueError("artifact selection index is empty or exceeds its size ceiling")
            with arguments.selection.open() as stream:
                selection = receipts.read_json(stream)
        if arguments.operation == "plan":
            report = {"status": "running", "operation": "plan", "commands": []}
            with execution_report(output, report):
                targets = dump_targets(repository, output=output, report=report)
                builds, tests = matrices(targets, arguments.platform)
                if arguments.mode:
                    import scheduling_policy
                    import workflow_scope
                    policy = scheduling_policy.load_policy()
                    scheduling_policy.validate_source_inventory(policy, repository)
                    if sorted(targets) != policy['inventory']['rootTargets']:
                        raise ValueError('evaluated SwiftPM inventory differs from reviewed source inventory')
                    scoped = workflow_scope.platform_plan(arguments.mode, arguments.platform,
                        component=arguments.component, suite=arguments.suite, repository=repository,
                        commit=os.environ['GITHUB_SHA'], run_id=os.environ['GITHUB_RUN_ID'],
                        run_attempt=os.environ['GITHUB_RUN_ATTEMPT'])
                    builds, tests = scoped['builds'], scoped['tests']
                    write_json(output / 'scope-plan.json', scoped)
            write_json(output / "build-matrix.json", builds)
            write_json(output / "test-matrix.json", tests)
            comparison_builds, comparison_tests = builds, tests
            if arguments.mode:
                comparison_builds = scoped['all-builds']
                comparison_tests = {'include': [*scoped['root-tests']['include'], *scoped['tests']['include'],
                    {'platform': arguments.platform, 'component': 'load', 'suite': 'load'}]}
            write_json(output / "scheduling-comparison.json", suite_groups.compare_baseline(comparison_builds, comparison_tests))
        elif arguments.operation == "compile":
            compile_component(repository, arguments.component, arguments.platform, arguments.jobs, output, arguments.archive.resolve())
        elif arguments.operation == "restore":
            restore_archive(repository, arguments.component, arguments.platform, arguments.archive.resolve(), output, selection=selection)
        else:
            run_tests(repository, arguments.component, arguments.suite, arguments.platform, arguments.jobs, output, arguments.archive.resolve(), selection=selection,
                      suites=json.loads(arguments.suites_json) if arguments.suites_json is not None else None)
    except (ValueError, OSError, KeyError, TypeError, AttributeError, RecursionError, tarfile.TarError, subprocess.SubprocessError) as error:
        write_json(output / "failure.json", {"status": "failed", "operation": arguments.operation, "error": str(error)})
        print(f"Native job failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
