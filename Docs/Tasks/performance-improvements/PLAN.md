<!--
File: Docs/Tasks/performance-improvements/PLAN.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Performance refinement plan

Status: Stage 0 implementation validated locally; Stage 1 implementation and
local validation are recorded in [Phase 1](PHASE-1.md). Stage 2 implementation and
local evidence are tracked in [Phase 2](PHASE-2.md). Stage 3 implementation and
validation are tracked in [Phase 3](PHASE-3.md). Stage 4 implementation, cache
scaling observations and resource tradeoffs are recorded in [Phase 4](PHASE-4.md).
Stage 5 implementation and local validation are recorded in [Phase 5](PHASE-5.md).
Stage 6 implementation and local validation are recorded in [Phase 6](PHASE-6.md).
Stage 7 implementation and local validation are recorded in [Phase 7](PHASE-7.md).
Stage 8 implementation and local validation are recorded in [Phase 8](PHASE-8.md).
Stage 9 implementation and local validation are recorded in [Phase 9](PHASE-9.md).
Reserved-host numerical and allocation/executor profiler qualification remain open.
Stage 10 remains planned. Source investigation and exploratory planning measurements were prepared against
`065e2b655c28250076ba53fca310f209be1d3fd5`. Stage 1 refines local admission;
Stage 2 refines request work and NIO buffering; Stage 3 refines bounded event
delivery; Stage 4 refines cache indexing and separates permission dimensions;
Stage 5 refines shared JSON strings and incremental RPC framing;
Stage 6 refines OAuth and Activity subscriber bookkeeping; the RPC queue marker
is deferred after measured tradeoffs. Stage 7 replaces serialized DSL payload
accounting with exact byte counting and separates authoring/build populations.
Stage 8 adds bounded immutable resampling phase plans, with separately measured
construction, processing, flush and local duplex observations.
Stage 9 replaces DAVE replay-set rebuilding with bounded bits, removes RTP
serialization used only for byte charging, and fixes reordered resumption after
empty-buffer PLC. Larger MLS and concurrent control/media workloads retain the
existing cryptographic and actor boundaries.
No numerical regression policy is selected.

The first target is avoidable waiting in shared request admission, followed by
redundant request work and scale-sensitive event/cache algorithms. Shared JSON,
optional protocols, authoring, DSP and secure voice follow their own measured
workloads. Priorities can change when a representative application's critical
path supplies stronger evidence.

The [findings and coverage inventory](INVENTORY.md) records source mechanisms,
discriminating experiments and invariants across every runtime product. The
[evidence record](EVIDENCE.md) and [capture index](observations.json) retain the
actual local observations. The existing [measurement guide](../../Measurements.md),
[metric catalog](../latency-timing/METRICS.md) and
[qualification ledger](../latency-timing/VALIDATION.md) remain authoritative for
timing semantics and completed instrumentation work.

## What the investigation establishes

- A focused public-API experiment reproduced delayed ordering handoff after the
  previous owner had returned. Ten alternating fresh-process pairs produced a
  median of process medians of 15.047 ms with the actual default scheduling
  policy, and 1.150 ms with a 100 µs polling interval. This isolates polling and
  local scheduling from REST/network work. It supports investigating notifications;
  it neither qualifies production tails nor selects a shorter polling interval
  as the solution.
- Source inspection confirms duplicate REST decoding, cache-wide expiry scans on
  hits, repeated hub-wide scans during publication, per-fragment RPC header work,
  per-string Foundation JSON coders and replay-set rebuilding in DAVE. Their
  contribution to a real application's response time remains to be measured.
- Seven supervised CPU cases and seven observation modes completed correctly.
  Sparse batch/call distributions and unreserved host conditions prohibit p99 or
  numerical baseline qualification. Scalar aggregation happened to appear faster
  than disabled observation in this single run: mode order and host effects must
  be controlled before drawing an overhead conclusion.

## Causal method and acceptance contract

For each proposed change, retain three separate claims: the code mechanism,
its measured cost in a defined workload, and its contribution to the workflow's
critical path. A mechanism alone does not establish user-visible delay.

1. Define the endpoint: caller-to-complete REST result, trusted receipt-to-confirmed
   response sink, full command result, scheduled-arrival-to-response, secure-ready,
   paced voice tick or clean/incremental consumer build. Measure it directly.
