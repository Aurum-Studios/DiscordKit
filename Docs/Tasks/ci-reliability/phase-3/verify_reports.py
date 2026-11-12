#!/usr/bin/env python3
# File: Docs/Tasks/ci-reliability/phase-3/verify_reports.py
# Created by Carson Rau.
# Copyright (c) 2026 Aurum Studios.
# https://aurum-studios.com

"""Verify the exact phase-3 populations and retain source-bound acceptance results."""
from pathlib import Path
import hashlib
import json
import math
import sys

ROOT = Path(__file__).resolve().parents[4]
OUTPUT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "Tools/ci"))
from native_jobs import read_timing_json, verify_common_smoke

CASES = ("directImmediate", "dslImmediate", "directDeferred", "dslDeferred",
         "directFailure", "dslFailure", "directCancelled", "dslCancelled")
OUTCOMES = {"success", "failure", "cancelled", "timedOut", "rejected", "uncertain"}
MAXIMUM_REPORT_BYTES = 32 * 1024 * 1024


def require(condition, message):
    """Reject a missing acceptance fact without relying on Python assertions being enabled."""
    if not condition:
        raise ValueError(message)


def natural(value):
    """JSON booleans must never masquerade as numeric population evidence."""
    return type(value) is int and value >= 0


def exact_fields(value, expected, label):
    """Check declared fields with exact JSON value types while allowing unrelated metadata."""
    require(isinstance(value, dict), label + " must be an object")
    for key, wanted in expected.items():
        require(type(value.get(key)) is type(wanted) and value[key] == wanted,
                f"{label}.{key} must equal {wanted!r}")


