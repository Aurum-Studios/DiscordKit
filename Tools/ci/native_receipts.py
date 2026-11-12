#!/usr/bin/env python3
# File: Tools/ci/native_receipts.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Version 2 native contracts with explicit immutable selection for producer reuse.

Default admission stays same-run and same-attempt. Only a complete resolver index
may authorize a successful earlier producer from this run and exact revision.
"""

from datetime import datetime, timezone
import copy
import hashlib
import json
import os
from pathlib import Path
import re


VERSION = 2
EXECUTION_KEYS = {"scope", "repository", "repositoryID", "workflowRef", "workflowSHA", "runID",
                  "runAttempt", "jobID", "event", "ref", "headRef", "baseRef"}
IDENTITY_KEYS = {"commit", "sourceSHA256", "dependencyPinsSHA256", "repository", "platform", "system",
                 "machine", "swiftVersion", "swiftTarget", "buildSystem", "runtime", "buildEnvironment"}
SHA256 = re.compile(r"[0-9a-f]{64}")
SHA1 = re.compile(r"[0-9a-f]{40}")


def object_keys(value, keys, name):
    """Reject omitted and unknown required schema fields rather than ignoring them."""
    if not isinstance(value, dict) or set(value) != set(keys):
        raise ValueError(f"invalid {name} fields; regenerate the native artifact")


def digest(value):
    """Bind structured inventories using one unambiguous canonical serialization."""
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     allow_nan=False).encode()).hexdigest()


def read_json(stream):
    """Do not let duplicate keys or nonfinite numbers disguise required identity facts."""
    def pairs(entries):
        result = {}
        for key, value in entries:
            if key in result:
                raise ValueError("duplicate native receipt JSON key")
            result[key] = value
        return result

    def invalid(value):
        raise ValueError(f"invalid native receipt JSON constant: {value}")

    return json.load(stream, object_pairs_hook=pairs, parse_constant=invalid)


def validate_execution(execution):
    """Require explicit local scope or complete GitHub workflow/event provenance."""
    object_keys(execution, EXECUTION_KEYS, "execution identity")
    if any(not isinstance(value, str) or "\0" in value for value in execution.values()):
        raise ValueError("execution identity values must be strings")
    if execution["scope"] == "local":
        if (not Path(execution["repository"]).is_absolute()
                or any(execution[key] != "local" for key in EXECUTION_KEYS
                       - {"scope", "repository", "ref", "headRef", "baseRef"})
                or any(execution[key] for key in ("ref", "headRef", "baseRef"))):
            raise ValueError("invalid local producer scope")
    elif execution["scope"] == "github":
        repository = execution["repository"]
        if (not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)
                or not execution["workflowRef"].startswith(repository + "/.github/workflows/")
                or not re.fullmatch(r"[^@]+@refs/\S+", execution["workflowRef"])
                or not SHA1.fullmatch(execution["workflowSHA"])
                or any(not re.fullmatch(r"[1-9][0-9]*", execution[key])
                       for key in ("repositoryID", "runID", "runAttempt"))
                or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*", execution["jobID"])
                or execution["event"] not in ("push", "pull_request", "workflow_dispatch", "workflow_call")
                or not execution["ref"].startswith("refs/")):
            raise ValueError("invalid GitHub producer scope")
        if execution["event"] == "pull_request":
            if (not re.fullmatch(r"refs/pull/[1-9][0-9]*/merge", execution["ref"])
                    or not execution["headRef"] or not execution["baseRef"]):
                raise ValueError("invalid pull-request trust scope")
        elif execution["headRef"] or execution["baseRef"]:
            raise ValueError("unexpected pull-request trust scope")
    else:
        raise ValueError("unknown producer trust scope")


def execution_identity(repository):
    """Never downgrade an incomplete hosted environment to an implicitly trusted local run."""
    variables = {"repository": "GITHUB_REPOSITORY", "repositoryID": "GITHUB_REPOSITORY_ID",
                 "workflowRef": "GITHUB_WORKFLOW_REF", "workflowSHA": "GITHUB_WORKFLOW_SHA",
                 "runID": "GITHUB_RUN_ID", "runAttempt": "GITHUB_RUN_ATTEMPT", "jobID": "GITHUB_JOB",
                 "event": "GITHUB_EVENT_NAME", "ref": "GITHUB_REF", "headRef": "GITHUB_HEAD_REF",
                 "baseRef": "GITHUB_BASE_REF"}
    hosted = os.environ.get("GITHUB_ACTIONS") == "true" or any(name in os.environ for name in variables.values())
    if hosted:
        execution = {"scope": "github", **{key: os.environ.get(name, "") for key, name in variables.items()}}
    else:
        execution = {key: "local" for key in EXECUTION_KEYS}
        execution.update(scope="local", repository=str(repository.resolve()), ref="", headRef="", baseRef="")
    validate_execution(execution)
    return execution


def utc_now():
    """Record a wall-clock provenance timestamp independently of command monotonic deadlines."""
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def producer_receipt(execution, tests, startedAt=None):
    """Seal successful compilation/discovery provenance without dropping the producer attempt."""
    validate_execution(execution)
    return {"execution": dict(execution), "compilation": "passed", "discovery": "passed" if tests else "not-applicable",
            "inventorySHA256": digest(tests), "startedAt": startedAt or utc_now(), "completedAt": utc_now()}


def validate_inventory(tests, packages):
    """Require every expected package and a nonempty unique partition of discovered test leaves."""
    object_keys(tests, packages, "package inventory")
    for inventory in tests.values():
        if not isinstance(inventory, dict) or not inventory:
            raise ValueError("compiled test inventory is missing or empty")
        seen = set()
        for module, leaves in inventory.items():
            if (not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", module)
                    or not isinstance(leaves, list) or not leaves):
                raise ValueError("invalid compiled test inventory")
            for leaf in leaves:
                if (not isinstance(leaf, str) or not re.fullmatch(re.escape(module) + r"[./]\S[^\r\n]*", leaf)
                        or leaf in seen):
                    raise ValueError("invalid or duplicate compiled test leaf")
                seen.add(leaf)
            if leaves != sorted(leaves):
                raise ValueError("compiled test inventory must be canonical")


def validate_metadata(metadata, current, execution, component, roots, *, selection=None, archive_sha256=None):
    """Admit exact inputs and require immutable resolver evidence before earlier-attempt reuse."""
    if not isinstance(metadata, dict) or type(metadata.get("formatVersion")) is not int or metadata.get("formatVersion") != VERSION:
        raise ValueError("native receipt version requires regeneration as version 2")
    object_keys(metadata, {"formatVersion", "status", "component", "compatibility", "producer", "tests",
                           "buildRoots", "payloadSHA256"}, "compilation receipt")
    if metadata["status"] != "passed" or metadata["component"] != component or metadata["buildRoots"] != roots:
        raise ValueError("native artifact component, status or build roots differ")
    compatibility = metadata["compatibility"]
    object_keys(compatibility, {"identity", "build"}, "compatibility")
    identity = compatibility["identity"]
    object_keys(identity, IDENTITY_KEYS, "build identity")
    if (not SHA1.fullmatch(str(identity["commit"])) or not SHA256.fullmatch(str(identity["sourceSHA256"]))
            or identity["buildSystem"] != "native" or not Path(identity["repository"]).is_absolute()
            or not isinstance(identity["runtime"], dict) or not identity["runtime"]
            or not isinstance(identity["dependencyPinsSHA256"], dict)
            or any(not isinstance(path, str) or not SHA256.fullmatch(str(value))
                   for path, value in identity["dependencyPinsSHA256"].items())):
        raise ValueError("invalid required build identity")
    # Comparing the complete records also rejects newly introduced required fields.
    if digest(compatibility) != digest(current):
        raise ValueError("native artifact compatibility differs from source, pins, flags, platform, compiler, SDK or checkout path")
    validate_inventory(metadata["tests"], current["build"]["testPackages"])
    producer = metadata["producer"]
    object_keys(producer, {"execution", "compilation", "discovery", "inventorySHA256", "startedAt", "completedAt"}, "producer")
    validate_execution(producer["execution"])
    validate_execution(execution)
    if (producer["compilation"] != "passed" or producer["discovery"] != ("passed" if current["build"]["testPackages"] else "not-applicable")
            or producer["inventorySHA256"] != digest(metadata["tests"])):
        raise ValueError("producer compilation/discovery or inventory seal is invalid")
    try:
        started = datetime.fromisoformat(producer["startedAt"].replace("Z", "+00:00"))
        completed = datetime.fromisoformat(producer["completedAt"].replace("Z", "+00:00"))
        if started.utcoffset() is None or completed.utcoffset() is None or completed < started:
            raise ValueError("invalid producer timestamps")
    except (AttributeError, TypeError, ValueError) as error:
        raise ValueError("invalid producer timestamps") from error
    if not isinstance(metadata["payloadSHA256"], str) or not SHA256.fullmatch(metadata["payloadSHA256"]):
        raise ValueError("invalid producer payload digest")
    if selection is None:
        if any(producer["execution"][key] != execution[key] for key in EXECUTION_KEYS - {"jobID"}):
            raise ValueError("native artifact producer differs from this repository, workflow, event, run or attempt")
    else:
        selected_artifact(selection, execution, metadata, archive_sha256)


def selected_artifact(selection, execution, metadata, archive_sha256):
    """Keep resolver checks mandatory for every admission path that accepts an index."""
    import artifact_index
    return artifact_index.validate_selection(selection, execution=execution,
        component=metadata["component"], platform=metadata["compatibility"]["identity"]["platform"],
        archive_sha256=archive_sha256, metadata=metadata)


def consumer_receipt(execution, producer, archive_digest, *, selection=None, metadata=None):
    """Bind this consumer to verified immutable selection or an explicit local content address."""
    validate_execution(execution)
    validate_execution(producer["execution"])
    if not isinstance(archive_digest, str) or not SHA256.fullmatch(archive_digest):
        raise ValueError("invalid consumer archive digest")
    artifact = {"id": "local:sha256:" + archive_digest, "idSource": "local-content-address",
                "archiveSHA256": archive_digest}
    verified = None
    if selection is not None:
        if metadata is None or digest(metadata["producer"]) != digest(producer):
            raise ValueError("consumer producer differs from the selected compilation receipt")
        selected = selected_artifact(selection, execution, metadata, archive_digest)
        artifact.update(id=selected["artifactID"], idSource="verified-artifact-index",
                        apiDigest=selected["artifactDigest"], name=selected["artifactName"],
                        receiptArtifactID=selected["receiptArtifactID"])
        verified = {"indexSHA256": digest(selection), "resolverExecution": dict(selection["execution"]),
                    "consumerExecution": dict(execution), "sourceCommit": selection["sourceCommit"],
                    "platform": selection["platform"], "component": metadata["component"],
                    "producerAttempt": producer["execution"]["runAttempt"]}
    elif any(producer["execution"][key] != execution[key] for key in EXECUTION_KEYS - {"jobID"}):
        raise ValueError("consumer requires verified selection for an earlier producer attempt")
    return {"execution": dict(execution), "selectedProducer": dict(producer["execution"]),
            "selectedProducerReceipt": copy.deepcopy(producer), "artifact": artifact, "selection": verified,
            "compatibilityVerified": True, "discovery": "pending", "selectedScope": None,
            "startedAt": utc_now(), "status": "restored"}
