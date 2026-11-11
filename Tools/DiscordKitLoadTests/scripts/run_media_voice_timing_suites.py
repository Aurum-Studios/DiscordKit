#!/usr/bin/env python3
# File: Tools/DiscordKitLoadTests/scripts/run_media_voice_timing_suites.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Supervise finite component and scripted voice captures with strict population checks."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import signal
import subprocess
import sys

from run_timing_suites import SuiteProcesses


def media_execution(case: str, batch_size: int) -> tuple[str, int]:
    """Keep actual native owners/jobs distinct from the serial outer wrapper loop."""
    if case == "dave.transition.queue":
        return "joined-concurrent-signaling-batches", batch_size
    if case == "mls.v4.mixed.dense.members8":
        return "joined-concurrent-transition-media-batches-v4", 2
    if case.startswith("dave.v4.open."):
        return "serial-population-stream-v4", 1
    if case.startswith(("resample.v3.continuous.", "pcm.v3.queue.")):
        return "serial-population-stream-v3", 1
    if case.startswith(("resample.v2.continuous.", "opus.v2.continuous.", "dave.v2.frame.open.")):
        return "serial-population-stream-v2", 1
    return "serial-wrapper-batches", 1


def versioned_media_dimensions(case: str) -> dict:
    """Authenticate version-four endpoint/population policy before compacting its distribution."""
    match = re.fullmatch(r"dave\.v4\.open\.(steady|reorderDuplicate|authenticationFailure)\.replay(64|1024|8192)", case)
    if match:
        policy, window = match[1], int(match[2])
        return dict(fixtureVersion=4, payloadBytes=80, replayWindow=window, prefillFrames=window, continuousState=1,
                    authenticatedFramesPerCall=2 if policy == "reorderDuplicate" else 1,
                    duplicateRejectionsPerCall=int(policy == "reorderDuplicate"),
                    authenticationFailuresPerCall=int(policy == "authenticationFailure"), frameIntervalNanoseconds=20_000_000)
    match = re.fullmatch(r"dave\.v4\.expiry\.replay(64|1024|8192)", case)
    if match:
        return dict(fixtureVersion=4, payloadBytes=80, replayWindow=int(match[1]), prefillFrames=int(match[1]),
                    continuousState=0, authenticatedFramesPerCall=1, generationExpiriesPerCall=1,
                    generationRetentionSeconds=10, expiryOpenAtSeconds=11, startingGeneration=1, prefillGeneration=0)
    match = re.fullmatch(r"mls\.v4\.(add1|remove1|remove3|mixed)\.(dense|sparse)\.members(4|8|16)", case)
    if match:
        action, shape, members = match[1], match[2], int(match[3])
        removed, sparse, mixed = (3 if action == "remove3" else 0 if action == "add1" else 1), int(shape == "sparse"), action == "mixed"
        return dict(fixtureVersion=4, startingMembers=members - sparse, initialTreeLeaves=members,
                    endingMembers=members - sparse - removed + int(action == "add1"),
                    cachedRemovalProposals=removed, cachedAddProposals=int(action == "add1"), startingBlankLeaves=sparse,
                    welcomeJoinInsideTimer=0, proposalAdmissionInsideTimer=0, prepareCommitInsideTimer=1,
                    allPeerAcceptanceInsideTimer=1, concurrentJobsPerCall=2 if mixed else 1,
                    authenticatedMediaFramesPerCall=64 if mixed else 0, mediaReplayWindow=1024 if mixed else 0,
                    mediaPrefillFrames=1024 if mixed else 0)
    match = re.fullmatch(r"(rtp|jitter)\.v4\.accounting\.(serialize|insertPop)\.payload(80|1200|16000)", case)
    if match:
        jitter, payload = match[1] == "jitter", int(match[3])
        return dict(fixtureVersion=4, packetsPerCall=8, payloadBytes=payload, contributingSources=2,
                    extensionBytes=8, paddingBytes=4, serializedBytesPerPacket=payload + 36,
                    jitterCapacity=8 if jitter else 0, jitterInsertAndPopInsideTimer=int(jitter),
                    serializationOnlyForLength=int(not jitter))
    return {}


def matrix(family: str, cases: list[str]) -> list[dict]:
    """Keep every case and explicit batch/cohort sweeps in separate fresh processes."""
    if family not in ("media", "voice") or not cases:
        raise ValueError("unsupported or empty family")
    rows = []
    for case in dict.fromkeys(cases):
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", case):
            raise ValueError("unsafe case identity")
        base = dict(name=case, case=case, family=family, batch_size=2, concurrency=1,
                    profile="smoke", duration_seconds=10, warmup_seconds=1)
        if family == "media":
            base["scheduler"], base["concurrency"] = media_execution(case, base["batch_size"])
        else:
            base["scheduler"] = "bounded-scripted-voice-cohort"
        rows.append(base)
        if family == "media" and case in ("jitter.reorder.loss", "dave.transition.queue"):
            rows.append(dict(base, name=case + "-batch8", batch_size=8,
                             concurrency=8 if case == "dave.transition.queue" else 1))
        if family == "voice" and case in ("voice.join", "voice.move", "voice.lifecycleJoined"):
            rows.append(dict(base, name=case + "-c4", concurrency=4))
    return rows


