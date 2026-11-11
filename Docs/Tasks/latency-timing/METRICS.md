<!--
File: Docs/Tasks/latency-timing/METRICS.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Timing metric catalog

Catalog identifier: **discordkit.timing**, revision **9**. Revision 1 was frozen 2026-11-10 at
`c8d842f7ce51e9adc69ff9997e2c0f374dc2ee68`. Every metric below has semantic
version **1**. The identity is `(catalog, metric ID, metric version)`; changing
endpoints, population, units or aggregation creates a new metric version.
This catalog is a contract, not a new report schema or an implementation claim.
See [ownership inventory](INVENTORY.md), [compatibility decisions](CONTRACTS.md)
and the [measurement and report guide](../../Measurements.md). Phase 11 adds
presentation and guidance without changing any metric identity or boundary.

## Shared interpretation

All duration rows use **integer nanoseconds** in future portable reports, with
checked conversion from monotonic elapsed time. Existing scalar APIs retain
`Duration`; existing legacy report units/formats remain unchanged. Each detailed
interval uses one explicit run clock domain and relative monotonic origin. Injected
virtual clocks establish semantics only. No cross-process clock subtraction is
permitted. Wall-clock dates and signature timestamps are never elapsed-time clocks.

Aggregation **H** means a bounded full-population histogram per finite outcome,
with counts, precision, censored/lost mass and supported p50/p95/p99/max. Stage 1
implements H; the current scalar API supplies observations only and retains none.
Use separate counts for success, failure, cancellation, timeout, rejection and
uncertainty where observable. The harness may refine a known typed timeout or
rejection; the existing public scalar outcomes remain `succeeded`, `failed`,
`cancelled`, `uncertain`. Unknown errors remain failure. An uncertain send never
counts as confirmed acknowledgement. A boundary that was never reached has no
duration observation; attempted/offered/refused counts still account for it.

**L** population means only observations currently emitted by the legacy owner,
partitioned by its four outcomes; it does not promise a sample for every invocation.
**S** means successful milestone only. **A** means every invocation reaching the
specified start, partitioned by observable outcome. A success-only milestone also
requires all-outcome workflow counters so failed work cannot vanish from a report.
**B** means a synchronous batch including expected successful or rejected cases,
with exact counts and a minimal observable checksum/result consumed inside the
timer; its overhead is included. Full expected-value assertions run after the
timer. Normalized batch cost is not per-call p99. Every duration row uses H, with
B histogrammed at batch granularity.

Parent/overlap relationships describe ownership only. Nested, parallel and
subscriber/exchange intervals overlap. Measure whole workflows directly; never
sum phase percentiles or subtract unrelated samples to construct a waterfall.
Owner-entry timings exclude preceding caller actor residence unless specified.
Ending timestamps precede the observation callback; earlier synchronous callbacks
may remain inside subsequent/enclosing intervals.

## Existing scalar observations

The following IDs map one-to-one to
[OperationTimingSample.Phase](../../../Sources/DiscordTransport/OperationTiming.swift).
They freeze actual behavior, not an idealized decomposition. Existing duration
regressions clamp to zero; future detailed invalid-clock flags do not change that.

| Metric ID (phase name) | Owner and start → stop, inclusions/exclusions | Population | Relationship |
| --- | --- | --- | --- |
| `gatewayLocalQueue` | GatewayEventHandlerDispatcher pending retention → removal for runnable callback, before child creation; excludes private hub/subscription residence and shared authority wait; discarded pending events have no queue sample | S | Inside dispatcher run; precedes shared admission |
| `gatewaySharedAdmission` | Dispatcher before shared authority acquire → acquire return/throw with existing cancellation handling; absent without authority; excludes callback/release | L | Inside run; after local queue |
| `gatewayReceiveToAdmission` | GatewayShard trusted receive age → admitted adapter callback before envelope decode/validation; includes parse/publication/hub/local/shared waits | S | Trusted age only; includes the two admission stages but is not their sum |
| `gatewayReceiveToAcknowledgement` | Same trusted receipt → initial sink confirmation/state transition; age is read after admission-to-ack observer; excludes admission release | S | Overlaps receive-to-admission and admission-to-ack; includes earlier observer cost |
| `gatewayAdmissionToAcknowledgement` | Dispatcher stamp immediately before admitted handler → initial sink confirmation/state transition timestamp; excludes admission release | S | Inside receive-to-ack; may include handler/provider wait |
| `gatewayRunJoined` | Dispatcher run entry → task-group children joined and subscription cancelled; before terminal diagnostic; cancellation is a whole-run milestone | L | Encloses dispatch work; not cancellation-only overhead |
| `interactionInitialResponse` | Responder actor entry before validation → sink confirmation, admission release and failure-scope clear; failure after normalization/release/failure recording | L | Excludes caller actor wait; overlaps Gateway acknowledgement milestones |
| `interactionOriginalEdit` | Responder edit actor entry → successful continuation return, before final state/log/failure-scope clear/deferred continuation release; failure after existing owned cleanup/failure record | L | Excludes caller actor wait; not whole caller-visible execution |
| `interactionAcknowledgementToOriginalEdit` | Stored confirmed initial-ack timestamp → first successful original edit observation; includes time between calls and initial release | S | Ends before original-edit sample; includes idle/application wait |
| `httpAdmission` | REST attempt before coordinator acquire → acquire return/throw; excludes construction and later lease release | L | Once per exchange attempt; inside logical execution |
| `httpHeaders` | Immediately before transport execute → headers return on success, before request-body close; failure after request-body close, uncertain lease release and failure mapping/diagnostics | L | Once per exchange attempt; headers success is not API success |
| `httpBody` | Before collection-start diagnostic → ResponseBody.collect return/throw with joined stream close, before rate-coordinator completion | L | Only when collection is reached; inside exchange/logical execution |
| `httpCoalescedSubscriber` | Before coalescer.run → its return/throw, before final context check/endpoint decode | L | Once per subscriber; overlaps shared exchange; never multiplies exchange counts |
| `httpExecutionJoined` | Nonactor public REST execute entry → executeObserved return/throw after decoding, structured joins and diagnostic scope terminal logging | L | Whole logical caller operation, including cache/retry/ordering; fresh hit has no exchange phases |

