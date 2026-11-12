#!/usr/bin/env python3
# File: Tools/ci/qualification_fault.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Fail one completed diagnostic consumer on attempt one, using local evidence only.

Ordinary native tests must finish successfully before this step. The helper never
compiles, runs tests, contacts GitHub, or retries. A later workflow attempt still
has to execute and validate the ordinary selected suite before this step passes.
"""

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import sys

import artifact_index
import native_receipts as receipts
import workflow_coverage


ROOT = Path(__file__).resolve().parents[2]
MAX_RECEIPT_BYTES = 16 * 1024 * 1024
SCOPE = {"mode": "diagnostic", "platform": "linux-x64", "component": "root",
         "suite": "DiscordBitsTests", "publication": False}
CONSUMER_KEYS = {"execution", "selectedProducer", "selectedProducerReceipt", "artifact", "selection",
                 "compatibilityVerified", "discovery", "selectedScope", "startedAt", "status",
                 "inventorySHA256", "completedAt", "executionResults"}
SELECTION_KEYS = {"indexSHA256", "resolverExecution", "consumerExecution", "sourceCommit", "platform",
                  "component", "producerAttempt"}


def validate_selection(*, enabled, mode, platform, component, suite, publication):
    """Permit the fault only for the single explicitly authorized diagnostic scope."""
    if type(enabled) is not bool:
        raise ValueError("qualification fault enabled must be boolean")
    if enabled and (type(publication) is not bool or publication
            or (mode, platform, component, suite) != (
                SCOPE["mode"], SCOPE["platform"], SCOPE["component"], SCOPE["suite"])):
        raise ValueError("qualification fault requires diagnostic linux-x64 root DiscordBitsTests without publication")
    return enabled


def boolean(value, name):
    """Accept the workflow's explicit boolean strings without Python truth coercion."""
    if value not in ("true", "false", ""):
        raise ValueError(f"{name} must be true or false")
    return value == "true"


def read_receipt(path):
    """Bound every local read and reject malformed or ambiguous JSON."""
    path = Path(path)
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= MAX_RECEIPT_BYTES:
        raise ValueError(f"missing, empty, linked or oversized qualification receipt: {path.name}")
    with path.open() as stream:
        return receipts.read_json(stream)


def completed_timestamps(value):
    """Reject incomplete or reversed consumer execution timestamps."""
    try:
        started = datetime.fromisoformat(value["startedAt"].replace("Z", "+00:00"))
        completed = datetime.fromisoformat(value["completedAt"].replace("Z", "+00:00"))
        if started.utcoffset() is None or completed.utcoffset() is None or completed < started:
            raise ValueError("invalid timestamps")
    except (AttributeError, KeyError, TypeError, ValueError) as error:
        raise ValueError("qualification requires completed consumer timestamps") from error