def compact(native: dict, row: dict) -> dict:
    """Reject relabeled inputs, missing terminal outcomes, biased histograms and owners."""
    media = row["family"] == "media"
    if (native.get("format") != ("DiscordMediaBenchmarks" if media else "DiscordKitLoadTests.voice-timing") or
            type(native.get("schemaVersion")) is not int or native["schemaVersion"] != 1):
        raise ValueError("unsupported native report")
    common, configuration = native["common"], native["configuration"]
    identity, counts, cleanup = common["identity"], common["counts"], common["cleanup"]
    expected = {"workload" if media else "scenario": row["case"], "profile": row["profile"],
                "durationSeconds": row["duration_seconds"], "warmupSeconds": row["warmup_seconds"], "seed": row["seed"]}
    if media:
        expected.update(batches=row["operations"], batchSize=row["batch_size"], warmupBatches=row["warmup_operations"])
        primary = "mls.transition" if row["case"].startswith("mls.") or row["case"] == "dave.transition.queue" else "media.batch"
        dimensions = {"batchSize": row["batch_size"], "batchesCap": row["operations"],
                      "warmupBatchesCap": row["warmup_operations"], "durationCapSeconds": row["duration_seconds"]}
        dimensions.update(versioned_media_dimensions(row["case"]))
        scheduler, concurrency = media_execution(row["case"], row["batch_size"])
        if (native["completedBatches"] != row["operations"] or
                native["completedCalls"] != row["operations"] * row["batch_size"] or
                native["warmupBatches"] != row["warmup_operations"] or
                native["warmupCalls"] != row["warmup_operations"] * row["batch_size"]):
            raise ValueError("incomplete component batches or calls")
    else:
        expected.update(requests=row["operations"], warmupRequests=row["warmup_operations"], concurrency=row["concurrency"])
        primary = "voice.lifecycleJoined"
        dimensions = {"requests": row["operations"], "warmupRequests": row["warmup_operations"],
                      "configuredConcurrency": row["concurrency"], "durationCapSeconds": row["duration_seconds"]}
        concurrency = min(row["concurrency"], row["operations"])
        scheduler = "bounded-scripted-voice-cohort"
        if any(type(value) is not int or value != 0 for value in native["measurement"]["ownership"].values()):
            raise ValueError("retained fixture owners")
    if any(configuration.get(key) != value or type(configuration.get(key)) is not type(value) for key, value in expected.items()):
        raise ValueError("participant configuration mismatch")
    if (common.get("format") != "DiscordBenchmarkReport" or common.get("schemaVersion") != 1 or
            identity.get("catalogVersion") != 9 or identity.get("scenario") != row["case"] or
            identity.get("profile") != row["profile"] or identity.get("concurrency") != concurrency or
            identity.get("scheduler") != scheduler or row["scheduler"] != scheduler or
            (media and row["concurrency"] != concurrency) or
            type(identity.get("seed")) is not int or identity["seed"] != row["seed"] or
            any(identity["inputSizes"].get(key) != value or type(identity["inputSizes"].get(key)) is not int
                for key, value in dimensions.items())):
        raise ValueError("common identity mismatch")
    outcomes = counts["outcomes"]
    if (common["status"] != "completed" or cleanup.get("completed") is not True or
            type(cleanup.get("remainingOwners")) is not int or cleanup["remainingOwners"] != 0 or
            any(type(counts.get(key)) is not int for key in ("offered", "admitted", "completed", "deadlineMisses")) or
            counts["completed"] != row["operations"] or counts["offered"] != counts["completed"] or
            not 0 <= counts["admitted"] <= counts["offered"] or not 0 <= counts["deadlineMisses"] <= counts["offered"] or
            set(outcomes) != {"success", "failure", "cancelled", "timedOut", "rejected", "uncertain"} or
            any(type(value) is not int or value < 0 for value in outcomes.values()) or
            sum(outcomes.values()) != counts["completed"]):
        raise ValueError("incomplete terminal population or cleanup")
    metrics = common["metrics"]
    if not metrics:
        raise ValueError("empty distributions")
    for outcome, count in outcomes.items():
        if sum(metric["distribution"]["observedCount"] for metric in metrics
               if metric["id"] == primary and metric["outcome"] == outcome) != count:
            raise ValueError("primary outcome mismatch")
    for metric in metrics:
        distribution = metric["distribution"]
        if distribution["droppedCount"] != 0 or distribution["counterOverflow"]:
            raise ValueError("aggregate timing loss")
        if metric["clockDomain"] != common["clockDomain"]:
            raise ValueError("mixed monotonic clock domains")
    return dict(row, inputSizes=identity["inputSizes"], scheduler=identity["scheduler"], counts=counts,
                metrics=[{key: metric[key] for key in ("id", "outcome", "p50", "p95", "p99", "maximum")}
                                           for metric in metrics], gauges=common["gauges"],
                nativeReport=str(Path(row["name"]) / "00-single" / "native-report.json"))