def load_pair(name, inputs):
    """Bound the two documents and preserve their byte identities before checking their contents."""
    documents = []
    for suffix in (".json", "-common.json"):
        path = OUTPUT / (name + suffix)
        require(0 < path.stat().st_size <= MAXIMUM_REPORT_BYTES,
                path.name + " is empty or exceeds the report ceiling")
        data = path.read_bytes()
        document = read_timing_json(path)
        require(path.read_bytes() == data, path.name + " changed during verification")
        inputs.append(dict(path=path.name, bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
        require(isinstance(document, dict), path.name + " must be an object")
        documents.append(document)
    native, common = documents
    require(native.get("common") == common, name + " common sidecar differs from its native report")
    return native, common


def measurement(native, family):
    """Require the declared Swift Codable measurement case and its sole associated value."""
    value = native.get("measurement")
    require(isinstance(value, dict) and set(value) == {family}, "unexpected measurement family")
    value = value[family]
    require(isinstance(value, dict) and set(value) == {"_0"} and isinstance(value["_0"], dict),
            "malformed measurement associated value")
    return value["_0"]


def check_counts(counts, requests, outcome):
    """All terminal categories remain explicit, including the five expected zero populations."""
    exact_fields(counts, dict(offered=requests, admitted=requests, completed=requests, deadlineMisses=0), "counts")
    outcomes = counts.get("outcomes")
    require(isinstance(outcomes, dict) and set(outcomes) == OUTCOMES, "incomplete outcome partition")
    exact_fields(outcomes, {key: requests if key == outcome else 0 for key in OUTCOMES}, "outcomes")


def check_matching_measurement(value, common, requests, outcome):
    """Native counters, distributions and clocks must be the actual common-envelope observations."""
    check_counts(value.get("counts"), requests, outcome)
    require(value["counts"] == common.get("counts"), "native/common counts differ")
    require(value.get("metrics") == common.get("metrics"), "native/common metrics differ")
    domain = value.get("clockDomain")
    require(isinstance(domain, str) and domain and common.get("clockDomain") == domain,
            "native/common clock domains differ or are absent")
    for metric in common.get("metrics", []):
        require(isinstance(metric, dict) and metric.get("clockDomain") == domain,
                "metric clock domain differs from its report")


def verify_synthetic(case, inputs):
    """Check every direct/DSL outcome and its exact response/cleanup population."""
    name = "scenario-" + case
    native, common = load_pair(name, inputs)
    outcome = "failure" if case.endswith("Failure") else "cancelled" if case.endswith("Cancelled") else "success"
    deferred = case.endswith("Deferred")
    scenario = "synthetic." + case
    exact_fields(native, dict(format="DiscordKitLoadTests.command-timing", schemaVersion=1), "native")
    exact_fields(native.get("configuration"), dict(scenario=scenario, profile="smoke", seed=1,
                 requests=7, concurrency=3, warmupRequests=0, rate=1000, delayMicroseconds=0,
                 durationSeconds=3, warmupSeconds=0), "configuration")
    value = measurement(native, "synthetic")
    exact_fields(value, dict(scenario=scenario, callbacks=7 if outcome == "success" else 0,
                 edits=7 if deferred else 0), "measurement")
    exact_fields(value.get("cleanup"), dict(handlers=0, acknowledgements=0, acknowledgementBytes=0), "cleanup")
    check_matching_measurement(value, common, 7, outcome)
    exact_fields(common, dict(adapter="synthetic-command-router", status="completed"), "common")
    identity = common.get("identity")
    exact_fields(identity, dict(catalog="discordkit.timing", catalogVersion=6, scenario=scenario,
                 profile="smoke", profileVersion=1, seed=1, instrumentation="whole-population-aggregate",
                 scheduler="closed-loop-command-cohort", concurrency=3, warmupNanoseconds=0,
                 requestedWarmupNanoseconds=0, repetitions=1), "identity")
    exact_fields(identity.get("inputSizes"), dict(requests=7, warmupRequests=0, configuredConcurrency=3,
                 configuredGatewayArrivalRate=1000, delayMicroseconds=0, durationCapSeconds=3), "inputSizes")
    duration = value.get("durationNanoseconds")
    require(natural(duration) and duration > 0 and identity.get("measuredNanoseconds") == duration,
            "measured duration does not match the native workflow interval")
    throughput = common.get("throughputPerSecond")
    require(type(throughput) in (int, float) and math.isfinite(throughput)
            and math.isclose(throughput, 7_000_000_000 / duration, rel_tol=1e-12),
            "throughput does not derive from the exact terminal population")

    expected_metrics = {(key, outcome) for key in ("synthetic.invoke", "synthetic.providerWait",
                                                 "command.route", "command.handler")}
    expected_metrics.update((key, "success") for key in ("command.arguments", "command.admission"))
    if outcome == "success":
        expected_metrics.add(("interaction.initialResponse", "success"))
    if deferred:
        expected_metrics.add(("interaction.originalEdit", "success"))
    metrics = common.get("metrics")
    require(isinstance(metrics, list) and len(metrics) == len(expected_metrics), "unexpected metric population")
    actual_metrics = set()
    for metric in metrics:
        exact_fields(metric, dict(version=1), "metric")
        exact_fields(metric.get("distribution"), dict(observedCount=7), "metric.distribution")
        key = (metric.get("id"), metric.get("outcome"))
        require(key in expected_metrics and key not in actual_metrics, "unexpected or duplicate metric/outcome")
        actual_metrics.add(key)
    require(actual_metrics == expected_metrics, "missing metric/outcome")
    # The reviewed shared smoke checker validates exact histogram partitions, bucket
    # counts and loss. Its success-only outcome restriction is projected solely on
    # this in-memory copy after the original outcome of every row was checked above.
    projected = dict(common, counts=dict(common["counts"], outcomes={key: 7 if key == "success" else 0 for key in OUTCOMES}),
                     metrics=[dict(metric, outcome="success") for metric in metrics])
    verify_common_smoke(projected)
    return dict(case=scenario, status="passed", expectedOutcome=outcome, counts=value["counts"],
                callbacks=value["callbacks"], edits=value["edits"], cleanup=value["cleanup"],
                metricPopulations=[dict(id=metric["id"], outcome=metric["outcome"],
                                       observedCount=metric["distribution"]["observedCount"]) for metric in metrics])


def verify_smoke(kind, inputs):
    """Reuse CI smoke acceptance and additionally inspect native peer/pool/REST ownership."""
    native, common = load_pair("smoke-" + kind, inputs)
    scenario, adapter, family = ("rest.cacheFresh", "scripted", "rest") if kind == "rest" else ("transport.smallBody", "nio", "transport")
    exact_fields(native, dict(format="DiscordKitLoadTests.timing", schemaVersion=1), "native")
    exact_fields(native.get("configuration"), dict(scenario=scenario, adapter=adapter, requests=16,
                 concurrency=2, warmupRequests=2, profile="smoke", seed=1, durationSeconds=3, warmupSeconds=1), "configuration")
    verify_common_smoke(common)
    value = measurement(native, family)
    check_matching_measurement(value, common, 16, "success")
    exact_fields(common.get("identity"), dict(catalogVersion=5, scenario=scenario, profile="smoke", seed=1,
                 concurrency=2, requestedWarmupNanoseconds=1_000_000_000, repetitions=1), "identity")
    cleanup = value.get("cleanup")
    if kind == "rest":
        exact_fields(value, dict(scenario="cacheFresh", requests=16, concurrency=2, wireExchanges=0,
                     setupWireExchanges=1, subscribers=0), "measurement")
        exact_fields(cleanup, {key: 0 for key in ("active", "queued", "ordered", "flights", "waiters",
                     "cacheEntries", "transportBodies", "transportActive")}, "cleanup")
    else:
        exact_fields(value, dict(scenario=scenario, configuredRequests=16, concurrency=2, adapter="nio",
                     connectionMode="warm", tls=False, warmupRequests=2, receivedBytes=4096, uploadedBytes=0), "measurement")
        exact_fields(cleanup, dict(ownedAdaptersClosed=True, poolActiveAfterShutdown=0, poolIdleAfterShutdown=0), "cleanup")
        peer = cleanup.get("peerConnections")
        exact_fields(peer, dict(activeConnections=0), "peerConnections")
        require(all(natural(peer.get(key)) and peer[key] > 0 for key in ("acceptedConnections", "peakConnections")),
                "loopback smoke has no confirmed accepted/peak connection evidence")
        require(peer["peakConnections"] <= peer["acceptedConnections"], "peer peak exceeds accepted connections")
    return dict(case=scenario, status="passed", counts=value["counts"], cleanup=cleanup,
                metricCount=len(common["metrics"]))


def main():
    """Always retain all ten acceptance verdicts; no command here runs a load or performance probe."""
    inputs, scenarios, smokes = [], [], []
    for case in CASES:
        try:
            scenarios.append(verify_synthetic(case, inputs))
        except (OSError, ValueError, KeyError, TypeError, AttributeError, OverflowError) as error:
            scenarios.append(dict(case="synthetic." + case, status="failed", error=str(error)))
    for kind in ("rest", "loopback"):
        try:
            smokes.append(verify_smoke(kind, inputs))
        except (OSError, ValueError, KeyError, TypeError, AttributeError, OverflowError) as error:
            smokes.append(dict(case="smoke-" + kind, status="failed", error=str(error)))
    passed = all(row["status"] == "passed" for row in scenarios + smokes)
    summary = dict(schemaVersion=1, status="passed" if passed else "failed",
                   scope="Local report semantics and joined cleanup; no numerical, native-host or live-service qualification.",
                   verifierSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                   scenarios=scenarios, smokes=smokes, inputs=inputs)
    (OUTPUT / "scenario-report-validation.json").write_text(json.dumps(summary, sort_keys=True, indent=2, allow_nan=False) + "\n")
    print(json.dumps(dict(status=summary["status"], scenarios=len(scenarios), smokes=len(smokes)), sort_keys=True))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
