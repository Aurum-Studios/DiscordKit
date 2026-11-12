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
TEST_SCOPE_KEYS = {"platform", "component", "suite", "suites", "jobID"}
TEST_EVIDENCE_KEYS = {"artifactID", "artifactDigest", "artifactName", "receiptSHA256"}
GROUP_RECEIPT_KEYS = {"formatVersion", "status", "component", "suite", "suites", "platform",
                      "sourceCommit", "execution", "producer", "compatibility", "inventory",
                      "inventorySHA256", "expectedLeaves", "executedLeaves", "excludedLeaves", "suiteResults"}
SUITE_RECEIPT_KEYS = {"suite", "status", "expectedLeaves", "executedLeaves", "excludedLeaves", "result"}
PLATFORMS = {"linux-x64", "macos-arm64", "windows-x64", "shared"}
ENTRY_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:/-]*")
NATIVE_PREFIXES = {"linux-x64": "Linux x64 / ", "macos-arm64": "macOS ARM64 / ",
                   "windows-x64": "Windows x64 / "}


def validate_test_scope(scope):
    """A stable group ID always names an explicit, nonempty whole-suite selection."""
    import native_jobs
    receipts.object_keys(scope, TEST_SCOPE_KEYS, "expected test coverage")
    identifier = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_-]*")
    if (not isinstance(scope["platform"], str) or scope["platform"] not in NATIVE_PREFIXES
            or not isinstance(scope["component"], str) or scope["component"] not in native_jobs.COMPONENTS
            or scope["component"] == "release"
            or not isinstance(scope["suite"], str) or not identifier.fullmatch(scope["suite"])
            or not isinstance(scope["suites"], list) or not scope["suites"]
            or any(not isinstance(suite, str) or not identifier.fullmatch(suite) for suite in scope["suites"])
            or scope["suites"] != sorted(set(scope["suites"]))
            or scope["jobID"] != ("canary" if scope["component"] == "load" else
                                   "tests-root" if scope["component"] == "root" else "tests")):
        raise ValueError("invalid expected whole-suite group selection")
    return scope


def evidence_prefix(scope, manifest, attempt):
    return (f"test-coverage-{scope['platform']}-{scope['suite']}-{manifest['commit']}-"
            f"{manifest['runID']}-{attempt}")


def validate_test_evidence(scope, manifest, item, attempt):
    """Preserve the digest-verified artifact selected beside the immutable API job."""
    receipts.object_keys(item, TEST_EVIDENCE_KEYS, "selected test evidence")
    if (not isinstance(item["artifactID"], str) or not artifact_index.positive_id(item["artifactID"])
            or not isinstance(item["artifactDigest"], str)
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", item["artifactDigest"])
            or not isinstance(item["receiptSHA256"], str) or not receipts.SHA256.fullmatch(item["receiptSHA256"])
            or not isinstance(item["artifactName"], str)
            or not re.fullmatch(re.escape(evidence_prefix(scope, manifest, attempt)) + r"-t[1-3]", item["artifactName"])):
        raise ValueError("selected test evidence source, group, attempt or immutable identity differs")
    return item


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
        if not isinstance(entry, dict) or set(entry) not in (ENTRY_KEYS, ENTRY_KEYS | {"stepName"},
                                                                         ENTRY_KEYS | {"stepName", "testCoverage"}):
            raise ValueError("invalid expected coverage entry fields")
        if (not isinstance(entry["id"], str) or not ENTRY_ID.fullmatch(entry["id"])
                or any(not isinstance(entry[key], str) or not entry[key].strip()
                       or any(character in entry[key] for character in "\0\r\n")
                       for key in set(entry) - {"id", "testCoverage"})):
            raise ValueError("invalid expected coverage entry identity")
        if "testCoverage" in entry:
            test_scope = validate_test_scope(entry["testCoverage"])
            if manifest["platform"] not in ("shared", test_scope["platform"]):
                raise ValueError("expected test coverage platform differs")
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
        receipts.object_keys(item, set(entry) | SELECTED_KEYS |
                             ({"testEvidence"} if "testCoverage" in entry else set()), "selected coverage entry")
        if (any(item[key] != value for key, value in entry.items()) or item["status"] != "passed"
                or any(not isinstance(item[key], str) or not artifact_index.positive_id(item[key])
                       for key in ("jobID", "jobAttempt"))
                or int(item["jobAttempt"]) > int(manifest["runAttempt"])):
            raise ValueError("selected coverage job identity, status or attempt differs")
        if "testCoverage" in entry:
            validate_test_evidence(entry["testCoverage"], manifest, item["testEvidence"], item["jobAttempt"])
        name = entry["jobName"]
        if (item["jobID"] in job_ids and job_ids[item["jobID"]] != name
                or name in job_attempts and job_attempts[name] != (item["jobID"], item["jobAttempt"])):
            raise ValueError("coverage jobs alias different names or attempts")
        job_ids[item["jobID"]] = name
        job_attempts[name] = (item["jobID"], item["jobAttempt"])
    return summary


