#!/usr/bin/env python3
# File: Tools/ci/workflow_coverage.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Certify an explicit scope against immutable Actions job and attempt identities.

The fresh barrier observes every expected row independently. A partial GitHub
rerun may retain an earlier success in this same run, but a newer failed,
cancelled or unfinished replacement always wins. Job names select rows only;
run metadata and checkout identity separately establish their provenance.
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess

import artifact_index
import native_receipts as receipts


VERSION = 1
MANIFEST_KEYS = {"schemaVersion", "mode", "commit", "runID", "runAttempt", "platform", "entries"}
SUMMARY_KEYS = MANIFEST_KEYS | {"status", "headSHA", "manifestSHA256"}
ENTRY_KEYS = {"id", "jobName"}
SELECTED_KEYS = {"jobID", "jobAttempt", "status"}
PLATFORMS = {"linux-x64", "macos-arm64", "windows-x64", "shared"}
ENTRY_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:/-]*")
NATIVE_PREFIXES = {"linux-x64": "Linux x64 / ", "macos-arm64": "macOS ARM64 / ",
                   "windows-x64": "Windows x64 / "}


def validate_manifest(manifest):
    """Reject incomplete or ambiguous plans before consulting any job result."""
    receipts.object_keys(manifest, MANIFEST_KEYS, "coverage manifest")
    if (type(manifest["schemaVersion"]) is not int or manifest["schemaVersion"] != VERSION
            or manifest["mode"] not in ("full", "diagnostic", "preflight")
            or not isinstance(manifest["commit"], str) or not receipts.SHA1.fullmatch(manifest["commit"])
            or any(not isinstance(manifest[key], str) or not artifact_index.positive_id(manifest[key])
                   for key in ("runID", "runAttempt"))
            or not isinstance(manifest["platform"], str) or manifest["platform"] not in PLATFORMS
            or not isinstance(manifest["entries"], list) or not manifest["entries"]):
        raise ValueError("invalid coverage manifest identity or empty expected scope")
    ids, names = set(), set()
    for entry in manifest["entries"]:
        if not isinstance(entry, dict) or set(entry) not in (ENTRY_KEYS, ENTRY_KEYS | {"stepName"}):
            raise ValueError("invalid expected coverage entry fields")
        if (not isinstance(entry["id"], str) or not ENTRY_ID.fullmatch(entry["id"])
                or any(not isinstance(entry[key], str) or not entry[key].strip()
                       or any(character in entry[key] for character in "\0\r\n")
                       for key in set(entry) - {"id"})):
            raise ValueError("invalid expected coverage entry identity")
        name = (entry["jobName"], entry.get("stepName"))
        if entry["id"] in ids or name in names:
            raise ValueError("duplicate expected coverage id or job/step")
        ids.add(entry["id"])
        names.add(name)
    return manifest


def validate_summary(manifest, summary, *, require_full=False):
    """Admit only the complete exact plan sealed by this fresh barrier attempt."""
    validate_manifest(manifest)
    receipts.object_keys(summary, SUMMARY_KEYS, "coverage summary")
    if (type(summary["schemaVersion"]) is not int
            or any(summary[key] != manifest[key] for key in MANIFEST_KEYS - {"entries"})
            or summary["status"] != "passed"
            or not isinstance(summary["headSHA"], str) or not receipts.SHA1.fullmatch(summary["headSHA"])
            or summary["manifestSHA256"] != receipts.digest(manifest)
            or require_full and manifest["mode"] != "full"
            or not isinstance(summary["entries"], list)
            or len(summary["entries"]) != len(manifest["entries"])):
        raise ValueError("coverage summary scope, source, attempt or expected-plan seal differs")
    selected = {}
    for item in summary["entries"]:
        if (not isinstance(item, dict) or not isinstance(item.get("id"), str)
                or item["id"] in selected):
            raise ValueError("invalid or duplicate selected coverage entry")
        selected[item.get("id")] = item
    if set(selected) != {entry["id"] for entry in manifest["entries"]}:
        raise ValueError("coverage summary omits or adds expected entries")
    job_ids, job_attempts = {}, {}
    for entry in manifest["entries"]:
        item = selected[entry["id"]]
        receipts.object_keys(item, set(entry) | SELECTED_KEYS, "selected coverage entry")
        if (any(item[key] != value for key, value in entry.items()) or item["status"] != "passed"
                or any(not isinstance(item[key], str) or not artifact_index.positive_id(item[key])
                       for key in ("jobID", "jobAttempt"))
                or int(item["jobAttempt"]) > int(manifest["runAttempt"])):
            raise ValueError("selected coverage job identity, status or attempt differs")
        name = entry["jobName"]
        if (item["jobID"] in job_ids and job_ids[item["jobID"]] != name
                or name in job_attempts and job_attempts[name] != (item["jobID"], item["jobAttempt"])):
            raise ValueError("coverage jobs alias different names or attempts")
        job_ids[item["jobID"]] = name
        job_attempts[name] = (item["jobID"], item["jobAttempt"])
    return summary


