<!--
File: Docs/Tasks/latency-timing/PHASE-10.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 10 — Baselines, regression policy and CI

Implements [Stage 10](PLAN.md#stage-10--baselines-regression-policy-and-ci)
from Phase 9 revision `a0703a47`, under the existing
[measurement contracts](CONTRACTS.md). Completed evidence belongs in
[validation](VALIDATION.md#phase-10-validation).

## Implementation plan

1. Extend the shared development package with versioned comparison series and
   reviewed, hash-bound policies. Preserve historical reports, runtime products,
   metric identities and default compatibility checks.
2. Compare five fresh-process pairs and five independent no-change pairs. Retain
   each run's distributions, sample counts and directional deltas. Validate noise
   floors against measured no-change deltas, and keep correctness/cleanup hard.
3. Reuse finite process supervision for sequential alternating A/B captures.
   Bind release executables to source/pin receipts and record named hosts,
   allocation, contention, order, failures and partial artifacts. Build before
   measurement; prohibit automatic baseline replacement.
4. Repair Linux hardware-model receipts without substituting an architecture for
   a machine identity. Keep compiler consumer builds under their existing debug
   configuration and runtime timing under release builds. Audit the existing DSL
   benchmark's standalone shared-support dependency through an explicit development
   package policy, preserving runtime dependency isolation.
5. Extend ordinary native CI with deterministic harness tests and short optimized
   integrity captures using existing exact-attempt compiled-artifact verification.
   Prepare separate controlled comparisons and periodic stress/soak workflows.
6. Test deliberate slowdowns, censored tail stalls, incompatible environments,
   sparse populations, missing evidence, cleanup, process deadlines and ordering.
   Review documentation and scope, then commit the completed implementation.

## Regression policy

Numerical policies start in reporting mode. Reviewed promotion to a required gate
is explicit and workload-specific; no product SLO follows from an informational
capture. A regression greater than ten percent in three matching pairs requires
investigation even when a workload's reviewed tolerance is more permissive.
Correctness, resource closure, terminal outcomes, loss and deadlines remain
separate from a faster successful latency population.

Each gated metric identifies its catalog/workload/profile, metric version,
outcome, statistic and direction. Cost limits are maxima; throughput limits are
minima. Absolute floors use the metric's own units and measured no-change noise.
The older DSL one-microsecond and one-MiB floors are not universal defaults.
Policies bind exact baseline and noise evidence hashes; candidate source and
executable identities may change while environment and semantics must match.
Failure never refreshes the reference artifacts.

Policies bind complete canonical baseline reports, including their measured
distributions. Capture and evaluation are consequently separate operations:
retain immutable paired evidence, review its hashes and policy, then evaluate
that exact series. Replaying a policy uses the frozen reference; a newly captured
reference requires explicit review even when the executable is unchanged.

Each P99 comparison requires at least 10,000 observations in that population in
every run. Sparse, censored, dropped or missing required evidence cannot pass.
Individual paired deltas and their range describe run variation; they are not
pooled percentiles or confidence intervals. Operations within a run are not
independent process repetitions.

Scope limitations remain attached to the original reports. A reviewed policy
can accept exact workload-scope statements, such as local scripted qualification;
it cannot supply missing provenance, restore lost samples, or establish native,
device or live-service qualification. Compiler, OS/SDK/target, dependency pins,
fixtures, adapter, instrumentation and actual host allocation must match.

## CI and qualification

Ordinary native smoke checks report integrity and joined cleanup, with numerical
results informational on shared runners. Deterministic comparison tests establish
that the evaluator detects artificial regressions and refuses incompatible data;
they do not establish a production performance baseline.

Separately invoked workflows retain finite process/job budgets and failure
artifacts. Controlled host comparisons require explicit reviewed evidence and
host allocation; periodic stress/soak remains informational. Preparing these
workflows does not dispatch them or qualify their native execution. Hosted
qualification requires completed runs at the exact committed revision.

The local host is a candidate reference environment with competing workspace
processes. No local capture is promoted to a controlled numerical baseline or a
required gate. Real Discord, physical audio, other native hosts, publication and
later roadmap stages retain their separate qualification boundaries.
