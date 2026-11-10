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

from contextlib import suppress
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import time

import linux_ci


PLATFORMS = linux_ci.PLATFORMS
COMPONENTS = ("root", "macros", "extensions", "tooling", "load", "benchmarks", "consumers", "release")
PACKAGES = {"root": ".", "macros": "Packages/DiscordDSLMacros",
            "extensions": "Packages/DiscordDSLExtensions", "tooling": "Tools/DiscordKitTools",
            "load": "Tools/DiscordKitLoadTests", "benchmarks": "Tools/DiscordDSLBenchmarks"}
CONSUMER_TESTS = ("LoggingApp", "CommandsApp", "DSLCommands", "DSLEvents", "DSLBot", "ActivityHost")
CONSUMER_SMOKES = ("LoggingApp", "CommandsApp", "DSLCommands", "DSLEvents", "DSLBot", "VoiceBot", "SocialApp")
CONSUMER_SUITES = tuple(sorted(set(CONSUMER_TESTS) | set(CONSUMER_SMOKES)))
METADATA = "native-build.json"
MAX_METADATA_BYTES = 16 * 1024 * 1024
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def write_json(path, value):
    """Atomically retain progress without requiring an existing output directory."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def dump_targets(repository, package="."):
    """Read SwiftPM's evaluated test-target inventory without resolving or building dependencies."""
    document = json.loads(subprocess.check_output(
        ["swift", "package", "--package-path", package, "dump-package"], cwd=repository,
        text=True, timeout=120))
    targets = [target["name"] for target in document["targets"] if target.get("type") == "test"]
    if len(targets) != len(set(targets)) or any(not IDENTIFIER.fullmatch(name) for name in targets):
        raise ValueError("SwiftPM test targets must have unique supported module names")
    return sorted(targets)


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


def matrices(root_targets):
    """Partition each platform's modules and consumer checks into independent jobs."""
    if not root_targets or len(root_targets) != len(set(root_targets)):
        raise ValueError("a nonempty unique root test-target inventory is required")
    if any(not IDENTIFIER.fullmatch(name) for name in root_targets):
        raise ValueError("unsupported root test-target name")
    builds, tests = [], []
    for native_platform in PLATFORMS:
        for component in COMPONENTS:
            builds.append({**runner_entry(native_platform, True), "component": component})
        for suite in active_targets(sorted(root_targets), native_platform):
            tests.append({**runner_entry(native_platform, False), "component": "root", "suite": suite})
        for component in ("macros", "extensions", "tooling", "load", "benchmarks"):
            tests.append({**runner_entry(native_platform, False), "component": component, "suite": component})
        for suite in CONSUMER_SUITES:
            tests.append({**runner_entry(native_platform, False), "component": "consumers", "suite": suite})
    if len(builds) > 256 or len(tests) > 256:
        raise ValueError("native scheduling exceeds GitHub's matrix limit; partition the workflow")
    return {"include": builds}, {"include": tests}


def source_identity(repository):
    """Bind committed identity and current tracked file contents, including dirty changes."""
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True, timeout=30).strip()
    names = subprocess.check_output(["git", "ls-files", "-z"], cwd=repository, timeout=30).split(b"\0")
    digest = hashlib.sha256()
    for name in sorted(set(name for name in names if name)):
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


