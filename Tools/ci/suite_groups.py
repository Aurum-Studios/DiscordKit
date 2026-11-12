# File: Tools/ci/suite_groups.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Deterministic complete-module groups from retained, explicitly mixed timings.

The baseline API step includes restore/discovery/test work. These weights balance
initial groups; they do not measure isolated test runtime or predict savings.
"""

from datetime import datetime
import hashlib
import json
from pathlib import Path
import re


REPOSITORY = Path(__file__).resolve().parents[2]
DEFAULT_DATA = Path(__file__).with_name("suite-groups.v1.json")
DEFAULT_BASELINE = REPOSITORY / "Docs/Tasks/ci-reliability/baseline"
PLATFORMS = ("linux-x64", "macos-arm64", "windows-x64")
GROUP_NAMES = ("root-01", "root-02", "root-03", "root-04")
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def load_duration_data(path=DEFAULT_DATA):
    """Validate versioned planning input without silently replacing malformed data."""
    data = json.loads(Path(path).read_text())
    if data.get("schemaVersion") != 1 or data.get("rootGroupNames") != list(GROUP_NAMES):
        raise ValueError("unsupported suite-group duration contract")
    if data.get("weightKind") != "mixed-restore-discovery-test-api-step-seconds":
        raise ValueError("suite weights must identify their mixed-stage measurement")
    if set(data.get("platforms", {})) != set(PLATFORMS):
        raise ValueError("suite-group duration platforms are incomplete")
    sources = data.get("sources", {})
    for platform, entry in data["platforms"].items():
        fallback = entry.get("fallbackWeightSeconds")
        if type(fallback) is not int or fallback < 1:
            raise ValueError("a positive conservative fallback weight is required")
        for suite, observation in entry.get("suites", {}).items():
            seconds = observation.get("seconds")
            if (not IDENTIFIER.fullmatch(suite) or type(seconds) is not int or seconds < 1
                    or observation.get("source") not in sources
                    or type(observation.get("jobID")) is not int
                    or type(observation.get("stepNumber")) is not int):
                raise ValueError(f"invalid retained suite weight: {platform}/{suite}")
        if entry.get("suites") and fallback < max(row["seconds"] for row in entry["suites"].values()):
            raise ValueError("new-suite fallback must cover the largest observed platform step")
    return data


def active_targets(targets, platform):
    """Retain the planner's declared source-availability platform exclusions."""
    return [suite for suite in targets
            if not (platform == "windows-x64" and suite == "DiscordUnixPlatformTests")
            and not (platform != "macos-arm64" and suite == "DiscordFoundationTransportTests")]


def root_groups(targets, platform, *, data=None):
    """Assign every active whole module exactly once by deterministic greedy balance.

    Descending measured/fallback weight is placed in the lowest-total group;
    module name and group name break ties. Inventory order never changes output.
    The returned weights remain planning inputs, never measured group durations.
    """
    if platform not in PLATFORMS:
        raise ValueError("unsupported native platform")
    targets = list(targets)
    if not targets or len(targets) != len(set(targets)):
        raise ValueError("a nonempty unique root test-target inventory is required")
    if any(not isinstance(suite, str) or not IDENTIFIER.fullmatch(suite) for suite in targets):
        raise ValueError("unsupported root test-target name")
    data = data if data is not None else load_duration_data()
    entry = data["platforms"][platform]
    weights = {suite: entry["suites"].get(suite, {}).get("seconds", entry["fallbackWeightSeconds"])
               for suite in active_targets(targets, platform)}
    groups = [{"name": name, "suite": name, "suites": [], "planningWeightSeconds": 0,
               "durationSources": []} for name in GROUP_NAMES]
    for suite in sorted(weights, key=lambda name: (-weights[name], name)):
        group = min(groups, key=lambda row: (row["planningWeightSeconds"], row["name"]))
        observation = entry["suites"].get(suite)
        source = {"suite": suite, "seconds": weights[suite],
                  "kind": "retained-mixed-step" if observation else "unmeasured-conservative-fallback"}
        if observation:
            source.update(source=observation["source"], jobID=observation["jobID"],
                          stepNumber=observation["stepNumber"])
        else:
            source["reason"] = entry["fallbackReason"]
        group["suites"].append(suite)
        group["planningWeightSeconds"] += weights[suite]
        group["durationSources"].append(source)
    for group in groups:
        group["suites"].sort()
        group["durationSources"].sort(key=lambda row: row["suite"])
    return groups