def select_jobs(manifest, jobs, *, head_sha):
    """Choose the latest exact API job before admitting any result artifact."""
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
    return selected_jobs


def validate_jobs(manifest, jobs, *, head_sha, test_evidence=None):
    """Require exact job and step success plus separately verified executed leaves."""
    selected_jobs = select_jobs(manifest, jobs, head_sha=head_sha)
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
        selected = {**entry, "jobID": str(job["id"]), "jobAttempt": str(job["run_attempt"]), "status": "passed"}
        if "testCoverage" in entry:
            # Jobs are selected before artifacts. Only certify() can supply proof
            # after resolving inventory and validating the immutable result bytes.
            if test_evidence is None or entry["id"] not in test_evidence:
                raise ValueError("expected executed-leaf evidence is missing")
            selected["testEvidence"] = test_evidence[entry["id"]]
        entries.append(selected)
    summary = {**manifest, "status": "passed", "headSHA": head_sha,
               "manifestSHA256": receipts.digest(manifest), "entries": entries}
    return validate_summary(manifest, summary)


def qualified_inventory(inventory):
    """Package identity separates test modules reused by independent consumer graphs."""
    return sorted(package + "::" + leaf for package, modules in inventory.items()
                  for leaves in modules.values() for leaf in leaves)


def suite_inventory(metadata, component, suite):
    """Derive expected leaves from the selected immutable producer, never the result."""
    import native_jobs
    if component == "consumers":
        if suite not in native_jobs.CONSUMER_SUITES:
            raise ValueError("unknown selected consumer suite")
        package = f"Examples/{suite}"
        if suite not in native_jobs.CONSUMER_TESTS:
            return package, []
    else:
        if component != "root" and suite != component:
            raise ValueError("package group selects a different suite")
        package = native_jobs.PACKAGES[component]
    inventory = metadata["tests"].get(package, {})
    if component == "root":
        leaves = inventory.get(suite, [])
    else:
        leaves = [leaf for module in inventory.values() for leaf in module]
    if not leaves or len(leaves) != len(set(leaves)):
        raise ValueError("selected producer suite inventory is empty or duplicated")
    return package, sorted(leaves)


def expected_exclusions(metadata):
    """Only explicit preexecution producer exclusions may remove executed leaves."""
    configured = metadata["compatibility"]["build"].get("testExclusions", {})
    if not isinstance(configured, dict):
        raise ValueError("invalid producer platform exclusions")
    inventory = set(qualified_inventory(metadata["tests"]))
    result = {}
    for package, exclusions in configured.items():
        if not isinstance(package, str) or not isinstance(exclusions, dict):
            raise ValueError("invalid producer platform exclusions")
        for leaf, reason in exclusions.items():
            if (not isinstance(leaf, str) or not isinstance(reason, str) or not reason.strip()
                    or package + "::" + leaf not in inventory):
                raise ValueError("producer exclusion is outside its expected inventory")
            result[package + "::" + leaf] = reason
    return result


def validate_group_receipt(value, *, scope, manifest, metadata, execution, job_attempt):
    """Reconcile every whole suite and its exclusions against independently selected bytes."""
    import test_results
    receipts.object_keys(value, GROUP_RECEIPT_KEYS, "executed group receipt")
    if (type(value["formatVersion"]) is not int or value["formatVersion"] != 1
            or value["status"] != "passed"
            or any(value[key] != scope[key] for key in ("component", "suite", "suites", "platform"))
            or value["sourceCommit"] != manifest["commit"]
            or receipts.digest(value["producer"]) != receipts.digest(metadata["producer"])
            or receipts.digest(value["compatibility"]) != receipts.digest(metadata["compatibility"])
            or receipts.digest(value["inventory"]) != receipts.digest(metadata["tests"])
            or value["inventorySHA256"] != receipts.digest(metadata["tests"])):
        raise ValueError("group result status, selected scope, source or producer inventory differs")
    artifact_index.same_execution(value["execution"], execution, earlier=True)
    if value["execution"]["runAttempt"] != job_attempt or value["execution"]["jobID"] != scope["jobID"]:
        raise ValueError("group result consumer job or selected attempt differs")
    rows = value["suiteResults"]
    if (not isinstance(rows, list) or len(rows) != len(scope["suites"])
            or any(not isinstance(row, dict) for row in rows)):
        raise ValueError("missing or malformed executed suite results")
    selected, expected_all, executed_all, excluded_all = {}, [], [], {}
    allowed = expected_exclusions(metadata)
    for row in rows:
        receipts.object_keys(row, SUITE_RECEIPT_KEYS, "executed suite result")
        if not isinstance(row["suite"], str) or row["suite"] in selected:
            raise ValueError("duplicate executed whole-suite result")
        selected[row["suite"]] = row
    if set(selected) != set(scope["suites"]):
        raise ValueError("executed whole-suite selection differs")
    for suite in scope["suites"]:
        row = selected[suite]
        package, leaves = suite_inventory(metadata, scope["component"], suite)
        expected = sorted(package + "::" + leaf for leaf in leaves)
        exclusions = {leaf: reason for leaf, reason in allowed.items() if leaf in expected}
        executed = sorted(set(expected) - set(exclusions))
        if (row["status"] != "passed" or row["expectedLeaves"] != expected
                or row["executedLeaves"] != executed or row["excludedLeaves"] != exclusions):
            raise ValueError("executed suite has missing, duplicate, skipped or unexpected leaves")
        if leaves:
            unqualified_exclusions = {leaf.split("::", 1)[1]: reason for leaf, reason in exclusions.items()}
            test_results.validate_result(leaves, row["result"], exclusions=unqualified_exclusions)
        elif row["result"] is not None:
            raise ValueError("test-free consumer smoke cannot claim executed test leaves")
        expected_all.extend(expected)
        executed_all.extend(executed)
        excluded_all.update(exclusions)
    if (len(expected_all) != len(set(expected_all)) or len(executed_all) != len(set(executed_all))
            or value["expectedLeaves"] != sorted(expected_all)
            or value["executedLeaves"] != sorted(executed_all)
            or value["excludedLeaves"] != excluded_all):
        raise ValueError("group executed-leaf coverage omits or duplicates producer inventory")
    return value


