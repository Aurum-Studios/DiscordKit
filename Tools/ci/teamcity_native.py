#!/usr/bin/env python3
# File: Tools/ci/teamcity_native.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Run one native phase in the DiscordKit TeamCity build chain."""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import time

import build_documentation_site
import documentation_inputs
import linux_ci
import native_jobs
import native_receipts
import package_source
import platform_probe
import scheduling_policy
import suite_groups


REPOSITORY = Path(__file__).resolve().parents[2]
TEAMCITY_STATE = Path(".build/teamcity")
PLATFORMS = ("linux-x64", "macos-arm64")
BUILD_COMPONENTS = (*native_jobs.COMPONENTS, "apple")
DIRECT_TESTS = tuple(component for component in native_jobs.COMPONENTS if component not in ("root", "release"))
GROUPS = {name: (("root", name),) for name in suite_groups.GROUP_NAMES}
GROUPS.update({component: ((component, component),) for component in DIRECT_TESTS})
GROUPS.update(authoring=(("macros", "macros"), ("extensions", "extensions")),
              benchmarks=tuple((component, component) for component in ("benchmarks", *native_jobs.TIMING_PACKAGES)),
              audit=(("tooling", "audit"),))
API_COMPONENTS = {
    "root": ("0.20.0", ("api-baseline.json", *(f"api-baseline-0.{minor}.0.json" for minor in range(15, 20)))),
    "macros": ("0.15.0", ("api-baseline-macros-0.15.0.json",)),
    "extensions": ("0.15.0", ("api-baseline-extensions-0.15.0.json",)),
}
# The Linux agent can admit just one compiler process. Both large graphs were
# still compiling at the shared 20-minute deadline on that agent.
LINUX_COMPILE_BUDGETS = {"root": 2460, "release": 7200}
LINUX_COMPILE_COMMAND_SECONDS = 2400


def verify_checkout(repository):
    """Require precisely the committed revision assigned by TeamCity."""
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip()
    execution = native_receipts.execution_identity(repository)
    if execution["scope"] == "teamcity" and execution["revision"] != revision:
        raise ValueError("checkout does not match the assigned TeamCity revision")
    status = subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=no"], cwd=repository)
    if status:
        raise ValueError("native CI requires unchanged tracked sources and dependency pins")
    return revision, execution


def qualify(repository, target, evidence):
    """Prove the native compiler/runtime and compare SwiftPM's evaluated inventory."""
    platform_probe.probe(repository, evidence / "platform", target)
    policy = scheduling_policy.load_policy()
    scheduling_policy.validate_source_inventory(policy, repository)
    report = {"status": "running", "commands": []}
    with native_jobs.execution_report(evidence / "manifest", report):
        targets = native_jobs.dump_targets(repository, output=evidence / "manifest", report=report)
        if targets != sorted(policy["inventory"]["rootTargets"]):
            raise ValueError("evaluated SwiftPM inventory differs from reviewed source inventory")
        builds, tests = native_jobs.matrices(targets, target)
        native_jobs.write_json(evidence / "build-matrix.json", builds)
        native_jobs.write_json(evidence / "test-matrix.json", tests)


def execute(repository, evidence, name, arguments, timeout):
    """Keep a supervised command, its deadline, and output in TeamCity artifacts."""
    command = linux_ci.Command(name, tuple(map(str, arguments)), timeout, stage="teamcity-native")
    report = {"status": "running", "commands": []}
    with native_jobs.execution_report(evidence / name, report):
        native_jobs.execute_commands([command], repository, evidence / name, report,
                                     deadline=time.monotonic() + timeout)


