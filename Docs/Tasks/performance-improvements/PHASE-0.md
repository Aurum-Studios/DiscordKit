<!--
File: Docs/Tasks/performance-improvements/PHASE-0.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 0 — Attribution and measurement controls

Implements the measurement work in [Stage 0](PLAN.md#stage-0--qualify-attribution-and-measurement).
Runtime scheduling, JSON algorithms, replay protection and logging behavior retain
their existing policies. Numerical budgets remain unselected. Local integrity
checks and exploratory comparisons do not close the reserved-host qualification
gate or authorize the later optimization stages.

## Implementation plan and boundaries

1. Preserve every historical workload identity. Add versioned default-policy
   ordering and open-loop mutation workloads, plus a no-op arrival service using
   the same bounded generator. Retain complete policy and generator receipts.
2. Prepare full DAVE replay windows and continuous FIR/codec state once per
   population, separating warmup from measurement. Keep setup, independent result
   validation and final teardown outside batch timers. Vary JSON byte size,
   depth, width, string count, escaping and Unicode independently in versioned
   fixed-byte fixtures.
3. Compare observation modes at cohorts 1/4/16 and shared versus per-worker
   development collectors. Retain one shared correlation identity source, exact
   loss/output accounting and bounded resources. Keep default identities intact.
4. Fill direct attribution gaps without inferring unknown spans: opt-in REST
   execute entry, caller-to-verifier actor admission and each Gateway lease-store
   validate await. Existing storage/backend callback and pool hooks remain their
   documented boundaries; unavailable connect/TLS internals remain unknown.
5. Validate deterministic state, failure, cancellation, schema and cleanup
   contracts. Build release receipts only after code edits stop. Run independent
   no-change pairs and separate profiler captures sequentially, retaining host
   observations, failures and limitations. Select no numerical policy here.

## Workload identities

| Owner | Added controls | Historical interpretation |
| --- | --- | --- |
| REST | `rest.orderedMutationDefaultV1` | Literal `SchedulingPolicy()`; old `rest.orderedMutation` retains its tuned policy. |
| Arrival | `arrival.noopV1`, `arrival.orderedMutationDefaultSharedV1`, `arrival.orderedMutationDefaultIndependentV1` | Same bounded generator; shared and independent mutation partitions are distinct cases. Old `arrival.rest` remains the tuned GET rate control. |
| JSON | 24 `json.v2.parse.*` / `json.v2.serialize.*` cases | Exact-byte one-factor sweeps; all 77 old foundation case identities remain. |
| Media | Four `resample.v2.continuous.*`, twelve `opus.v2.continuous.*`, two `dave.v2.frame.open.replay*` | Population-owned streams and full default/max replay windows; all 80 old media cases retain per-batch preparation. |
| Observation | `--collector-scope shared` or `perWorker`, repeatable wrapper `--cohort 1/4/16` | Shared remains default. Per-worker identities append `.per-worker-collectors-v1`; `callbackContention` alone requires at least two workers. |

The [load](../../../Tools/DiscordKitLoadTests/README.md),
[foundation](../../../Tools/DiscordFoundationBenchmarks/README.md),
[media](../../../Tools/DiscordMediaBenchmarks/README.md) and
[observation](../../../Tools/DiscordTimingBenchmarks/README.md) guides document
finite commands and precise fixture contracts.

Arrival generator diagnostics have bounded whole-population lateness/headroom
histograms and explicit offered, assigned, pending-overflow rejection, missed,
terminal, drain and remaining-owner counts. Assigned-to-worker admission is
separate from an actual owner timestamp. The new REST timestamp is
`RESTClient.execute` entry after fixture admission and endpoint construction;
RESTClient is a class. It does not measure a REST actor queue or rate grant.
Unknown timestamps in old cases remain unknown. No-op service results locate
driver limits; closed-loop waves and deliberately held coalescing fixtures remain
separate from capacity evidence.

The original synchronous isolated `SignedRequestVerifier.verify` API remains.
`verifyWithAdmissionTiming` starts an optional interval before the actor hop and
ends it at actual actor entry. `DiscordSignedIngress` uses this wrapper. Signature
and replay checks still run atomically without suspension. Successful actor entry
does not imply accepted authentication. Gateway `leaseValidation` surrounds only
the injected store await; local generation fences still decide authority after it
returns. Existing scalar and signpost ordinals remain stable; the new stage is
appended. Nil hooks perform no observation-clock or identity work.

The supervisor now retains bounded before/after peer-process CPU-time/percentage
observations without arguments or environment, macOS thermal/power observations
when available and visible Linux cgroup-v2 ancestor throttling counters. These
snapshots are outside child measurement. They do not establish exclusive host
allocation, interval peer CPU deltas, process-tree peak RSS or allocation events.
Missing probes retain explicit unavailability.

## Qualification record

Local validation passed: 2,617 strict runtime tests in 34 targets; 9 observation,
20 foundation, 14 media and 105 load-harness tests; the strengthened JSON density
test was rerun after review. Python suites passed 47 shared driver/comparison,
4 observation wrapper, 38 load wrapper and 3 foundation wrapper tests. Fresh
public symbol graphs, scoped DocC regeneration, complete curation checks,
documentation example checks and conversion of all 33 public modules completed.
The retained API baseline comparison accepts the current pre-1.0 version intent.

Release receipts and local capture summaries follow in a separate evidence
commit so they identify a clean, reachable implementation revision. Five
no-change pairs per selected priority
workload establish descriptive local noise only when host reservation is unknown.
No p99 is accepted below 10,000 observations in each gated outcome population;
CPU/media percentiles always describe batches. No percentile subtraction, pooling
of run percentiles or batch-to-call percentile conversion is used.

The exit gate remains open until a named reserved host, reviewed no-change floor,
adequate precision/range and the target workload's sample population are all
established. Profiler failures are retained as failures. Local macOS evidence does
not establish Linux, hosted CI, devices, live Discord or production capacity.