def certify_test_evidence(client, *, manifest, execution, source_commit, run, jobs, budget):
    """Digest-verify immutable group receipts for the exact selected API job attempts."""
    required = [entry for entry in manifest["entries"] if "testCoverage" in entry]
    if not required:
        return {}
    selected_jobs = select_jobs(manifest, jobs, head_sha=run["head_sha"])
    indexes = {}
    for platform in sorted({entry["testCoverage"]["platform"] for entry in required}):
        components = sorted({entry["testCoverage"]["component"] for entry in required
                             if entry["testCoverage"]["platform"] == platform})
        if manifest["mode"] == "full":
            import native_jobs
            complete = set(native_jobs.COMPONENTS) - {"release"}
            if platform == "windows-x64":
                complete -= set(native_jobs.TIMING_PACKAGES)
            if set(components) != complete:
                raise ValueError("full executed-leaf coverage omits a test component")
        indexes[platform] = artifact_index.resolve(client, execution=execution, platform=platform,
            components=components, source_commit=source_commit, budget=budget)
    artifacts = client.list_artifacts()
    if (not isinstance(artifacts, list)
            or any(not isinstance(item, dict) or not artifact_index.positive_id(item.get("id")) for item in artifacts)
            or len({str(item["id"]) for item in artifacts}) != len(artifacts)):
        raise ValueError("invalid or duplicate executed-result artifact listing")
    selected, expected_by_platform = {}, {}
    for entry in required:
        scope = entry["testCoverage"]
        job = selected_jobs[entry["jobName"]]
        attempt = str(job["run_attempt"])
        prefix = evidence_prefix(scope, manifest, attempt)
        candidates = [artifact for artifact in artifacts if isinstance(artifact.get("name"), str)
                      and artifact["name"].startswith(prefix + "-")]
        if not candidates:
            raise ValueError("missing immutable executed-leaf artifact for selected job attempt")
        metadata = indexes[scope["platform"]]["components"][scope["component"]]["metadata"]
        proofs, values = [], []
        for artifact in candidates:
            if not re.fullmatch(re.escape(prefix) + r"-t[1-3]", artifact["name"]):
                raise ValueError("invalid immutable executed-result artifact name")
            artifact_index.validate_artifact(artifact, run, execution)
            value = client.read_zip_json(str(artifact["id"]), artifact["digest"], "group-coverage.json")
            validate_group_receipt(value, scope=scope, manifest=manifest, metadata=metadata,
                                   execution=execution, job_attempt=attempt)
            proofs.append({"artifactID": str(artifact["id"]), "artifactDigest": artifact["digest"],
                           "artifactName": artifact["name"], "receiptSHA256": receipts.digest(value)})
            values.append(value)
        if len({proof["receiptSHA256"] for proof in proofs}) != 1:
            raise ValueError("ambiguous immutable executed-result artifacts for selected job")
        selected[entry["id"]] = min(proofs, key=lambda proof: int(proof["artifactID"]))
        expected_by_platform.setdefault(scope["platform"], []).extend(values[0]["expectedLeaves"])
    for platform, expected in expected_by_platform.items():
        if len(expected) != len(set(expected)):
            raise ValueError("duplicate executed-leaf ownership across runtime groups")
        if manifest["mode"] == "full":
            complete = sorted(leaf for component in indexes[platform]["components"].values()
                              for leaf in qualified_inventory(component["metadata"]["tests"]))
            if sorted(expected) != complete:
                raise ValueError("full executed-leaf coverage omits producer inventory")
    return selected


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
        test_evidence = certify_test_evidence(client, manifest=manifest, execution=execution,
            source_commit=source_commit, run=run, jobs=jobs, budget=budget)
        return validate_jobs(manifest, jobs, head_sha=run["head_sha"], test_evidence=test_evidence)


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
