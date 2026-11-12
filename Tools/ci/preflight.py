#!/usr/bin/env python3
# File: Tools/ci/preflight.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Run compiler-free source/workflow checks and bounded, shared helper groups.

This gate never evaluates a Swift manifest, resolves packages, builds native
tools or certifies native coverage. Native documentation/inventory/generation/
parity audits retain their producer dependencies in the platform workflow.
"""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

import linux_ci
import native_jobs
import scheduling_policy


REPOSITORY = Path(__file__).resolve().parents[2]
# Consolidate the short suites while keeping the larger CI/tooling inventories
# and Node provisioning separate. Each retained helper suite appears once.
GROUPS = {
    "ci-python": (("ci-python", "Tools/ci"),),
    "tooling-python": (("tooling-python", "Tools/DiscordKitTools/scripts"),
                       ("load-python", "Tools/DiscordKitLoadTests/scripts")),
    "benchmark-python": (("benchmarks-python", "Tools/DiscordDSLBenchmarks/scripts"),
                         ("timing-support-python", "Tools/DiscordBenchmarkSupport/scripts"),
                         ("foundation-timing-python", "Tools/DiscordFoundationBenchmarks/scripts")),
    "browser": (),
}
OPERATIONS = ("source", "workflow", "group")


def plan_commands(operation, repository, *, group=None, policy=None):
    """Require a nonempty, literal command inventory without invoking a compiler."""
    if operation not in OPERATIONS:
        raise ValueError(f"unknown preflight operation: {operation}")
    if operation == "group":
        if group not in GROUPS:
            raise ValueError(f"unknown preflight helper group: {group}")
    elif group is not None:
        raise ValueError("helper group is only valid for the group operation")
    repository = Path(repository).resolve()
    policy = policy if policy is not None else scheduling_policy.load_policy(
        repository / "Tools/ci/scheduling-policy.v1.json")
    scheduling_policy.validate_policy(policy)
    timeout = policy["deadlinesSeconds"]["localHelperCheck"]
    stage = f"preflight-{group or operation}"

    def command(name, *arguments):
        return linux_ci.Command(name, tuple(map(str, arguments)), timeout,
                                operation="localHelperCheck", stage=stage)

    if operation == "source":
        return [command("policy-source-inventory", sys.executable, "Tools/ci/scheduling_policy.py",
                        "validate", "--policy", repository / "Tools/ci/scheduling-policy.v1.json",
                        "--repository", repository),
                command("documentation-example-snapshots", sys.executable,
                        "Tools/ci/documentation_examples.py", "--repository", repository)]
    if operation == "workflow":
        workflows = sorted(str(path.relative_to(repository)) for pattern in ("*.yml", "*.yaml")
                           for path in (repository / ".github/workflows").glob(pattern) if path.is_file())
        if not workflows:
            raise ValueError("workflow source files are missing")
        return [command("actionlint", "actionlint", *workflows)]
    if group == "browser":
        tests = sorted(str(path.relative_to(repository)) for path in
                       (repository / "Browser/DiscordActivityBridge").glob("*.test.mjs") if path.is_file())
        if not tests:
            raise ValueError("browser bridge tests are missing")
        return [command("browser", "node", "--test", *tests)]
    planned = []
    for name, directory in GROUPS[group]:
        if not any(path.is_file() for path in (repository / directory).glob("test_*.py")):
            raise ValueError(f"Python helper tests are missing: {directory}")
        planned.append(command(name, sys.executable, "-m", "unittest", "discover",
                               "-s", directory, "-p", "test_*.py"))
    return planned


def run_checks(operation, repository, output, *, group=None):
    """Preserve planning/command failures and cap the entire group to one helper budget."""
    repository, output = Path(repository).resolve(), Path(output).resolve()
    report = {"schemaVersion": 1, "stage": "preflight", "operation": operation,
              "group": group, "status": "running", "certifying": False,
              "repository": str(repository), "commands": []}
    with native_jobs.execution_report(output, report):
        policy = scheduling_policy.load_policy(repository / "Tools/ci/scheduling-policy.v1.json")
        planned = plan_commands(operation, repository, group=group, policy=policy)
        aggregate = policy["deadlinesSeconds"]["localHelperCheck"]
        report.update(aggregateSeconds=aggregate, deadlineMonotonic=time.monotonic() + aggregate)
        native_jobs.execute_commands(planned, repository, output, report,
                                     deadline=report["deadlineMonotonic"])
    return report


def main(argv=None):
    """Return failure for missing suites, malformed source, failed children or timeouts."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=OPERATIONS)
    parser.add_argument("--repository", type=Path, default=REPOSITORY)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--group", choices=GROUPS)
    arguments = parser.parse_args(argv)
    try:
        result = run_checks(arguments.operation, arguments.repository, arguments.output,
                            group=arguments.group)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"preflight failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"status": result["status"], "operation": arguments.operation,
                      "group": arguments.group, "certifying": False}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
