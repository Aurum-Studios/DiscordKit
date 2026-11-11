<!--
File: Docs/Tasks/performance-improvements/INVENTORY.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Performance findings and coverage

Source coordinates refer to `065e2b65`, before the planning documents. A confirmed
code mechanism is distinct from a qualified performance bottleneck. Only F01 has
a dedicated causal timing reproduction here; the CPU observations expose workload
cost and fragmentation sensitivity, not attributed profile stacks. All candidate
implementations remain proposed. See [stage gates](PLAN.md) and [evidence](EVIDENCE.md).

## Shared runtime paths

| ID / stage | Confirmed source mechanism or attribution gap | Discriminating experiment and possible refinement |
| --- | --- | --- |
| F01 / 1 | [RateLimitCoordinator](../../../Sources/DiscordHTTP/RateLimitCoordinator.swift), 125–143, 181–209, 225–248: each blocked waiter sleeps; completion/release supplies no successor notification. [SchedulingPolicy](../../../Sources/DiscordHTTP/SchedulingPolicy.swift), 42, 59: default polling interval 10 ms. | Barrier release after a real sleep invocation reproduced post-release delay. Extend to rate permits, multiple partitions, real authority retry deadlines and overload; evaluate bounded notifications, retaining remote-authority rechecks. Preserve FIFO, quotas, cancellation and fail-closed ownership. |
| F02 / 2 | [RESTClient](../../../Sources/DiscordHTTP/RESTClient.swift), 156–199: unshared misses decode before possible retention and again for the caller, even with cache/coalescer disabled. Shared byte flights validate once plus caller decoding. | Count decoder calls; hold bytes/model complexity fixed, compare disabled reuse, misses, hits and subscribers. Consider one decoded result on the unshared path; preserve malformed-success refusal, typed isolation and subscriber cancellation. Performance benefit remains unmeasured. |
| F03 / 2 | [InteractionResponder](../../../Sources/DiscordInteractions/InteractionResponder.swift), 162: full serialization charges admission bytes; [InteractionHTTPApplication](../../../Sources/DiscordInteractions/InteractionHTTPApplication.swift), 115–119: sink serializes again. | Count encodings over small/large valid responses and errors; profile before internal validated-byte reuse. Preserve initial reservation before suspension, exact byte charging, typed custom sinks and ambiguous acknowledgement state. |
| F04 / 2 | [SignedRequestVerifier](../../../Sources/DiscordInteractions/SignedRequestVerifier.swift), 103–135: synchronous verification and replay maintenance share one actor; replay expiry scans retained state. Internal signature/replay timing omits the caller's preceding actor residence. | Independently sweep body bytes, replay entries and callers; split caller admission, crypto and replay commit. Consider expiry indexing before concurrency redesign. Authenticating exact original bytes before decode and atomic replay admission cannot be weakened. |
| F05 / 2 | [FoundationHTTPTransport](../../../Sources/DiscordFoundationTransport/FoundationHTTPTransport.swift), 174–187: async bytes consumed individually with per-byte cancellation/append until a configured chunk fills. | Fixed total bytes with chunk/trickle sweeps, CPU/allocation and direct first-byte/full-body timings. Evaluate bulk delivery/bounded reservation if material. Preserve byte caps, cancellation and exact close behavior. |
| F06 / 2 | [NIOHTTPTransport](../../../Sources/DiscordNIOTransport/NIOHTTPTransport.swift), 426–438, 560, 594–605: per-pull task/deadline work, front removal and ByteBuffer/Data/subdata materialization. [Lifecycle](../../../Sources/DiscordTransport/Lifecycle.swift), 50–75: structured deadline race. | Sweep chunks at equal bytes, active deadlines, complete/abandoned and EOF-framed bodies. Profile task, copy and allocator costs. The deadline sleeper's 100 ms cancellation checkpoints do not impose a 100 ms operation delay. Preserve the cumulative response cap and complete EOF drain. |
| F07 / 2 | Foundation, 59–79, and NIO, 122–137: complete upload is collected before sending. NIO, 200–223, 319–337: pool refusal and lease lifetime include response ownership. Headers combine several connection/upload/peer costs. | Independently vary producer delay, cold/warm connection, TLS, pool load, full/abandoned bodies and peer delay. Add genuine adapter lifecycle timestamps where available. Producer failure sending no bytes is deliberate; true streaming needs separate contract design. Pool/thread limits need utilization evidence. |
| F08 / 3 | [EventHub](../../../Sources/DiscordGateway/EventHub.swift), 202–203, 217–226, 257–264, 323–328: per-event sort; admission repeatedly recomputes hub usage with full subscriber scans, including eviction loops. | Independently sweep subscriber count, hubs, bytes and queue occupancy. Profiles may justify maintained order and exact hub counters. Preserve aggregate/subscriber caps, publication order, overflow and resynchronization behavior. |
| F09 / 3, 8 | EventHub, 218/283, and [PCMFrameStream](../../../Sources/DiscordMedia/PCMFrameStream.swift), 165–170: bounded arrays remove from the front. Similar raw/dispatcher, IPC and media queues need occupancy-specific review. | Compare realistic shallow occupancy and supported large occupancy before a bounded ring/head index. Verify consumed payloads are released promptly, compaction stays bounded and ordering/cancellation/priority semantics survive. Do not apply a queue rewrite indiscriminately. |
| F10 / 3 | [GatewayShard](../../../Sources/DiscordGateway/GatewayShard.swift), 555–559, 690–729: frame receipt validates the injected lease before decode; sends fence around writes. | Inject zero/slow/failing authority and count calls; correlate socket receipt and explicit authority wait. Remote validation may dominate while decode appears cheap. Preserve ownership generations and fail-closed fences; do not cache them without a consistency contract. |
| F11 / 3 | [CommandRouter](../../../Sources/DiscordCommands/CommandRouter.swift), 267–300: lookup already uses a dictionary; synchronous preparation executes on the router actor, async execution suspends reentrantly. | Separate queued residence, preparation, middleware, hydration/provider, handler and response sink. Vary independent/slow handlers and offered load. Optimize measured preparation, not an assumed linear route search; protect control progress and trusted receipt origin. |
| F12 / 4 | [EntityCache](../../../Sources/DiscordCache/EntityCache.swift), 98–117, 607–632, and [ReadCache](../../../Sources/DiscordHTTP/ReadCache.swift), 91–127, 160–162: hot lookups prune the whole retained dictionary; identity totals and eviction selection scan repeatedly. | Working-set, identity, expiry fraction, churn and payload sweeps with setup excluded. Evaluate bounded expiry/LRU indexes and exact identity counters. Index tombstones, memory and compaction must remain bounded; preserve inclusive expiry, visibility and invalidation fencing. |
| F13 / 4 | EntityCache apply/merge serializes fields for byte charging. [PermissionResolver](../../../Sources/DiscordCache/PermissionResolver.swift) composes arbitrary-width role/overwrite decisions. Current largest fixture increases roles, overwrites and width together. | Separate charge/projection from lookup, then vary assigned roles, overwrites and bit width independently. Consider reusable immutable aggregates only with explicit revision invalidation. Cache results never replace current authorization. |

