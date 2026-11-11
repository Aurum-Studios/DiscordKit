<!--
File: Docs/Tasks/performance-improvements/PHASE-4.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 4 — Cache scaling and permission computation

Authorized 2026-11-11 from `3e806674`. Implements the
[stage contract](PLAN.md#stage-4--refine-cache-scaling-and-permission-computation).
Earlier reserved-host numerical and profiler qualification remain open.

## Implementation plan

1. Give entity and REST read caches exact global/per-identity LRU links and
   count/byte accounting. Replace lookup-time full expiry scans with an indexed
   minimum-expiry heap containing exactly one record per retained entry. Remove
   replacement, eviction and invalidation metadata immediately; retained indices
   must remain bounded across repeated churn without tombstone compaction.
2. Preserve inclusive expiry, scoped visibility, input rejection, sparse merges,
   null/redaction/absence, observation order, invalidation generations, stale
   loader fencing, independent refresh cancellation and joined shutdown. Inspect
   refresh admission counters separately from retained-entry accounting.
3. Add deterministic expiry, identity/global budget, LRU, repeated replacement,
   invalidation and recovery coverage. Reuse the existing refresh race/cancellation
   tests and verify exact accounting after every relevant state transition.
4. Add versioned cache workloads varying aggregate working set, identity count,
   payload and churn independently. Keep population setup outside lookup timers
   and include near-capacity eviction, expiry storms and invalidation. Preserve
   historical cache/client workloads and their single-flight/lifecycle controls.
5. Add independent permission role, overwrite and arbitrary bit-width controls
   with prepared immutable facts and independent exact result oracles. Keep the
   resolver stateless: no revision/invalidation contract justifies a retained
   permission aggregate. Permission snapshots remain observations, never authority.
6. Run focused and full runtime tests, affected benchmark suites, independent
   consumers, repository/documentation/API checks and serial release captures.
   Use identical development harnesses with original and candidate runtime sources;
   record fresh-process no-change and alternating pairs, failed attempts, source
   receipts and cleanup. Separate local observations from reserved-host gates.
7. Record decisions, validation and measurement limits, review the owned diff,
   commit the authorized changes and verify the final commit and working tree.

## Implementation and decisions

Both caches now maintain exact per-identity count/byte totals, global and scoped
LRU links, and a minimum-expiry heap. Each retained entry has exactly one heap
record and one membership in each LRU order. Replacement, eviction and
invalidation remove that metadata immediately. Empty identity records disappear;
there are no stale-record lists or periodic tombstone compactions. A fresh lookup
checks the earliest expiry and promotes its entry without scanning unrelated
entries. Insert/remove work is O(log n) per affected entry; each budget eviction
selects its victim directly. Read-cache invalidation visits only the selected
identity, while retaining conservative global generation fencing.

The entity cache stores links in its entry values. The read cache uses private
actor-owned entry references, with value-key links rather than reference cycles.
These choices preserve public value snapshots and keep all mutation under the
existing actors. No public API, dependency pin, manifest or runtime product changed.
Entity refresh identity counters now increment only when a flight is admitted
and decrement when that exact flight finishes; cancelling subscribers does not
release a still-running loader's admission charge. Joined close leaves no refresh
identity metadata.

The tradeoff is explicit: removing k expired entries costs O(k log n), including
O(n log n) for a simultaneous full drain, where the old scan/removal was O(n).
The new metadata also consumes memory. Logical index cardinality is bounded by
live entries/identities, but dictionary/array backing allocations can retain their
high-water capacity. Accounted payload/serialized bytes exclude index and allocator
overhead. This phase accepts that local implementation tradeoff for bounded hot
lookup and victim selection; it does not qualify an expiry-storm or memory gate.

Entity field serialization remains the exact byte-charging authority. There is
no allocation profile supporting a count-only replacement. Permission resolution
also remains stateless: neither cached observations nor a reused role aggregate
has an explicit revision/invalidation contract that would establish current
authorization. The phase adds independent permission measurements rather than
changing that authority boundary.

## Correctness coverage

The entity reference model checks 900 deterministic mixed operations against an
independent scan-based implementation. Repeated replacement checks 2,000 updates,
inclusive expiry and exact index cardinality. One hundred success/error refresh
cycles verify identity metadata does not accumulate. Existing subscriber
cancellation and close tests now also assert zero retained refresh identities.

The read-cache reference model checks 1,500 operations at each capacity
1/2/3/4/15/32, with a full initial population, varied and equal deadlines,
replacement, arbitrary deletion, expiry and eviction. Separate rejection,
generation, identity-budget and churn controls verify exact count/byte/index
accounting. Existing sparse merge, order, redaction/null/absence, visibility,
single-flight, stale-loader fencing and independent cancellation suites pass.
The new index diagnostics are internal, accessible to tests without extending
the public API.

## Measurement controls

The development-only `cache-scaling-timing` command selects entity or read owner
and versioned hot-hit, miss, update, expiry-storm, capacity or invalidation cases.
Aggregate working set, identity count, payload bytes and pre-call churn are
independent dimensions. Fixtures prefill the requested working set and size policy
budgets explicitly. An independent LRU model verifies exact victims and recovery.
Setup, churn and recovery writes stay outside the selected call timer and are
bounded by the parser's ten-million-write and 16 MiB accounted-state limits.
Historical cache/client case identities and defaults remain available.

`cache.call` measures caller entry through selected completion. Entity owner
intervals use the existing production hook, filtered to the selected operation;
read-cache cases expose only the direct caller boundary. Their common identities
include the owner, preventing an entity/read comparison from passing as compatible.
The existing histogram has **100 µs bins**. Gross process duration/CPU includes
population, the driver's linear-array LRU model, validation, diagnostics, recovery
and cleanup; it is not pure cache service capacity. The injected lock-backed
freshness clock is frozen except for explicit expiry advances. Removing repeated
clock reads is part of this workload's difference, not a projection to another
application clock. Prepared Data/string storage can be shared across entries, so
charged payload bytes do not establish unique allocation or retained heap size.
Expiry retention fields are sampled before final untimed recovery.

Fourteen new `permission.v2` cases independently vary roles 1/16/128, overwrites
1/16/128, or width 64/256/4096 around the 16-role/16-overwrite/256-bit control,
in both allow and deny modes. Immutable facts are prepared outside timing and
exact independent oracles verify outputs. The historical ten permission cases
retain their identities and fixtures. The foundation catalog now has 115 cases,
including 24 permission cases. Batch distributions and normalized means remain
separate populations; this phase makes no permission speedup claim.

## Validation and local observations

Local implementation and validation completed on 2026-11-11 with Apple Swift 6.4,
arm64 macOS and SDK 27.0, pinned dependencies and four build jobs. Builds, tests
and performance processes ran serially on the host. The
[capture index](phase-4-observations.json) retains release/source identities,
configurations, commands, per-process observations, cleanup and artifact hashes.
Raw logs/reports remain in the ignored local capture directory; the index is not
a published artifact store. Post-capture documentation edits leave all 976
recorded executable/test inputs unchanged. The identical 161-file load harness
was installed in the detached original-runtime checkout before both release
builds; the later README clarification is recorded separately from that snapshot.

- Root build and strict tests passed: **2,666 methods in 334 suites across 34
  test-target runs**, zero issues. The initial focused cache/reuse/safety run
  passed 95 methods in eight suites. Final focused execution after test-only
  refinements passed 78 methods in six suites.
- Load harness passed **130 methods in 24 suites**; foundation benchmarks passed
  **21 methods in five suites**, verifying all 115 catalog cases. Development
  tooling passed **106 methods in eight suites**. Python suites passed 234
  repository-tooling, 42 load-harness, 47 benchmark-support and three foundation
  tests.
- RESTOnly and GatewayBot independent consumer builds passed. Inventory,
  deterministic generation, parity, symbol graphs, DocC curation and documentation
  example synchronization passed. The callable audit found **969 Swift files,
  10,386 explicit callable declarations and zero missing comments**. Strict
  DiscordCache/DiscordHTTP DocC passed with analysis and warnings as errors.
- API policy checks passed; the complete public API snapshot is byte-identical
  to phase 3. Independent production and cross-owner reviews found no correctness
  defect. Final documentation, artifact/hash and whitespace checks passed.

Failed attempts remain part of the evidence. The first callable audit found two
undocumented reference-model getters; comments were added and the final audit
passed. The first complete new harness run failed 14 schema assertions because
zero-valued outcome categories were absent; all 130 methods passed after the
outcome dictionary was corrected. That failed log overwrote an earlier passing
suite's log; the earlier success is excluded from the retained successful checks.
The initial DocC invocation omitted its output parent; creating it allowed both
strict conversions to pass. These failed logs are retained in the index.

### Paired cache comparisons

Eight configurations each ran five independent candidate/candidate no-change
pairs and five alternating original/candidate pairs: **160 fresh processes and
20,480 successful selected calls**. Each process used 128 measured calls, one
caller, one identity, 128-byte payload, zero churn and zero warmup. The baseline
runtime was `3e806674`; both arms used the same new harness and release flags.
Every child exited zero, all owners joined, every process group was reaped, and
no histogram observations were lost or overflowed.

The table shows the enclosing range of individual process p50 bins, in µs, not
pooled percentiles or paired deltas. Every candidate and no-change process p50
fell in [0, 100). The no-change data cannot resolve a floor within that bin.

| Owner / operation | Entries | Original p50 bin range (µs) | Candidate p50 bin range (µs) |
| --- | ---: | ---: | ---: |
| Entity hot hit | 16 | [0, 100) | [0, 100) |
| Entity hot hit | 4,096 | [400, 600) | [0, 100) |
| Entity capacity insertion | 256 | [100, 200) | [0, 100) |
| Entity capacity insertion | 4,096 | [2,400, 2,500) | [0, 100) |
| Read hot hit | 16 | [0, 100) | [0, 100) |
| Read hot hit | 4,096 | [400, 500) | [0, 100) |
| Read capacity insertion | 256 | [100, 200) | [0, 100) |
| Read capacity insertion | 4,096 | [1,900, 2,000) | [0, 100) |

These local observations support the large-working-set mechanism. They cannot
establish finer small-cache differences, a numerical regression policy or an
application latency improvement. At 128 observations per process, p99 is
unavailable; no process populations are pooled to manufacture a tail.

### Functional sweeps and resource tradeoffs

An additional **58 release processes / 928 successful selected calls** cover both
runtime arms: all six cache cases and both owners at 32 entries/three identities/
five churn writes, plus separate larger identity, payload and churn controls.
Existing refresh, single-flight, stale-fence, sparse-merge and projection controls
also pass. Cancellation has deterministic functional coverage, not a dedicated
timed cancellation distribution. Fourteen permission processes completed **1,792
batches / 28,672 calls**, with exact outputs and joined cleanup. These finite
sweeps establish fixture correctness, not statistically qualified scaling curves.

Simultaneous expiry exposes the expected adverse case. In the 256-entry smoke,
one process per arm with 16 calls, entity p50 moved from [500, 600) to
[1,300, 1,400) µs and read p50 from [400, 500) to [800, 900) µs. There is no
repeated expiry no-change series. Full-drain latency remains a known tradeoff
requiring representative expiry-distribution profiling before a separate change.
Gross process CPU can fall while that direct lookup slows, because untimed
refills dominate total work; gross CPU is not evidence of faster expiry service.

Entity 4,096-entry hot-hit peak process RSS rose from 15.30–15.70 MiB to
18.92–19.23 MiB; capacity insertion rose from 15.55–16.20 to 18.91–19.31 MiB.
Read hot-hit RSS ranges overlapped (12.69–12.97 versus 12.75–12.86 MiB).
These are process high-water gauges, not allocation-event counts or an isolated
cache retained-heap measurement. No net memory-saving claim is made. Repeated
churn/reference tests establish bounded logical metadata rather than a lower RSS.

## Remaining qualification

Stage 4's authorized local implementation, checks and evidence are complete.
Reserved-host no-change floors, reviewed numerical policy, profiler/allocation
attribution, power and representative workflow critical-path qualification remain
open. The unreserved host captures do not satisfy those gates. No Linux/hosted
CI, live Discord, production, publication or deployment qualification occurred.
Stages 5–10 remain planned; this phase does not start those tracks.
