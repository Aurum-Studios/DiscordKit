<!--
File: Docs/Tasks/performance-improvements/PHASE-3.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 3 — Event delivery and client critical paths

Authorized 2026-11-11 from `5e06464b`. This phase follows the
[stage contract](PLAN.md#stage-3--refine-event-delivery-and-client-critical-paths).
Earlier reserved-host numerical and profiler qualification remain open.

## Implementation plan

1. Replace publication-time subscriber filtering/sorting and repeated hub-wide
   accounting scans with maintained creation order and exact per-hub counters.
   Keep aggregate budgets, admission priority, terminal subscription metadata,
   direct waiting-consumer delivery and all overflow policies exact.
2. Use bounded FIFO event storage that releases consumed payloads immediately.
   Inspect shared handler-permit handoff independently; preserve cancellation,
   bounded metadata and first-eligible per-shard dispatcher scheduling.
3. Inspect client ingestion, lease validation, routing and response ownership.
   Preserve trusted interaction provenance, stale-generation fencing, heartbeat,
   reconnect and joined shutdown. Keep concurrency policy and exact route lookup
   unless discriminating evidence supports a change.
4. Add finite versioned fan-out/backlog controls with independently varied
   subscriber count, hub count, event bytes and depth. Retain existing lease and
   provider-delay controls and distinguish publication, residence, first response
   and completed-handler boundaries. Test waiting/slow consumers, loss policies,
   cancellation, saturation and recovery deterministically.
5. Run focused and full runtime tests, affected harness and repository checks,
   independent consumer builds and strict documentation/API checks. Build identical
   release harnesses against the original and candidate runtimes, then capture
   serial fresh-process no-change and alternating comparisons with source/build,
   process/cleanup and failed-attempt evidence.
6. Record retained and deferred decisions, exact validation outcomes and local
   measurement limits; update behavior guides, inventory and changelog, review
   the scoped diff and commit the authorized local implementation.

## Implementation and decisions

The hub now maintains one creation-order subscription list and exact event, byte
and waiting-consumer counters for each admitted hub. Publication visits only its
hub's subscription IDs and actual evictions; capacity checks and snapshots use
counters rather than repeated scans of unrelated hubs. Terminal resynchronization
metadata remains admitted until observation, cancellation or hub finish. Empty
hub metadata is removed. Direct waiting-consumer handoff retains no queue charge.

An actor-owned subscriber reference holds a lazily grown circular event queue.
This avoids both live-entry front shifting and dictionary-value copy-on-write of
the queue. Growth is bounded by the minimum individual/hub/shared event count
limit, consumed slots release payload references immediately, and empty queues
release slot storage. Growth and empty-slot cleanup are amortized over admitted
entries. Creation-order removal remains a bounded subscription-lifecycle cost;
finishing many subscriptions can perform quadratic ID-list removal work. Envelope
byte accounting does not include metadata or allocator overhead. Nonempty queues
can retain their bounded slot high-water capacity; no net memory-saving claim is
made. Waiting consumers allocate no queued slot.

Shared handler-permit handoff now clears consumed continuation slots and advances
a head index. It reclaims a sufficiently large prefix when it is at least as long
as the live suffix, preserving amortized FIFO transfer and bounded logical slot
extent. Cancellation searches the live suffix by exact invocation ID. The backing
array can retain its bounded high-water allocation after drain.

The dispatcher's first-eligible-shard pending scan remains: a FIFO replacement
would change its ability to skip a shard whose previous handler is suspended.
The current four-handler concurrency and 128-event/4 MiB retention policy remain.
Client ingestion and router preparation were inspected; routing already uses exact
dictionary lookup. No evidence selects a router rewrite, larger handler
concurrency or ownership-validation caching. Every real lease fence remains in
place around asynchronous work; trusted interaction receipts and stale-generation
rules are unchanged.

## Correctness and attribution

Deterministic tests cover circular growth/wrap/non-power-of-two limits, repeated
drain/refill, byte-driven multi-eviction, creation priority after removal and
replacement, independent shared hubs, terminal metadata and exact counters. A
cross-hub test confirms that dropOldest can discard only its own backlog even
when the new event still cannot fit because another hub holds the shared bytes.

Seventy separately supervised dispatchers exercise FIFO shared-permit transfer,
queued cancellation before and after prefix reclamation, and joined permit and
subscription cleanup. A suspended callback can exhaust its own queue while a fast
subscription receives every event and observes the exact continuity failure.
An integrated control test keeps a callback suspended while heartbeat ACK,
reconnect/RESUMED, a fast subscription and socket shutdown all complete. Structured
callback cleanup joins independently afterward.

Zero-delay and 17 ms virtual-time controls hold one actual post-receipt lease
validation. Sequence and decoding cannot advance before release; successful
validation contributes exactly that delay to the receipt and lease intervals,
while decode remains zero in that clock. A failing authority closes without
accepting or decoding the new event. Existing cancellation, lease-loss, old-socket,
trusted-provenance, response-deadline and joined-shutdown suites remain applicable.
These barriers establish causality and invariants, not real-time latency budgets.

## Measurement controls

The new versioned public-API hub workloads vary subscriptions, hub count, queued
depth and payload size independently. Queued mode prefills outside publication
timing and replaces one copy per subscriber per iteration, maintaining a fixed
backlog. Waiting mode confirms each parked consumer before publication. Held
populations exercise all three overflow policies and cancellation. Subscriber
sequence and copy accounting are explicit, including setup, discarded admitted
copies and terminal resynchronization observations.

Publication is measured directly from caller entry through actual return, with
1 microsecond bins. Pull-call distributions also include setup returns and final
drain; residence uses production intervals including retained setup copies and
teardown. They are different overlapping populations and must not be subtracted.
Gross duration and process CPU include fixture setup, barriers, optional consumer
hold, final drain and joined cleanup. The hub workload contains no socket,
cache/reducer, dispatcher, lease, provider or trusted interaction receipt.

Existing Gateway trusted-response and deferred-handler fixtures retain separate
first-acknowledgement, completed-handler and response-sink populations. Slow
provider work is an injected control, not attributed to hub CPU.

## Validation and local observations

Local implementation and validation completed on 2026-11-11. Apple Swift 6.4,
arm64 macOS and SDK 27.0; pinned dependencies and four build jobs. The
[capture index](phase-3-observations.json) retains release/source identity, identical
harness hashes, configurations, exact commands, per-process observations and
artifact hashes. Raw reports/logs remain in the ignored local capture directory;
this is local evidence, not a published artifact store. Evidence-only edits after
capture leave executable and test input hashes unchanged.

- Root build passed. Final `SWIFTNIO_STRICT=1 swift test --skip-build --jobs 4`
  passed **2,658 methods in 332 suites across 34 test-target runs**, zero issues.
  Final focused coverage passed **29 methods in four suites**, including the
  corrected cross-hub fixture and integrated control test.
- Load harness passed **123 methods in 23 suites**; development tooling passed
  **106 methods in eight suites**. Python suites passed **234 repository-tooling,
  42 load-harness and 47 benchmark-support tests**.
- Independent RESTOnly and GatewayBot consumer builds passed. Offline inventory,
  deterministic generation, parity, symbol graph extraction, DocC curation and
  documentation example synchronization passed.
- The callable audit found **963 Swift files, 10,327 explicit callable declarations,
  zero missing comments**. Strict Gateway DocC passed with warnings as errors and
  analysis. The API policy check passed, and the candidate public API snapshot is
  exactly equal to phase 2's snapshot.
- Independent production review found no correctness defect. It caught an initial
  byte-cap arithmetic mistake in the new cross-hub test before final focused
  execution; the corrected test passes. The initial documentation audit saw nine
  unfinished harness comments. Two early harness compile attempts exposed signed
  interval conversion and optional-Bool fixture errors. Cancellation testing then
  caught a real diagnostic race: cancelling an iterator may release its queue
  before a snapshot. The harness now counts actual cancelled residence endings
  after joined teardown. The failed cancellation log is retained. Two early compile
  logs were overwritten; their known errors/resolutions are summarized explicitly,
  rather than reconstructed as raw evidence.

### Paired local observations

Original runtime: `5e06464b9dae57fcdeae63c14ea7f4c534de68ca`, with only identical
new development harness sources copied into its isolated detached checkout.
Original runtime Sources are unchanged. Compiler, flags and dependency pins match;
release receipts retain actual pre-commit source fingerprints and executable hashes.
Builds and tests completed before serial captures.

Eight configurations each have five independent candidate/candidate no-change
pairs and five alternating original/candidate pairs: **160 fresh measured
processes**. Every process publishes 128 times per hub, using one sequential
publisher, no in-process warmup, zero injected delay, seed 8113 and a ten-second
measured cap. All **576,000 offered subscriber copies** completed successfully
across **38,400 publication calls**. Every owner drained, every process was reaped,
no owned process group survived, and no aggregate timing/report output was lost.
P99 is unavailable for these per-run populations.

The following are ranges of the **individual process p50 bins** in microseconds,
not pooled quantiles, confidence intervals or a reviewed regression floor.
Queued rows use a 128-byte data string unless shown otherwise. Depth is prefilled
copies per subscriber; the next publication precedes one pull per subscriber.

| Subscribers per hub / hubs / depth | Original | Candidate | Candidate no-change |
| --- | ---: | ---: | ---: |
| 1 / 1 / 1 | 2–7 | 2–3 | 2–4 |
| 8 / 1 / 1 | 11–13 | 3–4 | 3–4 |
| 64 / 1 / 1 | 324–346 | 12–14 | 12–14 |
| 8 / 1 / 128 | 21–24 | 3–4 | 3–4 |
| 8 / 8 / 1 | 39–42 | 3–4 | 3–4 |
| 8 / 1 / 1, 16 KiB data | 11–13 | 3–4 | 3–4 |
| 8 waiting, one hub | 8–10 | 5–7 | 4–7 |
| 64 waiting, one hub | 48–52 | 25–29 | 25–27 |

These observations support retaining the smaller publication mechanism on this
host, especially at larger fan-out and shared-hub occupancy. The shallow single
subscriber and waiting populations retain visible scheduling/no-change spread.
They do not establish a deployment capacity or end-user response-time improvement.
For the 64-subscriber queued case, gross process CPU was 61.269–64.579 ms originally,
20.329–21.398 ms with the candidate and 20.365–21.393 ms in candidate no-change runs.
That gauge includes histogram/fixture setup and joined cleanup; it is not a CPU
profile of publication. Process-lifetime peak RSS across all eight configurations
was 19.688–20.547 MiB. No allocation profile or metadata memory-saving claim follows.

These comparisons exercise the combined hub representation/counter/order refinement;
they do not isolate each sub-mechanism or quantitatively qualify handler-permit FIFO
handoff. Circular storage, shared admission and permit behavior also have independent
deterministic coverage. Selective dispatcher pending scans remain deferred.

### Release regression controls

An additional **26 fresh release smoke processes** cover both arms and all overflow
policies, retained cancellation, slow consumers, maximum 64 KiB data strings,
trusted immediate/deferred responses at zero and 2 ms injected provider delay,
overload/recovery and reconnect. Exact terminal classifications total **1,536
successes, 1,166 rejections and 194 cancellations** across 2,896 offered subscriber
copies/handler invocations. All planned continuity, response-send, control-progress
and reconnect receipts matched, with no remaining owner or process group.

The trusted workflows confirmed **48 initial responses and 32 original-message
continuations**. First acknowledgement, completed handler and response-sink metrics
remain separate in the raw/native reports. These small functional controls do not
resolve an acknowledgement or completed-workflow latency gain. Cancellation and
refusal are intentional outcomes in the selected loss/recovery workloads, not
unclassified missing work.

## Remaining qualification

The host was not reserved; contention/exclusivity, thermal/frequency behavior and
allocation/executor/CPU profile stacks remain unqualified. No numerical regression
policy is promoted. Real socket-to-provider critical-path contribution, sustained
arrival/saturation capacity, long soak, Linux/hosted CI, live Discord and production
qualification remain separate. Phase 3 completes the authorized local implementation
and evidence; [stages 4–10](PLAN.md#stage-order-and-dependencies) remain planned.