def validate_consumer(consumer, coverage, restored, *, execution, source_commit):
    """Bind the completed consumer, selected producer and actual leaf results together."""
    receipts.validate_execution(execution)
    if execution["scope"] != "github" or execution["jobID"] != "tests-root":
        raise ValueError("qualification fault requires a hosted tests-root consumer")
    if not isinstance(source_commit, str) or not receipts.SHA1.fullmatch(source_commit):
        raise ValueError("qualification fault requires the current GITHUB_SHA")
    receipts.object_keys(consumer, CONSUMER_KEYS, "qualification consumer")
    if (receipts.digest(consumer["execution"]) != receipts.digest(execution)
            or consumer["status"] != "passed" or consumer["compatibilityVerified"] is not True
            or consumer["discovery"] != "passed"):
        raise ValueError("qualification requires this attempt's successful completed consumer")
    completed_timestamps(consumer)
    if not isinstance(restored, dict):
        raise ValueError("qualification requires restored native metadata")
    metadata = {key: value for key, value in restored.items() if key not in {"archiveSHA256", "consumer"}}
    artifact_index.validate_native_metadata(metadata, execution, "root", "linux-x64", source_commit)
    if metadata["buildRoots"] != [".build"]:
        raise ValueError("qualification root producer build roots differ")
    producer = metadata["producer"]
    if (receipts.digest(consumer["selectedProducer"]) != receipts.digest(producer["execution"])
            or receipts.digest(consumer["selectedProducerReceipt"]) != receipts.digest(producer)):
        raise ValueError("qualification consumer selected producer differs from restored metadata")
    original = restored.get("consumer")
    if not isinstance(original, dict) or any(receipts.digest(original.get(key)) != receipts.digest(consumer[key])
            for key in {"execution", "selectedProducer", "selectedProducerReceipt", "artifact", "selection"}):
        raise ValueError("qualification consumer differs from the original restored selection")
    artifact = consumer["artifact"]
    receipts.object_keys(artifact, {"id", "idSource", "archiveSHA256", "apiDigest", "name", "receiptArtifactID"},
                         "qualification immutable artifact")
    if (artifact["idSource"] != "verified-artifact-index"
            or not isinstance(artifact["id"], str) or not artifact_index.positive_id(artifact["id"])
            or not isinstance(artifact["receiptArtifactID"], str)
            or not artifact_index.positive_id(artifact["receiptArtifactID"])
            or not isinstance(artifact["archiveSHA256"], str)
            or not receipts.SHA256.fullmatch(artifact["archiveSHA256"])
            or artifact["archiveSHA256"] != restored.get("archiveSHA256")
            or not isinstance(artifact["apiDigest"], str)
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", artifact["apiDigest"])):
        raise ValueError("qualification requires immutable restored artifact identity")
    prefix = artifact_index.artifact_prefix("linux-x64", "root", source_commit, producer["execution"])
    if not isinstance(artifact["name"], str) or not re.fullmatch(re.escape(prefix) + r"-t[1-3]", artifact["name"]):
        raise ValueError("qualification artifact source or producer attempt differs")
    selection = consumer["selection"]
    receipts.object_keys(selection, SELECTION_KEYS, "qualification resolver selection")
    if (not isinstance(selection["indexSHA256"], str) or not receipts.SHA256.fullmatch(selection["indexSHA256"])
            or receipts.digest(selection["consumerExecution"]) != receipts.digest(execution)
            or selection["sourceCommit"] != source_commit or selection["platform"] != "linux-x64"
            or selection["component"] != "root"
            or selection["producerAttempt"] != producer["execution"]["runAttempt"]):
        raise ValueError("qualification requires current-attempt exact-source resolver selection")
    artifact_index.same_execution(selection["resolverExecution"], execution)
    if selection["resolverExecution"]["jobID"] != "tests-root":
        raise ValueError("qualification resolver must run in the current consumer job")
    receipts.object_keys(consumer["selectedScope"], {"component", "suite"}, "qualification selected scope")
    if not isinstance(coverage, dict) or not isinstance(coverage.get("suite"), str):
        raise ValueError("qualification requires completed group coverage")
    group = coverage["suite"]
    if (group != "DiscordBitsTests"
            or consumer["selectedScope"] != {"component": "root", "suite": group}
            or consumer["inventorySHA256"] != receipts.digest(metadata["tests"])):
        raise ValueError("qualification consumer scope or discovered inventory differs")
    scope = {"platform": "linux-x64", "component": "root", "suite": group,
             "suites": ["DiscordBitsTests"], "jobID": "tests-root"}
    workflow_coverage.validate_group_receipt(coverage, scope=scope, manifest={"commit": source_commit},
        metadata=metadata, execution=execution, job_attempt=execution["runAttempt"])
    commands = consumer["executionResults"]
    if (not isinstance(commands, list) or len(commands) < 2
            or any(not isinstance(command, dict) or command.get("status") != "passed" for command in commands)):
        raise ValueError("qualification requires successful discovery and suite command receipts")
    discovery, tests = commands[:2]
    if any(command.get("operation") != "metadata" for command in commands[2:]):
        raise ValueError("qualification permits only final identity queries after selected tests")
    for command in (discovery, tests):
        arguments = command.get("arguments")
        if (not isinstance(arguments, list) or not all(isinstance(value, str) for value in arguments)
                or arguments[:2] != ["swift", "test"] or "--skip-build" not in arguments
                or "--package-path" not in arguments
                or arguments[arguments.index("--package-path") + 1:arguments.index("--package-path") + 2] != ["."]):
            raise ValueError("qualification command was not restored root test execution")
    test_arguments = tests["arguments"]
    if ("list" not in discovery["arguments"] or "list" in test_arguments or "--no-parallel" not in test_arguments
            or test_arguments.count("--filter") != 1
            or test_arguments[test_arguments.index("--filter") + 1:test_arguments.index("--filter") + 2]
                != ["^DiscordBitsTests[./]"]):
        raise ValueError("qualification requires exact selected suite execution after discovery")
    return producer["execution"]


def marker(consumer_directory, *, execution, source_commit):
    """Return proof only after all local native receipts have passed validation."""
    directory = Path(consumer_directory)
    consumer = read_receipt(directory / "consumer.json")
    coverage = read_receipt(directory / "group-coverage.json")
    restored = read_receipt(directory / "restored.json")
    producer = validate_consumer(consumer, coverage, restored, execution=execution, source_commit=source_commit)
    intentional = execution["runAttempt"] == "1"
    return {"formatVersion": 1, "kind": "diagnostic-consumer-fault",
            "status": "intentional-failure" if intentional else "passed", "intentionalFailure": intentional,
            "execution": execution, "sourceCommit": source_commit, "scope": dict(SCOPE),
            "producerExecution": producer, "consumerSHA256": receipts.digest(consumer),
            "coverageSHA256": receipts.digest(coverage)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--consumer", type=Path, required=True, help="completed native test output directory")
    parser.add_argument("--output", type=Path, required=True, help="dedicated qualification marker JSON")
    parser.add_argument("--repository", type=Path, default=ROOT)
    arguments = parser.parse_args(argv)
    try:
        protected = {arguments.consumer / name for name in (
            "consumer.json", "group-coverage.json", "restored.json", "restored-root.json", "commands.json")}
        if arguments.output.resolve() in {path.resolve() for path in protected}:
            raise ValueError("qualification marker cannot overwrite a native receipt")
        # Rejected scope or receipts must not leave an earlier invocation's proof.
        arguments.output.unlink(missing_ok=True)
        selected = {key: os.environ.get("ADMISSION_" + key.upper(), "")
                    for key in ("mode", "platform", "component", "suite")}
        enabled = boolean(os.environ.get("ADMISSION_QUALIFICATION_FAULT", ""), "qualification fault")
        if not validate_selection(enabled=enabled, **selected,
                publication=boolean(os.environ.get("ADMISSION_PUBLICATION", ""), "publication")):
            raise ValueError("qualification fault is not enabled")
        execution = receipts.execution_identity(arguments.repository)
        report = marker(arguments.consumer, execution=execution, source_commit=os.environ.get("GITHUB_SHA", ""))
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        temporary = arguments.output.with_suffix(arguments.output.suffix + ".tmp")
        temporary.write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")
        temporary.replace(arguments.output)
        if report["intentionalFailure"]:
            print("Intentional first-attempt diagnostic consumer failure after complete DiscordBitsTests execution.",
                  file=sys.stderr)
            return 1
        print("Diagnostic consumer qualification marker passed after complete DiscordBitsTests execution.")
        return 0
    except (ValueError, OSError, KeyError, TypeError, IndexError) as error:
        print(f"Qualification fault rejected: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