2. Record cold versus warmed state, fixture/size, adapter, concurrency, offered
   rate, policy, observer mode, deadlines and source/build identity. Use default
   production policy as well as explicitly named stress/tuned profiles.
3. Correlate genuine intervals for one finite cohort. Distinguish submission,
   actor admission, local service, policy wait, injected provider/peer wait,
   response completion and cleanup. A synchronous CPU profile and allocation
   profile answer different questions from an inclusive wall-time interval.
4. Change one causal dimension at a time. Hold total bytes constant while changing
   fragments; hold entries constant while changing identities; hold subscribers
   constant while changing backlog; sweep injected delay through zero. Add a
   no-op service or fake authority control where the driver/provider may dominate.
5. Confirm the suspected stack/queue with a separate profiler capture or a barrier
   experiment. A slow parent with no matching child is an attribution gap. Add the
   smallest bounded hook needed before redesigning that owner.
6. Compare five independent no-change pairs and five alternating baseline/candidate
   pairs on a named reserved host. Keep gross measurements, failed/partial runs,
   exact native/common reports, release receipts, fixture hashes, policy and
   decision. Work inside one process is not independent replication.
7. Accept a change only when its direct target improves beyond the reviewed
   no-change floor and its correctness, successful throughput, adverse outcomes,
   deadlines, fairness and resource budgets remain acceptable at equal offered
   load. Record CPU/memory tradeoffs explicitly. Discard or defer an unhelpful
   refinement. Keep a small reversible change per mechanism.

P99 needs at least 10,000 observations in each gated outcome population in each
run, without disqualifying loss/censoring. CPU/media tails describe batches;
normalized means are separate. Never sum phase percentiles, subtract independent
percentiles, divide a batch percentile into a call percentile, or average run
percentiles into a pooled population. For a complete correlated trace, reason
about actual overlapping intervals and the critical path.

## Stage order and dependencies

Stage 0 has an [implementation and qualification record](PHASE-0.md); its
controlled-host numerical gate remains explicit. Stage 1 has a separate
[implementation record](PHASE-1.md), authorized with that numerical gate still
open. Stage 2 has its own [implementation and validation record](PHASE-2.md).
Stage 3 has its own [implementation and validation record](PHASE-3.md).
Stage 4 has its own [implementation, validation and tradeoff record](PHASE-4.md).
Stage 5 has its own [implementation, validation and observation record](PHASE-5.md).
Stage 6 has its own [implementation and validation record](PHASE-6.md).
Stage 7 has its own [implementation and validation record](PHASE-7.md).
Stage 8 has its own [implementation and validation record](PHASE-8.md).
Stage 9 has its own [implementation and validation record](PHASE-9.md).
Stage 10 remains **planned**.
Stage 0 qualifies measurement before any numerical claim. Stages 1–5 prioritize common library paths. Stages 6–9 are independently
adopted product tracks after Stage 0; source investigations can overlap, but host
builds and performance captures run sequentially. Stage 10 follows the selected
implementation tracks. Shared-core changes require affected consumers to be
rechecked even when their own track has not started.

| Stage | Main owner | First decision experiment | Completion evidence |
| --- | --- | --- | --- |
| 0 | Measurement and observation | No-change noise, observer/driver controls, production-policy coverage | Trustworthy attribution and reviewed workload identities |
| 1 | Rate/order admission | Held-owner release to eligible successor under default policy | Prompt bounded handoff with unchanged fairness/quota semantics |
| 2 | REST, interactions and transport | Decode/encode multiplicity; fixed-byte/chunk and cold/warm I/O | Reduced local request work and directly improved response boundary |
| 3 | Gateway, dispatch and client | Subscriber/backlog scaling; lease/provider delay control | Lower fan-out/residence cost with preserved control progress |
| 4 | Entity/read caches and permissions | Working-set/expiry/churn/identity sweeps | Bounded lookup/eviction scaling and unchanged freshness |
| 5 | Core, bits, models and framing | JSON string density and RPC fragmentation | Lower shared CPU/allocation costs with exact wire semantics |
| 6 | OAuth, RPC, Activities and service composition | Local-owner versus backend/IPC/storage waits | Improved selected workflow without stale authorization |
| 7 | DSL, macros and package/build paths | Separate authoring/runtime/clean/incremental processes | Measured developer/runtime benefit without product coupling |
| 8 | Media, codecs and Apple audio software | Continuous resampling, queue occupancy, codec scratch cost | Lower processing cost with preserved signal/stream behavior |
| 9 | Voice, DAVE and MLS | Full replay-window steady state; integrated paced/control load | Lower secure-media/transition cost without protocol shortcuts |
| 10 | Integration and regression policies | Mixed load, saturation, recovery and bounded soak | Reviewed narrow regression gates and target-platform receipts |