def participant_command(executable: Path, row: dict) -> list[str]:
    """Use argument arrays; warmup, caps and case dimensions are explicit participant inputs."""
    result = [str(executable)] + ([] if row["family"] == "media" else ["voice-timing"])
    result += ["--case", row["case"], "--profile", "{profile}", "--seed", "{seed}",
               "--duration-seconds", "{duration_seconds}", "--warmup-seconds", "{warmup_seconds}",
               "--output", "{output}", "--concurrency", "1" if row["family"] == "media" else "{concurrency}"]
    if row["family"] == "media":
        result += ["--batches", str(row["operations"]), "--warmup-batches", str(row["warmup_operations"]),
                   "--batch-size", str(row["batch_size"])]
    else:
        result += ["--requests", str(row["operations"]), "--warmup-requests", str(row["warmup_operations"])]
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--family", required=True, choices=("media", "voice"))
    parser.add_argument("--executable", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--validator", required=True, type=Path, help="built DiscordBenchmarkReports executable")
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--case", action="append", default=[])
    parser.add_argument("--operations", type=int, default=8)
    parser.add_argument("--warmup-operations", type=int, default=1)
    arguments = parser.parse_args(argv)
    if not 1 <= arguments.operations <= 10_000 or not 0 <= arguments.warmup_operations <= 1_000:
        parser.error("operations must be 1...10000; warmup operations 0...1000")
    processes = SuiteProcesses()
    signal.signal(signal.SIGINT, processes.request)
    signal.signal(signal.SIGTERM, processes.request)
    executable = arguments.executable.resolve()
    prefix = [] if arguments.family == "media" else ["voice-timing"]
    listed = processes.run([str(executable), *prefix, "--list-cases"], timeout=30,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if processes.cancelled:
        return 130
    listed.check_returncode()
    cases = listed.stdout.splitlines()
    if not cases or len(set(cases)) != len(cases):
        raise ValueError("empty or duplicate finite cases")
    if arguments.case:
        if not set(arguments.case).issubset(cases):
            parser.error("unknown case")
        cases = list(dict.fromkeys(arguments.case))
    rows = matrix(arguments.family, cases)
    arguments.output_dir.mkdir(parents=True, exist_ok=False)
    package = Path(__file__).resolve().parents[1]
    shared = package.parent / "DiscordBenchmarkSupport" / "scripts" / "run_benchmarks.py"
    captured = []
    for selected in rows:
        if processes.cancelled:
            return 130
        row = dict(selected, operations=arguments.operations, warmup_operations=arguments.warmup_operations)
        destination = (arguments.output_dir / row["name"]).resolve()
        command = participant_command(executable, row)
        supervised = [sys.executable, str(shared), "run", "--profile", row["profile"], "--scenario", row["name"],
                      "--receipt", str(arguments.receipt.resolve()), "--command", json.dumps(command),
                      "--output-dir", str(destination), "--concurrency", str(row["concurrency"]),
                      "--scheduler-policy", row["scheduler"],
                      "--duration-seconds", str(row["duration_seconds"]), "--warmup-seconds", str(row["warmup_seconds"]),
                      "--warmup-policy", "participant-declared"]
        if arguments.family == "media":
            # The listed catalog spans several fixture owners; retain the complete finite source policy as provenance.
            fixtures = sorted((package.parent / "DiscordMediaBenchmarks" / "Sources" / "DiscordMediaBenchmarks").glob("*.swift"))
        else:
            fixtures = [package / "Sources" / "DiscordKitLoadTests" / "VoiceLifecycleTimingRunner.swift"]
        for fixture in fixtures:
            supervised += ["--fixture", str(fixture)]
        status = processes.run(supervised).returncode
        if processes.cancelled:
            return 130
        if status:
            return status
        envelope = destination / "00-single" / "benchmark-envelope.json"
        verified = processes.run([str(arguments.validator.resolve()), "validate", str(envelope)],
                                 timeout=30, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if processes.cancelled:
            return 130
        verified.check_returncode()
        native = json.loads((destination / "00-single" / "native-report.json").read_text())
        if native["common"] != json.loads(envelope.read_text()):
            raise ValueError("native and independently validated common envelope disagree")
        orchestration = json.loads((destination / "orchestration.json").read_text())
        if (len(orchestration["processes"]) != 1 or orchestration["processes"][0]["status"] != "completed"):
            raise ValueError("incomplete supervised process")
        row["seed"] = orchestration["processes"][0]["observation"]["seed"]
        captured.append(compact(native, row))
        summary = dict(format="DiscordKit.phase9-timing-matrix", schemaVersion=1, family=arguments.family,
                       qualification="informational local smoke; no numerical, device or live qualification", cases=captured)
        temporary = arguments.output_dir / "summary.partial.json"
        temporary.write_text(json.dumps(summary, indent=2, sort_keys=True, allow_nan=False) + "\n")
        temporary.replace(arguments.output_dir / "summary.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