## Shared values, protocols and developer paths

| ID / stage | Confirmed source mechanism or coverage limit | Discriminating experiment and possible refinement |
| --- | --- | --- |
| F14 / 5 | [JSONValue](../../../Sources/DiscordCore/JSONValue.swift), 150–173, 291–303, 375–377: input copies; Foundation coder and temporary Data per string/key. Writer also sorts object keys. | Profile coder setup, copies, escaping and sorting separately. Independently vary string count/length, escapes, numeric density, Unicode, depth and width. Test fast paths or per-operation coder reuse before a rewrite; preserve lossless numbers, Unicode, deterministic bytes, duplicate rejection and error offsets. |
| F15 / 5 | [RPCFraming](../../../Sources/DiscordRPC/RPCFraming.swift), 104–106: incomplete payload fragments repeatedly materialize/reparse the same header. | Current 256 KiB cases observed 3611.738/113.397/21.432 µs per call at 7/256/4096-byte fragments. This is fragment sensitivity, including append-loop cost. Profile before retaining parsed header state. Preserve caps, frame ordering, EOF/reset and opaque control bytes. |
| F16 / 5 | [UnsignedBitSet](../../../Sources/DiscordBits/UnsignedBitSet.swift), 44–58: decimal conversion processes digits across words. Models/builders project and validate bounded JSON. | Existing 64/256/4096-bit and model/builder cases supply initial costs. Profile multi-digit conversion, projection allocation and validation traversals; retain arbitrary precision, absent/null/value and unknown fields, exact limits and rejection ordering. |
| F17 / 6 | [TokenCoordinator](../../../Sources/DiscordOAuth/TokenCoordinator.swift) already coalesces refreshes; authoritative storage and parent checks enforce generation/revocation. Service backends and Activity peers in timing fixtures are injected. | Same/unrelated-grant concurrency and zero/slow storage/backend controls; split subscriber/owner/storage populations. Investigate redundant work without skipping authoritative checks. Actual browser, desktop, IPC and provider qualification needs actual adapters. |
| F18 / 6 | [RPCIPCConnection](../../../Sources/DiscordRPC/RPCConnection.swift) owns bounded framing; [RPCClient](../../../Sources/DiscordRPC/RPCClient.swift) owns request correlation; [UnixIPCTransport](../../../Sources/DiscordUnixPlatform/UnixIPCTransport.swift) and browser bridge have separate native/host costs. Social/device/commerce workflows compose existing owners. | Correlation cardinality, event fan-out, peer delay, same/unrelated calls, unsubscribe/late responses, full-array publication and partial progress. Candidate indexes/coalescing must preserve host origin/nonce, exact writes, consent, authority and closure. No proven new bottleneck in these families yet. |
| F19 / 7 | [DefinitionPlan](../../../Sources/DiscordDSL/DefinitionPlan.swift), 466–469: shape, preflight and full serialization to charge payload bytes. Legacy DSL measurements use prefix samples and direct-before-DSL ordering. | Separate authoring from invocation, counterbalance fresh direct/DSL processes and use whole-population sidecars. Profile traversals; a bounded count-only writer must preserve diagnostic priority and exact accounting. |
| F20 / 7 | [Compiler benchmark](../../../Tools/DiscordDSLBenchmarks/README.md) separates dependency/plugin bootstrap, clean consumers and one-file incremental builds. It does not alone attribute package/compiler/module cost. | Capture type-check/plugin/planning/link timings, cold startup and memory, fixed pins/flags/jobs. Compare narrow consumer imports and actual macro consumers. Preserve public graph, generated definitions and no runtime plugin/benchmark coupling. |