### Stage 0 — Qualify attribution and measurement

Reuse the existing APIs and executables. Publish the initial workload receipts
and reserve a comparison host before spending time on broad numerical sweeps.

- Add versioned benchmark variants for actual default scheduling. Current
  `rest.orderedMutation` uses 100 µs polling, a 1 µs provisional window and enlarged
  rate allowance; it cannot measure default 10 ms polling. Preserve its old identity.
- Add long-lived prefilled DAVE replay state, realistic continuous resampler/codec
  state, and independently varied JSON dimensions. Existing cold/per-batch fixtures
  cannot establish their steady-state cost.
- Fill attribution only where necessary: caller-to-verifier admission, arrival REST
  owner admission, Gateway lease validation, backend/storage callbacks and genuine
  adapter connect/TLS/pool boundaries where the adapter can expose them. Preserve
  unknown spans as unknown. Do not estimate missing stages by percentile subtraction.
- Compare nil/noop/aggregate/sampled/filtered-log/output modes with bounded cohorts
  1/4/16 where supported; the existing convenience wrapper requires at least two
  workers. Compare per-worker development collectors against the shared collector
  to locate measurement contention. Keep task-local correlation and zero nil-hook
  clock/identity work intact. If filtered logging dominates, test a fast path only
  after specifying which diagnostics and correlation must still occur.
- Measure arrival-generator lateness/headroom with a no-op service, including
  offered/admitted/rejected/missed arrivals and drain. Closed-loop wave results
  and deliberately gated coalescing cases remain separate from capacity evidence.
- Profile allocations, task/executor/lock waits and CPU in separate runs. Record
  peer-process work, cgroup throttling or available thermal/power observations.
  Leader-only sampled RSS and host load average do not supply those facts.

Exit: deterministic tests for any new boundary/fixture, valid schemas and cleanup,
five no-change pairs per priority workload, reviewed precision/range and enough
samples for the proposed statistic. Start with means/p50/p95 when p99 is unavailable;
do not weaken the tail rule. Numerical budgets remain unselected until this gate.

### Stage 1 — Replace avoidable local admission polling

Start with whole-operation ordering, then rate admission as a separate change.
Add default-policy variants of the [ordering reproduction](ORDERING-PROBE.md) to
the existing timing suite. Measure release-to-next-owner, caller wait, successful
throughput, wakeups/CPU and timer/task count at 1/4/16/64 callers and multiple
partitions/identities. Release at several points in a polling cycle. Include slow
and failing shared-authority controls and genuine retry/reset deadlines.

Add a versioned default-policy ordered-mutation arrival workload with shared and
independent partitions for end-to-end ordering acceptance. Existing `arrival.rest`
uses GET requests, bypasses whole-operation ordering and inherits the tuned
fixture policy; retain it for rate-admission controls rather than treating it as
evidence for an ordering fix.

Evaluate bounded completion-driven notification of eligible waiters. Retain a
bounded wake timer strategy for real authority deadlines and remote authority
changes; cross-process completions cannot be inferred from local notifications.
Avoid waking every waiter or replacing one task per poll with one task per event.
Reducing the interval alone exchanges timer overhead for delay and does not remove
the mechanism.

Exit: deterministic FIFO/independent-partition, starvation, cancellation, timeout,
close and authority-failure checks; no early quota admission or reservation leak;
paired default-policy handoff and ordered-mutation arrival improvements. Confirm idle CPU and
timer count do not regress. Never remove ordering or refund uncertain quota.

### Stage 2 — Remove request duplication and refine transport work

Separate changes for REST decoding, interaction response encoding, signed ingress
and each adapter. Count decoder invocations and payload encodings in finite fixtures
before timing 1/16/256 KiB typed responses and representative command responses.
The unshared REST fast path may return a validated decoded result once; shared
byte retention still needs malformed-success validation and independent subscriber
results. Avoid a cross-type result cache or changed public decoder semantics.

