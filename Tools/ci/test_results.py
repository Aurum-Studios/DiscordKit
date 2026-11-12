#!/usr/bin/env python3
# File: Tools/ci/test_results.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Reconcile Swift 6.4.1's structured runtime events with producer discovery.

Invoke ``swift test --skip-build --no-parallel --event-stream-version 6.4
--event-stream-output-path <absolute-path>``. The event file is independent of
human-readable output. SwiftPM's serial XCTest runner does not emit xUnit results:
XCTest discovery (method names without Swift function parentheses) fails closed
until a serial structured XCTest observer is implemented. All current repository
tests use Swift Testing.

SwiftPM discovery identifies a test *function*. Swift Testing's IDs append a
source-location component, removed here for that exact mapping. A nonparameterized
function emits testStarted/testEnded only. A parameterized function emits those
outer events plus testCaseStarted/testCaseEnded for every argument invocation.
Stable ABI 6.4 does not encode argument case identities or enumerate their expected
population. We therefore reconcile function leaves, require at least one complete
serial case for parameterized functions, and retain invocation counts. These are
not independently inventoried argument-value results. Repetitions are forbidden.

For execution (as distinct from ``swift test list``), Runner.Plan applies the
configured filter before constructing the step graph; Runner posts testDiscovered
only for that graph, and ABI.Record+Streaming encodes those as test definitions.
Unselected function definitions therefore indicate an incorrect filter too.

Pinned upstream evidence (the fixture tests below model these encodings):
https://github.com/swiftlang/swift-package-manager/blob/swift-6.4.1-RELEASE/Sources/Commands/SwiftTestCommand.swift
https://github.com/swiftlang/swift-testing/blob/swift-6.4.1-RELEASE/Documentation/ABI/JSON.md
https://github.com/swiftlang/swift-testing/blob/swift-6.4.1-RELEASE/Sources/Testing/Test.ID.swift
https://github.com/swiftlang/swift-testing/blob/swift-6.4.1-RELEASE/Sources/Testing/ABI/Encoded/ABI.EncodedEvent.swift
https://github.com/swiftlang/swift-testing/blob/swift-6.4.1-RELEASE/Sources/Testing/ABI/ABI.VersionNumber.swift
https://github.com/swiftlang/swift-testing/blob/swift-6.4.1-RELEASE/Sources/Testing/Running/Runner.Plan.swift
https://github.com/swiftlang/swift-testing/blob/swift-6.4.1-RELEASE/Sources/Testing/Running/Runner.swift
https://github.com/swiftlang/swift-testing/blob/swift-6.4.1-RELEASE/Sources/Testing/ABI/ABI.Record%2BStreaming.swift
"""

import json
from pathlib import Path
import re


FORMAT_VERSION = 1
# CLI selector "6.4" is accepted, but ABI.VersionNumber.encode writes three components.
EVENT_STREAM_VERSION = "6.4.0"
MAX_EVENT_BYTES = 128 * 1024 * 1024
MAX_LINE_BYTES = 1024 * 1024
SOURCE_SUFFIX = re.compile(r"/[^/]+:[1-9][0-9]*:[1-9][0-9]*$")
MODULE_PREFIX = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\.")
RESULT_KEYS = {"formatVersion", "status", "framework", "eventStreamVersion", "expectedLeaves",
               "executedLeaves", "excludedLeaves", "leaves", "counts", "runCount"}


def _identifier(value):
    if (not isinstance(value, str) or not value or not MODULE_PREFIX.match(value)
            or any(ord(character) < 32 for character in value)):
        raise ValueError("invalid test identifier")
    return value


def canonical_id(value):
    """Match SwiftPM discovery's function specifier, removing only a source suffix."""
    return SOURCE_SUFFIX.sub("", _identifier(value))


def _inventory(expected_tests, exclusions):
    if not isinstance(expected_tests, (list, tuple)) or not expected_tests:
        raise ValueError("expected test inventory must be nonempty")
    expected = [_identifier(identifier) for identifier in expected_tests]
    if len(expected) != len(set(expected)):
        raise ValueError("expected test inventory has duplicate leaves")
    if any(canonical_id(identifier) != identifier for identifier in expected):
        raise ValueError("expected inventory must contain discovery identifiers without source locations")
    if any(not identifier.endswith(")") for identifier in expected):
        raise ValueError("unsupported XCTest inventory: serial structured XCTest results are required")
    exclusions = {} if exclusions is None else exclusions
    if (not isinstance(exclusions, dict) or set(exclusions) - set(expected)
            or any(not isinstance(reason, str) or not reason.strip() for reason in exclusions.values())):
        raise ValueError("exclusions must name expected leaves with explicit nonempty reasons before execution")
    active = sorted(set(expected) - set(exclusions))
    if not active:
        raise ValueError("expected active test inventory must be nonempty")
    return active, dict(sorted(exclusions.items()))


