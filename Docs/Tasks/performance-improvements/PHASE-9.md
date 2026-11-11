<!--
File: Docs/Tasks/performance-improvements/PHASE-9.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 9 — Secure voice and key transitions

Authorized 2026-11-11 from `f150293e` under the
[stage contract](PLAN.md#stage-9--refine-secure-voice-and-key-transitions).

## Implementation plan

1. Preserve the original runtime in a detached checkout. Add versioned,
   long-lived DAVE workloads prefilled through replay windows 64, 1024 and 8192.
   Measure full-window authenticated traffic before selecting a representation;
   include reordered frames, duplicates and failed authentication.
2. Evaluate bounded replay bookkeeping while preserving strict window edges,
   nonce uniqueness, authenticated state commitment, ratchet transactionality,
   verification budgets, generation expiry and idempotent closure. Add independent
   differential tests and retain the existing wire/vector oracles.
3. Fix the phase 8 empty-buffer PLC/reordered-arrival failure with deterministic
   sequence/timestamp regressions. Replace jitter serialization used only for byte
   accounting with exact validated lengths if its cost justifies the change.
   Verify integrated impairment and joined cleanup on successful and failed runs.
4. Extend MLS transition populations beyond two-to-three-member groups, including
   sparse removal and concurrent control/media. Keep endpoints, cryptographic
   service, actor admission and manager installation claims distinct. Defer
   cryptographic/copy/handoff changes without sufficient attribution.
5. Use identical release-built development harnesses for both runtimes, five
   independent no-change pairs and five alternating comparison pairs for selected
   workloads. Retain source/build identities, native/common reports, resource and
   cleanup observations, and separate CPU diagnostics. Builds and captures run
   serially; unreserved-host observations do not select numerical gates.
6. Run focused and strict complete tests, benchmark/tooling tests, offline
   consumers, inventory/generation/parity, dependency/API and documentation checks.
   Re-run available independent secure-wire checks and local paced duplex with
   loss/reorder/hold, preserving nonce, DTX, anti-catch-up and revocation invariants.
7. Review the complete diff and commit locally. Reserved-host numerical
   acceptance, allocation/executor profiling, security review, other-platform
   runtime and live interoperability remain separate qualification stages.

## Result and decisions

Phase 9 implementation and local validation are complete. Numerical acceptance
on a reserved host remains open, as in earlier authorized phases. The retained
[observation index](phase-9-observations.json) contains the source/build identities,
62 media series, six local duplex series, per-process observations, validation
receipts, failed attempts and diagnostic artifact hashes. Raw artifacts remain
under the ignored local `.build/performance-phase9` directory; the committed
index preserves their identities and compact observations, not their availability
on another checkout.

| Finding | Implementation decision | Preserved boundary |
| --- | --- | --- |
| F24: DAVE replay Set rebuilding scales with retained nonces | Store one circular bit per configured replay position | Strict absolute-distance admission, authentication before state commitment, verification quotas, ratchet transactionality, expiry and closure |
| F23: RTP serialization solely for byte charging | Compute exact wire length from immutable validated geometry | Full RTP overhead, exact byte budgets, failure without mutation and value isolation |
| Phase 8: empty PLC followed by reversed arrivals | Retain the cursor through the arrival batch; resume at its earliest wrapping sequence only when its timestamp is due | Finite packet/byte bounds, timestamp continuity, loss/DTX distinction and ordinary insertion policy |
| F25/F26: actor/copy and MLS transition attribution | Add larger dense/sparse and concurrent populations; retain existing actor and cryptographic boundaries | Entropy, transcript/exporter agreement, removal revocation, suspension fences and ownership |

### DAVE replay representation

Each receiver allocates `ceil(replayWindow / 64)` UInt64 words. The bit payload is
128 bytes for the default 1024-position window and at most 1024 bytes for 8192;
array/actor overhead is additional. This is a fixed initial allocation instead
of a lazily populated Set. Steady forward acceptance clears and sets one slot;
a jump shorter than the window clears the crossed positions, and a larger jump
clears at most 128 words. No per-frame Set reconstruction remains.

The original strict predicate `newest - nonce < replayWindow` is unchanged.
Modulo slots are unique within that live interval, including non-power-of-two
windows. Authentication and candidate-ratchet acceptance precede any replay-bit
mutation. Forged future frames cannot clear a colliding slot. Expired generations
fail the existing generation guard before replay lookup; forward motion clears
any reused slot, so pruning needs no replay scan. Failure budgets, key retention,
nonce limits, wire bytes and cryptographic algorithms remain unchanged.

New differential tests use independently produced SwiftCrypto GCM frames and a
historical Set oracle at windows 1, 3, 63, 64, 65, 1024, 8191 and 8192. They cover
multiple wraps, holes, duplicate/reordered frames, strict edges, large jumps and
forged future slot collisions. Existing generation, verification-limit, ratchet,
wire/vector and close tests remain in the full suite.

### RTP accounting and PLC resumption

The internal RTP length is exactly fixed header + CSRCs + optional extension
header/data + payload + padding. Construction already validates these immutable
fields. Jitter insert/pop and pipeline admission now use that length, avoiding
three serialization-for-count paths. Wire serialization itself is unchanged.
Regressions compare the count to actual bytes over optional sections, maximum
UDP geometry, shared Data copies, exact budgets and one-byte-short rejection.

An empty PLC interval cannot distinguish DTX from a loss gap. Previously the
first returning arrival reset sequence order immediately; a reversed batch then
rejected its earlier still-due packet. The media owner now retains all admitted
arrivals through the playout boundary, selects the earliest wrapping sequence,
and resumes only when its timestamp is due. A future packet retains the old
cursor while PLC fills the gap. Internal returning-stream admission allows a
long concealed gap while bounding the complete retained sequence span by packet
capacity and retaining the usual byte limit and half-range ordering rule. Public
jitter insertion keeps its existing forward-window policy.

Tests cover sequence and timestamp rollover, reversed arrivals, future-before-due
packets and a 65-position loss gap with capacity two. The encrypted loopback
regression reproduces loss every seventh packet, reorder every fifth packet
ordinal that survives loss and a 20 ms hold through the original failing interval. Failure and
cancellation tests verify awaited media/DAVE/datagram/worker closure.

The qualification tool now carries the original failure together with actual
joined cleanup receipts. A partial sidecar omits unavailable outcome/throughput
accounting rather than fabricating it. Datagram EOF diagnostics run in a fresh,
owned and awaited task so cancellation can still verify closure.

## Workloads and capture method

The legacy catalog identities remain intact. Thirty-one `v4` workloads extend the
catalog to 174 cases:

- Nine continuous DAVE populations prefill one long-lived receiver through windows
  64/1024/8192, then exercise steady opens, reordered opens plus duplicate refusal,
  and authentication failure plus recovery. A wrapper is policy-specific work,
  not always one successful decrypt. The measured 256 wrappers per process stay
  within the real verification quota; limits are never enlarged for measurement.
- Three expiry populations prefill generation zero, accept generation one, prove
  an old key works at nine seconds, then time a new-generation open at eleven
  seconds and verify the withheld old frame is rejected. These use real encrypted
  generation-boundary frames and the public time input, with separate owners.
- Twelve MLS populations start with 4/8/16 members: add one, remove one, remove
  three, or remove one after an untimed interior-leaf removal creates a sparse
  tree. The sparse population therefore has one fewer active member than its
  initial tree fixture. Every survivor accepts the commit and agrees on exporter
  and authenticator; removed peers lose access. Add uses a real proposal because
  no-proposal rekey is unsupported. Welcome join is outside the timed transition.
- One mixed population joins one eight-to-seven-member removal with 64 opens on
  an independent DAVE receiver with a 1024-position replay window. Its endpoint is
  completion of both concurrent batches. It establishes neither explicit actor
  queue residence nor manager installation or secure-ready latency.
- Six matched RTP serialization/jitter insert-pop cases use eight packets with
  payloads 80/1200/16000 bytes, two CSRCs, eight extension bytes and four padding
  bytes. Each packet has payload + 36 wire bytes. Changing payload preserves the
  remaining geometry; the serialization cases are retained controls.

Both arms use identical development harness sources. The original runtime and
root build inputs match `f150293e75bace0b1e72519346f09389b9d3925e` in a detached
checkout; only the copied development harness differs there. Four successful
release builds retain source fingerprints, compiler/pin/flag identities and exact
executable hashes, with separate retained binary copies. An 827-file frozen
source/test/harness manifest and root manifest/pin checks prove the final
documentation descendant did not alter measured executable inputs. Capture-time
dirty-source receipts remain historical and are not rewritten after documentation.

The host is local macOS arm64, Apple Swift 6.4, without reserved CPU/thermal or
frequency control. Builds/tests finished before captures; captures and separate
CPU diagnostics ran serially. Each workload has five independent candidate versus
candidate no-change pairs and five alternating original versus candidate pairs:
620 fresh media processes. Seeds, fixture source hashes, geometry, scheduler,
exact commands, receipts and raw/enriched reports are cross-checked per pair.

Continuous DAVE and RTP/jitter use 16 measured batches of 16 wrappers; expiry and
MLS use eight batches of one. Warmup is capped at one batch. The supervisor
requests ten-second warmup and thirty-second measurement ceilings, but these
finite batch caps determine the actual shorter populations. Native elapsed times
are retained. Scheduler identities distinguish continuous population streams,
serial wrappers and joined concurrent batches. The mixed case declares two
active branches while its outer wrapper remains serial.

Every accepted media process completed all offered batches, retained no owners,
had no histogram loss or deadline misses, and had its process group reaped with
no output truncation. Analysis verifies histogram conservation, quantile bounds,
native/common equality, exact timed sums, resource scopes and the complete
specification-to-series-to-process provenance chain. Sparse batch populations
leave p99 unavailable; normalized wrapper means are not call percentiles.

## Local observations

Values below are medians of five separate process means in microseconds per
wrapper. Percentage ranges are the five paired candidate/original changes and
the separate candidate/candidate no-change changes. They are descriptive local
observations, not accepted regression thresholds or user-visible latency claims.
The index retains all 31 workloads, complete ranges and resource observations.

| Population | Original µs | Candidate µs | Paired change % | No-change range % |
| --- | ---: | ---: | ---: | ---: |
| DAVE steady, 64 | 15.603 | 15.431 | −4.4 to +42.1 | −4.9 to +5.6 |
| DAVE steady, 1024 | 26.880 | 13.746 | −52.1 to −47.5 | −4.3 to +3.6 |
| DAVE steady, 8192 | 107.849 | 13.737 | −91.7 to −86.1 | −2.2 to +2.3 |
| DAVE reorder/duplicate, 1024 | 53.840 | 37.453 | −32.0 to −24.3 | −3.8 to +3.3 |
| DAVE reorder/duplicate, 8192 | 165.905 | 36.946 | −78.2 to −77.6 | −2.3 to +4.5 |
| DAVE authentication failure/recovery, 8192 | 122.435 | 27.866 | −78.4 to −77.1 | −2.8 to +2.0 |
| DAVE expiry, 64 | 14.838 | 15.287 | −4.9 to +20.0 | −11.5 to +49.9 |
| DAVE expiry, 8192 | 52.838 | 14.661 | −74.9 to −71.2 | −9.6 to +138.3 |
| Jitter eight-packet insert/pop, payload 80 | 12.101 | 0.714 | −94.2 to −94.1 | −0.2 to +8.5 |
| Jitter eight-packet insert/pop, payload 1200 | 12.619 | 0.702 | −94.5 to −94.3 | −0.6 to +2.6 |
| Jitter eight-packet insert/pop, payload 16000 | 20.155 | 0.710 | −96.5 to −96.2 | −5.4 to +7.7 |
| RTP eight-packet serialization, payload 16000 | 10.424 | 10.085 | −9.7 to +6.4 | −4.6 to +5.5 |

The large-window replay and direct jitter populations support retaining these
bounded mechanisms locally. The 64-position replay case shows little median
change and includes a +42.1% pair; small-window expiry is slightly slower by its
median. No-change expiry and tiny serialization populations also have large
outliers. These observations remain in the evidence rather than being discarded
or converted into a universal performance claim.

Independent original-runtime prefill probes at 64/1024/8192 positions measured
14.712/26.282/107.829 µs per wrapper with 2048 measured wrappers each under the
final retained original build. Earlier exploratory probes found the same scaling;
their original executable cache was later overwritten, so only the repeated final
probes have a currently verifiable retained build identity.

MLS add-one medians scale from 11.044 to 27.922 to 80.373 ms across initial
4/8/16-member original fixtures, versus 11.045/28.028/80.807 ms for the candidate.
Dense remove-one is 6.261/20.253/66.659 ms versus 6.275/20.230/66.503 ms. Sparse
remove-one and remove-three retain their own distinct populations in the index.
The mixed joined batch is 20.097 versus 20.047 ms. There is no material local MLS
algorithm change to claim: cryptographic encoding, entropy and actor ownership
remain intact pending separate attribution.

Resource receipts retain lifetime peak RSS, current RSS, process CPU and explicit
allocator availability. In steady replay at 8192, original peak RSS ranges
16.80–17.58 MiB versus 16.28–16.44 MiB; at 64 it is 16.02–16.03 versus
16.06–16.11 MiB. Jitter payload 16000 ranges 15.45–15.47 versus 15.53–15.58 MiB.
These whole-process figures include startup, fixtures and warmup; they are not
the bit-array size or cumulative allocation events.

Four separate one-second `sample` captures cover original/candidate replay8192
and jitter16000 release processes. Original replay samples contain the per-open
Set filter, and original jitter samples contain RTP serialization beneath insert.
Candidate jitter samples also include serialization in fixture preparation and
oracles. These captures include untimed setup and have unequal finite work;
stack presence supports the mechanism but sample totals establish no paired CPU
percentage, allocation-event reduction or executor-residence claim. No copy/actor
or MLS cryptographic redesign is selected from them.

### Paced local UDP and the retained original failure

Sixty fresh voice processes cover five no-change pairs and five comparison pairs
for stereo CELT (960 samples/frame) and hybrid (480), plus five candidate-only
no-change pairs each for impaired hybrid and impaired hybrid with two CPU workers.
The supervisor profile and participant profile are distinct checked identities.
Each process has two seconds of warmup and two measured seconds; synthetic local
signaling creates real encrypted loopback UDP owners, without a Discord session.

All 60 complete their media cohorts and join two media owners, two DAVE owners,
two datagram owners and any workers, with zero final buffered bytes. Unimpaired
CELT sends/receives 200 packets; hybrid sends/receives 400. Each impaired process
sends 400, deliberately drops 56, receives 344 and conceals 56 packets, with exact
decoded-frame counts. Reorder/hold selections and all terminal accounting are
retained. Policy cadence misses and schedule underruns are zero throughout.

One candidate-only contention process records **66 processing-budget overruns**
out of 200 measured ticks and a 9.791 ms processing median; the other 59 processes
record none. It remains a completed media run with adverse deadline evidence,
not a deadline-qualified result. Host interference versus workload effects is
unresolved. Unimpaired comparison medians of process p50s are 3.418/3.430 ms for
CELT and 2.898/2.859 ms for hybrid (original/candidate), within broad no-change
variation. They establish no direct user-visible secure-voice latency gain.

The original runtime under the same impairment still raises `duplicateOrLate`.
Its process exits unsuccessfully; the retained partial sidecar records failure,
actual joined zero-owner cleanup and partial metrics, with no invented counts or
throughput. The supervisor confirms process-group reaping. This failure is separate
from the 680 completed comparison processes and is not relabeled as success.
The Phase 8 historical failure record is preserved.

## Correctness, compatibility and validation

Validation ran on local macOS arm64 with resolved dependencies and four build
jobs. The frozen source/test inputs remain unchanged after these successful checks:

| Check | Result |
| --- | --- |
| Focused DAVE/MLS/Voice/VoiceCrypto, `SWIFTNIO_STRICT=1` | 268 tests, 34 suites, four test products passed |
| Root build and complete strict tests | 2692 tests, 339 suites, 34 test products passed |
| Cached native MLS++ initial-candidate oracle | One method with five scenarios passed; exact cached executable hash retained |
| Media harness Swift tests | 25 tests passed, including all 31 v4 identities and full catalog |
| Voice qualification Swift tests | 12 methods passed, including real encrypted impairment, failure and cancellation cleanup |
| Benchmark support | 68 Swift tests and 47 Python tests passed |
| Repository tooling | 106 Swift tests and 234 Python tests passed |
| CI tooling and media supervisor | 183 and six Python tests passed |
| Offline VoiceBot and RESTOnly consumers | Builds passed; offline VoiceBot also ran successfully |
| Inventory, generation check, parity, graph and release audit | Passed; generated output unchanged |
| API compatibility | All 33 module snapshots equal Phase 8 after JSON decoding; reviewed baseline check passed |
| Documentation | Callable audit, curation/examples and strict Voice/DAVE DocC passed |

The native oracle uses the already cached binary because the previous external
MLS++ source checkout is absent. This is an exact-binary wire check, not a fresh
upstream rebuild, full security audit or live interoperability qualification.
Existing full-suite nonce, quota, expiry, rollback, exporter, revocation,
suspension, DTX timestamp, ambiguity and anti-catch-up tests remain intact.
Read-only peer review found no blocking replay, accounting or ownership defects;
this is distinct from an independent cryptographic security review.

Initial unsuccessful attempts remain indexed: an incomplete harness failed to
compile, a concurrent-source-change build receipt was rejected, a Swift compiler
assertion on an async macro expression was avoided by separating macro extraction
from `await`, and an overbroad DocC input glob was narrowed to the exact module.
Subsequent builds/checks passed. Failed or source-drift receipts qualify no capture.

## Remaining qualification and phase 10 handoff

Reserved-host comparisons and reviewed numerical/no-change gates, sustained
saturation/recovery, the bounded 30-minute integration soak, allocation-event and
executor profiling, independent security review, other-platform runtime, native
audio/device behavior and live Discord interoperability remain open. Sparse batch
and tick populations do not qualify p99. Timing and local success establish no
cryptographic security property or production READY state.

Phase 10 should retain the small-window and contention adverse observations while
combining the selected mechanisms under actual offered-load and recovery controls.
No publication, hosted CI dispatch, deployment or live runtime operation belongs
to this local phase implementation.