def build(repository, target, component, jobs, output, evidence):
    """Build an independent graph once and produce a provenance-sealed archive."""
    if component == "apple":
        linux_ci.native_preflight(repository, evidence / "host", target)
        execute(repository, evidence, "apple-compile", [sys.executable, "Tools/ci/compile_apple.py",
                "--repository", repository, "--output", evidence / "apple-compile.json"], 2400)
        return
    compile_budget = LINUX_COMPILE_BUDGETS.get(component) if target == "linux-x64" else None
    native_jobs.compile_component(repository, component, target, jobs, evidence, output / f"{component}.tar.gz",
                                  archive_exclusions=(repository / TEAMCITY_STATE,),
                                  command_timeout=LINUX_COMPILE_COMMAND_SECONDS if compile_budget else None,
                                  compile_budget_seconds=compile_budget)


def check(repository, target, group, jobs, inputs, output, evidence):
    """Run pinned test groups against exact same-chain outputs or run compiler fixtures."""
    if group == "fixtures":
        linux_ci.native_preflight(repository, evidence / "host", target)
        jobs = native_jobs.bounded_jobs(jobs)
        for module in ("dsl_compile_fixtures", "dsl_extension_fixtures"):
            execute(repository, evidence, module, [sys.executable, f"Tools/ci/{module}.py",
                    "--repository", repository, "--jobs", jobs, "--timeout", 1200], 2400)
    elif group == "public-api":
        public_api(repository, target, inputs, output, evidence)
    else:
        for component, suite in GROUPS[group]:
            native_jobs.run_tests(repository, component, suite, target, jobs, evidence / component,
                                  inputs / f"{component}.tar.gz")


def clean_check_outputs(repository, group):
    """Remove only untracked SwiftPM output that could collide with the next archive restore."""
    components = API_COMPONENTS if group == "public-api" else (
        component for component, _ in GROUPS.get(group, ())
    )
    roots = sorted({root for component in components for root in native_jobs.build_roots(component)})
    if roots:
        subprocess.run(["git", "clean", "-ffdx", "-e", "/.build/teamcity/", "--", *roots],
                       cwd=repository, check=True)


def public_api(repository, target, inputs, output, evidence):
    """Compare all reviewed API baselines and seal strict DocC conversions once."""
    docc = shutil.which("docc") or subprocess.check_output(["xcrun", "--find", "docc"], text=True).strip()
    script = "Tools/DiscordKitTools/scripts/api_baseline.py"
    for component, (version, baselines) in API_COMPONENTS.items():
        native_jobs.restore_archive(repository, component, target, inputs / f"{component}.tar.gz",
                                    evidence / component)
        relative_package = native_jobs.PACKAGES[component]
        snapshot = evidence / f"current-{component}-api.json"
        api_scope = [] if component == "root" else ["--authoring-package", relative_package]
        execute(repository, evidence, f"snapshot-{component}",
                [sys.executable, script, "snapshot", "--repository", repository,
                 *api_scope,
                 "--symbolgraphs", repository / relative_package / ".build/out/symbolgraph",
                 "--version", version, "--output", snapshot], 300)
        for baseline in baselines:
            name = f"compare-{component}-{Path(baseline).stem}"
            execute(repository, evidence, name, [sys.executable, script, "check",
                    "--baseline", repository / "Docs/Release" / baseline, "--candidate", snapshot,
                    "--version", version, "--output", evidence / f"{name}.json"], 300)
        converted = output.parent / "work" / "docc" / component
        try:
            documentation_inputs.prepare(repository, component, converted,
                                         output / "documentation-inputs" / f"{component}.tar.gz",
                                         evidence / f"documentation-{component}.json", docc)
        finally:
            preparation = converted.with_name(converted.name + "-preparation")
            if preparation.is_dir():
                shutil.move(preparation, evidence / f"documentation-{component}-preparation")


