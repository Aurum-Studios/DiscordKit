<!--
File: Docs/Tasks/latency-timing/CONTRACTS.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Stage 0 measurement decisions

Contract revision: **1**, frozen 2026-11-10 against
`c8d842f7ce51e9adc69ff9997e2c0f374dc2ee68`. This is the design checkpoint for
[Stage 0](PLAN.md#stage-0--inventory-and-freeze-measurement-contracts).
The [inventory](INVENTORY.md), [metric catalog](METRICS.md) and
[validation record](VALIDATION.md) complete this checkpoint. Definitions marked
planned describe later implementation, not available instrumentation or results.

## Implementation sequence and acceptance

1. Inspect the existing scalar observers, owner boundaries, logging graph,
   executable reports and deterministic fixture seams.
2. Freeze metric identities, populations, ownership, compatibility, placement and
   collection limits; map each workload and later stage to its existing files.
3. Check document links and catalog coverage against source; run the existing
   timing/logging semantic suites; independently review the contracts and commit
   the Stage 0 documents. Record actual results in the validation record.

The accepted scope is documents and measurement contracts. There is no new SwiftPM
target, source hook, exporter, dependency, report writer, baseline or numerical
gate in Stage 0. Stages 1 and 2 can start after this checkpoint; each retains its
own implementation and test gate.

## Compatibility decision

Keep all fourteen cases of `OperationTimingSample.Phase`, all four outcomes,
`elapsed: Duration`, the negative-duration clamp and the existing initializers
unchanged. Keep nil timing options at zero observer calls and zero
instrumentation-clock reads. Existing logging has its own execution cost even
when scalar timing is disabled.

Adding cases to the existing public enums could break downstream exhaustive
switches. Do not add cases, associated values, correlation labels or timestamp
requirements to that API for detailed timing. Use a separate opt-in interval
model. Existing aggregate samples contain neither a start timestamp nor operation,
parent, attempt or clock-domain identity. Adapt them only as scalar observations;
never synthesize correlated traces or profiler begin/end pairs from them.

The catalog's existing metric version 1 freezes actual source behavior, including
asymmetric success/failure cleanup boundaries and success-only milestones. A
boundary correction requires a new metric version and a new baseline even if the
source API name is retained. Documentation clarifications that leave population,
unit and endpoints unchanged may increment the catalog revision only.

## Runtime and development placement

The separate interval value model, finite operation/stage identities, injected
monotonic clock, bounded numeric correlation context and synchronous optional
observer belong in the **existing DiscordLogging target** during Stage 2.
[Package.swift](../../../Package.swift) currently makes that target depend only
on SwiftLog; it is independent of Transport. The hook must remain usable without
bootstrapping SwiftLog or enabling trace diagnostics.

Transport already selects Logging and Core. Adapt `OperationTiming` at explicit
owner/composition boundaries, with no reverse Logging-to-Transport import. Cache,
Media and MLS can use their existing Logging dependency. Bits, Core, Models,
VoiceCrypto and codec kernels use external benchmark/batch wrappers; add no
Transport or Logging dependency to pure operations. Do not instrument value
accessors or individual audio samples/cryptographic rounds.

Stage 1's shared statistics, process runner, report validation and environment
capture belong in one **development-only support package**, adopted by the load,
DSL and qualification tools when it contains actual shared code. Its final name
and source layout are Stage 1 implementation choices. Runtime products must not
select it, compiler plugins, optional voice, histogram packages or subprocess code.
Keep optional file/profiler output in explicitly adopted adapters; applications
own output configuration, flushing and shutdown. Apple signposts need genuine
lifecycle hooks, not SwiftLog messages interpreted as intervals.

Do not add an external benchmark package in Stage 0. Stage 1 may evaluate one
with a small pinned development-only prototype and verified native support,
licensing, portability and maintenance benefit. Existing runners remain the
starting point. The current native CI hosts are macOS ARM64 and Ubuntu x64;
Windows is excluded from CI at this revision and is not a prerequisite inferred
from older planning text. Other hosts and devices remain explicitly unqualified.

## Context, clocks and sinks

Use a run-local monotonic origin plus an explicit clock-domain identifier in the
future detailed model. Virtual clocks prove ordering/elapsed semantics; real
monotonic clocks measure cost. Wall time records provenance only. Checked
conversion to integer nanoseconds must reject overflow, mixed domains and invalid
interval ordering. Preserve the existing scalar regression clamp; detailed reports
must flag invalid/regressing observations and cannot silently qualify them as zero.

New intervals carry ephemeral numeric operation/parent/attempt identities only.
They are not metric labels, persistent Discord IDs or authorization. Structured
children inherit context. Callback, actor, detached and shared-reader boundaries
need deliberate bounded propagation; task-local state alone does not identify
every later caller or every subscriber to one exchange. A shared exchange has
one exchange owner and independently timed subscribers.

The existing `DiscordLog.withOperation` creates context/UUIDs and captures a
monotonic start even when trace is filtered. Measure that mode separately;
SwiftLog's lazy terminal metadata does not justify assuming filtered formatting
or terminal-clock costs. Diagnostic string correlation remains distinct from the
numeric detailed model. Bridge only identities explicitly known at composition.

Capture timestamps before invoking synchronous sinks. Start callbacks and earlier
child/terminal callbacks can consume time inside later enclosing intervals.
Sinks are nonthrowing, prompt, concurrent-safe and invoked outside owner locks;
they must neither reenter the owner nor recursively log into themselves. No
task per observation, implicit global service or unbounded registry is allowed.
Collection may perturb scheduling and deadlines; report its cost and resulting
misses without changing operation outcomes, retries or ownership rules.

Head sampling is deterministic from a recorded seed and finite operation identity;
children follow the root selection. Aggregate populations cover all observations.
Slow-operation retention is a separately bounded ring with overwrite/loss counts;
it cannot promise beginnings already discarded.

## Initial collection and process limits

These are ceilings for the first harness implementation, not existing limits
retroactively applied to historical tools or product service levels. Every new
profile records its chosen lower bounds and cannot silently expand them.

| Resource | Initial ceiling / behavior |
| --- | --- |
| Metric keys | 256 catalog identities; finite outcome and declared size/concurrency classes only; reject unknown keys |
| Aggregate storage | 16 MiB per runner, including all histogram cells/keys/counters; checked counters; reject profiles that cannot fit |
| Detailed capture | 65,536 numeric records and 8 MiB, whichever is reached first; count loss without blocking the producer |
| Optional reservoir | 4,096 observations per selected population, within the aggregate budget; seeded replacement across the whole run |
| Active cohort | At most 64 in smoke and 256 in standard; stress/soak require an explicit finite reviewed profile; never allocate one task per logical account |
| Driver backlog | At most 1,024 outstanding scheduled arrivals; report missed/deferred arrivals and queue growth, do not spawn an unbounded backlog |
| Duration | Smoke: 10 measured seconds; standard/stress: 300; separately selected soak: 3,600; warmup at most 60 seconds per process |
| Process timeout | Selected warmup + measured cap + 30 seconds for teardown; terminate owned process group, escalate to kill after 5 seconds and reap it |
| Repetitions | Smoke: one integrity run; standard: five fresh-process paired observations; stress/soak: explicitly recorded finite count at most ten |
| Memory / output | Profile must set RSS and retained-state caps; 32 MiB serialized report and 16 MiB bounded diagnostic log per process; explicit truncation/failure status |

Histograms cover the full measured population with bounded mergeable storage.
Precision and supported range are profile fields, reviewed in Stage 1. Overflow
and underflow retain censored mass; neither may be clamped into a finite maximum.
Unknown loss that could bias a required quantile blocks numerical qualification.
Exceeding collection limits cannot change the operation's result; it invalidates
or degrades the measurement explicitly. Missing gauges are unavailable, never zero.

## Report and baseline compatibility

The load reports have no common schema envelope. DSL runtime/compiler reports
use schema version 1, local VoiceSessionQualification uses version 2, and Apple
audio uses version 1. These are independent formats, not interchangeable versions
of one schema. Keep their artifacts and readers intact. A Stage 1 common envelope
starts at version 1 with a distinct format identifier and explicit source-format
adapters; importing a legacy report cannot invent clocks, losses or provenance.

Reports must carry catalog/metric/profile versions; scenario, seed, fixture/input
hashes; source revision and dirty-content fingerprint; dependency pins; executable
hash/build flags; compiler, OS/SDK/target/architecture; machine/CPU/memory allocation;
adapter; instrumentation, warmup, duration, repetitions and scheduler policy.
Include per-outcome offered/admitted/completed counts, distributions and censor/loss
counts, throughput, deadline misses, cleanup, resource scope and optional artifact
hashes. An interrupted run retains bounded partial evidence and a failure status.

Comparison requires matching semantics, profile/fixtures, host allocation,
compiler/optimization, OS/SDK/target, adapter and instrumentation. Baseline and
candidate source/executable hashes are recorded but intentionally may differ.
Unknown hardware identity, missing fields, schema mismatch or unsupported metrics
produce incompatible/unavailable status, not a passing result. Current non-Darwin
DSL `hardwareModel = unavailable` must be repaired before numerical comparisons.
Process peak RSS covers the process lifetime, not an isolated workload row.

Keep the existing prefix-success distributions and diagnostic-inclusive timers
under their legacy identities. Stage 5 must move LoadRunner's `poolSlots()` call
after full body completion and capture the terminal timestamp before that snapshot.
It must likewise capture HTTPPolicyRunner's terminal timestamp before coordinator/
cache snapshots. A headers-only interval needs its own identity; stopping at the
current pool snapshot would omit body work. Corrected observations need new metric
and profile versions. Intermediate diagnostic actor hops can perturb the operation
even if their elapsed time is later subtracted, so subtraction is insufficient.

New numerical gates start informational. Require a pilot/no-change noise study,
five independent paired runs and at least 10,000 observations per population
before p99 qualification. Sparse results report insufficient-tail-data. Retain
the investigation rule for >10% regression reproduced in three matching runs;
do not copy DSL noise floors or refresh baselines automatically. Functional,
deadline, loss, rejection and resource accounting accompany success distributions.
The reference procedure and current qualification limits are in
[VALIDATION.md](VALIDATION.md).
