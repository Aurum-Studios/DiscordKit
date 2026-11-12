#!/usr/bin/env python3
# File: Tools/ci/scheduling_policy.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Read the Phase 0 policy without scheduling work or authorizing spending.

This is a shared planning/accounting interface for later phases, not Phase 10
admission. Existing workflows do not read it. Native build/suite scope comes from
native_jobs.matrices; it is deliberately not presented as an entire workflow or
cost plan. Root targets are anchored to the retained manifest bytes. Evaluated
SwiftPM inventory, discovered test leaves, shared gates and documentation remain
separate evidence. Published list rates do not prove account runner mappings.
"""

import argparse
from datetime import date, datetime, timezone
from decimal import Decimal, InvalidOperation, ROUND_CEILING
import hashlib
import json
from pathlib import Path
import re
import sys

import native_jobs


DEFAULT_POLICY = Path(__file__).with_name("scheduling-policy.v1.json")
REPOSITORY = Path(__file__).resolve().parents[2]
MODES = ("preflight", "diagnostic", "full")
PLATFORMS = ("linux-x64", "macos-arm64")
DEADLINES = {"discovery", "focusedTest", "suite", "wholeLoadPackage", "timingSmoke",
             "debuggerProbe", "coldCompileCommand", "transportAttempt", "transportTotal", "localHelperCheck"}
ROOT_TARGET = re.compile(r'\.testTarget\(\s*name:\s*"([A-Za-z_][A-Za-z0-9_]*)"')


def require(condition, message):
    """Raise ValueError with policy context when an invariant is false."""
    if not condition:
        raise ValueError(message)


def integer(value, name, minimum=1):
    """Reject booleans, fractional values and integers below the named bound."""
    require(type(value) is int and value >= minimum, f"{name} must be an integer >= {minimum}")
    return value


def dollars(value, name):
    """Parse a finite nonnegative decimal string or raise ValueError."""
    require(isinstance(value, str), f"{name} must be a decimal string")
    try:
        amount = Decimal(value)
    except InvalidOperation as error:
        raise ValueError(f"{name} must be a decimal string") from error
    require(amount.is_finite() and amount >= 0, f"{name} must be finite and nonnegative")
    return amount


def iso_date(value, name):
    """Parse a canonical ISO calendar date or raise ValueError."""
    require(isinstance(value, str), f"{name} must be an ISO date")
    try:
        parsed = date.fromisoformat(value)
    except ValueError as error:
        raise ValueError(f"{name} must be an ISO date") from error
    require(parsed.isoformat() == value, f"{name} must be an ISO date")
    return parsed


def unique_names(values, name):
    """Reject empty, duplicate or non-string inventory entries."""
    require(isinstance(values, list) and values and all(isinstance(item, str) for item in values),
            f"{name} must be a nonempty name list")
    require(len(values) == len(set(values)), f"{name} contains duplicates")


def _validate_policy(policy):
    """Validate the versioned contract, including fail-closed Phase 0 allowances."""
    require(isinstance(policy, dict), "policy must be an object")
    expected = {"schemaVersion", "policyID", "status", "modes", "platforms", "excludedPlatforms",
                "inventory", "dependencies", "deadlinesSeconds", "componentCompileSeconds",
                "reservesSeconds", "jobSeconds", "concurrency", "retentionDays", "attempts",
                "billing", "runnerRates", "allowances", "bootstrap", "limits"}
    require(set(policy) == expected, "policy fields do not match schema version 1")
    require(type(policy["schemaVersion"]) is int and policy["schemaVersion"] == 1,
            "unsupported scheduling policy version")
    require(policy["policyID"] == "ci-reliability-phase-0-v1", "unsupported policy identity")
    require(policy["modes"] == {mode: {"certifying": mode == "full"} for mode in MODES},
            "mode certification contract changed")
    require(policy["platforms"] == list(PLATFORMS), "unsupported platform scope")
    require(set(policy["excludedPlatforms"]) == {"windows-x64"}, "Windows must remain excluded")
    inventory = policy["inventory"]
    require(inventory["rootManifest"] == "Package.swift", "unsupported root inventory source")
    require(isinstance(inventory["rootManifestSHA256"], str)
            and re.fullmatch(r"[0-9a-f]{64}", inventory["rootManifestSHA256"]), "invalid manifest digest")
    unique_names(inventory["rootTargets"], "root targets")
    require(all(native_jobs.IDENTIFIER.fullmatch(name) for name in inventory["rootTargets"]),
            "unsupported root target")
    unique_names(inventory["components"], "components")
    unique_names(inventory["consumerSuites"], "consumer suites")
    require(set(policy["componentCompileSeconds"]) == set(inventory["components"]),
            "component budgets must cover the inventory exactly")
    require(policy["dependencies"] == {"platform": [], "plan": ["platform"],
            "build": ["plan"], "test": ["plan", "build"]}, "unsupported native stage dependencies")
    deadlines = policy["deadlinesSeconds"]
    require(set(deadlines) == DEADLINES, "operation deadlines must be complete")
    for name, value in deadlines.items():
        integer(value, name)
    require(deadlines["discovery"] <= deadlines["focusedTest"] <= deadlines["suite"]
            <= deadlines["wholeLoadPackage"], "test deadlines are inconsistent")
    require(deadlines["debuggerProbe"] < deadlines["focusedTest"], "probe exceeds test deadline")
    reserves = policy["reservesSeconds"]
    require(set(reserves) == {"setup", "diagnostics", "cleanup", "upload"}, "missing paid-time reserve")
    for name, value in reserves.items():
        integer(value, f"{name} reserve")
    reserve = sum(reserves.values())
    require(set(policy["jobSeconds"]) == {"focusedTest", "suite", "wholeLoadPackage"},
            "missing enclosing job budget")
    for name, value in policy["jobSeconds"].items():
        integer(value, f"{name} job deadline")
        require(value >= deadlines[name] + reserve, f"{name} job deadline omits reserves")
    for name, value in policy["componentCompileSeconds"].items():
        integer(value, f"{name} aggregate compilation")
    require(set(policy["concurrency"]) == {"buildsPerPlatform", "runtimeGroupsPerPlatform",
            "compilerJobsPerProcess"}, "missing concurrency bounds")
    for name, value in policy["concurrency"].items():
        integer(value, name)
    require(set(policy["retentionDays"]) == {"compiledArtifacts", "diagnosticArtifacts", "baselineArtifacts"},
            "missing artifact retention")
    for name, value in policy["retentionDays"].items():
        integer(value, name)
        require(value <= 90, "artifact retention exceeds initial policy limit")
    attempts = policy["attempts"]
    require(set(attempts) == {"testProcessesPerExperiment", "transportPerOperation", "workflowMaximum"},
            "missing attempt limits")
    for name, value in attempts.items():
        integer(value, name)
    require(attempts["testProcessesPerExperiment"] <= 2, "diagnostic experiments allow at most two test processes")
    require(attempts["transportPerOperation"] <= 3, "transport allows at most three attempts")
    require(deadlines["transportTotal"] >= deadlines["transportAttempt"] * attempts["transportPerOperation"],
            "transport aggregate omits permitted attempts")
    billing = policy["billing"]
    require(billing["currency"] == "USD" and billing["rounding"] == "ceil-each-job-minute",
            "unsupported billing contract")
    integer(billing["rateMaxAgeDays"], "maximum rate age")
    require(isinstance(policy["runnerRates"], dict) and policy["runnerRates"], "runner rates are required")
    for group, rate in policy["runnerRates"].items():
        require(isinstance(group, str) and rate["platform"] in PLATFORMS, "invalid runner rate scope")
        require(type(rate["billingMappingVerified"]) is bool, "runner mapping assurance must be explicit")
        require(isinstance(rate["sku"], str) and rate["sku"], "missing runner SKU")
        require(isinstance(rate["mappingAssurance"], str) and rate["mappingAssurance"], "missing mapping assurance")
        if rate["usdPerMinute"] is None:
            require(rate["verifiedOn"] is None and not rate["billingMappingVerified"],
                    "unknown rate cannot claim verification")
        else:
            require(dollars(rate["usdPerMinute"], group) > 0, "runner list rate must be positive")
            iso_date(rate["verifiedOn"], group)
            require(rate["sourceURL"].startswith("https://docs.github.com/"), "rate needs an official source")
    allowances = policy["allowances"]
    require(set(allowances) == {"experimentUSD", "workflowUSD", "safetyUSD", "maximumPaidJobs",
            "maximumPaidMinutes", "maximumPaidAttempts"}, "missing allowances")
    for name in ("experimentUSD", "workflowUSD", "safetyUSD"):
        require(dollars(allowances[name], name) == 0, "Phase 0 has no paid allowance")
    for name in ("maximumPaidJobs", "maximumPaidMinutes", "maximumPaidAttempts"):
        require(integer(allowances[name], name, 0) == 0, "Phase 0 authorizes no paid work")
    bootstrap = policy["bootstrap"]
    require(bootstrap["authorization"] == "local-helper-checks-only"
            and bootstrap["nativeExecutionAuthorized"] is False
            and type(bootstrap["localNativeTestAttempts"]) is int and bootstrap["localNativeTestAttempts"] == 0
            and type(bootstrap["localNativeCompilations"]) is int and bootstrap["localNativeCompilations"] == 0,
            "bootstrap authorizes only local helpers")
    future = bootstrap["futureDiagnostic"]
    require(future["authorized"] is False and future["platform"] == "linux-x64"
            and future["component"] == "load" and future["suite"] == "load", "unsupported future probe scope")
    require(future["maximumTestProcessAttempts"] == attempts["testProcessesPerExperiment"]
            and future["testProcessSeconds"] == deadlines["focusedTest"]
            and future["coldCompileCommandSeconds"] == deadlines["coldCompileCommand"],
            "bootstrap limits diverge from shared policy")
    return policy


def validate_policy(policy):
    """Validate schema and invariants, exposing malformed input as ValueError."""
    try:
        return _validate_policy(policy)
    except (KeyError, TypeError, AttributeError) as error:
        raise ValueError(f"malformed scheduling policy: {error}") from error


def load_policy(path=DEFAULT_POLICY):
    """Read JSON from the selected path and validate its versioned contract."""
    try:
        return validate_policy(json.loads(Path(path).read_text()))
    except (KeyError, TypeError, AttributeError) as error:
        raise ValueError(f"malformed scheduling policy: {error}") from error


def validate_source_inventory(policy, repository=REPOSITORY):
    """Reject source drift without invoking Swift, resolution, compilation or discovery.

    The manifest hash is essential: the small literal-name check below is not a
    general Swift parser. A changed manifest requires reviewed inventory refresh
    and later evaluated SwiftPM/discovery reconciliation, even for a benign edit.
    """
    validate_policy(policy)
    manifest = (Path(repository) / policy["inventory"]["rootManifest"]).read_bytes()
    require(hashlib.sha256(manifest).hexdigest() == policy["inventory"]["rootManifestSHA256"],
            "root manifest changed; refresh and review the inventory")
    targets = ROOT_TARGET.findall(manifest.decode())
    require(targets and len(targets) == len(set(targets)), "manifest target inventory is empty or duplicated")
    require(sorted(targets) == policy["inventory"]["rootTargets"], "root target inventory drift")
    inventory = policy["inventory"]
    require(inventory["components"] == list(native_jobs.COMPONENTS), "planner component inventory drift")
    require(inventory["packageSuites"] == {component: component for component in
            ("macros", "extensions", "tooling", "load", "benchmarks", *native_jobs.TIMING_PACKAGES)},
            "planner package suite inventory drift")
    require(inventory["consumerSuites"] == list(native_jobs.CONSUMER_SUITES), "planner consumer inventory drift")
    require(inventory["plannerSource"] == "Tools/ci/native_jobs.py", "unsupported planner source")
    for component in native_jobs.COMPONENTS:
        command_count = len(native_jobs.compile_commands(component, policy["concurrency"]["compilerJobsPerProcess"]))
        require(policy["componentCompileSeconds"][component] >=
                command_count * policy["deadlinesSeconds"]["coldCompileCommand"],
                f"{component} aggregate compilation budget omits commands")
    for platform in PLATFORMS:
        for large in (False, True):
            group = native_jobs.runner_entry(platform, large)["group"]
            require(group in policy["runnerRates"] and policy["runnerRates"][group]["platform"] == platform,
                    f"planner runner group drift: {group}")
    return {"rootTargets": len(targets), "components": len(native_jobs.COMPONENTS),
            "inventoryLevel": inventory["level"], "evaluatedSwiftPM": False, "discoveredTestLeaves": False}


def plan_scope(policy, mode, *, platform=None, component=None, suite=None, repository=REPOSITORY):
    """Describe existing native build/suite scope; never execute or certify it.

    Full mode forbids filters. Diagnostic mode requires one platform/component;
    a suite selects one consumer and its one producer, omission selects only the
    producer. This intentionally does not implement Phase 6 workflow selection.
    """
    validate_source_inventory(policy, repository)
    require(mode in MODES, "unsupported mode")
    if mode in ("preflight", "full"):
        require(platform is None and component is None and suite is None,
                f"{mode} mode does not accept native filters")
    if mode == "diagnostic":
        require(platform in policy["platforms"], "diagnostic requires one supported platform")
        require(component in policy["inventory"]["components"], "diagnostic requires one known component")
    if mode == "preflight":
        builds, tests = [], []
    else:
        builds, tests = [], []
        for selected_platform in (platform,) if platform else policy["platforms"]:
            build_matrix, test_matrix = native_jobs.matrices(policy["inventory"]["rootTargets"], selected_platform)
            builds.extend(build_matrix["include"])
            tests.extend(test_matrix["include"])
        if mode == "diagnostic":
            builds = [entry for entry in builds if entry["component"] == component]
            tests = [entry for entry in tests if entry["component"] == component and entry["suite"] == suite]
            require(suite is None or tests, "suite is not scheduled for the selected component/platform")
        for entry in builds:
            entry["id"] = f"build/{entry['platform']}/{entry['component']}"
            entry["needs"] = ["plan"]
        for entry in tests:
            entry["needs"] = list(policy["dependencies"]["test"])
            entry["artifactProducer"] = f"build/{entry['platform']}/{entry['component']}"
    return {"policyID": policy["policyID"], "mode": mode, "nativeBuilds": builds,
            "nativeSuites": tests, "executionAuthorized": False, "certificationEstablished": False,
            "completeWorkflowCostPlan": False, "limits": policy["limits"]}


def billed_minutes(seconds):
    """Round each started job independently; never round combined elapsed time."""
    require(isinstance(seconds, (int, float, Decimal)) and not isinstance(seconds, bool),
            "job duration must be numeric")
    value = Decimal(str(seconds))
    require(value.is_finite() and value >= 0, "job duration must be finite and nonnegative")
    return int((value / 60).to_integral_value(rounding=ROUND_CEILING))


def runner_rate(policy, group, *, as_of=None, require_verified_mapping=True):
    """Return a dated USD rate; paid planning rejects unverified account mappings."""
    validate_policy(policy)
    require(group in policy["runnerRates"], f"unknown runner group: {group}")
    rate = policy["runnerRates"][group]
    require(rate["usdPerMinute"] is not None, f"unknown runner rate: {group}")
    today = datetime.now(timezone.utc).date() if as_of is None else as_of
    require(type(today) is date, "rate comparison requires a date")
    age = (today - iso_date(rate["verifiedOn"], group)).days
    require(0 <= age <= policy["billing"]["rateMaxAgeDays"], f"stale or future runner rate: {group}")
    require(not require_verified_mapping or rate["billingMappingVerified"],
            f"runner billing mapping is unverified: {group}")
    return dollars(rate["usdPerMinute"], group)


def estimate_runner_cost(policy, jobs, *, as_of=None, require_verified_mapping=True):
    """Pure maximum runner-time arithmetic, never an execution admission decision.

    Callers must provide every job including startup/cleanup/upload and repeated
    attempts. Storage, transfer and missing workflow jobs are not priced here.
    Passing require_verified_mapping=False gives a labelled list-price estimate.
    Phase 10 must add complete exact-planner coverage and central reservations.
    """
    validate_policy(policy)
    records, total = [], Decimal(0)
    for job in jobs:
        require(set(job) == {"group", "maximumSeconds", "attempts"}, "invalid bounded job estimate")
        attempts = integer(job["attempts"], "job attempts")
        minutes = billed_minutes(job["maximumSeconds"])
        require(minutes > 0, "paid job must reserve positive startup time")
        rate = runner_rate(policy, job["group"], as_of=as_of,
                           require_verified_mapping=require_verified_mapping)
        cost = rate * minutes * attempts
        records.append({**job, "billedMaximumMinutes": minutes * attempts, "runnerCostUSD": str(cost)})
        total += cost
    return {"jobs": records, "runnerCostUSD": str(total), "executionAuthorized": False,
            "pricingAssurance": "billing-mapping-verified" if require_verified_mapping else "published-list-price-only",
            "includesStorageAndTransfer": False, "completeWorkflowCostPlan": False,
            "experimentAllowanceUSD": policy["allowances"]["experimentUSD"],
            "workflowAllowanceUSD": policy["allowances"]["workflowUSD"]}


def describe_bootstrap(policy):
    """Return the reviewed local scope and zero paid reservation for this phase."""
    validate_policy(policy)
    return {"policyID": policy["policyID"], "bootstrap": policy["bootstrap"],
            "allowances": policy["allowances"], "limits": policy["limits"]}


def main(argv=None):
    """Print local policy/scope descriptions; return nonzero for rejected input."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("validate", "show", "scope", "bootstrap"))
    parser.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    parser.add_argument("--repository", type=Path, default=REPOSITORY)
    parser.add_argument("--mode", choices=MODES, default="preflight")
    parser.add_argument("--platform")
    parser.add_argument("--component")
    parser.add_argument("--suite")
    arguments = parser.parse_args(argv)
    try:
        policy = load_policy(arguments.policy)
        if arguments.operation == "validate":
            result = {"status": "valid", **validate_source_inventory(policy, arguments.repository)}
        elif arguments.operation == "show":
            result = policy
        elif arguments.operation == "bootstrap":
            result = describe_bootstrap(policy)
        else:
            result = plan_scope(policy, arguments.mode, platform=arguments.platform,
                component=arguments.component, suite=arguments.suite, repository=arguments.repository)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f"scheduling policy rejected: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
