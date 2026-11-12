#!/usr/bin/env python3
# File: Tools/ci/artifact_index.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Resolve explicit native components using immutable API IDs and producer receipts.

Artifact names locate candidates only. The API digest, source/trust provenance,
successful attempt-specific build job and complete v2 receipt admit a candidate.
Consumers resolve again in their current job, including after a partial rerun.
"""

import argparse
import io
import json
import os
from pathlib import Path
import re

import native_receipts as receipts


VERSION = 1
MAX_INDEX_BYTES = 64 * 1024 * 1024
PLATFORMS = ("linux-x64", "macos-arm64", "windows-x64")
COMPONENT = re.compile(r"[a-z][a-z0-9-]*")
INDEX_KEYS = {"formatVersion", "execution", "sourceCommit", "platform", "expectedComponents", "components"}
ENTRY_KEYS = {"artifactID", "artifactDigest", "artifactName", "archiveSHA256", "producer", "metadata",
              "receiptArtifactID"}


def positive_id(value):
    """JSON API IDs are integers; persisted selected IDs are decimal strings."""
    return type(value) in (int, str) and re.fullmatch(r"[1-9][0-9]*", str(value)) is not None


def expected_components(value, platform):
    """Accept an explicit plan matrix or explicit subset, never a guessed prefix map."""
    if platform not in PLATFORMS:
        raise ValueError("unsupported artifact platform")
    if isinstance(value, dict):
        receipts.object_keys(value, {"include"}, "expected component matrix")
        if not isinstance(value["include"], list):
            raise ValueError("expected component matrix must contain a list")
        components = []
        for entry in value["include"]:
            if not isinstance(entry, dict) or entry.get("platform") != platform:
                raise ValueError("expected component matrix platform differs")
            components.append(entry.get("component"))
    else:
        components = value
    if (not isinstance(components, list) or not components
            or any(not isinstance(item, str) or not COMPONENT.fullmatch(item) for item in components)
            or len(set(components)) != len(components)):
        raise ValueError("expected components must be a nonempty unique explicit component list")
    return sorted(components)


def same_execution(actual, expected, *, earlier=False):
    """Attempts may move backwards only within an otherwise identical hosted scope."""
    receipts.validate_execution(actual)
    receipts.validate_execution(expected)
    ignored = {"jobID", "runAttempt"} if earlier else {"jobID"}
    if (actual["scope"] != "github" or expected["scope"] != "github"
            or any(actual[key] != expected[key] for key in receipts.EXECUTION_KEYS - ignored)
            or earlier and int(actual["runAttempt"]) > int(expected["runAttempt"])):
        raise ValueError("artifact producer or index repository, workflow, run, attempt or trust scope differs")


def validate_native_metadata(metadata, execution, component, platform, source_commit):
    """Check complete v2 structure before consumers compare live compatibility."""
    if not isinstance(metadata, dict):
        raise ValueError("invalid native producer metadata")
    try:
        producer = metadata["producer"]
        same_execution(producer["execution"], execution, earlier=True)
        identity = metadata["compatibility"]["identity"]
        if identity["commit"] != source_commit or identity["platform"] != platform:
            raise ValueError("artifact source revision or platform differs")
        if producer["execution"]["jobID"] not in ({"build"} if component == "load" else {"build", "build-remaining"}):
            raise ValueError("native artifact producer must be the build job")
        receipts.validate_metadata(metadata, metadata["compatibility"], producer["execution"],
                                   component, metadata["buildRoots"])
    except (KeyError, TypeError) as error:
        raise ValueError("incomplete native producer metadata") from error


def validate_selection(index, *, execution, component, platform, archive_sha256, metadata):
    """Bind restored bytes to the fresh resolver's complete, current-attempt index."""
    receipts.object_keys(index, INDEX_KEYS, "artifact index")
    if type(index["formatVersion"]) is not int or index["formatVersion"] != VERSION:
        raise ValueError("unsupported artifact index version")
    same_execution(index["execution"], execution)
    expected = expected_components(index["expectedComponents"], platform)
    receipts.object_keys(index["components"], expected, "artifact component index")
    if (index["platform"] != platform or not receipts.SHA1.fullmatch(str(index["sourceCommit"]))
            or component not in expected):
        raise ValueError("artifact index source, component or platform differs")
    # Validate every entry, so an incomplete or edited full index is never admitted.
    for name, entry in index["components"].items():
        receipts.object_keys(entry, ENTRY_KEYS, "artifact selection")
        if (not isinstance(entry["artifactID"], str) or not positive_id(entry["artifactID"])
                or not isinstance(entry["receiptArtifactID"], str) or not positive_id(entry["receiptArtifactID"])
                or not isinstance(entry["artifactDigest"], str)
                or not re.fullmatch(r"sha256:[0-9a-f]{64}", entry["artifactDigest"])
                or not isinstance(entry["archiveSHA256"], str)
                or not receipts.SHA256.fullmatch(entry["archiveSHA256"])
                or not isinstance(entry["artifactName"], str)):
            raise ValueError("invalid immutable artifact selection")
        validate_native_metadata(entry["metadata"], execution, name, platform, index["sourceCommit"])
        if receipts.digest(entry["producer"]) != receipts.digest(entry["metadata"]["producer"]):
            raise ValueError("selected producer receipt differs from native metadata")
        prefix = artifact_prefix(platform, name, index["sourceCommit"], entry["producer"]["execution"])
        if not re.fullmatch(re.escape(prefix) + r"-t[1-3]", entry["artifactName"]):
            raise ValueError("selected artifact name disagrees with producer identity")
    selected = index["components"][component]
    if archive_sha256 != selected["archiveSHA256"] or receipts.digest(metadata) != receipts.digest(selected["metadata"]):
        raise ValueError("downloaded archive digest or native metadata differs from immutable selection")
    return selected