def _integer(value):
    return type(value) is int


def validate_result(expected_tests, result, *, exclusions=None):
    """Independently verify a retained result against its selected producer inventory."""
    active, excluded = _inventory(expected_tests, exclusions)
    if (not isinstance(result, dict) or set(result) != RESULT_KEYS
            or type(result.get("formatVersion")) is not int or result.get("formatVersion") != FORMAT_VERSION
            or result.get("status") != "passed" or result.get("framework") != "swift-testing"
            or result.get("eventStreamVersion") != EVENT_STREAM_VERSION):
        raise ValueError("invalid or unsuccessful structured leaf result")
    if (result["expectedLeaves"] != active or result["executedLeaves"] != active
            or result["excludedLeaves"] != excluded):
        raise ValueError("structured leaf result does not match expected inventory and exclusions")
    leaves = result["leaves"]
    if not isinstance(leaves, dict) or set(leaves) != set(active):
        raise ValueError("structured leaf result has missing or unexpected leaves")
    cases = 0
    for identifier, leaf in leaves.items():
        if (not isinstance(leaf, dict) or set(leaf) != {"outcome", "parameterized", "caseCount"}
                or leaf.get("outcome") != "passed" or type(leaf.get("parameterized")) is not bool
                or not _integer(leaf.get("caseCount")) or leaf["caseCount"] < 1
                or (not leaf["parameterized"] and leaf["caseCount"] != 1)):
            raise ValueError(f"invalid structured leaf outcome or invocation count: {identifier}")
        cases += leaf["caseCount"]
    counts = {"expected": len(active), "executed": len(active), "passed": len(active),
              "excluded": len(excluded), "cases": cases}
    if (not isinstance(result["counts"], dict) or result["counts"] != counts
            or any(not _integer(value) for value in result["counts"].values())
            or not _integer(result["runCount"]) or result["runCount"] < 1):
        raise ValueError("structured leaf result counts do not reconcile")
    return result


def _object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON key in structured test event")
        value[key] = item
    return value


def _records(path):
    path = Path(path)
    if not path.is_file() or path.stat().st_size == 0:
        raise ValueError("missing or empty structured test event stream")
    if path.stat().st_size > MAX_EVENT_BYTES:
        raise ValueError("structured test event stream exceeds size limit")
    with path.open("rb") as stream:
        for number, raw in enumerate(stream, 1):
            if len(raw) > MAX_LINE_BYTES or not raw.endswith(b"\n") or not raw.strip():
                raise ValueError(f"invalid or truncated structured test event line {number}")
            try:
                record = json.loads(raw, object_pairs_hook=_object)
            except (ValueError, UnicodeError) as error:
                raise ValueError(f"invalid structured test event line {number}: {error}") from error
            if not isinstance(record, dict) or record.get("version") != EVENT_STREAM_VERSION:
                raise ValueError("structured test events require pinned ABI version 6.4")
            yield record