def identity(repository, native_platform):
    """Reject incompatible hosts and snapshot exact source, compiler and workflow-attempt facts."""
    expected_system, expected_machines = {
        "linux-x64": ("Linux", ("x86_64", "amd64")),
        "macos-arm64": ("Darwin", ("arm64", "aarch64")),
        "windows-x64": ("Windows", ("x86_64", "amd64")),
    }[native_platform]
    system, machine = platform.system(), platform.machine().lower()
    if system != expected_system or machine not in expected_machines:
        raise ValueError("actual host does not match the selected native platform")
    version = subprocess.check_output(["swift", "--version"], cwd=repository, text=True, timeout=30).strip()
    if not re.search(rf"\bSwift version {re.escape(linux_ci.SWIFT_VERSION)}(?:\s|$)", version):
        raise ValueError(f"expected Swift {linux_ci.SWIFT_VERSION}")
    target = json.loads(subprocess.check_output(["swift", "-print-target-info"], cwd=repository,
                                               text=True, timeout=30))["target"]["triple"]
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
    return {**source_identity(repository), "repository": str(repository.resolve()), "platform": native_platform,
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


def swift_command(name, verb, package, jobs, *arguments):
    """Keep pins, native build layout and finite compiler resources consistent across stages."""
    # Source-built SwiftSyntax keeps strict direct-import checks valid for macros.
    # SwiftPM's prebuilt dependency graph can report declared imports as missing.
    return linux_ci.Command(name, tuple(map(str, ("swift", verb, "--package-path", package,
        "--jobs", jobs, "--force-resolved-versions", "--build-system", "native",
        "--disable-experimental-prebuilts", *arguments))), 3600)


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


def execute_commands(commands, repository, output, report, *, capture_stdout=False):
    """Retain diagnostics and optionally separate machine-readable stdout from child warnings."""
    output.mkdir(parents=True, exist_ok=True)
    report_path = output / "commands.json"
    for command in commands:
        index = len(report.setdefault("commands", []))
        log = output / f"{index:02d}-{command.name}.log"
        record = {"name": command.name, "arguments": list(command.arguments), "status": "running", "log": log.name}
        if capture_stdout:
            stdout_log = log.with_suffix(".stdout")
            record["stdoutLog"] = stdout_log.name
        report["commands"].append(record)
        write_json(report_path, report)
        print(f"::group::{command.name}\n{shlex.join(command.arguments)}", flush=True)
        started = time.monotonic()
        try:
            if capture_stdout:
                linux_ci.execute(command, repository, log, stdout_log=stdout_log)
            else:
                linux_ci.execute(command, repository, log)
        except BaseException as error:
            record.update(status="failed", error=str(error), seconds=round(time.monotonic() - started, 3))
            report["status"] = "failed"
            write_json(report_path, report)
            raise
        else:
            record.update(status="passed", seconds=round(time.monotonic() - started, 3))
            write_json(report_path, report)
        finally:
            print("::endgroup::", flush=True)
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


def restore_archive(repository, component, native_platform, archive, output):
    """Validate the whole transport before extracting into an identical clean native checkout."""
    current = identity(repository, native_platform)
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
        transport.extractall(repository, members=[member for member in members if member.name != METADATA], filter="data")
    write_json(output / "restored.json", {"status": "passed", "archiveSHA256": file_digest(archive), **metadata})
    return metadata


def compile_component(repository, component, native_platform, jobs, output, archive):
    """Compile and seal inventories only after every command passed without changing tracked source."""
    jobs = bounded_jobs(jobs)
    original = identity(repository, native_platform)
    report = {"status": "running", "component": component, "jobs": jobs, "commands": []}
    write_json(output / "commands.json", report)
    execute_commands(compile_commands(component, jobs), repository, output, report)
    if native_platform == "macos-arm64" and component in ("root", "macros", "extensions"):
        # Emit documentation inputs while compiler intermediates are still local.
        # The later API/DocC job only validates and converts restored graphs.
        emitter = linux_ci.Command("public-symbol-graphs", (sys.executable,
            str(repository / "Tools/ci/emit_symbol_graphs.py"), "--repository",
            str((repository / PACKAGES[component]).resolve()), "--jobs", str(jobs)), 3600)
        execute_commands([emitter], repository, output, report)
    inventories = {}
    for index, package in enumerate(package_tests(component)):
        expected = active_targets(dump_targets(repository, package), native_platform)
        command = swift_command(f"discovery-{index}", "test", package, jobs, "list", "--skip-build")
        log = execute_commands([command], repository, output, report, capture_stdout=True)[0]
        inventories[package] = discovered_tests(log.read_text(errors="replace"), expected)
    if identity(repository, native_platform) != original:
        raise ValueError("source or compiler identity changed during compilation")
    metadata = {"formatVersion": 1, "status": "passed", "component": component,
                "identity": original, "tests": inventories}
    metadata = create_archive(repository, component, archive, metadata, excluded=(output,))
    report.update(status="passed", archiveSHA256=file_digest(archive), payloadSHA256=metadata["payloadSHA256"])
    write_json(output / "commands.json", report)
    write_json(output / "compilation.json", metadata)
    return metadata


def test_commands(component, suite, jobs, metadata):
    """Plan only existing compiled test executables and offline consumer/benchmark runs."""
    if component == "tooling" and suite == "audit":
        commands = linux_ci.commands("audit", Path(metadata["identity"]["repository"]), jobs)
        return [linux_ci.Command(command.name, (*command.arguments[:2], "--skip-build",
                    *(("--build-system", "native") if "--build-system" not in command.arguments else ()), *command.arguments[2:]), command.timeout)
                if command.arguments[:2] == ("swift", "run") else command for command in commands]
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
    return commands


def run_tests(repository, component, suite, native_platform, jobs, output, archive):
    """Restore an exact compilation, verify selected inventory and execute without rebuilding."""
    jobs = bounded_jobs(jobs)
    metadata = restore_archive(repository, component, native_platform, archive, output)
    report = {"status": "running", "component": component, "suite": suite, "jobs": jobs, "commands": []}
    commands = test_commands(component, suite, jobs, metadata)
    if suite != "audit" and (component != "consumers" or suite in CONSUMER_TESTS):
        package = f"Examples/{suite}" if component == "consumers" else PACKAGES[component]
        discovery = swift_command("verify-discovery", "test", package, jobs, "list", "--skip-build")
        log = execute_commands([discovery], repository, output, report, capture_stdout=True)[0]
        inventory = metadata["tests"][package]
        if discovered_tests(log.read_text(errors="replace"), sorted(inventory)) != inventory:
            raise ValueError("restored tests differ from the compiled test inventory")
    if component == "benchmarks":
        (repository / ".build/dsl-measurements").mkdir(parents=True, exist_ok=True)
    execute_commands(commands, repository, output, report)
    if identity(repository, native_platform) != metadata["identity"]:
        raise ValueError("tracked source or compiler changed during test execution")
    report["status"] = "passed"
    write_json(output / "commands.json", report)
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
            builds, tests = matrices(dump_targets(repository))
            write_json(output / "build-matrix.json", builds)
            write_json(output / "test-matrix.json", tests)
        elif arguments.operation == "compile":
            compile_component(repository, arguments.component, arguments.platform, arguments.jobs, output, arguments.archive.resolve())
        elif arguments.operation == "restore":
            restore_archive(repository, arguments.component, arguments.platform, arguments.archive.resolve(), output)
        else:
            run_tests(repository, arguments.component, arguments.suite, arguments.platform, arguments.jobs, output, arguments.archive.resolve())
    except (ValueError, OSError, KeyError, tarfile.TarError, subprocess.SubprocessError) as error:
        write_json(output / "failure.json", {"status": "failed", "operation": arguments.operation, "error": str(error)})
        print(f"Native job failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
