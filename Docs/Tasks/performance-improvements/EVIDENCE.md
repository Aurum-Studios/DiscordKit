<!--
File: Docs/Tasks/performance-improvements/EVIDENCE.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Planning evidence

Captured on 2026-11-10 America/Chicago (2026-11-11 UTC) against clean source
`065e2b655c28250076ba53fca310f209be1d3fd5`, before writing this plan. The host was
macOS 27.0.1, arm64, Apple M3 Max/Mac15,10, 14 visible logical CPUs and 36 GiB
physical memory. Release builds used Apple Swift 6.4 and four build jobs. The host
was not reserved; effective CPU affinity/quota, thermal/frequency and exclusivity
were not established. All captures ran sequentially, after their builds completed.

The checked-in [observations index](observations.json) retains source/build identity,
fixture/metric/profile configuration, exact commands, counts, distributions without
large bucket arrays, artifact SHA-256 digests and closure receipts. Full native,
common and orchestration files remain local under the ignored
[capture directory](../../../.build/performance-plan-20261110). These are exploratory
observations, not promoted numerical baselines or regression thresholds. Hashes
identify the retained artifacts; they do not replace missing controlled-host evidence.

## Ordering handoff reproduction

The [source listing and procedure](ORDERING-PROBE.md) exercise only public
`RateLimitCoordinator.withOrdering`. One owner holds a partition. A second caller
actually invokes the coordinator's clock sleep; the driver observes that invocation
and a snapshot containing one queued/one held operation, then signals the first
owner to return. Markers retain release signal, first operation exit, first
`withOrdering` return and successor operation entry. No REST, network, response
decode, quota reservation or external store call occurs.

Twenty fresh release processes ran serially in ten alternating policy pairs, eight
trials per process: 160 total trials. The default arm constructs `SchedulingPolicy()`;
the other changes only `fairnessInterval` to 100 µs. A trial has a two-second
structured timeout; each child has an external ten-second process-group timeout
and joined teardown. The default-policy probe is outside the common benchmark
schema and deliberately is not a qualified regression series.

| Policy | Median of process medians: release signal → successor | Range of process medians | Median of process medians: confirmed first return → successor |
| --- | ---: | ---: | ---: |
| Actual default (10 ms polling) | 15.047 ms | 12.367–15.066 ms | 15.027 ms |
| Only polling interval changed to 100 µs | 1.150 ms | 1.132–1.159 ms | 1.136 ms |

Every child exited zero. Every trial had zero queued and ordered owners afterward;
all 20 process groups were verified absent after reaping. Source/executable hashes
were unchanged. The confirmed-first-return gap was positive in all trials, so
waiting persisted after the preceding ownership release was externally visible.

This establishes a local polling-related handoff delay in the reproduced condition.
The release signal followed the observed sleep invocation by approximately 5–24 µs;
the clock callback precedes actual suspension and the snapshot/markers perturb
scheduling. Timer coalescing and OS/executor scheduling contribute to the measured
gap, which can exceed the requested interval. The experiment does not isolate
their individual shares, qualify production tails, prove rate-store handoff or
justify simply lowering the polling interval. Stage 1 investigates completion
notifications with the authority/fairness rules retained.

The current REST timing case is an important control mismatch:
`rest.orderedMutation` constructs 100 µs polling, a 1 µs provisional window and
an enlarged rate allowance. Its `rest.orderWait` metric is not a selectable case.
Reusing that case alone would miss the actual default behavior.

## Foundation CPU exploration

The shared build/supervisor created current-source release receipts and ran seven
fresh smoke processes. Each case completed 32 batches of eight calls after four
warmup batches: 224 measured batches / 1,792 calls total. Checksums, independent
semantic oracles and exact call counts passed; zero unexpected rejections or
histogram underflow/overflow/loss occurred. Each producer and process was joined.

