# File: Tools/ci/baseline_usage.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Reproduce the Phase 0 usage baseline from retained GitHub evidence, offline.

This estimates list-price runner usage, never invoice charges or spend admission.
Job and step API timestamps have second resolution; mixed helper steps stay whole.
"""

import argparse
from collections import Counter
from datetime import datetime
from decimal import Decimal
import gzip
import hashlib
import json
from pathlib import Path
import re

import scheduling_policy


DEFAULT_BASELINE = Path(__file__).resolve().parents[2] / "Docs/Tasks/ci-reliability/baseline"
CATEGORIES = ("setup", "compile", "discovery", "restore", "tests", "conversion", "upload", "download", "other")


def read_json(path):
    """Read one retained UTF-8 JSON document without modifying its evidence."""
    return json.loads(path.read_text())


def read_pages(directory, collection):
    """Reject missing pages, duplicate IDs, inconsistent totals and partial captures."""
    pages = sorted(directory.glob(f"{collection}-page-*.json"),
                   key=lambda path: int(path.stem.rsplit("-", 1)[1]))
    if not pages:
        raise ValueError(f"missing {collection} pages")
    rows, seen, total = [], set(), None
    for number, path in enumerate(pages, 1):
        if path.name != f"{collection}-page-{number}.json":
            raise ValueError(f"missing {collection} page {number}")
        page = read_json(path)
        # The jobs connector wraps the ordinary REST response in a `jobs` object.
        if isinstance(page.get(collection), dict):
            page = page[collection]
        count = page.get("total_count")
        if type(count) is not int or count < 0 or (total is not None and total != count):
            raise ValueError(f"invalid/inconsistent {collection} total_count")
        total = count
        for row in page[collection]:
            identity = row.get("id")
            if type(identity) is not int or identity in seen:
                raise ValueError(f"invalid/duplicate {collection} id: {identity}")
            seen.add(identity)
            rows.append(row)
    if len(rows) != total:
        raise ValueError(f"incomplete {collection}: expected {total}, retained {len(rows)}")
    return sorted(rows, key=lambda row: row["id"])


def duration(start, end):
    """Unknown/invalid timestamps remain unknown, including inverted cancellation data."""
    if not start or not end:
        return None
    try:
        first, last = (datetime.fromisoformat(value.replace("Z", "+00:00")) for value in (start, end))
        if first.tzinfo is None or last.tzinfo is None:
            return None
        seconds = (last - first).total_seconds()
    except (TypeError, ValueError):
        return None
    return seconds if seconds >= 0 else None


def step_category(name):
    """Assign whole named steps; do not invent finer timing for compound helpers."""
    text = name.casefold()
    if "download" in text:
        return "download", []
    if text.startswith(("retain ", "share ", "upload ")) or "upload-artifact" in text:
        return "upload", []
    if "restore" in text:
        return "restore", ["verification", "restore"]
    if "discover" in text:
        return "discovery", ["inventory", "planning"]
    if text.startswith("compile "):
        return "compile", ["compile", "symbol graphs where applicable", "discovery", "archive"]
    if "emit selected modules" in text:
        return "compile", []
    if "positive builds" in text:
        return "compile", ["compile", "compiler fixture assertions"]
    if "convert" in text or "documentation and export static routes" in text:
        return "conversion", ["API/documentation checks", "conversion", "website export where applicable"]
    if text.startswith(("run only the selected suite", "run audits using")):
        return "tests", ["restore", "discovery where applicable", "tests/audits", "timing smoke where applicable"]
    if text.startswith(("run selected python", "run browser bridge", "test documentation")):
        return "tests", []
    if (text.startswith(("set up job", "run actions/checkout", "post run ", "run actions/setup-",
                         "run ./.github/actions/setup-native", "run swift-actions/setup-swift"))
            or text.startswith(("check native host", "record compiler", "configure github pages",
                                "enable windows checkout"))):
        return "setup", []
    return "other", []


def runner_group(job, policy):
    """Normalize explicit runner-group evidence only; unknown identity is not a cheap SKU."""
    actual = job.get("runner_group_name")
    groups = {group.casefold(): group for group in policy["runnerRates"]}
    return groups.get(actual.casefold()) if isinstance(actual, str) else None


def summarize_job(job, policy, as_of):
    """Estimate one job's rounded cost while retaining unknowns and whole steps."""
    skipped = job.get("conclusion") == "skipped"
    group = runner_group(job, policy)
    seconds = 0 if skipped else duration(job.get("started_at"), job.get("completed_at"))
    minutes, cost, unknown = None, None, []
    if seconds is None:
        unknown.append("missing or invalid runner timestamps")
    if not group and not skipped:
        unknown.append("runner group absent or not mapped to the versioned policy")
    if skipped:
        minutes, cost = 0, "0.000"
    elif seconds is not None and group:
        try:
            rate = scheduling_policy.runner_rate(policy, group, as_of=as_of,
                                                 require_verified_mapping=False)
        except ValueError as error:
            unknown.append(str(error))
        else:
            minutes = scheduling_policy.billed_minutes(seconds)
            cost = str(Decimal(minutes) * rate)
    steps, categories = [], dict.fromkeys(CATEGORIES, 0)
    for step in job.get("steps", []):
        category, mixed = step_category(step["name"])
        elapsed = (0 if step.get("conclusion") == "skipped" else
                   duration(step.get("started_at"), step.get("completed_at")))
        if elapsed is not None:
            categories[category] += elapsed
        steps.append({"number": step["number"], "name": step["name"], "category": category,
                      "seconds": elapsed, "mixedStageComponents": mixed})
    return {"id": job["id"], "name": job["name"], "conclusion": job.get("conclusion"),
            "observedRunnerGroup": job.get("runner_group_name"), "policyRunnerGroup": group,
            "sku": policy["runnerRates"][group]["sku"] if group else None,
            "runnerSeconds": seconds, "billedMinutesEstimate": minutes,
            "listPriceUSDEstimate": cost,
            "createdToStartedSecondsUpperBound": (None if skipped else
                duration(job.get("created_at"), job.get("started_at"))),
            "stepSecondsByCategory": categories,
            "unknownStepDurations": sum(step["seconds"] is None for step in steps),
            "unknownReasons": unknown, "steps": steps}