## Media, voice and observation

| ID / stage | Confirmed source mechanism or coverage limit | Discriminating experiment and possible refinement |
| --- | --- | --- |
| F21 / 8 | [PCMBandlimitedResampler](../../../Sources/DiscordMedia/PCMBandlimitedResampler.swift), 192–214: sin/cos coefficient generation per output-frame tap. Current benchmark copies state and processes/finishes each call. | Continuous chunked stream, cold plan construction, rational/awkward rates, channels, finish and output quality. Evaluate bounded immutable phase tables. Preserve duration carry, DC/anti-aliasing, phase/chunk invariance and delay. |
| F22 / 8 | [CELTTransform](../../../Sources/DiscordVoiceCodecs/CELTTransform.swift), 112 onward: existing O(N log N) FFT with scratch materialization. Codec/state copies are included in current wrapper calls. | Profile stateful continuous encode/decode and scratch allocation across frame/mode/channel/PLC/FEC. Reuse owned workspaces only with correct value/concurrent isolation. No basis for replacing an assumed naive transform. |
| F23 / 9 | [JitterBuffer](../../../Sources/DiscordVoice/JitterBuffer.swift), 51/64: serializes an RTP packet on insert and removal solely to obtain byte count. | Independently vary payload, CSRC, extension, padding and occupancy; evaluate exact validated wire length and integrated receive/playout impact. Preserve byte charging, sequence wrap, rejection without mutation and reset. |
| F24 / 9 | [DAVEFrameCipher](../../../Sources/DiscordDAVE/DAVEFrameCipher.swift), 331–332: rebuilds replay Set after each authenticated frame. [CryptoWorkloads](../../../Tools/DiscordMediaBenchmarks/Sources/DiscordMediaBenchmarks/CryptoWorkloads.swift), 51–74: new owners per batch with at most 64 calls, versus default window 1024/max 8192. | Prefill long-lived receivers then hold window/state constant through steady traffic, reorder, forgery, expiry and generation changes. Consider a bounded sliding bitmap/ring only after profiling. Authenticate before committing replay/ratchet state. [Transport cipher](../../../Sources/DiscordVoiceCrypto/VoiceTransportCipher.swift) already has a fixed bitmap. |
| F25 / 9 | [VoiceMediaPipeline](../../../Sources/DiscordVoice/VoiceMediaPipeline.swift), 667–685: DAVE actor, RTP materialization, slices, transport AEAD actor, UDP. Existing ticks include nested/overlapping work and local diagnostics. | Profile copy/actor service with actual frame geometry and direct paced ticks under bounded contention. Preserve nonce/state ownership, revocation checks, DTX media time and no ambiguous resend/catch-up. Pacing, jitter depth and codec lookahead are intentional latency components. |
| F26 / 9 | [TransitionWorkloads](../../../Tools/DiscordMediaBenchmarks/Sources/DiscordMediaBenchmarks/TransitionWorkloads.swift), 41–48: create, small Welcome join, two-to-three-member rekey. DAVE queue wrapper includes scheduling without guaranteed depth. | Group/proposal/tree-sparsity/removal scaling, explicit queue admission and mixed media/control load. Retain entropy, rollback, transcript/exporter agreement and cryptographic oracles. Timing establishes no cryptographic security property. |
| F27 / 0 | [RunStatistics](../../../Tools/DiscordBenchmarkSupport/Sources/DiscordBenchmarkSupport/RunStatistics.swift), 239–247, and [DiscordTimingAggregate](../../../Sources/DiscordLogHandlers/DiscordTimingAggregate.swift), 222–252: shared locks. [DiscordIntervalTiming](../../../Sources/DiscordLogging/DiscordIntervalTiming.swift) allocates ID before child start and locks end state before stop. | Mode/cohort and shared/per-worker collector controls plus separate lock profile. Parent/gross durations include work omitted by child setup boundaries. Preserve bounded cardinality, nil-hook behavior, loss and clock identity; never subtract independent percentile estimates. |
| F28 / 0 | [DiscordLogOperation](../../../Sources/DiscordLogging/DiscordLogOperation.swift), 80–88: UUID/context work precedes filtered trace emission. [DiscordFileLogHandler](../../../Sources/DiscordLogHandlers/DiscordFileLogHandler.swift) performs synchronous bounded serialization/rotation/write. | Filtered/no-op/output modes, callback contention and flush outside timing. Profile before fast-path or owned buffered-output design. Any buffering must have explicit loss/backpressure/flush/close semantics; avoid file/format work in realtime loops. |
| F29 / 0, 10 | [ArrivalTimingRunner](../../../Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/ArrivalTimingRunner.swift) has independent scheduled arrivals; REST wave/coalescing runners include driver barriers. [Supervisor](../../../Tools/DiscordBenchmarkSupport/scripts/run_benchmarks.py) samples leader RSS and records load averages. | No-op arrival and delayed-fixture controls, generator headroom, separate peer/host/resource profiles. Include rejections, drain and missed arrivals; never infer capacity from a slowed closed-loop generator or process-peak RSS. |