def documentation(repository, jobs, inputs, output, evidence):
    """Merge same-chain DocC inputs into a native archive and package it for download."""
    destination = output.parent / "work" / build_documentation_site.ARCHIVE
    arguments = [sys.executable, "Tools/ci/build_documentation_site.py", "--repository", repository,
                 "--output", destination, "--archive-only", "--jobs", jobs]
    for component in API_COMPONENTS:
        arguments.extend(("--sealed-input", inputs / "documentation-inputs" / f"{component}.tar.gz"))
    execute(repository, evidence, "documentation-archive", arguments, 1200)
    members = sorted(destination.rglob("*"))
    if (not (destination / "metadata.json").is_file()
            or any(path.is_symlink() or not (path.is_file() or path.is_dir()) for path in members)):
        raise ValueError("DocC output must be a complete, regular archive bundle")
    artifact = output / f"{destination.name}.tar.gz"
    temporary = destination.with_suffix(".tar.gz.tmp")
    with tarfile.open(temporary, "w:gz") as archive:
        archive.add(destination, arcname=destination.name, recursive=False)
        for path in members:
            archive.add(path, arcname=path.relative_to(destination.parent).as_posix(), recursive=False)
    temporary.rename(artifact)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    phases = parser.add_subparsers(dest="phase", required=True)
    for name in ("qualify", "build", "check", "package", "documentation"):
        phase = phases.add_parser(name)
        phase.add_argument("platform", choices=PLATFORMS)
        phase.add_argument("--repository", type=Path, default=REPOSITORY)
        phase.add_argument("--separate-evidence", action="store_true",
                           help="Keep the phase's evidence under a unique directory in a grouped job")
        if name == "build":
            phase.add_argument("component", choices=BUILD_COMPONENTS)
        if name == "check":
            phase.add_argument("group", choices=(*GROUPS, "fixtures", "public-api"))
            phase.add_argument("--clean-inputs", action="store_true",
                               help="Clear the selected compiled graphs before restoring the staged archives")
        if name in ("build", "check", "documentation"):
            phase.add_argument("--jobs", type=int, default=2)
    arguments = parser.parse_args(argv)
    repository, target = arguments.repository.resolve(), arguments.platform
    component, group = getattr(arguments, "component", None), getattr(arguments, "group", None)
    if target != "macos-arm64" and (component == "apple" or group == "public-api" or arguments.phase == "documentation"):
        parser.error("Apple compilation and public documentation require macos-arm64")
    if getattr(arguments, "jobs", 1) < 1:
        parser.error("--jobs must be positive")
    inputs, output = (repository / TEAMCITY_STATE / name for name in ("in", "out"))
    evidence = output / "evidence"
    if arguments.separate_evidence:
        evidence = evidence / arguments.phase
        if component or group:
            evidence = evidence / (component or group)
    report = {"status": "running", "phase": arguments.phase, "platform": target,
              "component": component, "group": group, "commands": []}
    try:
        if "TEAMCITY_VERSION" in os.environ or "DISCORDKIT_CI_BUILD_ID" in os.environ:
            os.environ.setdefault("DISCORDKIT_CI_REPOSITORY", "Aurum-Studios/DiscordKit")
        with native_jobs.execution_report(evidence / "invocation", report):
            revision, execution = verify_checkout(repository)
            report.update(revision=revision, execution=execution)
            if arguments.phase == "qualify":
                if execution["scope"] == "teamcity" and execution["qualificationID"] != execution["buildID"]:
                    raise ValueError("qualification provenance must use its own TeamCity build ID")
                qualify(repository, target, evidence)
            elif arguments.phase == "build":
                build(repository, target, component, arguments.jobs, output, evidence)
            elif arguments.phase == "check":
                if arguments.clean_inputs:
                    clean_check_outputs(repository, group)
                check(repository, target, group, arguments.jobs, inputs, output, evidence)
            elif arguments.phase == "documentation":
                linux_ci.native_preflight(repository, evidence / "host", target)
                documentation(repository, arguments.jobs, inputs, output, evidence)
            else:
                linux_ci.native_preflight(repository, evidence / "host", target)
                package_source.package_source(repository, output, target, execution=execution)
            if verify_checkout(repository) != (revision, execution):
                raise ValueError("TeamCity source or execution changed during native validation")
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError, tarfile.TarError) as error:
        print(f"Native CI phase failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