def summarize_download_logs(directory):
    """Only completed downloads with observed artifact sizes contribute to this subset.

    Archive sizes are not wire traffic; no job fan-out or restore count is extrapolated.
    """
    observed = []
    artifact = re.compile(r"\(ID: (\d+), Size: (\d+), Expected Digest:")
    for path in sorted((directory / "logs").glob("job-*.log.gz")):
        pending = []
        with gzip.open(path, "rt") as stream:
            for line_number, line in enumerate(stream, 1):
                match = artifact.search(line)
                if match:
                    pending.append({"artifactID": int(match[1]), "archiveBytes": int(match[2]),
                                    "line": line_number})
                if "Artifact download completed successfully." in line:
                    observed.extend({"jobID": int(path.name.split("-")[1].split(".")[0]),
                                     "log": f"runs/{directory.name}/logs/{path.name}", **item}
                                    for item in pending)
                    pending = []
    return {"status": "observed subset" if observed else "unavailable",
            "observedCompletedDownloadArchiveBytes": sum(row["archiveBytes"] for row in observed),
            "workflowTotalDownloadedBytes": None, "wireBytes": None, "observations": observed}


def summarize_run(directory, policy):
    """Validate retained pages and account only evidence belonging to this source/run."""
    run = read_json(directory / "run.json")
    jobs = read_pages(directory, "jobs")
    artifacts = read_pages(directory, "artifacts")
    if any(job.get("run_id") != run["id"] for job in jobs):
        raise ValueError("job belongs to a different run")
    if any(artifact.get("workflow_run", {}).get("id") != run["id"] for artifact in artifacts):
        raise ValueError("artifact belongs to a different run")
    if any(job.get("head_sha") != run["head_sha"] for job in jobs):
        raise ValueError("job source identity missing or differs from the run")
    if any(artifact.get("workflow_run", {}).get("head_sha") != run["head_sha"] for artifact in artifacts):
        raise ValueError("artifact source identity missing or differs from the run")
    as_of = datetime.fromisoformat(run["created_at"].replace("Z", "+00:00")).date()
    summaries = [summarize_job(job, policy, as_of) for job in jobs]
    groups = {}
    for group, rate in sorted(policy["runnerRates"].items()):
        selected = [job for job in summaries if job["policyRunnerGroup"] == group]
        groups[group] = {"sku": rate["sku"], "usdPerMinute": rate["usdPerMinute"],
                         "mappingAssurance": rate["mappingAssurance"], "jobCount": len(selected),
                         "runnerSecondsKnown": sum(job["runnerSeconds"] or 0 for job in selected),
                         "billedMinutesEstimateKnown": sum(job["billedMinutesEstimate"] or 0 for job in selected),
                         "unknownCostJobIDs": [job["id"] for job in selected
                                               if job["listPriceUSDEstimate"] is None],
                         "createdToStartedSecondsUpperBoundKnown": sum(
                             job["createdToStartedSecondsUpperBound"] or 0 for job in selected),
                         "stepSecondsByCategory": {category: sum(job["stepSecondsByCategory"][category]
                             for job in selected) for category in CATEGORIES},
                         "listPriceUSDEstimate": str(sum((Decimal(job["listPriceUSDEstimate"])
                             for job in selected if job["listPriceUSDEstimate"] is not None), Decimal(0)))}
    return {"runID": run["id"], "name": run["name"], "headSHA": run["head_sha"],
            "url": run["html_url"], "conclusion": run["conclusion"], "jobCount": len(jobs),
            "conclusions": dict(sorted(Counter(job.get("conclusion") for job in jobs).items())),
            "unknownCostJobIDs": [job["id"] for job in summaries if job["listPriceUSDEstimate"] is None],
            "runnerGroups": groups,
            "runnerSecondsKnown": sum(job["runnerSeconds"] or 0 for job in summaries),
            "billedMinutesEstimateKnown": sum(job["billedMinutesEstimate"] or 0 for job in summaries),
            "listPriceUSDSubtotal": str(sum((Decimal(job["listPriceUSDEstimate"])
                for job in summaries if job["listPriceUSDEstimate"] is not None), Decimal(0))),
            "createdToStartedSecondsUpperBoundKnown": sum(job["createdToStartedSecondsUpperBound"] or 0
                                                           for job in summaries),
            "stepSecondsByCategory": {category: sum(job["stepSecondsByCategory"][category]
                                                     for job in summaries) for category in CATEGORIES},
            "unknownStepDurations": sum(job["unknownStepDurations"] for job in summaries),
            "artifacts": {"count": len(artifacts),
                          "storedArchiveBytes": sum(artifact["size_in_bytes"] for artifact in artifacts),
                          "missingDigests": sum(not artifact.get("digest") for artifact in artifacts),
                          "expiredAtCapture": sum(bool(artifact.get("expired")) for artifact in artifacts),
                          "uploadedWireBytes": None},
            "downloads": summarize_download_logs(directory), "jobs": summaries}