| Case | Gross normalized batch mean (µs/call) |
| --- | ---: |
| `json.parse.1024.depth1.ascii` | 5.095 |
| `json.parse.262144.depth64.ascii` | 626.882 |
| `json.serialize.262144.depth64.ascii` | 785.237 |
| `permission.allow.r128.w4096` | 75.903 |
| `rpc.decode.p262144.f7` | 3611.738 |
| `rpc.decode.p262144.f256` | 113.397 |
| `rpc.decode.p262144.f4096` | 21.432 |

The RPC cases hold payload size constant and expose fragment-sensitive work,
including append-loop and repeated header parsing/copying. They do not establish
what fraction a header-state refinement can remove. The JSON size cases change
multiple structural dimensions; they cannot isolate depth cost. Permissions also
pair roles/overwrites/bit width. Separate-factor fixtures and profiles precede
algorithmic conclusions.

These figures include operation allocation, loop/closure and minimal checksum
consumption. They are neither isolated CPU instructions nor per-call percentiles.
All p99 estimates are explicitly unavailable: 32 batches is below 10,000. The
1 µs bucket precision describes batch observations. Process gauges do not identify
allocation-event counts or the exact retained heap of an individual operation.

## Timing and output exploration

The shared supervisor ran seven modes with two workers, 128 warmup operations per
worker and 1,000 measured operations per worker. All 14,000 measured operations
completed, checksums/output counters reconciled, final owners were zero and all
processes were reaped. No histogram loss/censoring occurred. All p99 estimates are
unavailable at 2,000 observations per mode.

| Mode | Observed gross p50 bucket (ns) | Flush/export outside operation timers (ns) |
| --- | ---: | ---: |
| `disabled` | 0–99 | 1,167 |
| `noop` | 400–499 | 750 |
| `aggregate` | 600–699 | 15,459 |
| `filtered` | 3,100–3,199 | 1,458 |
| `combined` | 5,000–5,099 | 8,436,125 |
| `scalarDisabled` | 123,500–123,599 | 2,291 |
| `scalarAggregate` | 81,400–81,499 | 31,042 |

Interval modes time the small CPU fixture with genuine detailed timing/output
boundaries. Scalar modes time a different workload: the real REST owner with a
local injected HEAD/204 transport and no network. Their figures cannot be compared
against the CPU rows. The scalar result reverses the expected overhead ordering
in this single fixed-order capture; it demonstrates why these data cannot isolate
collection cost. Mode identities intentionally fail ordinary baseline compatibility.
Use separate controlled mode experiments, then compare the same mode across source
revisions. No subtraction of these buckets is an isolated overhead measurement.

## Reproduce the supervised exploration

From the repository root, choose fresh artifact directories/receipt names. These
commands intentionally match the small planning workloads, not Stage 0's eventual
standard comparison. Finish edits before building; later documentation changes
also change the receipt's source fingerprint. Existing evidence remains historical.

```sh
python3 Tools/DiscordBenchmarkSupport/scripts/run_benchmarks.py build \
  --repository . --package Tools/DiscordFoundationBenchmarks \
  --product DiscordFoundationBenchmarks \
  --receipt .build/performance-recapture/foundation-release.json
python3 Tools/DiscordFoundationBenchmarks/scripts/run_cases.py \
  --executable Tools/DiscordFoundationBenchmarks/.build/release/DiscordFoundationBenchmarks \
  --receipt .build/performance-recapture/foundation-release.json \
  --output-dir .build/performance-recapture/foundation \
  --case json.parse.1024.depth1.ascii \
  --case json.parse.262144.depth64.ascii \
  --case json.serialize.262144.depth64.ascii \
  --case permission.allow.r128.w4096 \
  --case rpc.decode.p262144.f7 --case rpc.decode.p262144.f256 \
  --case rpc.decode.p262144.f4096 \
  --batches 32 --batch-size 8 --warmup-batches 4
python3 Tools/DiscordBenchmarkSupport/scripts/run_benchmarks.py build \
  --repository . --package Tools/DiscordTimingBenchmarks \
  --product DiscordTimingBenchmarks \
  --receipt .build/performance-recapture/timing-release.json
python3 Tools/DiscordTimingBenchmarks/scripts/run_modes.py \
  --executable Tools/DiscordTimingBenchmarks/.build/release/DiscordTimingBenchmarks \
  --receipt .build/performance-recapture/timing-release.json \
  --output-dir .build/performance-recapture/timing \
  --mode disabled --mode noop --mode aggregate --mode filtered --mode combined \
  --mode scalarDisabled --mode scalarAggregate \
  --iterations 1000 --warmup-iterations 128 --concurrency 2
```

