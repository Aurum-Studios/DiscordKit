<!--
File: Docs/Tasks/latency-timing/PHASE-11.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 11 — Measurement guidance and qualification handoff

Implements [Stage 11](PLAN.md#stage-11--documentation-qualification-and-optimization-handoff)
from revision `5f1792bd`, preserving the [measurement contracts](CONTRACTS.md),
[catalog revision 9](METRICS.md) and historical validation entries. The
[maintainer guide](../../Measurements.md) is the starting point for a new capture.

## Implementation plan

1. Publish one entry point for workload selection, supervised recipes, common and
   native schemas, compatible-machine comparisons and troubleshooting. Link the
   existing family guides rather than copying their versioned workload matrices.
2. Add a bounded offline compact report command to the existing development
   package. Show each directly observed population with its own quantiles,
   uncertainty and loss; retain load, outcomes, deadlines, resources and cleanup.
   Never infer a waterfall, per-call percentile or isolated observer cost.
3. Extend the credential-free logging example and timing DocC guidance with
   application-owned aggregation, correlated intervals, bounded capture, file
   export and genuine live Apple signposts. Explain coherent head sampling and
   its limits for investigating slow operations.
4. Audit product and example dependencies, API compatibility, callable comments,
   DocC, links and tutorial snapshots. Run affected deterministic suites, root
   native build/strict tests and representative local integrity checks.
5. Record current evidence separately from retained earlier observations. Provide
   concrete reproduction paths for further profiling, preserving unqualified
   hardware, hosted, controlled-host and live-service boundaries; commit the
   completed handoff without publishing or dispatching workflows.

## Reading a compact report

The shared [report command](../../../Tools/DiscordBenchmarkSupport/README.md)
validates the common envelope before presentation. Metric ID, version and outcome
stay attached to every distribution. Histogram quantiles are bucket intervals or
censored bounds, not exact timings; sparse p99 and missing/lost observations stay
visible beside that population. Offered/admitted/completed and terminal outcomes
must be assessed together with latency. A failed or incomplete run can still be
presented, but presentation does not qualify it.

Aggregate samples cannot reconstruct operation timestamps or correlation. Optional
timeline references identify separately retained capture artifacts; they do not
verify a shared origin or establish a join to the aggregate report. Gross
instrumentation workloads include synchronous callbacks and harness work. Isolating
collection cost requires matching controlled mode comparisons, not subtraction of
unrelated percentile summaries.

## Qualification ledger and optimization handoff

Completed checks and qualification levels are recorded in
[Phase 11 validation](VALIDATION.md#phase-11-validation). Earlier sections remain
the evidence for their original revisions, fixtures and measurement boundaries.
The [guide's handoff procedure](../../Measurements.md) records a reproducible
workload, an observed cost and the next discriminating profile before proposing
an optimization.

No product bottleneck or numerical baseline has been qualified by this phase.
The retained Phase 4 scaling observations identify bounded CPU cases to profile;
they are single-process gross batch means, not individual-call tails. The retained
Phase 9 software duplex checks separate component costs from integrated tick and
schedule behavior; they do not measure acoustic/render latency. The Phase 10
same-binary pilot was explicitly refused for controlled-host qualification due
to recorded contention. Repeat the matching workload on an isolated named host
and collect independent no-change pairs before proposing budgets or speedups.

Remaining qualification work is concrete: review controlled-host noise and
budgets, complete hosted runs at the committed revision, and separately authorize
native devices, browser/desktop hosts or live Discord when those are the target.
Local correctness, source compatibility and readable reports establish their
stated offline scope only. No release, publication, deployment or production
capacity claim follows from the handoff.