Inspect signed-verifier actor residence separately from Ed25519 service and replay
expiry scans at empty/near-capacity state. Consider parallel verification only if
serialized CPU dominates; replay admission must remain atomic after authentication.

For Foundation and NIO independently, sweep total bytes, chunk sizes, immediate
versus trickled bodies, upload production, warm reuse versus cold connect/TLS,
complete versus abandoned bodies, deadlines and pool refusals. Profile byte-wise
reads, buffer materialization and per-pull tasks before selecting buffering or
deadline-owner refinements. Do not guess DNS/TLS latency from a headers interval.
First-byte and full-body improvements need separate direct endpoints.

Exit: same wire outputs and validation errors, malformed data never retained,
independent coalesced cancellation, no ambiguous mutation replay, bounded buffers,
EOF drain and exactly-once close/reuse checks. Preserve pre-send upload failure
semantics; true streaming is a separately designed API/contract change. Connection
or event-loop tuning requires measured utilization and fair resource tradeoffs.

### Stage 3 — Refine event delivery and client critical paths

Sweep subscriptions 1/8/64/up to supported caps, hubs, event size and queued depth
independently. Exercise waiting consumers, slow consumers, every overflow policy
and cancellation. Profile per-publication sorting, repeated hub snapshots and front
removal. Evaluate exact per-hub counters, maintained subscriber order and bounded
FIFO storage independently. Account metadata and release consumed event payloads.

Separate socket receipt, lease validation, decoding, hub residence, cache/reducer,
dispatcher residence, handler preparation, provider work and response sink. Inject
zero/slow lease authority and handler/provider controls. The router already uses
dictionary lookup; do not propose replacing a nonexistent linear route search.
Treat larger handler concurrency as a bounded policy choice after measuring the
saturation knee and resource envelope.

Exit: per-shard/subscription order, resynchronization/drop accounting, trusted
interaction provenance and stale-generation fencing remain exact. Heartbeats,
reconnect, shutdown and fast subscriptions keep progressing under slow handlers.
Compare first acknowledgement and completed handler workflows independently.

### Stage 4 — Refine cache scaling and permission computation

Local implementation and validation are complete; see [Phase 4](PHASE-4.md).
Logical indexes stay bounded under churn. Full-expiry latency and entity process
RSS increase in local captures; numerical and profiler qualification remain open.

Measure hot hits, misses, updates, expiry storms, capacity eviction, invalidation,
single-flight subscribers and cancelled/superseded loaders. Sweep working set,
identity count, payload size and churn separately; setup stays outside lookup
timers. Include near-capacity and recovery workloads, rather than only empty caches.

Evaluate exact per-identity count/byte counters, bounded expiry indexing and LRU
ordering to replace repeated full scans. Bound stale index records and compaction
work; an index that grows with updates violates retained-state limits. Profile
serialization used for byte charging separately before considering count-only
projection. Sweep assigned roles, overwrite count and arbitrary bit width
independently for permission resolution; precompute immutable aggregates only
with an explicit revision/invalidation boundary.

Exit: inclusive expiry, scope isolation, redaction/null/absence, merge order,
stale-loader fencing, independent cancellations and exact accounted byte/count
limits survive. Permission snapshots remain observations, never authorization.
Demonstrate hot-hit scaling and bounded memory across repeated churn/expiry cycles.

### Stage 5 — Reduce shared value and framing CPU/allocation costs

Local implementation and validation are complete; see [Phase 5](PHASE-5.md).
Safe ASCII strings bypass per-token Foundation work, fallback coders are local
to one operation, and fragmented RPC retains its validated header. Allocation,
reserved-host numerical and target-platform qualification remain open.

Profile the shared JSON parser/writer before changing it. Separate buffer copies,
per-string coder construction, escapes/Unicode, sorted keys and model projection.
Evaluate ASCII fast paths, reuse within one parse/write and bounded capacity
reservation before a broad parser rewrite. Vary key/string/numeric density,
depth and width independently. Include malformed and maximum-limit paths.