def artifact_prefix(platform, component, commit, execution, *, receipt=False):
    kind = "compiled-receipt" if receipt else "compiled"
    return f"{kind}-{platform}-{component}-{commit}-{execution['runID']}-{execution['runAttempt']}"


def validate_run(run, execution, source_commit):
    """The API's PR head SHA may differ from the checked-out merge commit SHA."""
    expected_path = execution["workflowRef"].split("/.github/", 1)[1].split("@", 1)[0]
    try:
        valid = (str(run["id"]) == execution["runID"]
                 and positive_id(run["id"]) and positive_id(run["repository"]["id"])
                 and positive_id(run["head_repository"]["id"])
                 and str(run["repository"]["id"]) == execution["repositoryID"]
                 and run["repository"]["full_name"] == execution["repository"]
                 and run["event"] == execution["event"]
                 and run["path"] == ".github/" + expected_path
                 and receipts.SHA1.fullmatch(run["head_sha"])
                 and (execution["event"] == "pull_request" or run["head_sha"] == source_commit))
    except (KeyError, TypeError):
        valid = False
    if not valid:
        raise ValueError("GitHub workflow run repository, workflow, event or source provenance differs")


def validate_artifact(artifact, run, execution):
    """Require API-observed immutable identity and live same-run provenance."""
    try:
        scope = artifact["workflow_run"]
        valid = (positive_id(artifact["id"]) and artifact["expired"] is False
                 and isinstance(artifact["name"], str)
                 and re.fullmatch(r"sha256:[0-9a-f]{64}", artifact["digest"])
                 and str(scope["id"]) == execution["runID"]
                 and str(scope["repository_id"]) == execution["repositoryID"]
                 and positive_id(scope["head_repository_id"])
                 and scope["head_sha"] == run["head_sha"]
                 and scope["head_repository_id"] == run["head_repository"]["id"])
    except (KeyError, TypeError):
        valid = False
    if not valid:
        raise ValueError("artifact is expired, missing its digest, or has different immutable API provenance; schedule a fresh build")


def successful_job(jobs, execution, platform, component, run):
    """Matrix jobs get a unique platform/component suffix; names cannot select an artifact."""
    suffix = f"Builds / {platform} / {component}"
    matches = [job for job in jobs if isinstance(job, dict)
               and (job.get("name") == suffix or str(job.get("name", "")).endswith(" / " + suffix))]
    if len(matches) != 1:
        raise ValueError("ambiguous or missing attempt-specific producer job provenance")
    job = matches[0]
    if (not positive_id(job.get("id")) or str(job.get("run_id")) != execution["runID"]
            or job.get("head_sha") != run["head_sha"]
            or "run_attempt" in job and str(job["run_attempt"]) != execution["runAttempt"]):
        raise ValueError("producer job run, source or attempt differs")
    return job.get("status") == "completed" and job.get("conclusion") == "success"