def verify_retained_sources(data=None, *, repository=REPOSITORY):
    """Prove every derived timing still matches its SHA-bound retained API step."""
    data = data if data is not None else load_duration_data()
    pages = {}
    for name, source in data["sources"].items():
        path = repository / source["path"]
        if hashlib.sha256(path.read_bytes()).hexdigest() != source["sha256"]:
            raise ValueError(f"retained duration source digest differs: {name}")
        document = json.loads(path.read_text())
        jobs = document["jobs"]
        jobs = jobs["jobs"] if isinstance(jobs, dict) else jobs
        pages[name] = {job["id"]: job for job in jobs}
    labels = {"linux-x64": "Linux x64", "macos-arm64": "macOS ARM64"}
    for platform, entry in data["platforms"].items():
        for suite, observation in entry["suites"].items():
            job = pages[observation["source"]][observation["jobID"]]
            steps = [step for step in job["steps"] if step["number"] == observation["stepNumber"]]
            if (job["name"] != f"{labels[platform]} / Tests / {suite}"
                    or job["conclusion"] != "success" or job["head_sha"] != data["baselineHeadSHA"]
                    or job["run_id"] != data["baselineRunID"] or len(steps) != 1):
                raise ValueError("retained suite duration owner differs")
            step = steps[0]
            elapsed = (datetime.fromisoformat(step["completed_at"].replace("Z", "+00:00"))
                       - datetime.fromisoformat(step["started_at"].replace("Z", "+00:00"))).total_seconds()
            if (not step["name"].startswith("Run only the selected suite")
                    or step["conclusion"] != "success" or elapsed != observation["seconds"]
                    or step["started_at"] != observation["startedAt"]
                    or step["completed_at"] != observation["completedAt"]):
                raise ValueError("retained suite duration differs")
    return True


def compare_baseline(build_matrix, test_matrix, *, baseline=DEFAULT_BASELINE):
    """Compare planned native topology with retained measurements without savings estimates."""
    baseline = Path(baseline)
    summary = json.loads((baseline / "cost-summary.json").read_text())
    runs = []
    for run in summary["runs"]:
        categories = run["stepSecondsByCategory"]
        native = [job for job in run["jobs"]
                  if job["name"].startswith(("Linux x64 / ", "macOS ARM64 / "))]
        native_tests = [job for job in native if " / Tests / " in job["name"]]
        native_builds = [job for job in native if " / Builds / " in job["name"]]
        runs.append({"runID": run["runID"], "name": run["name"],
                     "wholeWorkflowJobCount": run["jobCount"],
                     "nativeTestJobCount": len(native_tests),
                     "nativeBuildJobCount": len(native_builds),
                     "wholeWorkflowSetupSeconds": categories["setup"],
                     "wholeWorkflowSeparateRestoreSeconds": categories["restore"],
                     "wholeWorkflowMixedTestsRestoreSeconds": categories["tests"],
                     "wholeWorkflowRunnerSecondsKnown": run["runnerSecondsKnown"],
                     "wholeWorkflowRoundedRunnerMinutesKnown": run["billedMinutesEstimateKnown"],
                     "wholeWorkflowWallSeconds": None,
                     "storedArchiveBytes": run["artifacts"]["storedArchiveBytes"],
                     "observedCompletedDownloadArchiveBytes": run["downloads"]["observedCompletedDownloadArchiveBytes"],
                     "workflowTotalDownloadedBytes": None, "wireBytes": None})
    return {"schemaVersion": 1, "kind": "planned-native-topology-versus-retained-baseline",
            "baseline": runs,
            "plannedNative": {"buildJobs": len(build_matrix["include"]),
                              "testGroupJobs": len(test_matrix["include"]),
                              "totalBuildAndTestJobs": len(build_matrix["include"]) + len(test_matrix["include"])},
            "postChangeMeasurements": None,
            "limitations": ["Planned counts cover native build/test groups, not the whole workflow.",
                            "Baseline suite helper timings include restore/discovery/tests and are not isolated runtime.",
                            "Run completion timestamps are absent; workflow wall time remains unavailable.",
                            "Archive bytes are not transfer bytes; observed downloads cover only a retained subset.",
                            "Post-change setup/restore/bytes/runner minutes/wall time require authorized hosted measurement."]}
