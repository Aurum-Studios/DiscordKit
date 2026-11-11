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

Release receipts and local capture summaries are retained in the
[Phase 0 capture index](phase-0-observations.json). Captures ran on 2026-11-10
America/Chicago against clean implementation revision
`1b1ba8cd4fe8c7a7bbc5bce72098d092e608ceee`. This evidence-only descendant changes
documentation, preserving the executable inputs measured by those receipts.
All four release receipts were checked against source and executable again
before writing this evidence. Full native/common reports, comparison specs,
orchestration and profile diagnostics remain in the ignored
[local capture directory](../../../.build/performance-phase0), identified by
SHA-256 in the index. The index retains exact commands and per-run results,
including failures; it does not replace the full artifacts.

Eight priority workloads completed five independent no-change pairs each:
80 fresh processes with alternating baseline-first/candidate-first order within
each workload. The observer matrix added 60 fresh-process integrity runs across
ten modes, cohorts 1/4/16 and both collector scopes. Two additional default-policy
arrival controls completed. All 142 workload processes exited zero, reaped their
owners, left no live process-group members and reported zero remaining owners.
Independent shared-schema validation passed all 142 original common reports and
80 comparison copies. Builds, tests, workload captures and profiler captures did
not overlap with one another during measurement.

The table describes the enclosing range of ten separate per-run p50 bins for
each workload, not a pooled population or a numerical baseline. No-change pairs
establish descriptive local noise only because host reservation is unknown.

| Workload | Observations per run | Bucket width | Enclosing range of per-run p50 bins |
| --- | ---: | ---: | ---: |
| Default-policy ordered REST | 128 individual requests | 100 µs | 22.3–23.0 ms |
| No-op arrival scheduled response | 512 arrivals | 100 µs | 0.2–0.8 ms |
| Version-two 16 KiB JSON parse | 200 batches of eight calls | 1 µs | 260–273 µs per batch |
| Full 1,024-entry DAVE replay window | 100 batches of four opens | 10 µs | 90–110 µs per batch |
| Continuous 44.1 → 48 kHz mono FIR | 32 batches of four blocks | 10 µs | 2.83–2.99 ms per batch |
| Continuous CELT mono encode | 32 batches of four frames | 10 µs | 1.77–1.92 ms per batch |
| Shared aggregate, cohort four | 4,000 individual operations | 100 ns | 0.6–1.1 µs |
| Per-worker aggregate, cohort four | 4,000 individual operations | 100 ns | 0.6–1.4 µs |

Upper endpoints are exclusive. The index retains each p50/p95 bin, counts,
censoring and native receipts independently. Sparse media p95 populations are
exploratory. In the no-op arrival control, admission/submitted-response p50 bins
can fall entirely below the 100 µs bucket width; those do not establish zero
service cost or sufficiently precise admission budgets. The different observer
topologies were captured as separately identified controls in separate series;
their ordering was not counterbalanced against one another, so this table does
not establish an overhead reduction.

The two 128-offer/1,000-arrivals-per-second mutation smokes deliberately exercise
bounded pressure. Shared ordering recorded 42 successes/86 pending-overflow
rejections; independent partitions recorded 70 successes/58 rejections. Both
drained completely, recorded actual execute-entry timestamps for accepted work
and had no unaccounted outcomes. These single runs verify overload accounting;
they do not establish production throughput or a partition-scaling speedup.

No p99 is accepted below 10,000 observations in each gated outcome population;
CPU/media percentiles always describe batches. No percentile subtraction, pooling
of run percentiles or batch-to-call percentile conversion is used.

## Separate profiler attempts

Four supervised profiler runs were attempted after ordinary captures. CPU and
allocation attempts used the version-two JSON fixture; task/executor and system
wait attempts used default-policy ordered REST at cohort sixteen. Each has its
own command, process-group cleanup receipt and bounded diagnostics in the index.

| Profiler | Observed result | Qualification |
| --- | --- | --- |
| Time Profiler | Exit 2: fatal logging-system error; log archive corrupt/incomplete. Partial trace and table of contents retained. | Failed; no qualified CPU attribution. |
| Allocations | Recorder exceeded its 60-second owner deadline; termination joined. Native workload report and partial trace retained; trace export failed. | Failed; no allocation-event qualification. |
| Swift Concurrency | Exit 2 with the same logging-archive error. Partial trace and table of contents retained. | Failed; no qualified task/executor waits. |
| System Trace | Recorder exceeded its explicit 1 GiB sampled leader-RSS ceiling; termination joined. Native workload report and partial trace retained; trace export failed. | Failed; no qualified lock/system waits. |

All profiler owners were reaped with no live group members, and a final process
inspection found no benchmark or recorder left running. Partial trace existence,
native workload completion or exportable tables do not turn these failures into
successful profiles. Repair the host recorder/log-archive condition and review a
bounded profiler workload/resource profile before repeating; no host logging or
system configuration was changed here.

The exit gate remains open until a named reserved host, reviewed no-change floor,
adequate precision/range and the target workload's sample population are all
established. Profiler failures are retained as failures. Local macOS evidence does
not establish Linux, hosted CI, devices, live Discord or production capacity.