def reconcile(expected_tests, event_path, *, exclusions=None):
    """Fail closed on wrong selection, missing/duplicate execution, skips or failures."""
    active, excluded = _inventory(expected_tests, exclusions)
    selected = set(active) | set(excluded)
    definitions, functions, states, suites = {}, {}, {}, {}
    running = False
    run_count = 0

    for record in _records(event_path):
        kind, payload = record.get("kind"), record.get("payload")
        # The stable schema explicitly reserves unknown record kinds for extension.
        if kind not in ("test", "event"):
            continue
        if not isinstance(payload, dict):
            raise ValueError("structured test record requires an object payload")
        if kind == "test":
            raw_id = _identifier(payload.get("id"))
            if raw_id in definitions:
                raise ValueError("duplicate structured test definition")
            test_kind = payload.get("kind")
            if test_kind not in ("function", "suite"):
                raise ValueError("unknown structured test definition kind")
            definitions[raw_id] = payload
            if test_kind == "suite":
                suites[raw_id] = "pending"
                continue
            identifier = canonical_id(raw_id)
            if identifier not in selected:
                raise ValueError(f"unexpected structured test leaf (wrong filter): {identifier}")
            if identifier in functions:
                raise ValueError(f"duplicate discovered function mapping: {identifier}")
            if type(payload.get("isParameterized")) is not bool:
                raise ValueError("structured function is missing parameterization metadata")
            functions[identifier] = raw_id
            states[raw_id] = {"state": "pending", "parameterized": payload["isParameterized"],
                              "caseActive": False, "caseCount": 0}
            continue

        event = payload.get("kind")
        if event == "runStarted":
            if running:
                raise ValueError("duplicate or overlapping structured test run")
            running = True
            run_count += 1
            continue
        if not running:
            raise ValueError("structured test event outside a complete run")
        if event == "runEnded":
            if any(state["state"] == "running" for state in states.values()) or "running" in suites.values():
                raise ValueError("structured test run ended with unfinished leaves or suites")
            running = False
            continue
        if event == "issueRecorded":
            issue = payload.get("issue")
            if not isinstance(issue, dict) or type(issue.get("isFailure")) is not bool:
                raise ValueError("structured issue is missing its failure outcome")
            if issue["isFailure"]:
                raise ValueError("structured test stream recorded a failing issue")
            continue
        if event == "valueAttached":
            continue
        if event not in {"testStarted", "testEnded", "testCaseStarted", "testCaseEnded", "testSkipped",
                         "testCancelled", "testCaseCancelled"}:
            raise ValueError(f"unsupported structured test event: {event}")
        raw_id = payload.get("testID")
        if not isinstance(raw_id, str) or raw_id not in definitions:
            raise ValueError("structured event has no matching test definition")
        iteration = payload.get("iteration", 1)
        if not _integer(iteration) or iteration != 1:
            raise ValueError("duplicate test repetition is not permitted")
        if event in {"testCancelled", "testCaseCancelled"}:
            raise ValueError("structured test stream contains a cancelled test")
        if raw_id in suites:
            if event == "testSkipped":
                if suites[raw_id] != "pending" or any(
                    identifier.startswith(raw_id + "/") for identifier in active
                ):
                    raise ValueError("unexpected skipped suite contains expected active leaves")
                suites[raw_id] = "skipped"
            elif event == "testStarted" and suites[raw_id] == "pending":
                suites[raw_id] = "running"
            elif event == "testEnded" and suites[raw_id] == "running":
                suites[raw_id] = "passed"
            else:
                raise ValueError("duplicate or unpaired structured suite event")
            continue
        identifier = canonical_id(raw_id)
        state = states[raw_id]
        if event == "testSkipped":
            if identifier not in excluded or state["state"] != "pending":
                raise ValueError(f"unexpected skipped test leaf: {identifier}")
            state["state"] = "excluded"
            continue
        if identifier in excluded:
            raise ValueError(f"an inventory-excluded leaf executed: {identifier}")
        if event == "testStarted":
            if state["state"] != "pending":
                raise ValueError(f"duplicate test leaf execution: {identifier}")
            state["state"] = "running"
        elif event == "testEnded":
            if state["state"] != "running" or state["caseActive"]:
                raise ValueError("unpaired or unfinished structured test leaf")
            if state["parameterized"] and not state["caseCount"]:
                raise ValueError("parameterized test executed zero argument cases")
            state["state"] = "passed"
            if not state["parameterized"]:
                state["caseCount"] = 1
        elif event == "testCaseStarted":
            if state["state"] != "running" or not state["parameterized"] or state["caseActive"]:
                raise ValueError("duplicate or nonserial structured parameterized case")
            state["caseActive"] = True
        elif event == "testCaseEnded":
            if state["state"] != "running" or not state["caseActive"]:
                raise ValueError("unpaired structured parameterized case")
            state["caseActive"] = False
            state["caseCount"] += 1

    if running or not run_count:
        raise ValueError("structured test stream has no complete run boundary")
    missing = [identifier for identifier in active if identifier not in functions
               or states[functions[identifier]]["state"] != "passed"]
    if missing:
        raise ValueError("missing executed test leaves: " + ", ".join(missing))
    leaves = {identifier: {"outcome": "passed", "parameterized": states[functions[identifier]]["parameterized"],
                           "caseCount": states[functions[identifier]]["caseCount"]} for identifier in active}
    result = {"formatVersion": FORMAT_VERSION, "status": "passed", "framework": "swift-testing",
              "eventStreamVersion": EVENT_STREAM_VERSION, "expectedLeaves": active, "executedLeaves": active,
              "excludedLeaves": excluded, "leaves": leaves, "runCount": run_count,
              "counts": {"expected": len(active), "executed": len(active), "passed": len(active),
                         "excluded": len(excluded), "cases": sum(leaf["caseCount"] for leaf in leaves.values())}}
    return validate_result(expected_tests, result, exclusions=exclusions)
