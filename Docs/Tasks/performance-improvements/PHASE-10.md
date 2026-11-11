<!--
File: Docs/Tasks/performance-improvements/PHASE-10.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 10 — Integration, recovery and reporting policies

Authorized 2026-11-11 from `a8a7539b` under the
[stage contract](PLAN.md#stage-10--integrate-test-recovery-and-promote-narrow-policies).

## Implementation plan

1. Preserve the Phase 9 revision in a detached checkout. Recheck the combined
   runtime with an independent scheduled-arrival workload that exercises shared
   default-policy request admission, a fixed cache working set and bounded event
   delivery. Keep this scripted workflow distinct from network or live Discord
   capacity. Do not alter production policy to obtain a faster result.
2. Repeat below/near/above fixture-capacity load and recovery bands. Observe every
   offered request and terminal outcome, successful throughput, generator lateness,
   queue depth/age, control progress and resources. Exercise provider delay,
   cancellation, payload bursts and expiry with finite owner and report bounds.
3. Add durable process supervision and strict report validation. A process,
   resource, output or duration ceiling is failure evidence. Require a real
   1,800-second fixed-working-set soak with joined zero-owner cleanup; retain
   failed and partial attempts without relabeling them as completed runs.
4. Retain fresh independent no-change and alternating standard comparisons with
   exact release receipts and workload identities. Reuse the existing immutable
   hash-bound policy evaluator. Report uncontrolled-host and insufficient evidence
   classifications; promote no numerical threshold without reserved-host capture
   and explicit noise/stability review. Never refresh a baseline on failure.
5. Run strict root and affected development-package tests, offline consumers,
   inventory/generation/parity, graph/import and documentation checks. Preserve
   each earlier phase's mechanism, direct target, measured tradeoffs and remaining
   gates in a final reconciliation.
6. Review and commit locally. Linux runtime, actual browser/desktop/device,
   independent security review, live Discord, publication and deployment receive
   separate evidence when those stages are run.

## Execution record

Implementation and local validation are complete. The
[observation index](phase-10-observations.json) retains exact commands, source and
release identities, raw artifact hashes, complete outcome populations, canonical
baseline/no-change hashes, validation receipts and remaining gaps. Raw artifacts
remain in the ignored local `.build/performance-phase10` directory; the index
does not make those artifacts available on another checkout.

### Retained implementation

No production runtime optimization was added in this phase. Production `Sources`
and every tracked root/nested package manifest and dependency pin match
`a8a7539b32851e122ca1f81e399e77be996590c6`. The combined Phase 1–9 runtime is the
subject of the new development-only `integration-timing` workload.

The workload retains one default-policy ordered REST partition with injected
25 ms provider delay, a 64-key entity-cache working set, two data subscriptions
and one control subscription on a shared Gateway authority. A slow held consumer
and a draining consumer exercise bounded delivery. Independent arrivals offer
20/40/160/20 requests per second in below/near/above/recovery bands. Those names
refer to the injected provider control's nominal knee, including cold policy
initialization; they are not a measured platform-capacity claim.

Cache expiry, 8 KiB payload bursts, wrapping CPU arithmetic and actual REST child
cancellation overlap these owners. Cancellation after send can be uncertain and
is counted explicitly. Every band drains its eight active/eight pending driver
slots; the cache and hubs persist across cycles. A separate control hub publishes
and pulls every 100 ms on the same authority. This is software control progress,
not a Discord heartbeat. Queue-age observation is opt-in so legacy arrival
profiles perform no new clock reads. Integration CLI logging uses a fixed
critical-level filter to bound diagnostics; existing commands keep their policy.

The Python supervisor uses release receipts and the shared bounded process-group
driver. It rejects short duration, incomplete cycles, missing outcomes,
configuration/report disagreement, cap hits, modified artifacts and retained
owners. The scheduled integration profile builds an independent shared-schema
validator and requires it to accept the report. Its 110-minute job ceiling covers
both bounded builds and the full soak. Shared-runner CI is informational; the
workflow was not dispatched during this task. See the
[load-tool procedure](../../../Tools/DiscordKitLoadTests/README.md#performance-phase-10-integration-and-recovery).

### Mixed-load and soak observations

Both four-second aggregate/disabled-operation smoke processes passed. Mandatory
arrival-driver accounting remains enabled in both; this is not a clock-free
observer control. Two independent standard series each used five alternating
pairs, with eight requested seconds and complete four-band cycles per process.
All twenty standard processes passed duration, schema, outcome and cleanup
checks. Both arms use the same final frozen executable: they measure repeatability
and are not an original-versus-optimized comparison.

The 1,800-second soak exited successfully after
**1807.335 measured seconds** and
**214 complete load/recovery cycles**. It offered and completed
102,720 terminal operations: 51,330 success,
48,160 rejected, 2,184 cancelled,
1,046 uncertain, 0 failure and
0 timeout. It recorded 0 deadline
misses; this fixture sets no request deadline, so that count does not qualify a
production deadline. Successful throughput was 28.401/s;
terminal-outcome throughput was 56.835/s.

The following rates use each complete band's actual elapsed wall span, including
drain. Rejections have exact counts and no invented response latency.

| Band | Offered | Success | Rejected | Cancelled | Uncertain | Success/s | Peak pending | Max pending age (ms) | Control progress |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| below | 8,560 | 8,053 | 4 | 2 | 501 | 18.786 | 8 | 580.194 | 4,090 |
| near | 17,120 | 16,113 | 0 | 977 | 30 | 36.982 | 0 | 0.000 | 4,194 |
| above | 68,480 | 19,107 | 48,156 | 1,205 | 12 | 37.155 | 8 | 231.541 | 4,972 |
| recovery | 8,560 | 8,057 | 0 | 0 | 503 | 18.795 | 0 | 0.000 | 4,102 |

The raw receipts preserve generator lateness and censoring, per-cycle recovery,
all six outcomes and bounded histograms. Every completed cycle had zero retained
arrival owners, cache refreshes and cache waiters. The maximum retained public
cache/event counts stayed within 64. Final actual REST active/queued/ordered/
flight/waiter/cache/body/transport counts and Gateway subscription/event/byte/
consumer counts were all zero, and the entity cache was empty after close.
Control progress totalled 17,383. The native monitor observed
23,281,664 bytes maximum sampled RSS and
63.410117 process CPU seconds. Neither its explicit
resource ceilings nor the independent supervisor's caps were hit.
The configured ceilings were 2 GiB RSS, 7,230 process CPU seconds and 1,830 wall
seconds, with 16 MiB diagnostics and 32 MiB report limits. The maximum observed
scheduler lateness was 24.582 ms, with zero censored generator observations.

### Other representative receipts and policy decision

Six selected workflows each retain five independent no-change pairs and five
alternating repeatability pairs: shared OAuth refresh, string-dense JSON parsing,
DefinitionPlan byte admission, continuous 44.1-to-48 kHz stereo resampling,
prefilled DAVE replay-8192 and concurrent eight-member MLS transition/media.
All 120 fresh processes completed with valid native/common accounting and joined
cleanup. Their duration values are ceilings around fixed finite batch populations,
not claims of 30-second steady execution. The exact fixture, batch endpoint,
source/executable and scheduler identities remain in each series.

Three separate shared-collector observation modes (disabled, aggregate and
filtered; cohort four) completed. One two-second impaired hybrid stereo localhost
UDP receipt with a separate two-second warmup used two busy CPU workers, loss
every seventh packet, reorder every fifth surviving ordinal and 20 ms holds.
It sent 400 measured packets, received 344 and concealed 56; encoding deadlines,
policy cadence misses and processing-budget overruns were zero. Both contention
workers and all media/DAVE/datagram owners closed, with zero final media bytes.
This is an offline synthetic-PCM loopback receipt, not audio-device or Discord
qualification.

The existing immutable hash-bound evaluator remains authoritative. Canonical
baseline and independent no-change-series hashes are retained for review. The
named local macOS arm64 host had no reserved CPU, thermal or frequency control.
No reviewed noise floor, numerical threshold or required policy was adopted;
no baseline was automatically refreshed. Existing evaluator tests preserve
incompatible, insufficient-sample, host-failure and harness-failure outcomes.
No p99 is qualified by pooling processes or averaging percentiles.

### Correctness, continuity and remaining gates

The strict root build and all **2,692 tests in 339 suites** passed. Final affected
development-package runs passed: load 146, benchmark support 68, tooling 106,
media 25, voice qualification 12 and Apple audio 15 Swift tests. The focused
secure-media subset passed 268 tests, and the native cached MLS++ oracle passed
all five scenarios. Python suites passed: load 54, CI 187, tooling 234,
benchmark support 47, Foundation 3 and DSL 33 tests. Seven independent offline
consumers built successfully: VoiceBot, RESTOnly, GatewayBot, OAuthApp, RPCApp,
ActivityHost and DSLBot. Inventory, unchanged generation, parity, graph/import,
release, callable-documentation, curation and documentation-example checks passed.

Two initial load validation failures are retained: a missing transport import,
and a legacy scripted-clock failure caused by unconditional queue observation.
The import and opt-in clock behavior were fixed before final passing tests and
all release captures. Six release products built serially with one frozen
source identity. The 1,265-file executable/test/build input manifest
still matches the final worktree; final documentation does not rewrite historical
capture-time dirty-source fingerprints. Cross-SDK compilation, symbol emission
and API snapshot checks were not rerun: unchanged production/manifests/pins prove
input continuity, not fresh platform execution.

Fifteen additional Python helper tests passed in local Linux arm64 containers
using a pinned official Python image, read-only source and no network. This
qualifies the new supervisor and CI helper on that container only. Linux Swift,
Linux x64 and hosted qualification remain separate.

Simultaneous MLS/DAVE rekey/media with REST/cache/Gateway stress remains open;
the separate secure-media captures do not close it. Fixture construction occurs
before the integration clock, so fresh processes establish no application-startup
latency. Sustained CPU contention is qualified only in the separate short voice
receipt; the soak overlaps bounded arithmetic. Sampled RSS and public owner bounds
do not prove allocation counts, tombstone/native-buffer deallocation or universal
leak freedom. Reserved-host numerical acceptance, allocation/executor profiling,
independent security review, actual browser/desktop/device, live interoperability,
publication and deployment retain their separate gates.

## Reconciliation of the retained changes

The linked records retain the exact original/candidate identities, direct
before/after observations, correctness checks, rejected candidates and local
resource tradeoffs. Phase 10 does not retrospectively convert those observations
into reserved-host qualification or add their separate timings into a workflow.

| Phase and mechanism | Direct target and retained decision | Cost or remaining attribution |
| --- | --- | --- |
| [1: FIFO notifications](PHASE-1.md) | Completion-to-successor handoff and default-policy admission; retain bounded notifications and one earliest-wake timer | Remote authority changes still need finite rechecks; quota, fairness and uncertain-send rules remain |
| [2: request work](PHASE-2.md) | One unshared successful REST decode, one owned interaction serialization and NIO buffered reads | Shared readers still decode independently; native network internals and true upload streaming retain their own limits |
| [3: event delivery](PHASE-3.md) | Hub-local subscription indexing, circular queues and consumed permit-slot release | Lifecycle list removal can remain quadratic; bounded backing storage can retain its high-water allocation |
| [4: cache indices](PHASE-4.md) | Indexed expiry/LRU and per-identity accounting replace cache-wide hot-hit scans | Extra metadata and O(k log n) expiry drains; permission evaluation remains stateless |
| [5: JSON and framing](PHASE-5.md) | Validated ASCII string paths and one incomplete RPC header parse | Unicode/escaping retains Foundation validation; bitsets, model projection and builder algorithms remain unchanged |
| [6: optional services](PHASE-6.md) | Actor-confined OAuth flight owners and exact Activity token counts | One reference owner per flight; the RPC queue marker was reverted after measured tradeoffs |
| [7: authoring](PHASE-7.md) | Exact DefinitionPlan byte counting without full serialization | Diagnostic order and payload semantics retained; compiler/bootstrap/startup populations remain separate |
| [8: resampling](PHASE-8.md) | Immutable bounded phase plans reduce repeated coefficient work | Construction and up to 256 KiB of plan payload per owner; costly ratios retain direct evaluation; codec scratch/queues deferred |
| [9: secure media](PHASE-9.md) | Bounded replay bits, exact RTP charging and reordered resumption after empty PLC | Small-window variation and one contended tick-overrun run remain adverse evidence; MLS/actor/crypto boundaries retained |

All phases retain their open allocation/executor attribution, controlled-host
noise and numerical acceptance, and applicable native-platform/live-service
gates. The final integration receipts qualify only the exercised local software
owners and declared endpoints.
