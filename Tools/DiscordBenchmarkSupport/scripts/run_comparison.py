#!/usr/bin/env python3
# File: Tools/DiscordBenchmarkSupport/scripts/run_comparison.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Capture explicitly selected prebuilt pairs and evaluate reviewed policies offline.

Capture never builds, adopts baselines or edits policies. Commands and receipt
paths in a spec resolve relative to that spec, with JSON arrays retaining literal
arguments. Reports retain all participant qualification limitations. Only verified
build/host/fixture receipts are attached to a separate report artifact.
"""

from __future__ import annotations

import argparse
import copy
import datetime
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import uuid
from typing import Any

import run_benchmarks as runner


SPEC_FORMAT = "discordkit.benchmark-comparison-spec"
SERIES_FORMAT = "DiscordBenchmarkSeries"


def read_json(path: Path) -> Any:
    """Read strict bounded artifacts without silently accepting nonfinite numbers."""
    if path.stat().st_size > runner.MAX_REPORT_BYTES:
        raise ValueError("JSON artifact exceeds report ceiling")
    return runner.strict_json(path.read_bytes())


def resolve_path(value: str, base: Path) -> Path:
    """Resolve explicit paths against a spec instead of an implicit shell directory."""
    if not isinstance(value, str) or not value:
        raise ValueError("paths must be nonempty strings")
    return (base / value).resolve()


def arguments_from_spec(spec_path: Path, output: Path) -> tuple[argparse.Namespace, dict[str, Any]]:
    """Validate finite capture settings before any process or output is created."""
    spec = read_json(spec_path)
    if not isinstance(spec, dict) or spec.get("format") != SPEC_FORMAT or type(spec.get("version")) is not int or spec["version"] != 1:
        raise ValueError("unsupported comparison spec")
    host = spec.get("host")
    if not isinstance(host, dict) or not isinstance(host.get("name"), str) or not host["name"].strip() or len(host["name"]) > 128:
        raise ValueError("an explicit finite host name is required")
    if type(host.get("controlled")) is not bool or host.get("contention") not in ("none", "known", "unknown"):
        raise ValueError("host controlled status and none/known/unknown contention are required")
    if not isinstance(host.get("notes"), str) or not host["notes"].strip() or len(host["notes"]) > 4096:
        raise ValueError("explicit host contention/allocation notes are required")
    profile = spec.get("profile")
    if profile not in runner.PROFILES:
        raise ValueError("an explicit reviewed profile is required")
    base = spec_path.resolve().parent
    arms = {}
    for arm in ("baseline", "candidate"):
        value = spec.get(arm)
        if not isinstance(value, dict):
            raise ValueError("explicit baseline and candidate are required")
        command = runner.command_array(json.dumps(value.get("command")))
        command[0] = str(resolve_path(command[0], base))
        arms[arm] = (command, resolve_path(value.get("receipt"), base))
    fixture_paths = spec.get("fixtures")
    if not isinstance(fixture_paths, list) or not fixture_paths or len(fixture_paths) > 256:
        raise ValueError("one to 256 explicit fixture paths are required")
    for field in ("scenario", "scheduler_policy", "warmup_policy"):
        if not isinstance(spec.get(field), str) or not spec[field].strip():
            raise ValueError(f"an explicit {field} is required")
    for field in ("seed", "concurrency", "warmup_seconds", "duration_seconds"):
        if type(spec.get(field)) is not int:
            raise ValueError(f"{field} must be an explicit integer")
    return argparse.Namespace(profile=profile, scenario=spec["scenario"], seed=spec["seed"],
        fixture=[resolve_path(item, base) for item in fixture_paths], command=None, receipt=None,
        baseline_command=arms["baseline"][0], baseline_receipt=arms["baseline"][1],
        candidate_command=arms["candidate"][0], candidate_receipt=arms["candidate"][1],
        output_dir=output, warmup_seconds=spec["warmup_seconds"], warmup_policy=spec["warmup_policy"],
        duration_seconds=spec["duration_seconds"], concurrency=spec["concurrency"],
        scheduler_policy=spec["scheduler_policy"]), spec


def allocation(environment: dict[str, Any]) -> tuple[str | None, int | None]:
    """Require actual Linux affinity/quota evidence, preserving unknown allocation."""
    count, memory = environment.get("logical_cpu_count"), environment.get("memory_bytes")
    if not isinstance(count, int) or count <= 0:
        return None, None
    linux = str(environment.get("operating_system", "")).startswith("Linux")
    if linux and (not environment.get("cpu_affinity") or not isinstance(environment.get("cpu_quota"), dict)
                  or environment.get("memory_limit_state") not in ("finite", "unlimited")):
        return None, None
    cap = environment.get("memory_limit_bytes")
    memory = min(memory, cap) if isinstance(memory, int) and isinstance(cap, int) else memory
    cpu = {key: environment.get(key) for key in ("logical_cpu_count", "cpu_affinity", "cpu_quota")}
    cpu["affinity_policy"] = "sched_getaffinity" if linux else "native scheduler; no process affinity API"
    return json.dumps(cpu, sort_keys=True, separators=(",", ":")), memory


def attach_receipts(report: dict[str, Any], receipt: dict[str, Any], environment: dict[str, Any],
                    fixtures: dict[str, str], named_host: str) -> dict[str, Any]:
    """Copy original report, attaching only authoritative receipts without changing scope."""
    result = copy.deepcopy(report)
    version = result.get("schemaVersion")
    if result.get("format") != "DiscordBenchmarkReport" or type(version) is not int or version != 1:
        raise ValueError("unsupported participant report")
    provenance = result.setdefault("provenance", {})
    if not isinstance(provenance, dict) or not isinstance(result.get("identity"), dict):
        raise ValueError("participant report has no structured identity/provenance")
    cpu, memory = allocation(environment)
    machine = environment.get("machine_identity_sha256")
    target = receipt.get("target_info", {}).get("target", {}).get("triple")
    sdk = receipt.get("sdk", {})
    sdk_identity = json.dumps({key: sdk[key] for key in ("path", "version")}, sort_keys=True) if sdk.get("path") and sdk.get("version") else (
        "not-applicable: Linux compiler target" if str(environment.get("operating_system", "")).startswith("Linux") else None)
    source = receipt["source"]
    participant_fixtures = result["identity"].get("fixtureHashes", {})
    if not isinstance(participant_fixtures, dict):
        raise ValueError("participant fixture identities must be a dictionary")
    combined_fixtures = {"participant:" + key: value for key, value in participant_fixtures.items()}
    combined_fixtures.update({"capture:" + key: value for key, value in fixtures.items()})
    verified = {"machineIdentity": named_host + ":" + machine if machine else None,
        "cpuModel": environment.get("cpu_model"), "architecture": environment.get("architecture"),
        "cpuAllocation": cpu, "memoryBytes": memory, "compiler": receipt.get("compiler"),
        "optimization": receipt["optimization"], "operatingSystem": environment.get("operating_system"),
        "sdk": sdk_identity, "target": target, "sourceRevision": source["revision"],
        "dirtyFingerprint": source["dirty_fingerprint_sha256"], "dependencyHashes": source["dependency_hashes"],
        "fixtureHashes": combined_fixtures, "executableHash": receipt["executable"]["sha256"], "buildFlags": receipt.get("build_flags")}
    reasons = provenance.setdefault("unavailabilityReasons", {})
    for key, value in verified.items():
        provenance[key] = value
        if value is not None and value != {}:
            reasons.pop(key, None)
        else:
            reasons[key] = "Verified capture receipt could not establish this field."
    # Both common-schema fixture maps must agree. Keep exact producer digests in
    # their own namespace, alongside selected files; the original stays untouched.
    result["identity"]["fixtureHashes"] = combined_fixtures
    return result


def assemble_series(manifest: dict[str, Any], spec: dict[str, Any], session: str,
                    output: Path) -> dict[str, Any]:
    """Retain complete paired reports while explicitly identifying missing observations."""
    series: dict[str, Any] = {"format": SERIES_FORMAT, "schemaVersion": 1, "pairs": [], "noisePairs": [],
        "captureStatus": manifest["status"], "namedHost": spec["host"], "profile": spec["profile"],
        "session": session, "informationalOnly": spec["profile"] != "standard" or not spec["host"]["controlled"] or spec["host"]["contention"] != "none",
        "missingObservations": [], "sourceOrchestration": str(output / "capture" / "orchestration.json")}
    rows = { (item["observation"]["repetition"], item["observation"]["arm"]): item
             for item in manifest["processes"] }
    fixture_hashes = manifest["fixture_hashes"]
    for index in range(manifest["repetitions"]):
        members = {arm: rows.get((index, arm)) for arm in ("baseline", "candidate")}
        reports = {}
        for arm, row in members.items():
            if row is None or row["status"] != "completed":
                series["missingObservations"].append({"pair": index, "arm": arm,
                    "reason": "not started" if row is None else row["status"]})
                continue
            before, after = row["environment_before"], row["environment_after"]
            if before != after or before != manifest["environment"]:
                raise ValueError("host allocation changed during capture")
            source_path = Path(row["stdout"]["path"]).parent / "benchmark-envelope.json"
            retained = next((item for item in row["reports"] if item["path"] == str(source_path)), None)
            if retained is None or runner.artifact(source_path) != retained:
                raise ValueError("participant envelope changed after process collection")
            source = read_json(source_path)
            identity = source.get("identity", {})
            expected = {"scenario": spec["scenario"], "profile": spec["profile"],
                        "seed": row["observation"]["seed"], "concurrency": row["observation"]["declared_active_cohort"],
                        "scheduler": spec["scheduler_policy"],
                        "requestedWarmupNanoseconds": spec["warmup_seconds"] * 1_000_000_000}
            if any(identity.get(key) != value for key, value in expected.items()):
                raise ValueError("participant workload policy differs from capture spec")
            report = attach_receipts(source, manifest["build_receipts"][arm], before, fixture_hashes, spec["host"]["name"])
            runner.atomic_json(source_path.parent / "comparison-report.json", report)
            reports[arm] = report
        if len(reports) != 2:
            continue
        baseline, candidate = members["baseline"], members["candidate"]
        series["pairs"].append({"id": session + ":" + str(index),
            "order": "baselineFirst" if baseline["observation"]["position"] == 0 else "candidateFirst",
            "baselineProcess": session + ":" + str(baseline["pid"]),
            "candidateProcess": session + ":" + str(candidate["pid"]),
            "hostContended": not spec["host"]["controlled"] or spec["host"]["contention"] != "none",
            "baseline": reports["baseline"], "candidate": reports["candidate"]})
    return series


def capture_series(spec_path: Path, output: Path, noise_path: Path | None,
                   cancellation: runner.Cancellation) -> dict[str, Any]:
    """Preserve lifecycle evidence on every failure, without reusing output directories."""
    args, spec = arguments_from_spec(spec_path, output.resolve() / "capture")
    output.mkdir(parents=True, exist_ok=False)
    status = {"format": "discordkit.benchmark-comparison-capture", "version": 1, "status": "running",
              "created_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "spec": runner.artifact(spec_path.resolve()), "host": spec["host"]}
    runner.atomic_json(output / "capture.json", status)
    try:
        manifest = runner.run_suite(args, cancellation)
        runner.validate_receipt(args.baseline_receipt, args.baseline_command)
        runner.validate_receipt(args.candidate_receipt, args.candidate_command)
        if runner.sha256_file(spec_path) != status["spec"]["sha256"]:
            raise ValueError("comparison spec changed during capture")
        series = assemble_series(manifest, spec, uuid.uuid4().hex, output)
        if noise_path is not None:
            noise = read_json(noise_path)
            if noise.get("format") != SERIES_FORMAT or noise.get("schemaVersion") != 1 or noise.get("captureStatus") != "completed":
                raise ValueError("noise input must be a completed captured series")
            if noise.get("namedHost") != spec["host"] or noise.get("profile") != spec["profile"]:
                raise ValueError("noise series host/profile differs")
            series["noisePairs"] = noise["pairs"]
            for pair in series["noisePairs"]:
                left, right = pair["baseline"]["provenance"], pair["candidate"]["provenance"]
                if any(left.get(key) != right.get(key) for key in ("executableHash", "sourceRevision", "dirtyFingerprint")):
                    raise ValueError("noise series must compare unchanged source and executable")
            series["noiseSource"] = runner.artifact(noise_path.resolve())
        runner.atomic_json(output / "series.json", series, compact=True)
        status["status"] = manifest["status"]
        status["series"] = runner.artifact(output / "series.json")
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError) as error:
        status["status"], status["failure"] = "failed", str(error)[:4096]
        manifest_path = args.output_dir / "orchestration.json"
        if manifest_path.is_file():
            partial = read_json(manifest_path)
            partial["status"], partial["failure"] = "failed", status["failure"]
            runner.atomic_json(manifest_path, partial)
    runner.atomic_json(output / "capture.json", status)
    return status


def evaluate_series(series: Path, policy: Path, evaluator: Path, output: Path,
                    cancellation: runner.Cancellation) -> dict[str, Any]:
    """Invoke the shared strict evaluator once, with finite retained diagnostics."""
    # Identity hashes are from canonical Swift encoding, never Python re-encoding.
    read_json(series)
    read_json(policy)
    output.mkdir(parents=True, exist_ok=False)
    result = runner.run_process([str(evaluator.resolve()), "evaluate", str(series.resolve()), str(policy.resolve())],
        output / "evaluation", runner.ProcessLimits(60, report_bytes=runner.MAX_REPORT_BYTES), cancellation,
        stdout_is_report=True, require_json=True)
    metadata = {"format": "discordkit.benchmark-comparison-evaluation", "version": 1,
                "status": result["status"], "series": runner.artifact(series.resolve()),
                "policy": runner.artifact(policy.resolve()), "evaluator": runner.artifact(evaluator.resolve()),
                "process": result}
    if result["native_json_valid"]:
        metadata["decision"] = read_json(Path(result["stdout"]["path"]))
    runner.atomic_json(output / "evaluation.json", metadata)
    return metadata


def main(argv: list[str] | None = None) -> int:
    """Expose explicit capture/evaluate operations; no operation refreshes a baseline."""
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    capture = sub.add_parser("capture")
    capture.add_argument("--spec", type=Path, required=True)
    capture.add_argument("--noise-series", type=Path)
    capture.add_argument("--output-dir", type=Path, required=True)
    evaluate = sub.add_parser("evaluate")
    evaluate.add_argument("--series", type=Path, required=True)
    evaluate.add_argument("--policy", type=Path, required=True)
    evaluate.add_argument("--evaluator", type=Path, required=True)
    evaluate.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args(argv)
    cancellation = runner.Cancellation()
    previous = {value: signal.signal(value, cancellation.request) for value in (signal.SIGINT, signal.SIGTERM)}
    try:
        result = (capture_series(args.spec, args.output_dir, args.noise_series, cancellation)
                  if args.operation == "capture" else
                  evaluate_series(args.series, args.policy, args.evaluator, args.output_dir, cancellation))
        print(json.dumps({"status": result["status"], "format": result["format"]}))
        return 0 if result["status"] == "completed" else 1
    except (OSError, ValueError, KeyError, TypeError, argparse.ArgumentTypeError, subprocess.SubprocessError) as error:
        print(f"benchmark comparison: {error}", file=sys.stderr)
        return 1
    finally:
        for value, handler in previous.items():
            signal.signal(value, handler)


if __name__ == "__main__":
    raise SystemExit(main())