For RPC, hold 256 KiB bytes constant and vary 7/256/4096-byte fragmentation; retain
parsed header state as a candidate. Check coalesced small frames separately.
Profile bitset decimal conversion/algebra at 64/256/4096 bits, model unknown-field
roundtrips and builder validation; change only stacks that remain material.

Exit: exact numeric lexemes and arbitrary width, Unicode/escape correctness,
canonical-equivalent duplicate rejection, deterministic wire output, error offsets,
presence/unknown-field retention and resource caps. Parser/writer changes require
independent differential/generated malformed-input coverage. RPC preserves ordering,
ping/pong bytes, truncation rejection and full error/reset behavior. Recheck REST,
Gateway, DSL and optional-protocol callers after each shared-core change.

### Stage 6 — Refine optional protocol and service workflows

Local implementation and validation are complete; see [Phase 6](PHASE-6.md). Controlled
host numerical and external browser/desktop/provider qualification remain open.

Use service timing to split OAuth refresh subscribers from one shared refresh and
storage/backend latency; RPC submission/correlation from IPC/peer delay; Activities
local correlation/subscriptions from an actual browser bridge; and Social,
Commerce, GameServices and Certified Devices orchestration from provider work.
Sweep same-key and unrelated-key callers, storage delay, fan-out and cancellation.
Add real Unix/local adapter captures separately from injected protocol fixtures.

Evaluate duplicate projections, bounded subscription/correlation indexes and
batched change-only provider writes where semantics allow. OAuth already coalesces
refreshes. Authoritative parent/revocation checks cannot simply be cached away.

Exit: token generation/revocation, consent/capability and entitlement authority,
one-use flows, bounded correlations, late-response fencing, exact full-array device
publication, partial-progress reporting and closure remain intact. Injected backends
cannot qualify browser/desktop/provider latency or externally delivered responses.

### Stage 7 — Refine authoring and build performance

Local implementation and validation are complete; see [Phase 7](PHASE-7.md).
Prepared-plan and large-catalog authoring improve in local observations. Repeated
small-catalog concurrent invocation controls and large macro clean builds are
slower in local comparisons; attribution and
reserved-host numerical acceptance remain open. Package boundaries, macro
expansion and compiler parallelism are retained.

Keep runtime invocation, in-process catalog construction, manual/macro expansion,
clean consumer build, incremental build, dependency/plugin bootstrap, package
planning and cold runtime startup as separate workloads. Use fresh process
direct/DSL arms and common whole-population sidecars rather than legacy prefix
samples. Use compiler timing to locate type-checking versus plugin/link/planning
cost before adjusting manifest/module boundaries or build parallelism.

Profile DefinitionPlan shape/preflight/full serialization and typed routing setup.
Evaluate bounded count-only validation or reused validated projections only while
preserving diagnostic order. Package/import refinements must keep narrow consumers
independent of voice, output handlers, compiler plugins and benchmark dependencies.

Exit: identical generated definitions/routes and diagnostics, no startup side
effects, equivalent handler work, unchanged public/import graph contracts and
paired clean/incremental receipts. Measure peak memory and CPU allocation with
compile time; more jobs is not automatically faster. Dependency downloads are
outside warm consumer comparisons and recorded separately for cold setup.

### Stage 8 — Refine media and codec processing

Local implementation and validation are complete; see [Phase 8](PHASE-8.md).
Bounded phase plans improve selected continuous filtering and affected encoding
workflows. Constructor cost, plan memory and awkward fallback tradeoffs are
retained; codec scratch and queues remain deferred. Reserved-host numerical,
allocation-event and physical/native runtime qualification remain open.

Start with continuous bandlimited resampling at 16/44.1 kHz to 48 kHz and reverse/
awkward ratios, mono/stereo, varying chunks, startup and finish. Profile repeated
transcendental coefficient generation. Evaluate immutable bounded phase plans
using rational-rate periodicity; cap plan bytes, account construction latency and
keep a bounded fallback for costly ratios.

Profile codec scratch allocations and existing FFT transforms across modes,
frames, channels, silence, PLC and FEC. Reuse per-owner workspaces only when
concurrency/value-copy independence is preserved. Sweep PCM/mailbox queue depth
before replacing bounded arrays; do not retain consumed buffers behind a head
index indefinitely. Keep signal algorithm delay separate from processing cost.

