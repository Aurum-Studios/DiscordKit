<!--
File: Docs/Tasks/latency-timing/PHASE-1.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 1 — Shared development harness

Implemented 2026-11-10 from the Stage 0 checkpoint
`41935ddaf5dccb5ba9b981efd8e0d3afa1c2eba2`. Scope follows
[Stage 1](PLAN.md#stage-1--shared-development-harness-statistics-and-report-schema)
and the frozen [contracts](CONTRACTS.md). Runtime instrumentation remains Stage 2;
timer corrections, broader operation attribution and numerical CI gates retain
their later stage boundaries.

## Implementation plan and result

1. Add one development-only, dependency-free
   [support package](../../../Tools/DiscordBenchmarkSupport/README.md). Implement
   checked nanosecond conversion, bounded mergeable histograms, censored/lost
   observations and optional seeded reservoirs. Preallocate the finite adopted
   workload/outcome populations before measured work.
2. Define the distinct `DiscordBenchmarkReport` schema v1, catalog revision 2,
   native-format adapters, explicit unavailable receipts and strict decoding.
   Validate metric/version/clock/count/storage invariants and explain comparison
   incompatibilities. Keep legacy artifacts byte-preserved inside the new envelope.
3. Share release-build identity and fresh-process orchestration in one Python
   driver: finite profiles, seeded counterbalanced pairs, explicit warmup/cold
   policy, timeout/cancellation, bounded RSS/output and owned process-group cleanup.
   Preserve incomplete artifacts and verify sources, pins, executable and fixtures
   before and after every observation.
4. Adopt shared code from load, DSL and voice tools. Opt-in whole-population
   histograms observe all returned load/HTTP outcomes, all measured DSL invocations
   and started voice ticks. Keep legacy readers/timers and prefix summaries intact;
   the new metric IDs distinguish the different population. Add isolated DSL mode
   selection and same-plan unmeasured warmup for fresh-process comparisons.
5. Test deterministic integrity and process ownership, run existing regressions,
   build optimized participants and exercise local release captures. Review the
   combined diff and commit the implementation with its documentation.

## Boundaries and compatibility

The root manifest, runtime modules, scalar timing phases/outcomes and protocol
behavior are unchanged. Only the development tools select the support package.
No external package or compiler plugin was added. All native dependency pins are
preserved. Serialization, provenance capture and sidecar writes occur after work
and cleanup, outside operation timers. Numeric updates can perturb scheduling and
enclosing throughput; aggregate mode is recorded explicitly.

Existing timers retain their actual endpoint behavior: transport still samples
pool state before body work, HTTP policy still includes coordinator/cache snapshots,
and DSL/voice timers include their existing validation. New whole-population IDs
do not claim the corrected `transport.request`, `rest.request`, `interaction.route`
or component metrics scheduled for later phases. Gateway/cache adapter imports
retain native evidence without fabricating operation distributions.

Common imports are explicitly unqualified. Missing counts, gauges, provenance and
cleanup cannot become zero or a passing result. Process receipts carry available
host/build/source/fixture facts separately. The generic driver records requested
participant warmup, duration, cohort and retained-state settings; it cannot prove
those settings from arbitrary executables. It enforces actual process timeout,
sampled leader RSS, output limits and process ownership. A forced kill may leave
only bounded incomplete artifacts. Failed/cancelled DSL and voice owners attempt
a partial histogram envelope after their cleanup path finishes.

Fixed integration buckets cover 0...1 second at 100-microsecond absolute precision.
Higher values remain censored tail mass. All nine finite workload families and six
outcomes fit below 5 MiB; the general histogram API validates profiles against the
16-MiB aggregate ceiling. Full-population histograms cover early, middle and late
work; legacy prefix distributions remain historical. P99 needs 10,000 observations,
and loss/counter overflow prevents qualification. A compatible report is still
insufficient to establish a numerical gate without the later reference-host/noise
procedure.

## Validation

Local macOS ARM64 with Apple Swift 6.4; final executed results are recorded in
[VALIDATION.md](VALIDATION.md#phase-1-validation). The shared package has histogram,
reservoir, conversion, schema, provenance, partial-run and concurrent-collection
tests. Python tests exercise real subprocess groups, timeout escalation, descendant
cleanup, cancellation, truncation, RSS limits, fresh identities, all five standard
pairs, source changes and rejected debug/stale receipts.

Load integration proves whole-population count retention while keeping the native
prefix limit and outcome classifications. DSL integration proves same-plan warmup
exclusion, exact measured handler/callback counts and joined zero-owner cleanup.
Existing legacy-reader scripts remain unchanged. Release captures are local
integrity evidence, with sparse/unqualified populations explicit; they establish
no throughput budget, stable reference host, hosted CI, Linux, audio device or live
Discord qualification.