## Validation and qualification

Both release builds exited zero. Each of the 14 common envelopes passed the
existing `DiscordBenchmarkReports validate` semantic validator. Native benchmark
assertions verified results, counts and output/closure accounting. The ordering
probe build and all 20 child processes exited zero with explicit ownership read-back.

Runtime sources, manifests, dependency pins and tests were unchanged. This task
does not rerun unrelated runtime correctness suites for documentation edits. Local
JSON/hash/link/whitespace checks and independent review cover the planning artifacts:
149 relative links resolved, 50 referenced artifact hashes matched, both retained
Swift listings matched the compiled probe, and the documented small supervisor
retained correct status/cleanup for successful, failed and timed-out child checks.
Review corrections include a default-policy ordered-mutation arrival acceptance
case, correct RPC ownership and failure-path reproduction receipts.
Future implementation must run the affected meaningful correctness suites and
the stage-specific comparisons.

No profiler recording, controlled-host baseline/no-change qualification, numerical
gate promotion, Linux/hosted run, actual desktop/browser, physical audio, live
Discord, release, publication or deployment was performed. The existing
[timing qualification ledger](../latency-timing/VALIDATION.md) retains its separate
historical evidence and open gates.


## Phase 3 implementation evidence

The event-delivery refinements, retained ownership/routing decisions, deterministic
control-progress checks and finite comparison receipts are recorded separately in
[Phase 3](PHASE-3.md). This preserves the original planning observations above;
implementation receipts do not promote them to controlled-host numerical evidence.

## Phase 4 implementation evidence

The bounded entity/read cache indexes, exact identity accounting, retained
serialization and stateless-permission decisions, independent workload controls
and correctness checks are recorded in [Phase 4](PHASE-4.md). Its
[capture index](phase-4-observations.json) retains 160 paired cache processes,
58 functional release sweeps and 14 permission processes. Large-cache lookup and
eviction improve locally, while full expiry drains slow and entity process RSS
increases. These observations do not close the reserved-host numerical, profiler
or representative workflow gates.

## Phase 8 implementation evidence

Bounded immutable resampler phase plans, exact differential signal tests, retained
codec/queue ownership decisions and separated startup/process/flush controls are
recorded in [Phase 8](PHASE-8.md). Its [capture index](phase-8-observations.json)
retains 620 qualified media processes, 40 qualified paced localhost duplex
processes, four diagnostic CPU samples, rejected attempts and all source/build/
cleanup identities. Common-ratio filtering and affected encoding improve locally;
constructor cost and plan memory increase, and an awkward fallback adverse
observation remains explicit. The impaired hybrid control fails in both the original
and candidate runtimes; its trigger and Stage 9 follow-up are retained separately.
These results establish no controlled-host numerical,
physical audio, Linux/hosted or live Discord qualification.

## Phase 10 implementation evidence

The combined default-policy REST/cache/Gateway workload, bounded independent
arrival/recovery cycles, genuine 30-minute soak, reporting-only supervisor and
periodic CI integration are recorded in [Phase 10](PHASE-10.md). Its
[capture index](phase-10-observations.json) preserves 23 mixed-load processes,
120 representative repeatability processes, three observer controls, impaired
voice under two CPU workers, validation and immutable artifact identities.
Same-executable comparisons establish repeatability rather than an optimization
speedup. Reserved-host policy/noise review, simultaneous secure rekey/media
stress, profiler, Linux Swift/native-platform and live qualification stay open.
