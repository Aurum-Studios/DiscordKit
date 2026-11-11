<!--
File: Docs/Measurements.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Measuring latency and comparing changes

Use a versioned workload to measure a complete operation, inspect its defined
stages, and reproduce a comparison in fresh processes. Local CPU, scripted
protocol and loopback reports establish only their recorded scope. A successful
smoke proves integrity and cleanup; controlled numerical baselines, hosted runs,
physical audio, live Discord and production capacity require separate evidence.
The [qualification ledger](Tasks/latency-timing/VALIDATION.md) records completed
checks and gaps; the [metric catalog](Tasks/latency-timing/METRICS.md) defines
boundaries rather than claiming every proposed metric is emitted.

## Choose the workload and population

Start with the [ownership inventory](Tasks/latency-timing/INVENTORY.md) and
[measurement contracts](Tasks/latency-timing/CONTRACTS.md). Choose a finite case,
seed, fixture, adapter, instrumentation mode, concurrency, warmup and profile.
Runtime captures require Swift 6.4+ and optimized builds. Compiler measurements
retain their declared configuration, currently debug consumer builds. Build and
prepare fixtures before timing. Keep concurrent builds and other captures off a
host reserved for comparisons.

| Question | Executable or recipe | Population and scope |
| --- | --- | --- |
| Is parsing, model work, bit arithmetic, authoring or permission evaluation expensive? | [Foundation CPU suite](../Tools/DiscordFoundationBenchmarks/README.md), `--list-cases` | `pure.batch`; full batch results, local CPU; normalized mean is separate from the batch tail |
| Where does a request wait or spend time? | [Transport/REST suite](../Tools/DiscordKitLoadTests/README.md#phase-5-transport-and-rest-timing), `timing --list-cases` | Direct whole request plus defined stages; scripted, NIO and Foundation remain different adapters |
| Does offered load exceed bounded admission? | The same suite, `timing --case arrival.rest` | Independent scheduled arrivals; inspect offered/admitted/terminal counts, rejected work, missed arrivals and drain |
| Is Gateway or interaction handling slow? | [Gateway/command suite](../Tools/DiscordKitLoadTests/README.md#phase-6-gateway-and-command-timing), `command-timing --list-cases` | Scripted Gateway, genuinely signed local HTTP, trusted Gateway milestones and synthetic routing retain distinct origins |
| Is cache refresh, fan-out or client lifecycle costly? | [Cache/client suite](../Tools/DiscordKitLoadTests/README.md#phase-7-cache-and-client-timing), `cache-client-timing --list-cases` | Caller, owner and loader populations; one shared refresh is distinct from its subscribers |
| What does authoring add? | [DSL runtime and compiler recipes](DSLBenchmarks.md) | Equivalent direct/DSL runtime cases; separate clean and incremental compiler processes |
| Is OAuth, RPC or another optional service waiting? | [Service suite](../Tools/DiscordKitLoadTests/README.md#phase-8-optional-service-timing), `service-timing --list-cases` | Local ownership and injected backend/storage waits; injected Activities is not an actual browser capture |
| Is media processing or key transition costly? | [Media CPU suite](../Tools/DiscordMediaBenchmarks/README.md), `--list-cases` | `media.batch` / `mls.transition`; real implementations with local fixtures, batch populations |
| Are voice ticks late? | [Attributed local voice](../Tools/VoiceSessionQualification/README.md#attributed-and-impaired-profiles-native-schema-3) and [scripted voice lifecycle](../Tools/DiscordKitLoadTests/README.md#phase-9-media-and-voice-timing) | Direct gross ticks, component populations, pacing/deadline accounting and joined lifecycle; local UDP and scripted control are separate |
| What happens on an actual audio host? | [Apple audio qualification](../Tools/AppleAudioQualification/README.md) | Explicit native/device procedure; codec-only processing cannot establish render or acoustic delay |
| What does observation cost? | [Instrumentation modes](../Tools/DiscordTimingBenchmarks/README.md) | Gross individual operation timings, callbacks, output failures, loss and explicit flush; no automatic overhead subtraction |

Performance [Phase 7](Tasks/performance-improvements/PHASE-7.md) separates
prepared DefinitionPlan admission, complete authoring and steady invocation into
fresh-process populations. Its JSON writer control has a distinct identity.
Compiler native reports retain CPU, peak RSS, clean/incremental consumer work,
no-change SwiftPM invocation and inert startup as separate observations.

Performance [Phase 8](Tasks/performance-improvements/PHASE-8.md) separates immutable
resampler plan construction, continuous filtering and final flush; its version-three
cases include reverse/awkward rates and queue occupancy. Paired local paced duplex
reports keep processing and schedule misses distinct from media batch cost. Plan
payload accounting, process RSS and allocation-event profiling are different scopes.

Performance [Phase 9](Tasks/performance-improvements/PHASE-9.md) adds continuously
prefilled DAVE replay populations, actual generation expiry, matched RTP/jitter
accounting and larger dense/sparse MLS transitions. Concurrent control/media has a
joined batch endpoint; it does not measure queue residence or secure-ready.
Separate impaired local UDP receipts retain losses, concealment, scheduling and
joined cleanup, including the original-runtime failure.

Legacy account profiles describe 100/10,000/1,000,000 logical identities with
bounded active cohorts, not that many simultaneous connections. Avoid comparing
different input sizes or instrumentation modes as though they were the same
workload. Timers stop at documented endpoints: a confirmed response sink does
not prove Discord delivery, rendering or human-visible latency.

## Capture one bounded smoke

Run from the repository root after finishing source edits. This example builds
one CPU executable and supervises a small parse case. Receipts bind exact source,
dirty/untracked content, dependency pins and executable bytes. Every receipt stem
and output directory must be new; choose another run directory for a later capture.

```sh
python3 Tools/DiscordBenchmarkSupport/scripts/run_benchmarks.py build \
  --repository . --package Tools/DiscordFoundationBenchmarks \
  --product DiscordFoundationBenchmarks --receipt .build/measurements/foundation-release.json
python3 Tools/DiscordBenchmarkSupport/scripts/run_benchmarks.py run \
  --profile smoke --scenario json.parse.1024.depth1.ascii \
  --fixture Tools/DiscordFoundationBenchmarks/Package.resolved \
  --receipt .build/measurements/foundation-release.json \
  --command '["Tools/DiscordFoundationBenchmarks/.build/release/DiscordFoundationBenchmarks","--case","json.parse.1024.depth1.ascii","--batches","100","--batch-size","16","--warmup-batches","8","--warmup-seconds","{warmup_seconds}","--duration-seconds","{duration_seconds}","--output","{output}"]' \
  --concurrency 1 --scheduler-policy serial-synchronous-batches \
  --warmup-seconds 1 --warmup-policy participant-declared \
  --output-dir .build/measurements/foundation-smoke
swift run --package-path Tools/DiscordBenchmarkSupport DiscordBenchmarkReports \
  validate .build/measurements/foundation-smoke/00-single/benchmark-envelope.json
swift run --package-path Tools/DiscordBenchmarkSupport DiscordBenchmarkReports \
  summarize .build/measurements/foundation-smoke/00-single/benchmark-envelope.json
```

The supervisor retains orchestration, native report, common envelope and bounded
diagnostics. It enforces a process timeout, sampled leader RSS limit, output
limits and owned process-group teardown. A participant's time, warmup and cohort
declaration still requires its native receipts; arbitrary command substitutions
alone prove none of those facts. Direct executable runs are useful for exploration
but lack the independent supervisor. A 100-batch smoke cannot qualify p99.

Smoke admits at most 64 workers and ten measured seconds; standard allows 256
workers and 300 seconds. Statistics have a combined 16 MiB budget. Driver report
and diagnostic ceilings are 32 MiB and 16 MiB. See the
[shared driver](../Tools/DiscordBenchmarkSupport/README.md#release-preparation-and-fresh-processes)
for stress/soak limits and the process timeout, which includes warmup, measurement
and 30 seconds for teardown. Limits bound a run; they are not capacity results.

The [performance phase 6 record](Tasks/performance-improvements/PHASE-6.md)
separates OAuth/Activity bookkeeping from storage/backend delays and native
Unix adapter checks, records default-sized and enlarged-budget tradeoffs, and
retains the deferred RPC queue-marker experiment separately. Service fixture timings do not qualify real browser,
desktop, provider or distributed authorization performance.

## Observe a runtime operation

Select `DiscordLogging` for content-free interval hooks and select
`DiscordLogHandlers` explicitly for bounded outputs. Runtime owners do not select
output adapters or benchmark packages. The application owns setup, destinations,
producer shutdown and export. Nil observer options perform no instrumentation
clock reads, identity allocation or callbacks. Outer benchmark timers still run.

For aggregate-only timing, create `DiscordTimingAggregate`, forward genuine
`DiscordIntervalTiming` events to `aggregate.record`, and pass that observer into
the cooperating owner's `intervals` option. Forward existing scalar samples with
`aggregate.record(sample.observation)` through `OperationTiming` independently.
Take `aggregate.snapshot()` after joining producers. Scalar samples have no
historical start, operation ID or parent, so they cannot create a trace. The
[output composition recipe](../Sources/DiscordLogHandlers/DiscordLogHandlers.docc/Guides/TimingOutputs.md#composition)
shows both seams; scalar and detailed rows remain separate populations.

For one correlated operation, share one observer and one run-local monotonic
clock domain across cooperating owners. Use actual `begin`/`end` boundaries and
`DiscordIntervalScope.$context.withValue` when explicitly scoping an application
wrapper. Keep each operation's existing result, error and cleanup. Structured
children inherit numeric context; foreign callbacks, actor/shared-reader work
and unrelated later callers need explicit context propagation at the real owner.
Diagnostic `DiscordLog.withOperation` UUIDs are independent of numeric interval
identity. The [runtime interval guide](../Sources/DiscordLogging/DiscordLogging.docc/Guides/RuntimeIntervals.md)
describes each owner boundary and propagation rule.

For a bounded investigation of a slow operation, keep aggregate recording on and
attach one `DiscordIntervalCapture` to a finite cohort. Select `sampleEvery: 1`
for a small reproduction that must attempt every root, or record a larger head
sampling denominator and seed. Set explicit `maximumRecords`, `maximumBytes`
and `maximumActiveIntervals` within the documented ceilings. After joining and
closing, identify complete roots whose recorded elapsed time exceeds a declared
investigation threshold, then inspect their retained children. Capture retains
earlier endpoints and drops new ones when full; it has no slow-triggered rolling
history. A slow root excluded by head sampling or missing its beginning cannot
be recovered afterward. Record that absence and reduce the next capture's cohort
or scope. Sampling exclusions and loss are different counters.

For a trace file, join all producers, call `capture.close()`, then serialize
`capture.ndjson()` and `capture.chromeTrace()` and write the returned data on the
application's output path. Preserve `capture.snapshot()` beside both artifacts:
retained/dropped/sampled-out/late records, incomplete intervals, missing parents
and unmatched endpoints determine what the timeline can explain. Numeric capture
performs no file I/O; formatting and writes happen during explicit export.
The [LoggingApp example](../Examples/LoggingApp/README.md) and
[timing output guide](../Sources/DiscordLogHandlers/DiscordLogHandlers.docc/Guides/TimingOutputs.md)
provide application composition and ownership recipes.

For Apple Instruments, select `DiscordIntervalSignposts` in a separate native
profiling run, attach it to genuine live lifecycle events, and record the process
with Instruments' signpost support. Join producers, close the adapter and inspect
begun/ended/dropped/incomplete/active accounting. Keep portable numeric outputs
for the same run when useful. Instruments observes callback delivery time; it
cannot backdate intervals to recorded numeric offsets. Emission or a successful
smoke does not prove that Instruments recorded the process. Scalar durations and
replayed trace files cannot establish historical profiler intervals. See the
[Apple profiling procedure](../Sources/DiscordLogHandlers/DiscordLogHandlers.docc/Guides/TimingOutputs.md#recipe-apple-instruments).

Every sink is synchronous. Begin callbacks, child callbacks and earlier terminal
callbacks can remain inside enclosing intervals, and observation can consume a
deadline. Keep callbacks prompt, concurrent-safe, nonrecursive and free of owner
reentry. File, formatting and profiler callbacks belong outside realtime audio
and crypto/sample loops. Compare gross mode costs with the
[overhead suite](../Tools/DiscordTimingBenchmarks/README.md); do not subtract a
clock-read or empty-harness percentile from a workload percentile.

## Read the compact report and schema

`DiscordBenchmarkReports summarize FILE` validates a common envelope and prints
status, offered/admitted/completed counts, all outcomes, deadline misses,
throughput, each metric/outcome distribution, loss/censoring, scoped resources,
cleanup and qualification limitations. It does not establish numerical
qualification. Isolated observer cost remains explicitly unavailable; a gross
instrumented operation includes collection and is not an overhead-only metric.
Optional `--timeline REFERENCE` arguments attach up to four
caller-supplied references; the command does not open, parse or verify them.
Use the common envelope, not a tool's native report or a comparison series.
Large views state exact omitted counts and shorten long text fields. Valid partial,
failed or unqualified reports can be summarized successfully; inspect their
status. Malformed/oversized reports or invalid arguments fail. See the
[compact report reference](../Tools/DiscordBenchmarkSupport/README.md#compact-report-and-schema-reference)
for display bounds and unavailable estimate spellings.

Read the direct end-to-end row alongside its stage rows. P50/p95/p99 are inclusive
nanosecond bucket intervals, censored bounds or explicit unavailable results.
Do not add stage percentiles, subtract caller and owner percentiles to estimate
queue residence, average run percentiles into a population percentile, or treat
nested/parallel/subscriber intervals as additive. Batch p99 describes batches;
dividing it by batch size does not create individual-call p99. Each population
requires at least 10,000 observations for p99, in every gated run.

The current common format is `DiscordBenchmarkReport`, `schemaVersion: 1`.
Its catalog is `discordkit.timing`; supported catalog revisions are 2 through 9,
with revision 9 adding media/voice metrics. Catalog revision, metric version,
profile version and report schema version are independent. Different suites may
correctly emit different catalog revisions. The
[metric catalog](Tasks/latency-timing/METRICS.md) supplies exact IDs, start/stop
semantics, populations and overlap; the
[Swift schema](../Tools/DiscordBenchmarkSupport/Sources/DiscordBenchmarkSupport/Report.swift),
[histogram](../Tools/DiscordBenchmarkSupport/Sources/DiscordBenchmarkSupport/Histogram.swift)
and [provenance model](../Tools/DiscordBenchmarkSupport/Sources/DiscordBenchmarkSupport/Provenance.swift)
are the executable field references.

| Common field | Interpretation |
| --- | --- |
| `identity` | Catalog/scenario/profile versions, seed, fixture hashes/input sizes, instrumentation, scheduler, concurrency, actual/requested warmup, measured interval and repetitions |
| `provenance` | Source and dirty-content identity, dependencies, executable/build flags, compiler, OS/SDK/target/architecture, machine and effective allocation; missing receipts retain reasons |
| `adapter`, `clockDomain`, `status` | Execution identity, one monotonic domain and `completed` / `interrupted` / `failed` / `unqualified` run state |
| `counts` | Offered, admitted, completed, `deadlineMisses`; exact terminal outcomes `success`, `failure`, `cancelled`, `timedOut`, `rejected`, `uncertain` |
| `metrics` | Registered `id`, `version`, `outcome`, `clockDomain`, and whole-population `distribution`; independent child populations need not equal workflow counts |
| `distribution` | `configuration` range/bucket width, `bucketCounts`, `inRangeCount`, `underflowCount`, `overflowCount`, `droppedCount`, `counterOverflow`, `observedCount`, `maxInRangeNanoseconds` |
| `gauges` | Each value has `unit`, `method`, `scope`; missing values carry `unavailableReason`; process-lifetime peak RSS is not a workload-row allocation count |
| `cleanup`, `throughputPerSecond` | Awaited closure/remaining owners and measured completion rate, or explicit unavailable evidence |
| `qualificationLimitations`, `legacy` | Scope restrictions and optional byte-preserved independent legacy artifact; importing it cannot invent missing populations or provenance |

Durations use checked integer nanoseconds from monotonic time. Wall dates describe
provenance. Mixed clock domains and malformed count arithmetic fail validation. Counted
histogram underflow/overflow and flagged counter overflow remain readable
evidence, with censored or unavailable estimates; they cannot become a passing
finite-tail result.
Unknown aggregate loss prevents qualifying estimates; out-of-range mass stays
censored rather than becoming a finite maximum. Runtime output aggregation uses
its own bounded logarithmic buckets, distinct from the common development
histogram's fixed absolute widths.

Native formats retain their independent identities: the historical load report
is unversioned, DSL runtime/compiler reports use schema 1, and local voice has
historical schema 2 plus explicitly selected attributed schema 3. New timing
subcommands carry their own native details and a common envelope. Preserve those
artifacts and readers. Historical successful-prefix/diagnostic-inclusive rows
and new whole-population/corrected-boundary metrics cannot share a baseline.

The [series and policy reference](../Tools/DiscordBenchmarkSupport/README.md#paired-capture-and-reviewed-regression-policies)
describes `DiscordBenchmarkSeries` schema 1, `DiscordBenchmarkPolicy` schema 1
and the `discordkit.benchmark-comparison-spec` version-1 capture specification.
`hash`, `hash-series`, `compare` and policy evaluation have different purposes;
validating or summarizing one report cannot promote a regression gate.

## Compare on a compatible machine

1. Prepare unchanged baseline and candidate checkouts with independently built
   release executables and receipts. Match workload/profile/metric versions,
   native settings, fixture digests, seed schedule, adapter, instrumentation,
   compiler/build flags, OS/SDK/target and effective CPU/memory allocation. Source,
   dirty-content and executable identities may differ because code is changing.
2. Reserve and inspect a named host. Record allocation, contention, scheduling
   and available power/thermal observations. The capture specification's `host`
   declaration is a receipt to review, not proof of exclusivity. Uncontrolled or
   known/unknown contended hosts block controlled numerical qualification.
3. Follow the shared guide's complete
   [no-change and candidate recipes](../Tools/DiscordBenchmarkSupport/README.md#paired-capture-and-reviewed-regression-policies).
   Capture five fresh-process no-change pairs and five candidate pairs sequentially,
   with recorded alternating A/B and B/A order. Keep all failed/partial evidence.
   Pilot finite warmup/duration/batch settings first; maintain the same policy
   across arms. Never run independent performance captures concurrently.
4. Validate and summarize each common report. Review all outcomes, deadline
   misses, bounds, cleanup and scope before numerical deltas. Inspect paired
   changes and run spread. Operations in a run are not independent replications;
   the displayed spread is not a confidence interval.
5. Retain immutable series, run `hash-series`, then author and review a separate
   hash-bound reporting policy. Floors must cover the measured no-change deltas
   in each statistic's own units. A new capture changes the evidence hashes even
   for unchanged executables. Failure never refreshes a baseline automatically.
6. Evaluate that exact series and inspect the decision JSON. Classifications are
   `passed`, `regression`, `incompatible`, `insufficientSamples`, `hostFailure`
   and `harnessFailure`. Reporting mode can exit successfully with a regression
   or unavailable numerical result. An explicitly reviewed required policy has
   separate exit semantics. A greater-than-10% adverse change in three matching
   pairs requests investigation even with a more permissive budget.

Accepting an exact workload-scope limitation in a policy cannot supply missing
provenance, remove loss or qualify another platform. Ordinary native CI smoke
remains informational on shared runners. Hosted qualification needs completed
jobs at the exact committed revision; preparing or locally checking a workflow
does not dispatch or qualify it. See [native CI](Tasks/latency-timing/PHASE-10.md#ci-and-qualification).

## Troubleshoot evidence before changing code

| Observation | Next step |
| --- | --- |
| Receipt rejects changed source or executable | Finish edits and build a new receipt in a new run directory; retain the rejected attempt's diagnostics |
| Comparison is incompatible | Read the specific reasons; check catalog/profile/fixture/mode, requested policy, compiler/pins, adapter and effective host allocation before recapturing |
| P99 is unavailable or tail is censored | Check per-outcome sample count, histogram range, loss and counter overflow; pilot more observations or a versioned range without inventing finite values |
| Success latency improves while rejection or failures rise | Review offered/admitted/completed counts, all outcomes, throughput, missed arrivals and deadlines; do not call this an improvement from success latency alone |
| No interval exists for a refused or failed operation | Check whether its start boundary was reached; counters still account for work that cannot have a duration |
| Timeline is incomplete | Inspect dropped/late/missing-parent/unmatched accounting, active-state limits and producer join order; sampled-out work cannot be restored |
| Caller latency exceeds owner timings | Check actor admission and included waits in the catalog; only explicit matching submission/admission endpoints measure queue residence |
| RSS is zero or unavailable | Preserve an unavailable gauge's reason; verify method/scope and leader-only versus whole-process-lifetime sampling rather than substituting zero |
| Timeout or forced termination leaves no report | Inspect supervised process status and bounded logs/partial artifacts; do not invent unfinished counts or successful cleanup |
| Signposts exist but no profiler recording is available | Repeat a separately invoked native Instruments recording and retain its evidence; emitted callbacks alone are not a recording |
| Instrumented results get slower | Compare gross mode distributions, synchronous output and flush cost in a separate controlled overhead run; preserve observation-induced deadline misses |
| Local runs disagree with shared CI | Check host allocation, contention, compiler/OS/SDK and exact revision; shared CI smoke has a different qualification role |

## Hand off an optimization

The [performance refinement plan](Tasks/performance-improvements/PLAN.md) applies
these tools to source findings, causal experiments and staged optimization gates.
Its [planning evidence](Tasks/performance-improvements/EVIDENCE.md) retains current
local observations separately from the historical measurements below.
The [phase 5 record](Tasks/performance-improvements/PHASE-5.md) adds paired local
JSON/RPC observations, numeric/key-density and coalesced-frame controls, with
allocation tracing and controlled-host numerical qualification kept explicit.

Create a separate change only after reproducing the cost with a defined boundary.
Attach the exact case, catalog/metric/profile versions, fixture hashes, command
and release receipts; keep baseline, no-change and candidate series plus policy
and decision. Include direct end-to-end distributions, stage distributions,
offered/admitted/completed and all outcomes, deadline misses, cleanup, resource
method/scope, observer mode/cost limitations and relevant timeline loss. Give the
correctness invariant and tests that must survive the change.

The retained [Phase 4 observations](Tasks/latency-timing/VALIDATION.md#phase-4-validation)
provide concrete profiling candidates. These are historical gross normalized
batch means in microseconds per call, from one smoke process per case on macOS
arm64/Swift 6.4, source `7912304d` plus its recorded dirty-source fingerprint.
They establish workload cost in that capture; they do not establish current
performance, an isolated bottleneck, a noise floor or individual-call tails.

| Case | Historical mean (µs/call) | Profiling question |
| --- | ---: | --- |
| `json.parse.262144.depth64.ascii` | 630.121 | Which parse work dominates this combined size/depth/width fixture? |
| `json.serialize.262144.depth64.ascii` | 770.691 | Where does complete output construction spend CPU? |
| `permission.allow.r128.w4096` | 60.589 | Which resolution operations dominate the paired role/overwrite/bit-width case? |
| `rpc.decode.p262144.f256` | 110.460 | What is the cost of fresh decoder state, buffering and frame emission with 256-byte fragments? |

Remeasure with current source and fixtures before selecting an optimization.
The exact case identifiers come from the
[JSON](../Tools/DiscordFoundationBenchmarks/Sources/DiscordFoundationBenchmarks/JSONWorkloads.swift),
[permission](../Tools/DiscordFoundationBenchmarks/Sources/DiscordFoundationBenchmarks/PermissionWorkloads.swift)
and [RPC](../Tools/DiscordFoundationBenchmarks/Sources/DiscordFoundationBenchmarks/RPCWorkloads.swift)
fixture factories. This command selects those cases with the historical finite
batch settings and captures fresh fixture/source/executable receipts:

```sh
python3 Tools/DiscordBenchmarkSupport/scripts/run_benchmarks.py build \
  --repository . --package Tools/DiscordFoundationBenchmarks \
  --product DiscordFoundationBenchmarks --receipt .build/measurements/candidates-release.json
python3 Tools/DiscordFoundationBenchmarks/scripts/run_cases.py \
  --executable Tools/DiscordFoundationBenchmarks/.build/release/DiscordFoundationBenchmarks \
  --receipt .build/measurements/candidates-release.json \
  --output-dir .build/measurements/candidates \
  --case json.parse.262144.depth64.ascii \
  --case json.serialize.262144.depth64.ascii \
  --case permission.allow.r128.w4096 --case rpc.decode.p262144.f256 \
  --batches 32 --batch-size 8 --warmup-batches 4
```

These smoke results are leads for a profiler and subsequent paired standard
comparison, not a before/after optimization decision.

For example, investigate callback contention with the overhead suite's
`--mode callbackContention`; inspect a cache refresh cohort with
`cache-client-timing --case cache.singleFlight`; or inspect an arrival knee with
`timing --case arrival.rest` under explicit finite rate/cohort/queue settings.
Each linked suite identifies its fixture and reproduction command. These are
investigation candidates, not established bottlenecks: a slow inclusive refresh
row does not isolate refresh CPU, a fixed batch tail does not identify one call,
and a scripted wait does not characterize a remote provider. Record the measured
comparison and remaining uncertainty before proposing a particular optimization.
The task's [evidence ledger](Tasks/latency-timing/VALIDATION.md) distinguishes
implemented coverage from pending controlled-host, native, hardware and live
qualification.
