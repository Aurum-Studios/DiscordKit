<!--
File: Docs/Tasks/latency-timing/PHASE-3.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 3 — Timing outputs and observer overhead

Implemented 2026-11-10 from Phase 2 revision `bcf989ef`. This phase
implements [Stage 3](PLAN.md#stage-3--timing-outputs-and-instrumentation-overhead-suite)
under the frozen [measurement contracts](CONTRACTS.md). Actual completed checks
and capture limitations belong in the [validation record](VALIDATION.md).

## Implementation plan

1. Keep optional outputs in the existing `DiscordLogHandlers` product. Permit its
   dependency on `DiscordLogging`; keep protocol owners independent of outputs.
   Bridge legacy samples through a finite scalar observation in the logging
   foundation without inventing lifecycle endpoints or correlation.
2. Add bounded numeric aggregation, fixed SwiftLog timing records and explicit
   interval capture. Keep numeric recording synchronous, concurrent-safe and free
   of file writes and string formatting. Applications join producers, close
   collection and export snapshots, NDJSON and a local timeline themselves.
3. Enforce finite storage and active-state budgets with visible loss accounting.
   Seeded head sampling carries parent decisions while bounded state exists;
   unmatched or discarded endpoints remain incomplete. Closing cannot manufacture
   a successful terminal observation or a valid duration.
4. Add Apple signposts using genuine live lifecycle callbacks, bounded paired
   state and explicit close. Portable numeric exports retain original monotonic
   offsets; signposts observe callback delivery time and cannot backdate them.
5. Add a development-only release executable using the shared histogram/report
   harness. Cover baseline/clock, timing and logging modes, selected compositions,
   contention, saturation, rotation and sink failure. Separate warmup, measured
   batches and output close/export; retain gross observations, exact checksums,
   resource availability, losses and process identity.
6. Prove redaction, population accounting, one-endpoint loss, concurrent recording,
   idempotent close and bounded state deterministically. Run root and affected
   package checks, sequential optimized local captures, dependency/documentation
   audits and independent review before the requested local commit.

This phase establishes local semantics and measurement capability. Numerical
baselines, budgets, hosted CI, other-platform runtime and live Discord qualification
retain their separate gates. No logging-scope optimization is inferred from a
filtered-log capture.

## Adapters and ownership

`DiscordTimingObservation` lives in the existing logging foundation and carries
fourteen finite scalar phases, four outcomes and checked optional integer elapsed
nanoseconds. `OperationTimingSample.observation` maps the legacy boundary and
clamped duration without reading a clock or inventing correlation. The legacy
public enums, initializers and recording behavior are unchanged.

The optional `DiscordLogHandlers` product now selects the logging foundation.
Protocol owners never select output adapters. No external dependency, benchmark
target, subprocess code or optional voice product enters the runtime graph.
The release policy explicitly permits this edge and the foundation's existing
`Dispatch` clock import.

| Adapter | Behavior and finite limits |
| --- | --- |
| `DiscordTimingAggregate` | Preallocates numeric keys/rows and 64 logarithmic buckets per key. At most 256 configured keys and 16 MiB; 236 closed scalar/detailed/outcome combinations are possible. Default conservative storage bound is 161,120 bytes. Invalid durations, censored tails and key/observation/counter loss remain explicit. Snapshot/encoding is separate caller work. |
| `DiscordTimingLogAdapter` | Fixed SwiftLog events and finite/numeric metadata. Filtering precedes rendering; the supplied logger's label, base metadata and provider remain the application's privacy responsibility. Existing callback/console/file/unified outputs remain reusable. |
| `DiscordIntervalCapture` | At most 65,536 records and 8 MiB of numeric record/active-decision payload, with bounded additional container overhead. Seeded root selection propagates through tracked direct parents. Active lookup is linear within the configured finite ceiling. Missing parents and saturation count loss instead of independent resampling. |
| `DiscordIntervalSignposts` | Genuine begin/end hooks with bounded live profiler state, including begin/end callbacks still delivering. External emitters run outside locks. Close labels remaining states incomplete; joined producers make shutdown final. Apple timestamps are live callback times and never reconstructed from scalar durations. |

Capture retains earlier endpoints and drops new endpoints at capacity. A retained
begin whose end is dropped exports an incomplete interval with absent duration.
Unknown terminals count unmatched endpoint/loss; they do not acquire invented
begins or independently selected roots. Counter saturation never wraps. Invalid
clock offsets remain null in NDJSON and cannot become timestamp zero in the
timeline. End-of-run NDJSON and Chrome trace exports require explicit close and
retain their own schema version 1, sampling configuration and loss summary.
Exports have a 32 MiB artifact ceiling.

There is no continuous exporter queue or drain task. Applications join producers,
close admission and export/write returned data themselves. Repeated close is
harmless; callbacks arriving afterward count late loss. Aggregate snapshots can
be taken concurrently, but a final population requires joining producers. Neither
the aggregate nor the capture formats strings or writes files while recording.
Logging and profiler modes still consume synchronous caller time; none belongs
inside realtime audio/sample/crypto loops.

See [timing output ownership](../../../Sources/DiscordLogHandlers/DiscordLogHandlers.docc/Guides/TimingOutputs.md)
for composition. Apple's [performance recording guidance](https://developer.apple.com/documentation/os/recording-performance-data)
and [OSSignposter](https://developer.apple.com/documentation/os/ossignposter)
define the real paired profiler state used by the optional native initializer.

## Development overhead suite

The [timing executable](../../../Tools/DiscordTimingBenchmarks/README.md) adopts
the existing shared report, bounded histogram and fresh-process driver. Its 19
finite modes cover disabled/no-op/detail aggregation, sampled capture, filtered
diagnostic scopes, callback contention, console, rotating file, closed-sink
failure, capture saturation, unified log, signposts, a selected combination,
empty-harness/clock reads and real REST scalar disabled/no-op/aggregate paths.
The REST transport supplies only local HEAD/204 fixtures and synthetic rate
headers. It sends no network request and proves no wire behavior.

Tiny CPU and local REST fixtures have separate workload dimensions. Each started
measured operation is clocked externally through its observable result and
synchronous observer work, before checksum accumulation and statistics updates.
Warmup has separate output owners. Finite worker
histograms use 100 ns buckets over 0...2 ms; slower values remain censored mass.
Whole-cohort throughput/CPU and separate output flush/export costs accompany the
operation population. Current RSS, process-lifetime peak RSS and live allocator
indicators retain their actual scopes. Allocation-event counts are unavailable.

All results are gross observations. No empty-clock subtraction, filtered-log
optimization, percentile waterfall, numerical threshold or baseline promotion is
performed. Source/executable provenance, exact result counts, adapter losses and
post-close owner counts accompany locally supervised captures. The
[validation record](VALIDATION.md#phase-3-validation) records actual checks,
failed attempts and qualification limits separately.