def resolve(client, *, execution, platform, components, source_commit, budget=None, attempts=None):
    """Bound the whole index operation, including all components and API pages."""
    from artifact_transfer import Budget, TransferError, recover, wall_deadline
    budget = budget or Budget()
    def attempt(_number, deadline):
        with client.within(budget, deadline), wall_deadline(budget.remaining(deadline)):
            try:
                return _resolve(client, execution=execution, platform=platform, components=components,
                                source_commit=source_commit)
            except ValueError as error:
                if isinstance(error, TransferError):
                    raise
                raise TransferError(str(error)) from error
    with wall_deadline(budget.remaining()):
        return recover(attempt, budget=budget, attempts=attempts, description="resolve")


def _resolve(client, *, execution, platform, components, source_commit):
    """Select the latest successful admitted producer, rejecting ambiguous immutable IDs."""
    receipts.validate_execution(execution)
    if execution["scope"] != "github" or not receipts.SHA1.fullmatch(str(source_commit)):
        raise ValueError("artifact resolution requires complete GitHub execution and source identity")
    components = expected_components(components, platform)
    run = client.get_run()
    validate_run(run, execution, source_commit)
    artifacts = client.list_artifacts()
    if (not isinstance(artifacts, list)
            or any(not isinstance(item, dict) or not positive_id(item.get("id")) for item in artifacts)
            or len({str(item["id"]) for item in artifacts}) != len(artifacts)):
        raise ValueError("invalid or duplicate GitHub artifact listing")
    by_id = {str(item.get("id")): item for item in artifacts}
    jobs, selected = {}, {}
    for component in components:
        name_prefix = f"compiled-receipt-{platform}-{component}-{source_commit}-{execution['runID']}-"
        candidates, named_candidates = [], []
        for receipt_artifact in artifacts:
            name = receipt_artifact.get("name", "")
            if not isinstance(name, str) or not name.startswith(name_prefix):
                continue
            match = re.fullmatch(re.escape(name_prefix) + r"([1-9][0-9]*)-t([1-3])", name)
            if not match or int(match[1]) > int(execution["runAttempt"]):
                raise ValueError("invalid or future producer receipt candidate")
            named_candidates.append((match[1], receipt_artifact))
        selected_attempt = None
        for named_attempt, receipt_artifact in sorted(named_candidates, key=lambda item: int(item[0]), reverse=True):
            if selected_attempt is not None and int(named_attempt) < selected_attempt:
                continue
            if named_attempt not in jobs:
                jobs[named_attempt] = client.list_jobs(named_attempt)
            named_execution = {**execution, "runAttempt": named_attempt}
            if not successful_job(jobs[named_attempt], named_execution, platform, component, run):
                continue
            selected_attempt = int(named_attempt)
            validate_artifact(receipt_artifact, run, execution)
            envelope = client.read_zip_json(str(receipt_artifact["id"]), receipt_artifact["digest"], "producer-receipt.json")
            receipts.object_keys(envelope, {"formatVersion", "metadata", "artifact"}, "producer transfer receipt")
            if type(envelope["formatVersion"]) is not int or envelope["formatVersion"] != VERSION:
                raise ValueError("unsupported producer transfer receipt version")
            metadata = envelope["metadata"]
            validate_native_metadata(metadata, execution, component, platform, source_commit)
            producer = metadata["producer"]
            producer_execution = producer["execution"]
            if producer_execution["runAttempt"] != named_attempt:
                raise ValueError("producer receipt name and recorded attempt differ")
            remote = envelope["artifact"]
            receipts.object_keys(remote, {"id", "name", "digest", "archiveSHA256"}, "producer immutable artifact")
            if (not isinstance(remote["id"], str) or not positive_id(remote["id"])
                    or not isinstance(remote["archiveSHA256"], str)
                    or not receipts.SHA256.fullmatch(remote["archiveSHA256"])):
                raise ValueError("invalid producer immutable ID or archive digest")
            artifact = by_id.get(remote["id"])
            if artifact is None:
                raise ValueError("selected producer artifact is missing; explicitly schedule a fresh build")
            validate_artifact(artifact, run, execution)
            prefix = artifact_prefix(platform, component, source_commit, producer_execution)
            if (artifact["name"] != remote["name"] or artifact["digest"] != remote["digest"]
                    or not re.fullmatch(re.escape(prefix) + r"-t[1-3]", artifact["name"])):
                raise ValueError("producer receipt and immutable artifact name or digest differ")
            candidates.append({"artifactID": remote["id"], "artifactDigest": remote["digest"],
                               "artifactName": remote["name"], "archiveSHA256": remote["archiveSHA256"],
                               "producer": producer, "metadata": metadata,
                               "receiptArtifactID": str(receipt_artifact["id"])})
        if not candidates:
            raise ValueError(f"missing successful producer artifact for {component}; explicitly schedule a fresh build")
        latest = max(int(item["producer"]["execution"]["runAttempt"]) for item in candidates)
        latest_candidates = [item for item in candidates if int(item["producer"]["execution"]["runAttempt"]) == latest]
        # Retrying the tiny receipt can duplicate a reference, never the selected identity.
        identities = {receipts.digest({key: value for key, value in item.items() if key != "receiptArtifactID"})
                      for item in latest_candidates}
        if len(identities) != 1:
            raise ValueError(f"ambiguous immutable producer artifacts for {component}")
        selected[component] = min(latest_candidates, key=lambda item: int(item["receiptArtifactID"]))
    return {"formatVersion": VERSION, "execution": dict(execution), "sourceCommit": source_commit,
            "platform": platform, "expectedComponents": components, "components": selected}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("resolve",))
    parser.add_argument("--platform", required=True, choices=PLATFORMS)
    parser.add_argument("--components-json", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--receipt", type=Path, help="terminal resolver evidence; defaults beside the index")
    args = parser.parse_args(argv)
    from artifact_transfer import (AGGREGATE_SECONDS, ATTEMPT_SECONDS, MAX_ATTEMPTS,
                                   Budget, GitHubArtifactClient, wall_deadline)
    budget = Budget()
    report = {"formatVersion": VERSION, "operation": "resolve", "status": "failed", "attempts": [],
              "startedAt": receipts.utc_now(), "limits": {"attempts": MAX_ATTEMPTS,
              "attemptSeconds": ATTEMPT_SECONDS, "aggregateSeconds": AGGREGATE_SECONDS}}
    failure = None
    try:
        with wall_deadline(budget.remaining()):
            execution = receipts.execution_identity(Path.cwd())
            token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
            if not token:
                raise ValueError("GitHub Actions read token is required for immutable artifact resolution")
            client = GitHubArtifactClient(execution["repository"], token, execution["runID"])
            components = receipts.read_json(io.StringIO(args.components_json))
            index = resolve(client, execution=execution, platform=args.platform, components=components,
                            source_commit=os.environ.get("GITHUB_SHA", ""), budget=budget,
                            attempts=report["attempts"])
            encoded = json.dumps(index, indent=2, sort_keys=True) + "\n"
            if len(encoded.encode()) > MAX_INDEX_BYTES:
                raise ValueError("immutable artifact index exceeds its size bound")
            args.output.parent.mkdir(parents=True, exist_ok=True)
            temporary = args.output.with_suffix(args.output.suffix + ".tmp")
            temporary.write_text(encoded)
            temporary.replace(args.output)
            report.update(status="passed", execution=execution,
                          selectedArtifacts={name: {key: entry[key] for key in ("artifactID", "artifactDigest")}
                                             for name, entry in index["components"].items()})
    except (ValueError, OSError) as error:
        failure = str(error)
        report["error"] = failure
        args.output.unlink(missing_ok=True)
    finally:
        report["completedAt"] = receipts.utc_now()
        receipt = args.receipt or args.output.with_suffix(".resolution.json")
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    if failure:
        parser.exit(1, f"artifact resolution failed: {failure}\n")


if __name__ == "__main__":
    main()