def validate_jobs(manifest, jobs, *, head_sha):
    """Select each exact expected row once, including all required step conclusions."""
    validate_manifest(manifest)
    if not isinstance(head_sha, str) or not receipts.SHA1.fullmatch(head_sha) or not isinstance(jobs, list):
        raise ValueError("invalid observed workflow source or jobs listing")
    names = {entry["jobName"] for entry in manifest["entries"]}
    # The fresh root barrier combines both native platforms and shared gates.
    # Infer covered families from exact expected names, so platform="shared"
    # retains the same strict matrix boundary as each platform's own barrier.
    prefixes = [prefix for prefix in NATIVE_PREFIXES.values()
                if any(name.startswith(prefix) for name in names)]
    canonical = tuple(prefix + kind + " / " for prefix in prefixes for kind in ("Builds", "Tests"))
    if any(name.startswith("Helper suites / ") for name in names):
        canonical += ("Helper suites / ",)
    by_name, ids = {}, set()
    for job in jobs:
        if not isinstance(job, dict) or not artifact_index.positive_id(job.get("id")):
            raise ValueError("invalid GitHub job identity")
        if str(job["id"]) in ids:
            raise ValueError("duplicate GitHub job identity")
        ids.add(str(job["id"]))
        name = job.get("name")
        if isinstance(name, str) and name.startswith(canonical) and name not in names:
            raise ValueError(f"unexpected canonical build, suite or helper coverage job: {name}")
        if not isinstance(name, str) or name not in names:
            continue
        if (str(job.get("run_id")) != manifest["runID"] or job.get("head_sha") != head_sha
                or not artifact_index.positive_id(job.get("run_attempt"))
                or int(job["run_attempt"]) > int(manifest["runAttempt"])):
            raise ValueError("coverage job source, run or attempt differs")
        by_name.setdefault(job["name"], []).append(job)
    selected_jobs = {}
    for name in names:
        candidates = by_name.get(name, [])
        if not candidates:
            raise ValueError(f"missing expected coverage job: {name}")
        attempt = max(int(job["run_attempt"]) for job in candidates)
        latest = [job for job in candidates if int(job["run_attempt"]) == attempt]
        if len(latest) != 1:
            raise ValueError(f"duplicate expected coverage job in attempt {attempt}: {name}")
        job = latest[0]
        if job.get("status") != "completed" or job.get("conclusion") != "success":
            raise ValueError(f"coverage job did not pass: {name}")
        selected_jobs[name] = job
    entries = []
    for entry in manifest["entries"]:
        job = selected_jobs[entry["jobName"]]
        if "stepName" in entry:
            steps = job.get("steps")
            if not isinstance(steps, list):
                raise ValueError("expected step coverage is missing")
            matches = [step for step in steps if isinstance(step, dict) and step.get("name") == entry["stepName"]]
            if (len(matches) != 1 or matches[0].get("status") != "completed"
                    or matches[0].get("conclusion") != "success"):
                raise ValueError(f"missing, duplicate or unsuccessful coverage step: {entry['stepName']}")
        entries.append({**entry, "jobID": str(job["id"]), "jobAttempt": str(job["run_attempt"]), "status": "passed"})
    summary = {**manifest, "status": "passed", "headSHA": head_sha,
               "manifestSHA256": receipts.digest(manifest), "entries": entries}
    return validate_summary(manifest, summary)


def certify(client, *, manifest, execution, source_commit, budget=None):
    """Bound one independent API snapshot across every attempt in this exact run."""
    from artifact_transfer import Budget, wall_deadline
    validate_manifest(manifest)
    receipts.validate_execution(execution)
    if (execution["scope"] != "github" or source_commit != manifest["commit"]
            or manifest["runID"] != execution["runID"] or manifest["runAttempt"] != execution["runAttempt"]
            or "/.github/workflows/ci.yml@" not in execution["workflowRef"]):
        raise ValueError("coverage requires current CI workflow, source, run and barrier attempt")
    budget = budget or Budget()
    with client.within(budget, budget.deadline), wall_deadline(budget.remaining()):
        run = client.get_run()
        artifact_index.validate_run(run, execution, source_commit)
        if "run_attempt" in run and str(run["run_attempt"]) != execution["runAttempt"]:
            raise ValueError("workflow current attempt changed during coverage certification")
        jobs = []
        for attempt in range(1, int(manifest["runAttempt"]) + 1):
            observed = client.list_jobs(str(attempt))
            if not isinstance(observed, list):
                raise ValueError("invalid attempt-specific jobs listing")
            if any(not isinstance(job, dict) or ("run_attempt" in job
                   and str(job["run_attempt"]) != str(attempt)) for job in observed):
                raise ValueError("job listing returned a different attempt")
            # The attempt endpoint supplies provenance even when the job omits
            # run_attempt (as in the documented REST job response).
            jobs.extend({**job, "run_attempt": attempt} for job in observed)
        return validate_jobs(manifest, jobs, head_sha=run["head_sha"])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("certify")
    source = command.add_mutually_exclusive_group(required=True)
    source.add_argument("--manifest", type=Path)
    source.add_argument("--manifest-json")
    command.add_argument("--repository", type=Path, default=Path("."))
    command.add_argument("--output", type=Path, required=True)
    command.add_argument("--github-output", action="store_true")
    args = parser.parse_args(argv)
    if args.manifest:
        with args.manifest.open() as stream:
            manifest = receipts.read_json(stream)
    else:
        import io
        manifest = receipts.read_json(io.StringIO(args.manifest_json))
    execution = receipts.execution_identity(args.repository)
    source_commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=args.repository, text=True).strip()
    if os.environ.get("GITHUB_SHA") != source_commit:
        raise ValueError("checked-out source differs from GitHub execution revision")
    from artifact_transfer import GitHubArtifactClient, write_json
    client = GitHubArtifactClient(execution["repository"], os.environ.get("GH_TOKEN", ""), execution["runID"])
    summary = certify(client, manifest=manifest, execution=execution, source_commit=source_commit)
    write_json(args.output, summary)
    compact = json.dumps(summary, separators=(",", ":"), sort_keys=True)
    if args.github_output:
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write("coverage=" + compact + "\n")
    print(compact)
    return summary


if __name__ == "__main__":
    main()
