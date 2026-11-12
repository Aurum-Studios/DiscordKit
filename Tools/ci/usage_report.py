#!/usr/bin/env python3
# File: Tools/ci/usage_report.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Reconcile an exact admission plan with bounded, read-only execution evidence.

Rounded runner minutes are estimates. This report is neither an invoice, a spend
admission decision, nor an exact provider-enforced dollar cap. Running jobs and
unattributed receipts remain explicitly incomplete.
"""

import argparse
from datetime import datetime
from decimal import Decimal, InvalidOperation, ROUND_CEILING
import math
import os
from pathlib import Path

import artifact_transfer
import native_receipts


STAGES = ("startup", "setup", "provisioning", "archiveTransfer")
MAX_RECEIPTS = 10000
PRUNED_DIRECTORIES = {".git", "checkouts", "repositories", "node_modules", "artifacts",
                      "symbol-graphs", "symbolgraphs", "index", "ModuleCache", "modules-cache"}


def duration(start, end):
    """Missing, naive, inverted and malformed timestamps cannot prove duration."""
    try:
        first, last = (datetime.fromisoformat(value.replace("Z", "+00:00")) for value in (start, end))
        if first.tzinfo is None or last.tzinfo is None:
            return None
        seconds = (last - first).total_seconds()
        return seconds if seconds >= 0 else None
    except (AttributeError, TypeError, ValueError):
        return None


def elapsed(value):
    if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
        return None
    return value


def minutes(seconds):
    return int((Decimal(str(seconds)) / 60).to_integral_value(rounding=ROUND_CEILING))


def money(value):
    try:
        result = Decimal(value) if isinstance(value, str) else None
        return result if result is not None and result.is_finite() and result >= 0 else None
    except InvalidOperation:
        return None


def stage(name):
    """Whole API steps only; no invented split of a compound helper."""
    name = name.casefold()
    if name.startswith("set up job"):
        return "startup"
    if any(word in name for word in ("download", "upload", "retain ", "share ", "transfer")):
        return "archiveTransfer"
    if "setup-native" in name or "provision" in name:
        return "provisioning"
    if any(word in name for word in ("checkout", "setup-", "set up ", "configure ")):
        return "setup"
    return None


def stages(job):
    collected = {name: [] for name in STAGES}
    for step in job.get("steps", []):
        category = stage(str(step.get("name", "")))
        if category:
            collected[category].append(0 if step.get("conclusion") == "skipped" else
                                       duration(step.get("started_at"), step.get("completed_at")))
    return {name + "Seconds": (sum(values) if values and None not in values else None)
            for name, values in collected.items()}


def classification(value):
    timeout = value.get("timeoutCategory")
    status = value.get("conclusion") or value.get("status")
    if timeout or status in ("timed_out", "timeout"):
        return "timeout"
    if status in ("success", "passed", "verified", "admitted"):
        return "success"
    if status in ("cancelled", "canceled", "interrupted") or value.get("signal"):
        return "cancelled"
    if status == "skipped":
        return "skipped"
    if status in ("failure", "failed", "rejected", "action_required", "startup_failure", "stale"):
        return "failure"
    return "incomplete"


def receipt_results(receipts, planned, plan):
    """Keep local observations without guessing job identity from directories."""
    results, seen = [], set()
    for envelope in receipts:
        if not isinstance(envelope, dict):
            raise ValueError("receipt must be an object")
        receipt = envelope.get("receipt", envelope)
        if not isinstance(receipt, dict):
            raise ValueError("receipt payload must be an object")
        identity = receipt.get("identity", {})
        execution = identity.get("executionID") if isinstance(identity, dict) else None
        if execution and execution in seen:
            continue  # commands.json and the standalone receipt can retain the same command.
        if execution:
            seen.add(execution)
        job_id = envelope.get("jobID", receipt.get("jobID"))
        unknown = []
        if job_id not in planned:
            job_id = None
        expected = {"GITHUB_RUN_ID": plan.get("runID", plan.get("identity", {}).get("runID")),
                    "GITHUB_RUN_ATTEMPT": plan.get("runAttempt", plan.get("identity", {}).get("runAttempt")),
                    "GITHUB_SHA": plan.get("source", {}).get("commit"),
                    "GITHUB_JOB": envelope.get("expectedGitHubJob")}
        for key, value in expected.items():
            if isinstance(identity, dict) and key in identity and value is not None and str(identity[key]) != str(value):
                unknown.append("receipt " + key + " differs from the current source/run/job identity")
        if unknown:
            job_id = None
        hosted = str(expected["GITHUB_RUN_ID"]) not in ("None", "", "local")
        required = ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_SHA")
        complete_identity = isinstance(identity, dict) and all(key in identity for key in required)
        if hosted and not complete_identity:
            unknown.append("receipt has no complete embedded hosted run/attempt/source identity")
        attempts = receipt.get("attempts", [])
        if not isinstance(attempts, list):
            raise ValueError("receipt attempts must be a list")
        results.append({"jobID": job_id, "executionID": execution,
                        "name": receipt.get("name"), "stage": receipt.get("stage"),
                        "operation": receipt.get("operation"), "status": receipt.get("status"),
                        "classification": classification(receipt), "exitCode": receipt.get("exitCode"),
                        "timeoutCategory": receipt.get("timeoutCategory"), "signal": receipt.get("signal"),
                        "elapsedSeconds": elapsed(receipt.get("elapsedSeconds")),
                        "transferAttempts": attempts, "reasons": receipt.get("reasons", []),
                        "error": receipt.get("error"), "source": envelope.get("receiptFile"),
                        "provenance": identity, "unknownReasons": unknown,
                        "identityAssurance": "unverified" if unknown else "hosted" if hosted else "local"})
    return results


def _reservation_summary(plan, current_attempt):
    reservations = plan.get("reservations")
    totals = plan.get("totals", {})
    selected = ([row for row in reservations if type(row.get("attempt")) is int
                 and row["attempt"] <= current_attempt]
                if isinstance(reservations, list) and current_attempt is not None else None)
    costs = [money(row.get("totalUSD")) for row in selected] if selected is not None else None
    cost = sum(costs, Decimal(0)) if costs is not None and None not in costs else None
    allowance, safety = money(totals.get("allowanceUSD")), money(totals.get("safetyUSD"))
    return {"currentAttempt": current_attempt, "reservedAttempts": sorted({row["attempt"] for row in reservations})
                if isinstance(reservations, list) else [],
            "attemptedCumulativeReservationUSD": str(cost) if cost is not None else None,
            "attemptedCumulativeMaximumMinutes": sum(row["billedMaximumMinutes"] for row in selected)
                if selected is not None else None,
            "remainingAllowanceAfterAttemptReservationsUSD": str(allowance - safety - cost)
                if None not in (allowance, safety, cost) else None,
            "preparedMaximumUSD": totals.get("maximumUSD"),
            "preparedRemainingAllowanceUSD": totals.get("remainingUSD"),
            "allowanceUSD": totals.get("allowanceUSD"), "safetyUSD": totals.get("safetyUSD"),
            "method": "Fixed disjoint reservations through the current attempt, including unobserved partial rerun work."}


def reconcile(plan, jobs, receipts=()):
    """Report every observed attempt; latest success covers only its exact planned job."""
    if (not isinstance(plan, dict) or not isinstance(plan.get("jobs"), list) or not plan["jobs"]
            or not isinstance(plan.get("runnerRates", {}), dict) or not isinstance(jobs, list)):
        raise ValueError("an exact plan and jobs list are required")
    planned, names = {}, {}
    rates = plan.get("runnerRates", {})
    for row in plan["jobs"]:
        if (not isinstance(row, dict) or not isinstance(row.get("id"), str) or not row["id"]
                or row["id"] in planned or not isinstance(row.get("group"), str)
                or type(row.get("maximumSeconds")) is not int or row["maximumSeconds"] <= 0):
            raise ValueError("invalid or duplicate exact planned job")
        name = row.get("jobName", row["id"])
        if not isinstance(name, str) or not name or name in names:
            raise ValueError("planned GitHub job names must be unique")
        planned[row["id"]], names[name] = row, row["id"]
    run_attempt = plan.get("runAttempt", plan.get("identity", {}).get("runAttempt", 1))
    if isinstance(run_attempt, str) and run_attempt.isascii() and run_attempt.isdecimal() and not run_attempt.startswith("0"):
        run_attempt = int(run_attempt)
    elif run_attempt == "local" and plan.get("runID", plan.get("identity", {}).get("runID")) == "local":
        run_attempt = None
    elif type(run_attempt) is not int or run_attempt <= 0:
        raise ValueError("plan run attempt must be a positive integer")
    groups = {}
    def group_record(group):
        rate = rates.get(group, {})
        sku = rate.get("sku") or "unknown:" + str(group)
        if sku not in groups:
            groups[sku] = {"sku": rate.get("sku"), "runnerGroups": [],
                           "maximumMinutesPerAttempt": 0, "reservedMaximumMinutes": 0,
                           "observedRoundedMinutesKnown": 0, "observedUnknownMinutesJobIDs": [],
                           "observedJobCount": 0, "usdPerMinute": rate.get("usdPerMinute"),
                           "billingMappingVerified": rate.get("billingMappingVerified") is True}
        if group not in groups[sku]["runnerGroups"]:
            groups[sku]["runnerGroups"].append(group)
        return groups[sku]
    for row in planned.values():
        group_record(row["group"])["maximumMinutesPerAttempt"] += minutes(row["maximumSeconds"])
    for reservation in plan.get("reservations", []):
        group_record(reservation["group"])["reservedMaximumMinutes"] += reservation["billedMaximumMinutes"]
    normalized_groups = {group.casefold(): group for group in rates}
    reservation_keys = {(row["jobID"], row["attempt"]) for row in plan.get("reservations", [])}
    observations, seen, duplicate_executions = [], set(), set()
    expected_run = str(plan.get("runID", plan.get("identity", {}).get("runID", "")))
    expected_sha = plan.get("source", {}).get("commit")
    for row in jobs:
        if not isinstance(row, dict) or type(row.get("id")) is not int or row["id"] <= 0 or row["id"] in seen:
            raise ValueError("invalid or duplicate observed GitHub job ID")
        seen.add(row["id"])
        job_id = names.get(row.get("name"))
        attempt, unknown = row.get("run_attempt"), []
        if row.get("status") != "completed":
            unknown.append("job has not reached terminal execution status")
        if type(attempt) is not int or attempt <= 0:
            attempt = None
            unknown.append("missing or invalid run attempt")
        if not job_id:
            unknown.append("job name is absent from the exact plan")
        if attempt and (run_attempt is None or attempt > run_attempt or (job_id, attempt) not in reservation_keys):
            unknown.append("execution attempt has no current permitted reservation")
        if expected_run and str(row.get("run_id", "")) != expected_run:
            unknown.append("job belongs to a different run")
        if expected_sha and row.get("head_sha") != expected_sha:
            unknown.append("job source differs from the exact plan")
        observed_group = row.get("runner_group_name")
        group = normalized_groups.get(observed_group.casefold()) if isinstance(observed_group, str) else None
        skipped = row.get("conclusion") == "skipped"
        if not group and not skipped:
            unknown.append("observed runner group is absent or unmapped")
        if group and job_id and group != planned[job_id]["group"]:
            unknown.append("observed runner group differs from the planned reservation")
        seconds = 0 if skipped else duration(row.get("started_at"), row.get("completed_at"))
        rounded = minutes(seconds) if seconds is not None else None
        if rounded is None:
            unknown.append("runner duration is unavailable until valid terminal timestamps exist")
        if job_id and seconds is not None and seconds > planned[job_id]["maximumSeconds"]:
            unknown.append("observed duration exceeds the job maximum reservation")
        observation = {"id": row["id"], "name": row.get("name"), "planJobID": job_id,
                       "attempt": attempt, "conclusion": row.get("conclusion"),
                       "status": row.get("status"), "classification": classification(row),
                       "observedRunnerGroup": observed_group, "policyRunnerGroup": group,
                       "sku": rates.get(group, {}).get("sku"), "runnerSeconds": seconds,
                       "observedRoundedMinutes": rounded,
                       "queueSeconds": None,
                       "dependencyAndQueueSecondsUpperBound": duration(row.get("created_at"), row.get("started_at")),
                       "stageSeconds": stages(row), "unknownReasons": unknown}
        if job_id and attempt and any(item["planJobID"] == job_id and item["attempt"] == attempt for item in observations):
            duplicate_executions.add((job_id, attempt))
            unknown.append("more than one observed execution matches this reservation")
        observations.append(observation)
        if group or not skipped:
            aggregate = group_record(group or "unmapped-observed-runner")
            aggregate["observedJobCount"] += 1
            aggregate["observedRoundedMinutesKnown"] += rounded or 0
            if rounded is None:
                aggregate["observedUnknownMinutesJobIDs"].append(row["id"])
    coverage = []
    for job_id in planned:
        rows = [row for row in observations if row["planJobID"] == job_id and row["attempt"] is not None]
        latest = max(rows, key=lambda row: row["attempt"]) if rows else None
        covered = bool(latest and latest["classification"] == "success" and not latest["unknownReasons"]
                       and (job_id, latest["attempt"]) not in duplicate_executions)
        coverage.append({"jobID": job_id, "covered": covered, "latestJobID": latest["id"] if latest else None,
                         "latestAttempt": latest["attempt"] if latest else None,
                         "reason": None if covered else latest["classification"] if latest else "missing"})
    commands = receipt_results(receipts, planned, plan)
    unknown_jobs = [row["id"] for row in observations if row["unknownReasons"]]
    remaining = [row["jobID"] for row in coverage if not row["covered"]]
    failures = [row["id"] for row in observations if row["classification"] in ("failure", "timeout", "cancelled")]
    receipt_failures = [row for row in commands if row["classification"] not in ("success", "skipped") or row["unknownReasons"]]
    return {"schemaVersion": 1, "kind": "execution-usage-reconciliation",
            "status": "incomplete" if remaining or unknown_jobs or receipt_failures else "complete",
            "invoiceReconciled": False, "providerEnforcedDollarCap": False,
            "planStatus": plan.get("status"), "planAdmitted": plan.get("admitted", False),
            "planReasons": plan.get("reasons", []), "identity": plan.get("identity", {}),
            "guard": plan.get("guard"),
            "source": plan.get("source", {}), "planTotals": plan.get("totals", {}),
            "reservationAccounting": _reservation_summary(plan, run_attempt),
            "runnerSKUs": dict(sorted(groups.items())), "jobs": observations, "coverage": coverage,
            "remainingCoverage": remaining, "unknownJobIDs": unknown_jobs, "failedJobIDsAllAttempts": failures,
            "commandResults": commands, "unattributedReceiptCount": sum(row["jobID"] is None for row in commands),
            "limitations": ["Runner minutes are rounded per observed job, including failed attempts; no invoice is reconciled.",
                            "Queue time is unavailable; created-to-started includes dependency wait and is only an upper bound.",
                            "API stage durations cover whole named steps; local command and transfer receipts may overlap them.",
                            "Missing, skipped, running, failed, unknown and unreserved work cannot establish remaining coverage.",
                            "The reporting job can observe itself still running; this snapshot is not final workflow certification."]}


def github_jobs(client, plan):
    """Read all attempts under one existing wall/transport budget; never write APIs."""
    budget = artifact_transfer.Budget()
    def capture(_number, deadline):
        with client.within(budget, deadline):
            run = client.get_run()
            attempt = run.get("run_attempt")
            if type(attempt) is not int or not 1 <= attempt <= 100:
                raise artifact_transfer.TransferError("invalid or excessive observed run attempts")
            if str(run.get("id")) != str(plan.get("runID", plan.get("identity", {}).get("runID"))):
                raise artifact_transfer.TransferError("usage run differs from the admission plan")
            if plan.get("source", {}).get("commit") and run.get("head_sha") != plan["source"]["commit"]:
                raise artifact_transfer.TransferError("usage source differs from the admission plan")
            jobs = []
            for number in range(1, attempt + 1):
                for row in client.list_jobs(number):
                    if row.get("run_attempt", number) != number:
                        raise artifact_transfer.TransferError("GitHub job attempt differs from queried attempt")
                    jobs.append({**row, "run_attempt": number})
            return jobs
    return artifact_transfer.recover(capture, budget=budget, attempts=client.attempts, description="usage-jobs")


def read_json(path):
    path = Path(path)
    if path.stat().st_size > artifact_transfer.MAX_JSON:
        raise ValueError("usage input exceeds JSON size limit")
    with path.open() as stream:
        return native_receipts.read_json(stream)


def read_receipts(directory):
    """Read recognized durable receipts only, with bounded size/count and no symlinks."""
    if directory is None:
        return []
    directory = Path(directory)
    if not directory.is_dir() or directory.is_symlink():
        raise ValueError("receipt directory is missing or unsafe")
    result, candidates, walked = [], 0, 0
    for current, directories, filenames in os.walk(directory, followlinks=False):
        walked += 1
        if walked > MAX_RECEIPTS:
            raise ValueError("receipt directory exceeds traversal limit")
        directories[:] = sorted(name for name in directories if name not in PRUNED_DIRECTORIES
                                and not (Path(current) / name).is_symlink())
        for name in sorted(filenames):
            if not (name.endswith(".receipt.json") or name == "commands.json" or
                    (name.endswith(".json") and ("transfer" in name or name.endswith("-download.json")))):
                continue
            candidates += 1
            if candidates > MAX_RECEIPTS:
                raise ValueError("receipt directory exceeds file limit")
            path = Path(current) / name
            if path.is_symlink():
                raise ValueError("receipt file must not be a symlink")
            value = read_json(path)
            values = [value]
            if name == "commands.json" and isinstance(value, dict):
                values = [row.get("execution", row.get("supervisor")) for row in value.get("commands", [])
                          if isinstance(row, dict)]
            for value in values:
                if isinstance(value, dict) and ("timeoutCategory" in value or
                        ("elapsedSeconds" in value and isinstance(value.get("attempts"), list))):
                    result.append({"receipt": value, "jobID": value.get("jobID"),
                                   "receiptFile": path.relative_to(directory).as_posix()})
    return result


def markdown(report):
    def cell(value):
        return str(value).replace("|", "\\|").replace("\n", " ").replace("\r", " ")
    rows = ["### CI usage snapshot", "", f"Reconciliation: **{cell(report['status'])}**. "
            "Rounded usage estimates; no invoice or exact provider-enforced dollar cap.", ""]
    if report.get("error"):
        return "\n".join(rows + [cell(report["error"]), ""])
    rows += [f"Plan: {cell(report.get('planStatus'))}; admitted: {report.get('planAdmitted')}.",
             f"Remaining coverage: {len(report['remainingCoverage'])}; unknown jobs: {len(report['unknownJobIDs'])}; "
             f"failed/cancelled/timed out jobs across all attempts: {len(report['failedJobIDsAllAttempts'])}.", "",
             "| Runner SKU | Maximum minutes per attempt | Reserved maximum minutes | Observed rounded minutes known | Unknown durations |",
             "| --- | ---: | ---: | ---: | ---: |"]
    for sku, group in report["runnerSKUs"].items():
        rows.append(f"| {cell(sku)} | {group['maximumMinutesPerAttempt']} | {group['reservedMaximumMinutes']} | "
                    f"{group['observedRoundedMinutesKnown']} | {len(group['observedUnknownMinutesJobIDs'])} |")
    accounting = report["reservationAccounting"]
    rows += ["", f"Allowance USD: {cell(accounting['allowanceUSD'])}; prepared maximum USD: "
             f"{cell(accounting['preparedMaximumUSD'])}; cumulative attempted reservations USD: "
             f"{cell(accounting['attemptedCumulativeReservationUSD'])}; remaining after attempted reservations USD: "
             f"{cell(accounting['remainingAllowanceAfterAttemptReservationsUSD'])}.", "",
             "Queue time remains unavailable. Whole API step durations and command/transfer receipts are retained in JSON.", ""]
    if report["planReasons"]:
        rows += ["Plan reasons: " + "; ".join(cell(reason) for reason in report["planReasons"]) + ".", ""]
    rows += ["| Whole API stage | Known seconds | Jobs with unavailable stage duration |",
             "| --- | ---: | ---: |"]
    for name in STAGES:
        values = [job["stageSeconds"][name + "Seconds"] for job in report["jobs"]]
        known = sum(value for value in values if value is not None) if any(value is not None for value in values) else "unavailable"
        rows.append(f"| {name} | {known} | "
                    f"{sum(value is None for value in values)} |")
    results = report["commandResults"]
    failed = sum(row["classification"] in ("failure", "cancelled", "timeout") for row in results)
    transfers = [row for row in results if row["operation"] in ("upload", "download")]
    rows += ["", f"Local command/transfer receipts: {len(results)}; failed/cancelled/timed out: {failed}; "
             f"unattributed: {report['unattributedReceiptCount']}; archive transfer seconds known: "
             f"{sum(row['elapsedSeconds'] or 0 for row in transfers)} "
             f"({sum(row['elapsedSeconds'] is None for row in transfers)} unavailable); "
             f"transport attempts: {sum(len(row['transferAttempts']) for row in transfers)}.", ""]
    if any(row["unknownReasons"] for row in results):
        rows += [f"Receipts with unverified or mismatched provenance: {sum(bool(row['unknownReasons']) for row in results)}.", ""]
    if report["remainingCoverage"]:
        rows += ["Remaining exact jobs: " + ", ".join(cell(item) for item in report["remainingCoverage"]) + ".", ""]
    return "\n".join(rows)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    inputs = parser.add_mutually_exclusive_group()
    inputs.add_argument("--jobs", type=Path)
    inputs.add_argument("--github", action="store_true")
    parser.add_argument("--receipts", type=Path, action="append", default=[])
    parser.add_argument("--job-id", help="Explicit current job for local receipts; must match guard identity if present")
    args = parser.parse_args(argv)
    report, result = {"schemaVersion": 1, "kind": "execution-usage-reconciliation", "status": "failed"}, 1
    try:
        plan, jobs = read_json(args.plan), []
        if not isinstance(plan, dict):
            raise ValueError("an exact plan object is required")
        if args.jobs:
            jobs = read_json(args.jobs)
            if isinstance(jobs, dict):
                if jobs.get("total_count") != len(jobs.get("jobs", [])):
                    raise ValueError("incomplete offline jobs snapshot")
                jobs = jobs["jobs"]
        if args.github:
            client = artifact_transfer.GitHubArtifactClient(os.environ.get("GITHUB_REPOSITORY", ""),
                os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN", ""), os.environ.get("GITHUB_RUN_ID", ""))
            jobs = github_jobs(client, plan)
        receipts = [receipt for directory in args.receipts for receipt in read_receipts(directory)]
        guarded_job = plan.get("guard", {}).get("jobID")
        current_job = args.job_id or guarded_job
        if current_job is not None:
            if current_job not in {job["id"] for job in plan["jobs"]}:
                raise ValueError("current receipt job is absent from the exact plan")
            if guarded_job and guarded_job != current_job:
                raise ValueError("current receipt job differs from the entry guard")
            for envelope in receipts:
                if envelope["jobID"] is None:
                    envelope["jobID"] = current_job
                if os.environ.get("GITHUB_JOB"):
                    envelope["expectedGitHubJob"] = os.environ["GITHUB_JOB"]
        report = reconcile(plan, jobs, receipts)
        result = 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        report["error"] = str(error)
    finally:
        artifact_transfer.write_json(args.output, report)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as stream:
                stream.write(markdown(report))
    return result


if __name__ == "__main__":
    raise SystemExit(main())