## Runtime product coverage

All 33 source product directories were inventoried. A group below can have shared
root causes without requiring a separate rewrite. The existing instrumentation
[ownership inventory](../latency-timing/INVENTORY.md) supplies the larger public API
and workload list; this document records optimization decisions and gaps.

| Products / adjacent component | Coverage and proposed stage |
| --- | --- |
| DiscordBits, DiscordCore, DiscordModels | Exact bits/JSON, model decode/encode/unknown fields and builders; F13–F16, stages 4–5 |
| DiscordTransport | Deadline/task/body lifecycle, ownership and scalar observation; F06/F27, stages 0/2 |
| DiscordFoundationTransport, DiscordNIOTransport | Actual local adapters, upload/chunk/pool/connect/reuse/close; F05–F07, stage 2 |
| DiscordHTTP | Admission, duplicate decode, coalescing/read cache, catalog/pagination/projection; F01/F02/F12, stages 1/2/4; remote pagination/indexing delay stays separate |
| DiscordGateway, DiscordClient | Lease/socket/control/dispatch, fan-out, reducer/ingestion/start/stop; F08–F11, stage 3 |
| DiscordCache | Expiry/eviction/refresh/scoping/permissions; F12/F13, stage 4 |
| DiscordInteractions, DiscordCommands | Signed ingress/replay, response encoding/lifecycle, exact routing/change-only reconciliation; F03/F04/F11, stages 2–3 |
| DiscordDSL, DiscordCommandDSL, DiscordBotDSL | Construction/lowering/typed invocation and authenticated bot pipeline; F11/F19/F20, stages 3/7 |
| DiscordOAuth | Grant/subscriber/storage/backend generation and cancellation; F17, stage 6 |
| DiscordRPC, DiscordUnixPlatform | Incremental framing, correlation, native IPC ownership; F15/F18, stages 5–6 |
| DiscordActivities, browser bridge | Injected protocol work and separately actual browser message/correlation/subscriptions; F18, stage 6 |
| DiscordCertifiedDevices | Full-array HTTP/RPC publication and host ownership; F18, stage 6 |
| DiscordSocial, DiscordGameServices, DiscordCommerce | Provider/consent/capability/entitlement workflows and partial progress; F18, stage 6; unavailable schemas/native providers stay unavailable |
| DiscordMedia, DiscordVoiceCodecs | PCM queues/resampling, continuous codecs, scratch and signal delay; F09/F21/F22, stage 8 |
| DiscordApplePlatform | Capture mailbox/codec software and separate native device/render/route procedures; stage 8; no device operation during this planning task |
| DiscordVoice, DiscordVoiceCrypto | Jitter/RTP/AEAD/UDP/pacing/secure-ready/lifecycle; F23/F25, stage 9 |
| DiscordDAVE, DiscordMLS | Replay/ratchets/transition admission/group scaling; F24–F26, stage 9 |
| DiscordLogging, DiscordLogHandlers | Filtered log, numeric observation, lock/capture/output costs; F27/F28, stage 0 |
| DiscordKit umbrella | Import/dependency graph, narrow-consumer startup/build cost and integrated compatibility; stage 7/10; no independent protocol owner to optimize |
| DiscordDSLMacros, DiscordDSLExtensions packages | Actual plugin/manual clean/incremental consumers and extension composition; F19/F20, stage 7 |

## External and intentional contributors

Retain actual provider RTT, DNS/connect/TLS, browser/native scheduling, application
handlers/hydration/storage, Discord policy backoff, upload production, media pacing,
codec lookahead and jitter residence in the latency map. Some are configurable
tradeoffs; some are required waits. Local work can improve while those dominate
the endpoint. Record the affected fraction before projecting workflow benefit.

CPU saturation, allocator pressure, lock contention, actor admission, timer
coalescing, host thermal/power behavior and container throttling can amplify tails.
The planning captures do not qualify these factors individually. Use matched
host/peer controls and scoped profiles, rather than diagnosing every slow interval
as network latency or every large RSS peak as a leak.