Exit: chunk invariance, sample-count carry, DC/anti-alias quality, channel order,
clipping/endpoint behavior, packet conformance, overlap/PLC/FEC and queue ownership
checks. Then compare paced duplex processing/scheduling misses. Apple device,
render, routing and acoustic latency use the explicit native procedure; codec
batch timings cannot establish those properties.

### Stage 9 — Refine secure voice and key transitions

Implementation and local evidence are recorded in [Phase 9](PHASE-9.md), including
full-window replay comparisons, exact RTP charging, larger MLS controls and
successful impaired local duplex. Reserved-host numerical acceptance, allocation
and executor attribution, independent security review, live interoperability and
other-platform qualification remain open.

Phase 8 recorded a pre-existing integrated impairment failure: empty-buffer PLC
followed by a same-tick reversed arrival pair reanchors jitter sequence to the later
packet and rejects the still-due earlier packet. See [Phase 8](PHASE-8.md) for the
loss/reorder/hold trigger and original-runtime reproduction. Phase 9 fixes arrival
batch anchoring, adds sequence/timestamp regressions and records joined success,
failure and cancellation cleanup. The original failure remains retained evidence.

First fill the DAVE replay coverage gap: prefill long-lived receivers at windows
64/1024/8192, then measure authenticated steady traffic, reorder/duplicates,
failures and generation expiry. Existing per-batch owners see at most 64 frames.
Evaluate a bounded sliding representation only after the full-window profile.
Transport crypto already has a fixed bitmap; do not generalize this diagnosis.

Measure jitter wire serialization used solely for accounting, then exact
validated length computation. Profile DAVE/RTP/transport AEAD copies and actor
handoffs within real local UDP ticks. Preserve pacing and frame geometry; neither
shorter sleeps nor larger queues is evidence of lower processing latency.

Extend MLS beyond two-to-three-member transitions: bounded group sizes, sparse
trees, proposal/removal counts and concurrent control/media. Separate queue
residence from cryptographic service and secure-ready from manager installation.
Evaluate redundant encoding/allocation or public immutable derivation only when
profiles show it; retain cryptographic algorithms and entropy.

Exit: nonce uniqueness, authenticate-before-replay commit, ratchet transactionality,
failure budgets, epoch/exporter agreement, revocation after suspension, ambiguity,
DTX timestamps, anti-catch-up, jitter reorder/wrap and joined cleanup. Re-run the
available independent wire/oracle checks. Security review and live interoperability
remain distinct from timing, and performance never justifies weakened checks.

### Stage 10 — Integrate, test recovery and promote narrow policies

Re-run the representative workflows after combining accepted changes. Sweep
offered load below/near/above the saturation knee, then recovery; retain successful
throughput alongside all terminal outcomes, generator lateness, queue age/depth,
control progress and final owners. Use independent scheduled arrivals for overload.
Exercise cold startup, warm fixed working set, payload bursts, slow providers,
CPU contention, observer modes, expiry/rekey storms and cancellation together.

Run a bounded standard comparison and fixed-working-set soak, initially 30 minutes,
with explicit process/resource ceilings. A cap hit is failure evidence, not a
successful short soak. Repeated load/recovery cycles must not accumulate retained
entries, index tombstones, tasks, sockets, crypto generations or native buffers.
Recheck relevant correctness suites, graph/import audit and consumer builds.

Start regression policies in reporting mode, with immutable hash-bound baseline,
no-change series and reviewed noise floors. Require narrow policies only after
stability review; retain incompatible/insufficient/host/harness classifications.
No automatic baseline refresh on failure. Keep numerical comparisons on the named
host and ordinary CI smoke informational on shared runners.

Exit: a per-change record containing mechanism, before/after target and tradeoffs,
exact validation and remaining gaps. macOS and Linux native execution, actual
browser/desktop/device and any subsequently authorized live workflow receive
separate receipts. Publication, deployment and live Discord are separate actions.

## Implementation handoff

Begin with Stage 0's default-policy workload and Stage 1's ordering notifications.
Each stage change records the source revision, case/fixture/metric identities,
correctness invariant, direct endpoint, profile/timeline evidence, no-change and
candidate series, resource/cleanup outcome and a keep/revise/defer decision.
An investigated track can exit as deferred when its cost is outside the measured
critical path; completing this plan does not require speculative rewrites.
