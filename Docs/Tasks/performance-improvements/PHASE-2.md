<!--
File: Docs/Tasks/performance-improvements/PHASE-2.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 2 — Request work and transport refinement

Authorized 2026-11-11 from `1b10c663`. This phase follows the
[stage contract](PLAN.md#stage-2--remove-request-duplication-and-refine-transport-work)
with the earlier reserved-host and profiler gates still open.

## Implementation plan

1. Return the already validated typed REST value on the unshared path. Keep byte
   validation before retention, shared byte flights and independent subscriber
   decoding. Count actual decoder calls for cache misses/hits, malformed successes,
   coalescing, cancellation and 1/16/256 KiB typed fixtures.
2. Serialize interaction initial responses once for both exact byte admission and
   built-in delivery. Keep public typed custom sinks, pre-suspension reservation,
   signed original bytes, ambiguous outcomes and response limits unchanged.
3. Replace signed-ingress full replay scans with a bounded expiry index if exact
   inclusive expiry, eviction and atomic post-authentication admission survive.
   Preserve serialized signature service until attribution supports changing it.
4. Refine NIO buffering independently: a bounded FIFO and one materialization per
   emitted native chunk. Preserve cumulative caps, complete EOF drain, abandoned
   bodies, deadline children and exactly-once lease/connection cleanup. Inspect
   Foundation separately; retain pre-send upload collection and current pool sizes.
5. Run deterministic focused coverage, full runtime and affected harness suites,
   consumer builds, repository/API/documentation checks. Build identical release
   harnesses against original and candidate runtimes, then run serial finite
   fresh-process no-change and alternating comparisons. Retain source fingerprints,
   process/cleanup receipts, failures and numerical qualification limitations.
6. Update the inventory, behavior guides and changelog, review the complete diff,
   and commit the authorized local phase. Hosted/platform and live qualification
   remain separately recorded.

## Implementation and decisions

Local implementation and validation completed on 2026-11-11. The
[capture index](phase-2-observations.json) retains original/candidate release
receipts, exact dirty source fingerprints, identical harness hashes, commands,
per-process observations, cleanup and raw artifact hashes. Raw logs and reports
remain in the ignored `.build/performance-phase2` directory; this is local
evidence, not a published artifact store. The later commit includes evidence-only
updates after capture; executable and test input hashes were rechecked unchanged.

### REST decoding

Keep the unshared fast path. A successful wire exchange now returns its validated
value along with its bytes. It still validates before cache insertion and checks
cancellation/deadline after suspended work and before returning. Cache hits run the
current caller's decoder. Shared flights retain only bytes: the owner validates
before retention, and each successful subscriber decodes independently. There is
no typed value cache or shared mutable response object.

Actual interval counts in each 64-request typed fixture are **128 original → 64
candidate decoder invocations**, at exactly 1/16/256 KiB. Focused reference-value
tests also verify one invocation per cache hit, one owner validation plus one
per successful shared subscriber, independent cancellation and distinct reference
identities. Malformed successes fail before retention and a later valid request
recovers. Retries, API-error decoding and cancellation/deadline during synchronous
decoding retain the existing failure and uncertain-mutation classification.

### Interaction response serialization

Keep one responder-owned serialization for built-in initial-response delivery.
The same validated Data is charged to acknowledgement admission and sent through
inline HTTP or a package-only REST endpoint. Reservation still happens before
suspension; validation, byte caps, a single initial slot and ambiguous outcomes remain
unchanged. Public custom sinks retain their typed callback. REST sinks also retain
compatibility validation against their bound interaction kind when it differs
from the responder's kind.

The inspected call graph changes built-in delivery from two serializations to
one. Small and 32 KiB Unicode fixtures verify exact callback bytes and admission
charges, including a one-byte-short capacity refusal before sink invocation,
invalid callbacks and ambiguous submission. The responder's validated log event
counts the successful serialization boundary; it is **not** a global encoder-call
counter, and custom sink work is outside this library count. These finite workflow
timings do not resolve an interaction latency improvement.

### Signed ingress

Keep the bounded replay expiry index. A binary minimum heap and signature-to-slot
index replace full live-entry filtering and oldest-entry searches. One heap entry
and one index slot exist per retained signature; repeated retries replace neither
with stale tombstones. Insertion/eviction is O(log n); checking an all-live window
examines its root. Expiry removes only entries strictly older than current time.
Signature authentication still happens before pruning or atomic replay admission,
inside the existing serialized actor. Saturating expiry arithmetic handles the
accepted upper timestamp bound.

This trades additional bounded O(n) index metadata for less repeated scanning.
There is no allocation profile establishing net memory savings. Deterministic
coverage includes out-of-order timestamps, inclusive expiry, full drain/refill at
capacities 1/2/3/4/15/64/127, retries, advisory oldest eviction, clock regression,
failed authentication without pruning, Int64.max and concurrent duplicate admission.

The new versioned near-capacity fixture authenticates 4,095 distinct entries before
measurement, then measures 128 new requests at capacity 4,223. Setup is excluded
from workflow/service histograms. A separate native 1 μs histogram records actual
caller-to-verifier actor admission; the historical `ingress.admission` metric
continues to mean replay admission service. At concurrency one, verifier admission
p50 remains within 0–1 μs in both arms. Replay service p50 remains within the
historical 0–100 μs bucket, so this run cannot resolve its central latency. Its
per-process maximum spans 7.292–11.542 μs originally and 1.625–5.542 μs with the
candidate (candidate no-change: 1.333–5.708 μs). These are observed maxima for finite
populations, not tail estimates or a contention profile. Parallel signature
verification remains deferred: these results do not establish serialized crypto
as the dominant workflow cost.

### Transport

Keep the narrow NIO representation changes: a CircularBuffer releases consumed
queued chunks without array front shifts, and each bounded native buffer slice
becomes Data directly, removing the complete-buffer Data plus subrange copy pass.
Cumulative payload bounds, complete EOF drain, demand, deadline children, body
ownership and connection release rules remain unchanged. Patterned 256 KiB tests
exercise 257/4,096-byte output at both content-length and close-delimited EOF,
including drain after the peer closes, repeated EOF/close and a fresh request.
Existing adapter suites cover overflow, abandoned bodies, pending reads,
cancellation/deadline/parent close, pool release/reuse and upload failures.

Foundation was investigated independently and remains unchanged. Its AsyncBytes
interface yields bytes; speculative bulk buffering or up-front maximum reservation
has no demonstrated benefit and can increase retained memory. Pool sizes, event
loop/thread counts, TLS policy and per-pull deadline tasks remain unchanged. Both
adapters still collect bounded uploads before transmission, preserving producer
failure before any send; true streaming requires a separate API contract.

The new native controls hold the immediate response at 65,536 bytes and vary only
the emitted chunk bound (257 or 65,536), independently for NIO and Foundation.
Neither establishes an adapter latency gain beyond the local no-change spread.
First-byte instrumentation is unavailable: headers are not a first-byte measure.
The retained streamed-body peer flushes chunks without a controlled per-piece
delay, and streamed-upload production is immediate. Delayed trickle/producer,
first-byte, allocation and executor attribution remain open; deterministic
abandonment and pool-refusal checks are not timed saturation experiments.

## Validation

Apple Swift 6.4, arm64 macOS, SDK 27.0; pinned dependencies and `--jobs 4` throughout.
Builds/tests finished before serial timing processes began.

- Root build passed. `SWIFTNIO_STRICT=1 swift test --skip-build --jobs 4` passed
  **2,650 methods in 330 suites across 34 test-target runs**, zero issues. Focused
  REST multiplicity/timing, interaction encoding/replay and native adapter suites
  also passed after rebuilding.
- Final load-harness suite passed **114 methods in 22 suites**. Python suites passed
  **234 repository-tooling, 42 load-harness and 47 benchmark-support tests**.
- Independent RESTOnly, HTTPApp and GatewayBot consumer builds passed.
- Offline inventory, deterministic generation, parity, public symbol graphs,
  DocC curation and example synchronization passed. The callable documentation
  audit found **957 Swift files, 10,279 explicit callable declarations, zero missing
  comments**. The API policy check against 0.18.0 at candidate 0.19.0 passed.
- Strict DocC conversion passed `--warnings-as-errors --analyze` for DiscordHTTP,
  DiscordInteractions and DiscordNIOTransport. Whitespace and local evidence
  read-back checks passed.

Early failed attempts remain indexed: Swift Testing suite-level availability and
async expectation compilation; replay fixtures that incorrectly generated a new
signature for a duplicate; an incorrect lifecycle-state expectation; and a harness
Int64/UInt64 histogram conversion. Those fixtures/compile issues were corrected
before the passing runs above. A first comparison attempt completed ten processes
but its wrapper rejected a mismatched scheduler declaration. Its reports and exact
original spec are retained separately and excluded from the following comparison.

### Native transport regression smoke

An additional **38 fresh native smoke processes** cover both release arms and
both adapters: immediate small bodies in warm/cold modes, streamed bodies,
streamed uploads, wrong-byte response validation, cancellation after headers,
deadlines and both equal-byte chunk controls, plus verified private-PKI TLS for
NIO. All 120 measured terminal classifications matched: 96 success, eight
validation failure, eight cancellation and eight timeout; 22 separate warmup
requests are excluded from those counts. Validated response bytes total 3,158,016
and produced upload bytes total 1,048,576. All adapter closes joined, all peer
connections drained, and every NIO pool snapshot reported zero active/idle slots
after shutdown. Each cold row accepted exactly two new connections. Supervisors
reaped every process with no surviving owned group or unexpected descendants.
Foundation's private pool counts remain unavailable.

These are functional smoke receipts, not additional paired numerical comparisons.
The wrong-byte fixture is not a truncated socket-body test; cancellation abandons
the body before its first pull. Small-cohort pool refusal cannot be induced with
the runner's matching concurrency/capacity policy and remains deterministic test
coverage. One initial candidate smoke was refused before launch because intervening
documentation edits changed the strict full-source fingerprint. A new real release
build receipt, with **the identical executable hash**, allowed the final captures;
the rejection remains indexed. The scope of CPU/memory and unmeasured first-byte,
trickle, producer-delay and private Foundation TLS behavior remains explicit.

## Paired local observations

Original runtime: `1b10c663e70cae90c0f49c7bb80aba89ff90600f`, with only the same
new/updated development harness copied in. Its runtime Sources are unchanged.
Both release arms use identical harness sources and compiler/flags/dependency pins;
receipts retain executable hashes and actual pre-commit source fingerprints.

Nine configurations each have five independent candidate/candidate no-change pairs
and five alternating original/candidate pairs: **180 fresh measured processes**.
REST uses 64 requests at each typed size; immediate and prefilled interactions use
128; each native adapter/chunk variant uses 32. All use concurrency one, zero
in-process warmup and injected delay, root seed 8112, and a ten-second measured cap.
Every offered request succeeded. There was no histogram loss/overflow, truncated
process output or surviving owned process group. Runtime owner counts drained;
Foundation close and peer connection cleanup completed, but its private pool
counts remain unavailable rather than reported as zero.

The spans below are minimum lower and maximum upper **per-process p50 bucket
bounds**, rounded outward, across five comparison processes per arm or ten
candidate no-change processes. They are not pooled percentiles or confidence
intervals. Common histograms use 100 μs buckets.

| Workload / direct endpoint | Original p50 span | Candidate p50 span | Candidate no-change p50 span |
| --- | --- | --- | --- |
| Typed REST 1 KiB: request | 0.1–0.2 ms | 0.1–0.2 ms | 0.1–0.2 ms |
| Typed REST 16 KiB: request | 0.1–0.2 ms | 0.1–0.2 ms | 0.1–0.2 ms |
| Typed REST 256 KiB: request | 0.4–0.5 ms | 0.3–0.4 ms | 0.3–0.4 ms |
| Immediate interaction: workflow | 0.1–0.2 ms | 0.1–0.2 ms | 0.1–0.2 ms |
| Prefilled replay: workflow | 0.1–0.2 ms | 0.1–0.2 ms | 0.1–0.2 ms |
| NIO 64 KiB / 257-byte chunks: request | 5.0–5.2 ms | 5.1–5.2 ms | 5.0–5.3 ms |
| NIO 64 KiB / 65,536-byte chunks: request | 0.4–0.5 ms | 0.4–0.5 ms | 0.4–0.5 ms |
| Foundation 64 KiB / 257-byte chunks: request | 9.3–9.5 ms | 9.3–9.5 ms | 8.5–9.6 ms |
| Foundation 64 KiB / 65,536-byte chunks: request | 6.6–6.8 ms | 6.6–6.8 ms | 6.5–7.2 ms |

For the 256 KiB REST case, whole-process user+system CPU spans **37.558–38.260 ms
original → 28.358–30.135 ms candidate** (candidate no-change: 27.589–29.554 ms).
The deterministic invocation reduction and separated bucket spans support this
local fixture improvement. Smaller responses and the remaining endpoints do not
establish a general latency/CPU win. Transport full-body, headers and request
histograms are retained separately; none supplies DNS/TLS or first-byte attribution.

CPU probes include fixture setup, signing, near-capacity prefill, warmup and joined
shutdown. In particular the replay fixture's CPU includes thousands of setup
verifications and cannot be labeled measured-request replay CPU. Peak RSS is
process-lifetime memory with allocator/runtime noise, not retained heap/index
allocation accounting. For example replay peak RSS spans 22,609,920–22,937,600 bytes
originally, 22,872,064–23,019,520 with the candidate and 22,708,224–22,953,984 in
candidate no-change processes; these observations do not qualify memory savings.

The named host's reservation/contention status is unknown. No numerical regression
policy or noise threshold was selected/evaluated. Each outcome population is below
the retained 10,000-sample p99 gate; no p99 result is claimed. Reserved-host
qualification, causal allocation/CPU/executor profiles, Linux/hosted CI, live
Discord and production capacity remain open gates. The scoped implementation is
kept on correctness, exact removed work and bounded ownership evidence; the local
measurements do not close the earlier numerical/profiler gates.