Stage 5 transport child metrics are grouped by the final caller outcome; REST
phase observations retain their own boundary-local outcome. `transport.bodyClose`
often observes an idempotent close after EOF already joined automatic cleanup.
No pool-acquire, DNS, TLS or final upload-write duration is fabricated when the
adapter exposes no such timestamp. Whole workflow throughput ends at the last
terminal operation before final diagnostics; driver elapsed is separately retained.
REST inter-wave setup/expiry gaps remain in the first-submission→last-terminal
denominator. Arrival offered rate uses the scheduled window; native submitted
completion rate and whole terminal-outcome rate remain distinct when arrivals
are missed. See the [suite guide](../../../Tools/DiscordKitLoadTests/README.md#phase-5-transport-and-rest-timing).

Gateway trusted receipt is the timestamp captured immediately after
`socket.receive()` returns in `GatewayShard.receiveLoop`, before generation
validation and parsing. It is not a kernel/transport arrival timestamp and cannot
measure earlier actor residence. Replayed/public events do not gain receipt trust.
Only cooperating owners using the same timing clock may compute the admission
milestones. Stage 6 records these as success-only scalar distributions; uncertain
initial sends emit no confirmed acknowledgement milestone. The signed HTTP path currently has no adapter receipt timestamp or
scalar timing injection; application entry is a different boundary.

## Primary-workflow durations

Stages 5 and 6 implement transport/REST/arrival and Gateway/interaction/command subsets below; explicitly unavailable IDs and later stages remain reservations. None was emitted by Stage 0. Population A and
H apply unless a row explicitly specifies S or B. One logical operation may have
many attempt intervals. All child work retains its owning workflow's outcome
counts and independent terminal result.

| Metric ID | Owner and start → stop, inclusions/exclusions | Relationship / implementing stage |
| --- | --- | --- |
| `transport.construct` | Harness request descriptor/upload producer construction entry → descriptor built | Separate from adapter invocation; Stage 5 |
| `transport.headers` | Caller before adapter invocation → response metadata or error | Includes observable connection/pool/upload work; Stage 5 |
| `transport.body` | Caller begins full byte consumption → EOF/error and joined stream cleanup | Body byte validation included; explicit close separately observed; Stage 5 |
| `transport.request` | Harness caller immediately before adapter invocation → full validated body completion and awaited owned close; excludes fixture setup/diagnostic snapshots/report writes | Direct whole request; Stage 5; corrected identity distinct from historical LoadRunner |
| `transport.poolWait` | Adapter before pool acquire → lease or refusal/cancel completion; excludes body service | Child of transport request, may overlap HTTP headers; Stage 5 |
| `transport.upload` | Adapter begins consuming upload → final write completion or joined failure; excludes pool wait; unavailable if adapter exposes no honest boundary | Child of request/headers; Stage 5 |
| `transport.bodyClose` | Caller/owner requests response close → owned body cleanup completes | Child of whole request; may be included in legacy httpBody; Stage 5 |
| `rest.request` | Harness caller immediately before RESTClient.execute → result/error, before correctness assertions and coordinator/cache snapshots | Direct whole request; overlaps legacy execution; Stage 5 |
| `rest.executionJoined` | Existing scalar httpExecutionJoined owner boundary | Legacy boundary meaning preserved within corrected REST suite; Stage 5 |
| `rest.admission` | Existing scalar httpAdmission owner boundary | Rate/FIFO policy unchanged; Stage 5 |
| `rest.headers` | Existing scalar httpHeaders owner boundary | Adapter return/error; includes actual upload/connection work; Stage 5 |
| `rest.body` | Existing scalar httpBody owner boundary | Collection and owned cleanup; Stage 5 |
| `rest.subscriber` | Existing scalar httpCoalescedSubscriber owner boundary | One observation per registered subscriber, independent of shared wire work; Stage 5 |
| `rest.construct` | Request builder entry → encoded request descriptor or typed error | Child of logical request; per attempt if rebuilt; Stage 5 |
| `rest.orderWait` | Before ordering authority acquire → admitted/refused/cancelled acquire result | Child of logical request; Stage 5 |
| `rest.cacheLookup` | Caller before cache lookup → fresh/miss/expired result; includes cache actor wait | Child of logical request; Stage 5 |
| `rest.decode` | Endpoint response decoder entry → decoded value or thrown error; excludes body I/O | Synchronous child of logical request; Stage 5 |
| `rest.retryWait` | Retry policy accepts a retry and starts wait → wake/cancel; excludes next attempt | Child of logical request; per retry; Stage 5 |
| `arrival.scheduledResponse` | Scheduled arrival offset → joined terminal outcome, including driver lateness/admission/service | Direct scheduled-arrival workflow; Stage 5 |
| `arrival.submittedResponse` | Actual submission before any owner hop → joined terminal outcome | Direct actual-submission workflow; overlaps scheduled-response; Stage 5 |
| `arrival.lateness` | Scheduled arrival offset → actual submission; missed arrivals have counts, not fabricated latency | Precedes service; Stage 5 |
| `arrival.admissionWait` | Actual driver submission → explicitly supplied owner admission | Historical `arrival.rest` leaves this unknown. Versioned default-policy mutation arrivals observe `RESTClient.execute` entry, including preceding fixture residence and descriptor construction; no REST actor queue is implied. |
| `arrival.service` | Driver operation closure invocation → joined return | Includes REST admission and service; optional finer timestamp ranges do not change this metric; Stage 5 |
| `gateway.decode` | Shard begins parsing received supported JSON → decoded payload or rejection | Child of receipt-to-dispatch; Stage 6 |
| `gateway.hubResidence` | One subscription retains an event → iterator removes it, or explicit discard/cleanup | Precedes legacy local queue; each retained copy has its own actual owner hook; Stage 6 |
| `gateway.handler` | Admitted callback invocation → callback completion and existing owned cleanup | Child of dispatcher run; Stage 6 |
| `gateway.heartbeatAck` | Heartbeat write confirmation → matching ACK handled or deadline/cancel outcome | Independent control lane; includes peer/scheduling wait; Stage 6 |
| `gateway.reconnect` | Owner begins reconnect → new session identified/resumed and locally usable, or joined failure | Lifecycle interval, may overlap handlers; Stage 6; no live READY claim |
| `ingress.applicationResponse` | Application first-response begin, after workflow begin callback → first confirmed HTTP response sink completion, or joined failure before confirmation | Direct application response; later handler failure belongs to interaction.workflow; excludes earlier adapter/socket wait; Stage 6 |
| `ingress.trustedResponse` | Future trusted adapter receipt hook → first confirmed response sink completion, or joined failure before any confirmation | Direct trusted response; later handler failure belongs to interaction.workflow; unavailable until real receipt provenance exists; Stage 6 |
| `ingress.bodyRead` | Bounded request-body read entry → EOF/error and existing close | Child of application workflow; Stage 6 |
| `ingress.signature` | Verification entry with exact bytes → verified/rejected signature result | Synchronous child; excludes body read; Stage 6 |
| `ingress.admission` | Verified signature begins replay authority admission → admission/refusal/error | Replay admission for ordinary interaction profiles; actual consumer transaction for separately identified durable webhook profiles, without replay-window double counting; Stage 6 |
| `command.route` | CommandRouter.route caller entry → route result/error and owned cleanup | Child of interaction workflow; Stage 6 |
| `command.arguments` | Typed argument preparation starts → prepared arguments or validation failure | Synchronous/owned route child; Stage 6 |
| `command.policy` | Policy/middleware invocation → result/error and joined middleware work | Route child; may include application code; Stage 6 |
| `interaction.handler` | Admitted application handler invocation → its joined return/error | Child of workflow; includes injected provider waits; Stage 6 |
| `interaction.providerWait` | Explicit fixture/application provider call → provider result/error/cleanup | Child of handler only when composition exposes it; no subtraction; Stage 6 |
| `interaction.workflow` | HTTP suite caller immediately before application.handle → joined return/error, before result/ownership diagnostic snapshots | Direct whole signed application workflow, classified by harness terminal result; may outlive acknowledgement; Stage 6 |
| `cache.call` | Caller before selected cache operation actor hop → result/error | Per fixed operation class: lookup/merge/project/permission/expire/evict/invalidate/refresh; Stage 7 |
| `cache.owner` | Same selected operation's owner entry → owner result including owned suspensions | Nested in caller interval; do not infer queue time by subtracting histograms; Stage 7 |
| `cache.loader` | Explicit loader invocation → value/error/owned cleanup | Child of refresh; single-flight loaders count once, callers independently; Stage 7 |
| `client.start` | Caller before local startup → documented local-ready milestone or joined failure | Discovery/ingestion included; construction separately; Stage 7 |
| `client.shutdown` | Caller requests stop → all owned runtime tasks/subscriptions/transports joined | Direct lifecycle interval; Stage 7 |
| `dsl.definition` | Definition compile/lower invocation → validated lowered definitions/error | Separate from runtime/compiler process costs; Stage 7 |
| `dsl.invoke` | Synthetic direct/DSL route invocation → equivalent response validation and joined responder cleanup | Whole synthetic call; bypasses trusted ingress; Stage 7 |
| `compiler.clean` | Driver starts supervised consumer build → bounded output collection, RSS probes, process-group teardown and reap; receipt serialization excluded | Manual/macro consumer build, prepared dependencies excluded; Stage 7; compiler configuration explicit |
| `compiler.incremental` | Driver starts supervised build after a declared fixture edit → bounded collection/probes, group teardown and reap; receipt serialization excluded | Separate process cost, excludes fixture mutation; Stage 7 |

`interaction.workflow` uses signed application caller origin. Trusted Gateway scalar
milestones and synthetic invocation use distinct metric IDs and incompatible
profiles; no HTTP socket receipt is inferred. For cache queue attribution,
add explicit paired submission/admission hooks before claiming residence. Do not
subtract aggregate caller and owner distributions. Expiry/eviction are currently
side effects of cache calls; profiles select the triggering public operation and
state that setup, rather than inventing public expiry/eviction methods.

## Additional Stage 7 registered populations

Catalog revision 7 implements the Stage 7 rows above and adds these explicit
version-1 populations. All durations use H aggregation across their measured
terminal outcomes. Compiler histograms declare a separate range and precision.

| Metric ID | Actual start and stop / population |
| --- | --- |
| `cache.broadcast` | Actual hub publication owner entry through retained-copy handling; caller delivery is separately enclosed by `cache.call` |
| `client.construct` | Caller immediately before the complete client constructor through returned actor, including default storage/stream allocation and configured synchronous observer cost; excludes dependency construction and starts no runtime work |
| `client.discovery` | Accepted run's shard preparation entry through discovery/budget/topology result or error; excludes socket startup |
| `client.ingestion` | Per-event ingestion begins before package receiver/projection through public hub publication or error |
| `client.lifecycleJoined` | Accepted client run entry through existing joined children, leases, subscriptions, budget and cleanup |
| `dsl.policy` | Explicit equivalent application policy wrapper through its result/error; includes enclosed middleware/handler |
| `dsl.middleware` | Explicit equivalent middleware wrapper through its result/error; includes enclosed handler |

`cache.call` uses one selected fixed scenario per report, including permission,
broadcast, expiry/eviction triggers and stale fencing. Owner and loader metrics
are present only where actual hooks exist. Client `start` ends at its documented
local milestone; absent readiness terminates with the joined failure/cancellation.
The compiler driver measures a separate process population and retains exact
fixture/dependency/build receipts. No elapsed clock crosses process domains.

## Additional Stage 6 registered populations

Catalog revision 6 registers the following additional IDs with semantic version 1.
They preserve actual scalar or detailed owner boundaries and do not relabel older
samples. All use bounded whole-population H aggregation per finite outcome.

| Metric ID | Actual start and stop / population |
| --- | --- |
| `gateway.sessionJoined` | Accepted shard run before observation → joined run exit; includes session ownership, no discovery/client startup claim |
| `gateway.socketReceipt` | Transport receive returns → accepted frame processing or discard/error; excludes pre-receipt network wait |
| `gateway.ingestionQueue` | Shard enqueues a dispatch → consumer removal or joined discard |
| `gateway.publication` | Hub actor owner enters publication → bounded publication result; excludes preceding actor hop |
| `gateway.dispatchJoined` | Dispatcher run → handlers/permits/subscription joined |
| `gateway.localQueue`, `gateway.admission` | Actual dispatcher local retained queue and shared-authority acquire boundaries |
| `gateway.shutdown` | Run supervision has joined siblings → socket/control/request/lease teardown completed |
| `gateway.receiveToAdmission`, `gateway.receiveToAcknowledgement`, `gateway.admissionToAcknowledgement` | Existing trusted scalar owner milestones, adapted directly as durations; confirmed acknowledgement only |
| `gateway.initialResponse`, `gateway.originalEdit`, `gateway.acknowledgementToOriginalEdit` | Existing trusted responder scalar boundaries; no fabricated receipt interval starts |
| `ingress.decode` | Authenticated bounded body → typed interaction or decode failure |
| `command.admission` | Router owner entry → exact-route admission/refusal; excludes earlier actor hop |
| `command.handler` | Real route execution → unchanged handler/wrapper result; overlaps application handler |
| `interaction.initialResponse`, `interaction.originalEdit` | Existing detailed actor-owned response/edit boundary through release and cleanup |
| `synthetic.invoke` | External caller immediately before typed route → joined return/error; responder construction and authoring excluded |
| `synthetic.providerWait` | Explicit identical provider fixture → result/failure/cancellation; excludes response work |

The complete catalog exceeds a single collector's storage allowance. Each suite
preallocates only its selected finite identities. Runtime aggregate outputs keep
their configured retained-key cap; expanded identities cannot escape that cap and
excess keys count as loss. New optional signpost codes append to existing codes.

## Implemented optional service durations — catalog eight

The `service-timing` command implements the following external wrapper boundaries
with actual public runtime owners and injected, credential-free peers. All use H
and A populations in integer nanoseconds unless explicitly marked as cohort/batch
populations below. They introduce no runtime callback or
public runtime enum changes. Fixed case names and explicit injected delay/fanout/concurrency
fields distinguish incomparable operations. Primary distributions account for
every terminal call; supporting peer requests are separately counted and excluded
from primary offered/completed counts. Versioned cohort primaries instead count
completed batches, independently of their per-call context observations. Timing stops before diagnostics except for
the explicitly inclusive joined-refresh boundary below.

| Metric ID | Start → stop and population |
| --- | --- |
| `oauth.lookup` | Immediately before `accessToken` → returned token/error. One per reader; refresh cohorts preserve independent caller cancellation. |
| `oauth.install` | Immediately before public `install` → returned result/error; storage mutation and CAS included. |
| `oauth.revoke` | Immediately before public `revokeToken` → returned result/error; remote fixture revoke and storage mutation included. |
| `oauth.storage.load` | Injected storage method entry → result/error after configured wait; setup and diagnostic storage reads excluded. |
| `oauth.storage.cas` | Injected compare-exchange entry → generation comparison and mutation result/error after configured wait. |
| `oauth.refresh.io` | Injected refresh backend method entry after actor admission → returned rotated token/error, including configured wait or held gate. Once per actual backend invocation; excludes the closure-to-actor hop. |
| `oauth.refresh.joined` | External independent-refresh caller or shared-cohort submission → every caller joined and coordinator close complete. Includes harness joining, diagnostic and close work; one per actual refresh flight. This does not claim internal flight admission. |
| `oauth.refreshCohortV2` | Driver submission before creating a finite V2 cohort's caller tasks → every terminal reader joined, before subsequent coordinator close and diagnostic snapshots. B population: one observation per cohort, including unrelated-grant cohorts with multiple actual refresh flights. Includes deliberate backend admission gate, final subscriber observation and caller joining; excludes fixture construction. Selected partial-reader cancellation is a successfully completed cohort; individual reader outcomes remain in `oauth.lookup`. External cancellation is a separate cohort outcome. Never emitted as `oauth.refresh.joined`; cohort percentiles are not per-reader or per-flight percentiles. |
| `oauth.revoke.io` | Injected revoke backend method entry after actor admission → returned result/error after configured wait. Excludes the closure-to-actor hop and its preceding storage-inspection precondition. |
| `oauth.close` | Caller before coordinator close → joined return, before fixture storage disposal. Repeated close calls remain actual calls. |
| `rpc.request` | Caller before public request → correlated reply or typed failure/rejection/cancellation. Legacy fixtures observe one primary call per independently owned fixture and exclude supporting correlation/pressure calls. `rpc.queuedRepliesV1` separately observes all 64 selected already-sent public calls per cohort, including their prefill/setup residence, while excluding the parked writer and unsent supporting callers. The per-call endpoint is unchanged; primary offered/completed counts belong to its separate cohort metric. |
| `rpc.queuedReplyCohortV1` | Immediately before submission of prepared synthetic reverse replies → all 64 already-sent public caller tasks returned. B population: one fixed 64-request cohort per independently owned fixture while one writer and an independently sized unsent backlog remain parked. Includes reply delivery, production correlation, task scheduling, joining and minimal caller result consumption; excludes fixture construction, pending admission, reply preparation, histogram recording, diagnostics and final cancellation/close. Native exact duration sum/cohort count accompany the histogram. Cohort percentiles and throughput are not per-call statistics. Injected complete-frame `RPCConnection` only; no native IPC/framing/browser/provider qualification. |
| `activities.request` | Caller before public execute → correlated reply or typed failure/rejection/cancellation. One primary call per independently owned fixture; supporting correlation/pressure calls excluded. In `activities.subscriptionGroupsV1` this is a later control request after subscription release, not subscription-admission timing. |
| `rpc.handshake`, `activities.handshake` | Caller before public connect/start → READY accepted or failure; separately followed by a primary request. |
| `rpc.write`, `activities.write` | Injected adapter write after its initial cancellation/deadline check → frame/tuple processing and response submission complete. Includes fixture framing/preparation work; no internal admission claim. |
| `rpc.peerWait`, `activities.peerWait` | Immediately before configured complete-frame delivery delay → delay completion/error, before fragment/tuple delivery. No samples when no configured wait is performed. |
| `rpc.eventDispatch`, `activities.eventDispatch` | Injected event batch submission → sentinel reply and public event drain complete; includes queue residence and batch work, not an individual-event P99. |
| `rpc.close`, `activities.close` | Caller before public close → joined return and explicit fixture adapter-read join; peer receipts follow the endpoint. |
| `activities.subscription` | Public subscribe caller boundary → acquired token/error. In `activities.subscriptionGroupsV1`, initial acknowledged owners seed distinct groups outside this population; subsequent duplicate acquisitions and separate capacity-rejection probes use the unchanged public-call endpoint. Native exact successful-duplicate duration sum/count remain separate from rejection observations. Releases are verified by exact shared upstream subscribe/unsubscribe native counts; no release duration is inferred. |
| `service.operation` | Caller before selected implemented Social/GameServices/Commerce/CertifiedDevices orchestration → result/error; local validation, snapshot work and backend waits included where selected. |
| `service.backend` | Injected backend method entry after actor admission → provider/executor/body-read result/error after configured wait. Excludes preceding actor residence and does not time the entire HTTP transport call. |
| `service.validation` | External selected public validation or snapshot-application call → returned result/error; excluded setup checks never become observations. |
| `service.cleanup` | Before selected owner cleanup → joined return; actual closed-body/backend/in-flight receipts are read after timing. |

Child populations can overlap primary work or cover separate lifecycle phases.
Handshake precedes primary calls; close and service cleanup follow them. Their
percentiles cannot be added to or subtracted from caller percentiles. The catalog does not fabricate internal refresh admission,
RPC nonce-matching CPU time, browser-process latency or actual desktop delivery.
See [Phase 8](PHASE-8.md) for independent ownership/correctness receipts.
The earlier proposed `oauth.storage` and `oauth.refresh` identities below remain
reserved and are not emitted; the concrete IDs above freeze observable boundaries.

## Planned pure, optional-product and instrumentation durations

`pure.batch` is implemented in Stage 4. The Stage 8 rows implemented above use their concrete wrapper definitions;
remaining optional-product rows retain their planned status. The CPU executable uses one finite case
per process, four prepared variants, 1,000 ns histogram buckets over 0...100 ms,
and exact success/rejected **batch** counts. Calls/rejections and normalized batch
mean remain separate native fields; throughput is calls per wall second. Fixture
preparation and full semantic assertions are excluded. Minimal result consumption
and batch-loop work are included. P99 population requirements apply to batches.
See the [CPU suite guide](../../../Tools/DiscordFoundationBenchmarks/README.md)
for size dimensions, cap/cancellation boundaries and unavailable qualifications.

| Metric ID | Owner and start → stop, inclusions/exclusions | Population / relationship / stage |
| --- | --- | --- |
| `pure.batch` | External wrapper before fixed batch → minimal observable result/checksum consumed; fixture preparation and full correctness assertions excluded | B; fixed operation class JSON/model/field/identifier/bitset/builder/permission/RPC-frame; Stage 4 implemented in catalog revision 4 |
| `oauth.lookup` | Caller token lookup → returned token/error and existing joins | A; whole local orchestration; Stage 8 |
| `oauth.storage` | Injected load/CAS/revoke call → backend result/error | A; fixed storage operation class, child of token operation; Stage 8 |
| `oauth.refresh` | Refresh owner accepts flight → refresh I/O/CAS completion and joined cleanup | A; once per flight, subscribers independently counted; Stage 8 |
| `rpc.request` | Caller before request admission → correlated reply/error and pending ownership release | A; child writes/reply waits require real hooks; Stage 8 |
| `activities.request` | Caller before protocol request → correlated reply/error and pending ownership release | A; injected bridge vs actual browser are incompatible profiles; Stage 8 |
| `service.operation` | Caller before implemented Social/GameServices/Commerce/CertifiedDevices operation → result/error and existing joins | A; fixed operation class; overlaps underlying REST/RPC, not additive; Stage 8 |
| `voice.join` | Caller before manager join/move → installed session result/error and cleanup | A; installation is not secure/media readiness; Stage 9 |
| `voice.secureReady` | Before manager join/move → session control loop observed after verified secure-ready milestone | S with all-outcome `voice.lifecycleJoined`; includes credential/installation/handshake waits; injected E2EE authorization is not real DAVE acceptance; catalog 9 |
| `media.batch` | External wrapper before DSP/codec/jitter/RTP/AEAD/DAVE batch → minimal observable result/checksum consumed; full correctness assertions excluded | B; fixed component class, no sample-loop logs; Stage 9 |
| `mls.transition` | Prepared external batch starts → complete create/join/rekey or joined DAVE signaling results; verification and owned cleanup follow timer | B; real crypto/transition class, not steady tick; catalog 9 |
| `voice.tick` | Warmed duplex tick begins → selected sends/receives/authentication/playout, bounded diagnostics and PCM checks complete | A; gross directly observed tick excludes pacing, warmup, RSS sampling and delayed drain; selected cadence/impairment determines included operations; catalog 9 |
| `voice.pacingLate` | Profile's scheduled tick → actual tick start | A for started ticks; missed ticks counted separately; Stage 9 |
| `audio.deviceOperation` | Explicit device permission/enumeration/open/route/close call → actual adapter completion/error | Proposed distinct metric; not emitted by the codec-only Apple adapter; explicit device procedures remain native evidence |
| `instrumentation.batch` | External wrapper before selected observation batch → batch consumption complete | B; mode/destination/concurrency fixed; includes synchronous callback/formatting cost; Stage 3 |
| `instrumentation.flush` | Application requests output flush/close → awaited completion/error | A; separate from foreground workflow, bounded output; Stage 3 |

Catalog 9 also implements these observed boundaries (all durations use H):

| Metric ID | Owner and start → stop, inclusions/exclusions | Population / relationship |
| --- | --- | --- |
| `voice.lifecycleJoined` | Caller before manager join → awaited manager stop after selected script | A; primary all-outcome population including expected terminal close failure |
| `voice.credentials` | First routed credential delivery → session factory admission after both halves | S; overlaps join; neither a wire exchange nor isolated actor residence |
| `voice.handshake` | Session run begins → control loop observed after secure-ready milestone | S; overlaps caller secure-ready interval; injected peer/UDP/E2EE only |
| `voice.heartbeat` | Observed heartbeat sleep admitted → exact-nonce ACK processed and next sleep parked | S; runtime virtual deadline advanced explicitly; elapsed measurement uses real ContinuousClock; not network RTT |
| `voice.reconnect` | Injected resumable EOF → resumed secure readiness observed | S; retry clock advanced after admitted sleep; includes scheduling and caller observation |
| `voice.speaking` | Before public true/false speaking calls → both writes return | A; scripted control writes, not audible delivery |
| `voice.termination` | Injected terminal peer close → joined failed session run result | A; expected failure retained in primary lifecycle counts |
| `voice.shutdown` | Before manager stop → joined session children finish | A; independent ownership snapshots follow terminal timestamps |
| `voice.encode` | External encoder wrapper → production encode/DTX result/error | A; synchronous codec call, includes suppression decisions |
| `voice.encrypt` | External transformer wrapper → DAVE seal result/error | A; DAVE only; concrete transport AEAD remains inside gross tick |
| `voice.send` | Before actual UDP adapter send → adapter return/error | A; excludes preceding packet protection |
| `voice.receiveDecrypt` | Before public pipeline receive → authentication, RTP and jitter insertion return/error | A; excludes preceding UDP receive wait; overlaps gross tick |
| `voice.decode` | Before public playout → jitter pop, decode/PLC, PCM saturation return/error | A; isolated jitter operations use `media.batch`; overlaps gross tick |
| `appleAudio.codec` | Actual synchronous native-tool encode/decode begins → returned PCM validation/error | A; no device scheduling, resampling, playback, render or acoustic delay |

Each fixed operation/component class is an explicitly enumerated profile field;
do not derive it from a method name, raw route, persistent identity or error text.
Device render/acoustic measurements require a later reviewed physical procedure
and separate metric; no software interval above stands in for them.

## Counts, throughput and gauges

These metric IDs share semantic version 1 and are planned report fields. Counts
use checked nonnegative integers and exact sums, never histogram percentiles.

| Metric ID | Unit and population | Boundary / aggregation |
| --- | --- | --- |
| `work.offered` | operations; complete selected run | Count scheduled/offered logical work, including later refusal/miss |
| `work.admitted` | operations; complete selected run | Count successful admission; distinguish exchanges, subscribers and handlers by finite owner class |
| `work.terminal` | operations; per outcome | Exactly one terminal category per logical operation; refused/missed-before-admission separate from admitted completions |
| `work.deadlineMiss` | operations or ticks, fixed profile unit | Count at documented deadline boundary, including observer-induced misses; record uncertain terminal result independently |
| `work.throughput` | completed operations/second, per outcome | All admitted operations reach terminal outcome; divide complete counts by first measured offer/submission through last measured terminal, including drain and excluding warmup/report writes; no successful-prefix denominator |
| `collection.loss` | observations, per cause/metric | Exact dropped/overwritten/censored/overflow counts, with unknown counts explicitly invalid; no silent loss |
| `process.cpu` | CPU nanoseconds, runner process | Monotonic process CPU delta across measured run; unsupported/failed gauge unavailable |
| `process.resident` | bytes, runner process | Bounded sampled RSS with cadence and sample count; max is sampled maximum only |
| `process.peakRSS` | bytes, process lifetime | OS high-water mark; never attributed to an individual row in a reused process |
| `owner.retained` | count or bytes, fixed owner/resource class | Snapshots outside operation timers; exact versus sampled high-water scope recorded |
| `cleanup.remaining` | count or bytes, fixed owner/resource class | After awaited shutdown; compare exact resource/sleeper/task gauges to documented baseline |

Reject arbitrary labels, raw URLs/routes, payloads, credentials, file paths,
persistent user/guild/session IDs, cryptographic values and free-form errors.
For arrival-rate profiles, the throughput interval starts at the first scheduled
arrival; otherwise it starts at the first submission. Record the offered window,
drain duration and post-window completions separately. A fixed-window throughput
variant would need a separate metric version. Cancellation/timeouts still drain
existing owned work before the terminal measurement; forced process termination
retains partial status and cannot produce a complete throughput qualification.

Report provenance can contain approved build/artifact paths; they never become
metric keys. No existing diagnostic UUID is an aggregate dimension.

## Stage 1 development populations

Revision 2 adds these distinct version-1 identities without changing earlier
metric meanings. Each uses H across every observed completion partitioned by
finite outcome. Existing native prefix summaries keep their original formats.
These IDs retain historical diagnostic/validation inclusions; they do not implement
the corrected runtime metrics proposed above. All use integer nanoseconds from
one process ContinuousClock domain; sidecar serialization is outside measured work.

| Metric ID | Start and stop / population |
| --- | --- |
| `legacy.transport.wholePopulation` | Existing exchange entry through validated body completion or joined failure; includes the existing pool snapshot before body consumption; every returned success/rejection/cancel/failure. |
| `legacy.httpPolicy.wholePopulation` | Existing logical exchange entry through result classification and coordinator/cache diagnostic snapshots; every returned success/rejection/cancel/failure. |
| `legacy.dsl.direct10.wholePopulation`, `legacy.dsl.direct100.wholePopulation`, `legacy.dsl.direct1000.wholePopulation` | Existing handwritten invocation entry through responder construction, routing and acknowledgement validation; all started measured invocations, partitioned by observed outcome. |
| `legacy.dsl.dsl10.wholePopulation`, `legacy.dsl.dsl100.wholePopulation`, `legacy.dsl.dsl1000.wholePopulation` | Same legacy boundary for lowered DSL routes at each finite handler count; separate identities preserve working-set and mode differences. |
| `legacy.voice.duplexTick.wholePopulation` | Existing tick begins through duplex sends, receives, authentication, decode and expected-PCM assertions; measured tick success or started failure/cancel; pacing, RSS diagnostics and 100-frame warmup excluded. |

The integration collector has 100-microsecond absolute buckets in 0...1 second,
explicit overflow/loss and exact observed maximum only when supported. Underflow
is zero for valid nonnegative durations with this range. General shared profiles
may choose other validated precision/range; mismatched configurations are
incompatible. A partial run contains only intervals that actually began; requested
but unstarted work has no invented zero sample. Process-driver partial status,
missing owner counts and legacy imports cannot establish numerical qualification.

## Stage 3 instrumentation populations

Revision 3 adds the version-1 `instrumentation.operation.gross` identity. One
observation begins immediately before a selected fixture operation and ends after
its observable result and synchronous observer work. It excludes checksum accumulation, histogram updates,
diagnostic resource snapshots and output export/close. The directly measured
operation includes its own detailed start callback and terminal callback when
enabled; these outer gross timings deliberately include observer cost. It does
not alter any earlier scalar or lifecycle boundary.

The timing executable selects finite CPU-fixture, empty-harness, clock-read and
local REST-owner modes. Mode, fixture family, cohort and warmup/input dimensions
are profile identity: REST scalar modes cannot be compared as equivalent work to
the tiny CPU fixture. Every completed measured call enters a shared bounded
histogram; warmup uses separate owners and counters. Precision/range, censored
mass, failures, observer drops and joined cleanup accompany the distribution.
Flush/close/export is measured separately in the native report's
`flushNanoseconds` field, corresponding to the planned `instrumentation.flush`
boundary. It is not yet a separate common-envelope metric. Failed close exits
unsuccessfully rather than inventing a successful flush sample.

Runtime aggregate summaries use their own schema version 1, with separate finite
scalar and detailed rows, invalid counts, logarithmic bucket ranges and censored
mass. Numeric interval captures likewise use a distinct schema version 1 with
explicit sampling, unmatched/incomplete endpoints and loss. These are optional
local artifacts, not replacements for the common provenance envelope or legacy
reports. Live Apple profiler timestamps describe callback delivery time rather
than portable numeric offsets.