def summarize(baseline, policy_path=scheduling_policy.DEFAULT_POLICY):
    """Produce a deterministic, explicitly nonbilling baseline from captured inputs."""
    policy = scheduling_policy.load_policy(policy_path)
    runs = [summarize_run(directory, policy) for directory in sorted((baseline / "runs").iterdir())
            if directory.is_dir() and (directory / "run.json").exists()]
    if not runs:
        raise ValueError("no retained run evidence")
    return {"schemaVersion": 1, "kind": "offline-list-price-baseline", "currency": policy["billing"]["currency"],
            "policyFile": policy_path.name, "policySHA256": hashlib.sha256(policy_path.read_bytes()).hexdigest(),
            "billingMappingVerified": False, "invoiceReconciled": False,
            "reportedAdditionalSpendUSD": "40", "reportedSpendSource": "user observation; not invoice evidence",
            "rounding": policy["billing"]["rounding"],
            "limitations": ["List-price estimates use workflow runner groups, not billing-verified SKU identity.",
                           "created_at to started_at is an upper bound including dependency wait, not pure queue time.",
                           "Step categories sum whole API steps; compound compile/discovery/archive and restore/test stages are not split.",
                           "Step timestamps have second resolution; step sums need not equal job runner seconds.",
                           "Retained artifact sizes measure stored archives, not uploaded wire bytes or repeated consumer traffic.",
                           "Completed downloads observed in retained logs cover only a subset; total transfer bytes remain unavailable.",
                           "Unknown runner identity, timestamps or rate leave job cost unknown and subtotals incomplete.",
                           "No billing invoice, storage/network charges, credits or discounts are reconciled."],
            "listPriceUSDSubtotal": str(sum((Decimal(run["listPriceUSDSubtotal"]) for run in runs), Decimal(0))),
            "runs": runs}


def main():
    """Print or retain the offline summary; never contact GitHub or dispatch a job."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    parser.add_argument("--policy", type=Path, default=scheduling_policy.DEFAULT_POLICY)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    rendered = json.dumps(summarize(args.baseline, args.policy), indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(rendered)
    else:
        print(rendered, end="")


if __name__ == "__main__":
    main()
