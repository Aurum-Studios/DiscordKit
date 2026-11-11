<!--
File: Tools/DiscordBenchmarkSupport/README.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Shared development measurements

This dependency-free Swift package supplies bounded whole-population statistics,
strict common reports, a bounded compact report view and a Python process driver. Load, DSL and local voice
tools adopt it; runtime products do not. It implements latency-plan
[Stage 1](../../Docs/Tasks/latency-timing/PHASE-1.md).

Performance [Phase 0](../../Docs/Tasks/performance-improvements/PHASE-0.md) adds
bounded before/after host observations: the 64 busiest visible process CPU-time
and percentage estimates (no arguments or environment), available macOS
thermal/power observations and visible Linux cgroup-v2 ancestor `cpu.stat`
throttling counters. Snapshots occur outside child measurement. Missing probes
remain unavailable; process snapshots do not prove host reservation, interval
peer CPU deltas or process-tree peak memory. Controlled comparison still requires
an explicit reviewed host declaration and independent no-change pairs.

## Collection and reports

Catalog nine adds `dsl.definitionPlanV1` for public compilation of a prepared raw
catalog and `dsl.definitionSerializationControlV1` for its JSON writer control.
They retain distinct populations: the writer does not perform structural admission.
Existing metric versions and legacy authoring populations remain unchanged. See
the [phase record](../../Docs/Tasks/performance-improvements/PHASE-7.md).

`BoundedHistogram` uses checked integer nanoseconds, fixed absolute bucket widths
and mergeable counts. Underflow and overflow retain censored mass. An affected
quantile or maximum reports a bound; unknown loss blocks numerical estimates.
P99 requires at least 10,000 observations. `SeededReservoir` optionally retains at
most 4,096 seeded Algorithm R examples across the entire input stream. Reservoirs
never stand in for full-population histograms. Profiles validate the combined
16-MiB aggregate budget before allocation.

Catalog eight also registers versioned performance-phase-six batch identities.
`oauth.refreshCohortV2` runs from driver cohort submission through every terminal
reader join, before coordinator close and subsequent diagnostic snapshots. It
counts cohorts even when unrelated grants have multiple refresh owners; caller
outcomes and actual refresh exchanges have separate populations. Legacy
`oauth.refresh.joined` retains its flight population and inclusive close boundary
and is never emitted by V2 workloads.

`rpc.queuedReplyCohortV1` runs from first synthetic reply submission through
all 64 already-sent public request results while an independently sized unsent
backlog remains parked. It has one observation per cohort, with exact native
duration sum and cohort count; neither its percentile nor its common cohort
throughput is a per-call statistic. Setup, pending admission and final shutdown
are outside this target interval. The separate `rpc.request` population retains
whole public caller durations and remains unchanged. See the
[service controls](../DiscordKitLoadTests/README.md#phase-8-optional-service-timing)
for adapter distinctions and independent OAuth/storage/subscription controls.

Set `DK_BENCHMARK_ENVELOPE` to a destination to enable shared collection in the
existing tools. Without it, legacy sampling and JSON remain available. The new
sidecar uses distinct `legacy.*.wholePopulation` metric identities. It preserves
native JSON bytes and native format identity: unversioned load, DSL v1 or voice
v2. It never derives distributions from old percentile summaries. Legacy imports
remain explicitly unqualified; missing provenance, outcome accounting, gauges and
cleanup evidence are unavailable. Runtime timing enums are unchanged.

The adopted collector uses 100-microsecond buckets over 0...1 second and a finite
workload/outcome registry below 6 MiB. Longer stalls are censored, never clamped.
Transport and HTTP-policy observations retain their diagnostic-inclusive timers;
moving those boundaries belongs to Stage 5. DSL observations include responder
construction and validation. Voice observations retain integrated validated ticks
and exclude its existing 100-frame warmup. Gateway/cache imports currently carry
their native evidence without new operation histograms. Failed DSL/voice owners
write partial envelopes after cleanup when possible; forced termination can leave
only the driver's bounded logs and incomplete artifact status.

```sh
swift test --package-path Tools/DiscordBenchmarkSupport
python3 -m unittest discover -s Tools/DiscordBenchmarkSupport/scripts -p 'test_*.py'
swift run --package-path Tools/DiscordBenchmarkSupport DiscordBenchmarkReports validate .build/stage1/dsl-smoke/00-single/benchmark-envelope.json
swift run --package-path Tools/DiscordBenchmarkSupport DiscordBenchmarkReports compare baseline.json candidate.json
```

Validation rejects unsupported versions, malformed counts, inconsistent histogram
summaries, overflow, mixed clock domains and oversized reports. Comparison explains
semantic and provenance incompatibilities; neither command promotes a numerical
gate. Source/executable hashes may differ between valid candidates. Actual elapsed
time is an observation, while requested policy and input dimensions must match.
Resource gauges must retain matching names, units, collection methods, scopes and
availability; their measured values may differ.

## Compact report and schema reference

[Stage 11](../../Docs/Tasks/latency-timing/PHASE-11.md) adds a deterministic,
plain-text view of one validated common artifact:

```sh
swift run --package-path Tools/DiscordBenchmarkSupport DiscordBenchmarkReports summarize benchmark-envelope.json
swift run --package-path Tools/DiscordBenchmarkSupport DiscordBenchmarkReports summarize benchmark-envelope.json \
  --timeline capture.json --timeline trace.jsonl
```

The input must be `format: DiscordBenchmarkReport`, `schemaVersion: 1`, at most
32 MiB. Native unversioned load, DSL-v1 and voice-v2 artifacts require their
explicit existing adapters; series and policies use their own commands. The
summary applies the same strict validation as `validate`. Invalid arguments,
unsupported schemas, malformed counts and inconsistent serialized percentile
claims fail without creating a partial successful summary. `summarize` exits
successfully for structurally valid failed, interrupted and unqualified reports;
inspect `status`. It never applies a numerical gate.

Each metric identity/version/outcome has independent p50, p95, p99 and maximum
values with integer nanoseconds. `[40,49] ns` is an inclusive histogram bucket,
`<10 ns (censored)` and `>100 ns (censored)` are exclusive bounds, and
`unavailable(insufficientTailData)` preserves the 10,000-observation p99 gate.
Unknown aggregate loss or counter overflow prevents numerical estimates.
Observed, in-range, underflow, overflow, dropped and counter-overflow accounting
appears beside every displayed population, with its configured range and bucket
width. Direct end-to-end and component/phase identities remain separate; locate
their actual endpoints in the [metric catalog](../../Docs/Tasks/latency-timing/METRICS.md). The view
never pools populations, adds marginal percentiles, derives distributions from
native summaries or invents a correlated waterfall.

The view retains offered/admitted/completed counts, all six terminal outcomes,
deadline misses, observed throughput, requested/actual warmup and measurement
interval, run status, resource gauge units/methods/scopes, cleanup, missing
provenance and qualification limitations. Missing evidence displays as
`unavailable`, independently of an observed zero. Resource values retain their
reported scope; a process-lifetime maximum is not a measured-interval peak.
`numericalQualification=false` remains explicit even for a completed artifact.
`observerCost=unavailable` is deliberate: the current schema has no isolated
observer-cost metric. `instrumentation.operation.gross` measures a whole fixture
operation including its configured synchronous observers; the summary displays
it as such and performs no overhead subtraction.

Optional `--timeline REFERENCE` arguments are caller-supplied pointers, not
timeline data added to the envelope. At most four nonempty references of at most
512 UTF-8 bytes each are admitted. Their existence, contents, correlation,
completeness and clock compatibility are unverified. Without references, timeline
evidence is explicitly unavailable because the common schema has no correlated
intervals. Inspect a separately captured bounded timing/trace artifact using its
own tool and clock/context contract.

Output has finite display ceilings: the first 64 metrics sorted by identity and
outcome, 16 gauges sorted by name, eight notes in each note group, and 160 UTF-8
bytes per metadata field. ASCII/C1 controls are escaped; `[truncated]` visibly
marks shortened text. Exact omitted-row counts point back to the original JSON.
These ceilings limit presentation, never collection or qualification. The common
JSON remains the complete authoritative artifact, including preserved legacy
bytes. Optional references also obey the field-display ceiling.

The schema is defined by [Report.swift](Sources/DiscordBenchmarkSupport/Report.swift)
(envelope/counts/gauges/cleanup and strict codecs),
[Histogram.swift](Sources/DiscordBenchmarkSupport/Histogram.swift)
(range/precision/loss and `QuantileEstimate`),
[Provenance.swift](Sources/DiscordBenchmarkSupport/Provenance.swift)
(build/host receipts), and
[RunStatistics.swift](Sources/DiscordBenchmarkSupport/RunStatistics.swift)
(finite metric identities and minimum catalog revisions). The rendering API and
its display ceilings are in
[Summary.swift](Sources/DiscordBenchmarkSupport/Summary.swift); the CLI implements
`summarize`, `validate`, `compare`, `hash`, `hash-series` and `evaluate` in
[main.swift](Sources/DiscordBenchmarkReports/main.swift). These are development
contracts; the package is not a dependency of runtime products.

## Release preparation and fresh processes

The [foundation CPU suite](../DiscordFoundationBenchmarks/README.md) directly
emits common version-1 reports with catalog revision 4 and `pure.batch` version 1.
Common counts/distributions are batches; its native report separately records
calls/rejections and gross normalized mean. Catalogs 2/3 remain readable and
cannot claim the new metric. Runtime products still do not select this package.

The [transport/REST suites](../DiscordKitLoadTests/README.md#phase-5-transport-and-rest-timing)
emit catalog revision 5 with corrected native and REST operation boundaries and
independent arrival populations. Earlier catalogs remain readable. New identities
cannot relabel historical diagnostics-inclusive or successful-prefix artifacts.

The [Gateway/command suites](../DiscordKitLoadTests/README.md#phase-6-gateway-and-command-timing)
emit catalog revision 6 with signed application, trusted Gateway and explicitly
synthetic origins. New metrics require catalog six; earlier catalogs retain their
semantics. Allocate only the selected finite workload subset: the complete catalog
exceeds one collector's 16 MiB budget and is rejected before histogram allocation.

The [optional service suites](../DiscordKitLoadTests/README.md#phase-8-optional-service-timing)
emit catalog revision 8 with credential-free OAuth storage/refresh, RPC, Activities
and service orchestration populations. New identities require catalog eight;
catalogs 2...7 retain their original semantics. Runtime products remain independent
of this development package.

The [media and voice suites](../../Docs/Tasks/latency-timing/PHASE-9.md) emit catalog
revision 9 for externally timed media/MLS batches, scripted voice lifecycle,
attributed local UDP ticks and actual Apple codec processing. Historical catalogs
remain readable; component and child populations retain their separate meanings.

Run from the repository root with Python 3.10+ and Swift 6.4+. Keep receipts and
outputs in ignored build directories. Finish source edits before preparation:
receipts bind revision, exact dirty/untracked content, dependency pins, executable
hash, release flags, compiler, target and available SDK evidence. The driver checks
source, executable and fixture identity before and after every observation.

```sh
python3 Tools/DiscordBenchmarkSupport/scripts/run_benchmarks.py build \
  --repository . --package Tools/DiscordDSLBenchmarks \
  --product DiscordDSLBenchmarks --receipt .build/stage1/dsl-release.json

python3 Tools/DiscordBenchmarkSupport/scripts/run_benchmarks.py run \
  --profile smoke --scenario dsl-direct \
  --fixture Tools/DiscordDSLBenchmarks/Sources/DiscordDSLBenchmarks/RuntimeBenchmark.swift \
  --receipt .build/stage1/dsl-release.json \
  --command '["Tools/DiscordDSLBenchmarks/.build/release/DiscordDSLBenchmarks","--mode","direct","--handlers","10","--invocations","10000","--concurrency","1"]' \
  --concurrency 1 --scheduler-policy bounded-workers \
  --output-dir .build/stage1/dsl-smoke
```

Each output directory must be new. Build preparation also requires an unused
receipt filename stem; choose a new receipt for a later build. JSON command arrays
avoid shell interpretation.
`{output}` optionally supplies a native JSON destination; otherwise stdout is the
native report. `{seed}`, `{concurrency}`, `{duration_seconds}` and other documented
CLI substitutions are requests to the participant, not proof it honored them.
The common-envelope destination is injected separately. Native and common JSON
share a 32-MiB output budget; bounded diagnostics have a separate 16-MiB budget.

For five paired repetitions use `--profile standard`, replace `--command` and
`--receipt` with `--baseline-command`, `--baseline-receipt`, `--candidate-command`
and `--candidate-receipt`. A pair may select `--mode direct` versus `--mode dsl`
using the same binary receipt. Each observation starts a new process; the recorded
seed chooses the initial A/B order and subsequent pairs alternate. Distinct source
checkouts and receipts support baseline/candidate binaries. Results remain
informational, and differing modes/fixtures are distinct workload identities.

The DSL executable accepts `--warmup-invocations 0...1000000`; it runs the same
plan before measurement and resets joined activity counters. Warmup batches must
finish within 60 seconds. Native legacy gauges remain process-wide and include
warmup. The process driver defaults to cold-process observations with zero declared
warmup. Nonzero `--warmup-seconds` requires `--warmup-policy participant-declared`;
the generic driver cannot verify in-process warmup, duration, cohort or retained
state from arbitrary commands. Record those native settings honestly.

| Profile | Measured ceiling | Repetitions | Cohort ceiling | Sampled leader RSS cap |
| --- | --- | --- | --- | --- |
| smoke | 10 seconds | 1 | 64 | 1 GiB |
| standard | 300 seconds | 5 paired | 256 | 2 GiB |
| stress | 300 seconds | 3 load levels | 256 | 2 GiB |
| soak | 3,600 seconds | 1 | 256 | 2 GiB |

Stress requires a literal `{concurrency}` in the native command and sweeps one
quarter, one half and the selected maximum cohort. All profiles declare a 1,024
driver backlog ceiling and a 16-MiB participant retained-state cap; the process
driver itself runs one observation at a time. The timeout is selected warmup plus
the selected measured budget (the profile ceiling by default) plus 30 seconds. Cancellation, timeout, RSS/output breach and
orphaned descendants terminate the owned process group, escalate to kill after a
configured grace of at most five seconds and reap the direct child. Partial artifacts retain failure/truncation counts.
Current RSS is a sampled leader-process gauge; child memory and unsupported
gauges remain explicitly unavailable. Process high-water RSS is never a row gauge.

No live Discord, hardware audio, Linux qualification or numerical performance
baseline is implied by a successful local capture. See the task's
[validation procedure](../../Docs/Tasks/latency-timing/VALIDATION.md).

## Paired capture and reviewed regression policies

[Stage 10](../../Docs/Tasks/latency-timing/PHASE-10.md) adds explicit series capture
and offline evaluation. Preparation, capture, policy review and required-gate
promotion are separate operations. Nothing adopts or refreshes a baseline when
a candidate fails. Ordinary shared-runner smoke remains informational.

Finish source edits, resolve pinned dependencies and build optimized executables
before capture. Use separate unchanged source checkouts for distinct baseline and
candidate revisions; modifying a checkout invalidates its prior build receipt.
Prepare the evaluator outside capture too:

```sh
python3 Tools/DiscordBenchmarkSupport/scripts/run_benchmarks.py build \
  --repository . --package Tools/DiscordFoundationBenchmarks \
  --product DiscordFoundationBenchmarks --receipt .build/phase10/foundation-release.json
swift build --package-path Tools/DiscordBenchmarkSupport -c release \
  --product DiscordBenchmarkReports --force-resolved-versions --jobs 4 \
  --build-system native --disable-experimental-prebuilts
```

The following creates a real Foundation no-change recipe in an ignored build
directory. Both arms intentionally use the same receipt and binary. Its host
declaration starts uncontrolled with unknown contention; change that declaration
only after reserving and inspecting a named controlled host. A local recipe alone
does not establish exclusivity or platform qualification. Select warmup and finite
duration/batch counts from a pilot; the example requests 10,000 **batches** for the
batch-level p99 population, which must finish before the cap to supply that count.

```sh
python3 - <<'PY'
import json
from pathlib import Path
root = Path.cwd().resolve()
directory = root / '.build/phase10'
directory.mkdir(parents=True, exist_ok=True)
arm = {
    'receipt': str(directory / 'foundation-release.json'),
    'command': [str(root / 'Tools/DiscordFoundationBenchmarks/.build/release/DiscordFoundationBenchmarks'),
                '--case', 'json.parse.1024.depth1.ascii', '--batches', '10000',
                '--batch-size', '16', '--warmup-batches', '64', '--output', '{output}'],
}
spec = {
    'format': 'discordkit.benchmark-comparison-spec', 'version': 1,
    'profile': 'standard', 'scenario': 'json.parse.1024.depth1.ascii', 'seed': 1,
    'fixtures': [str(root / 'Tools/DiscordFoundationBenchmarks/Package.resolved')],
    'host': {'name': 'replace-with-reserved-host-name', 'controlled': False,
             'contention': 'unknown', 'notes': 'Recipe only; allocation and contention not qualified.'},
    'baseline': arm, 'candidate': arm, 'concurrency': 1,
    'scheduler_policy': 'serial-synchronous-batches',
    'warmup_seconds': 1, 'warmup_policy': 'participant-declared', 'duration_seconds': 30,
}
path = directory / 'no-change-spec.json'
with path.open('x') as output:
    json.dump(spec, output, indent=2)
PY
python3 Tools/DiscordBenchmarkSupport/scripts/run_comparison.py capture \
  --spec .build/phase10/no-change-spec.json --output-dir .build/phase10/no-change
```

The spec requires `format`/integer `version`, `profile`, `scenario`, integer `seed`,
`fixtures`, `host`, explicit `baseline`/`candidate` command arrays and receipts,
integer `concurrency`, `scheduler_policy`, integer `warmup_seconds`, `warmup_policy`
and integer `duration_seconds`. Host fields are a finite `name`, boolean
`controlled`, `contention` (`none`, `known` or `unknown`) and nonempty observed
allocation/contention `notes`. Paths resolve relative to the spec file; absolute
paths make distinct-checkout recipes unambiguous. JSON command arguments retain
literal values; shell substitutions do not run. Shared-driver environment variables
supply native profile, pair seed, warmup, duration, concurrency and common-report
destination. Tools that do not honor them must receive the corresponding CLI
arguments with the driver's substitutions.

Capture validates build/source/executable/input receipts before and after runs,
records host allocation and load indicators around every process, and refuses an
allocation change. Linux allocation requires visible affinity, cgroup-v2 CPU quota
and memory-limit state; an unavailable controller remains unavailable. Host load
indicators do not prove exclusivity. Unknown/known contention or an uncontrolled
host marks pairs contended and blocks controlled numerical qualification.

Five standard pairs run in fresh owned processes with deterministic initial order
and alternating A/B, B/A order. Source reports and process artifacts remain in
`capture/`; `comparison-report.json` adds verified build/host receipts in a separate
copy. Participant fixture digests and explicit file digests retain their values
under separate `participant:` and `capture:` namespaces in both schema fixture
maps. Scope notes, status, actual populations and actual measured values remain
unchanged. A missing report, timeout, stale input or failed cleanup retains bounded
partial artifacts and fails capture. Every output directory and release receipt
must be new.

For a candidate comparison, prepare a separate explicit spec selecting the same
baseline receipt and the candidate receipt, matching native settings and the same
host/seed schedule. Keep the independently captured no-change series, then run:

```sh
python3 Tools/DiscordBenchmarkSupport/scripts/run_comparison.py capture \
  --spec .build/phase10/candidate-spec.json --noise-series .build/phase10/no-change/series.json \
  --output-dir .build/phase10/candidate
Tools/DiscordBenchmarkSupport/.build/release/DiscordBenchmarkReports \
  hash-series .build/phase10/candidate/series.json
python3 Tools/DiscordBenchmarkSupport/scripts/run_comparison.py evaluate \
  --series .build/phase10/candidate/series.json --policy .build/phase10/reviewed-policy.json \
  --evaluator Tools/DiscordBenchmarkSupport/.build/release/DiscordBenchmarkReports \
  --output-dir .build/phase10/evaluation
```

`hash-series` outputs canonical `baselineHashes` and `noiseSeriesHash`; `hash FILE`
returns one canonical report SHA-256. These use validated Swift encoding rather
than a hash of Python JSON presentation. Copy reviewed receipts into a separately
authored `DiscordBenchmarkPolicy` schema-1 file with `mode` (`reporting` initially),
`acceptedQualificationLimitations` (exact reviewed scope-note strings),
`maximumErrors`, `maximumDeadlineMisses` and `budgets`. No helper generates or
updates this policy. Accepting a scope note does not waive structural validation,
complete outcome accounting, zero aggregate loss or joined cleanup.

Baseline hashes cover each measured reference report's complete canonical bytes,
including its distribution. A new capture produces new receipts even for the
same executable. The controlled workflow therefore separates capture from
evaluation: retain the series, review its hashes and thresholds, then evaluate
those exact artifacts. An existing policy can be replayed against its frozen
reference evidence; adopting a newly captured reference requires explicit review.
These hashes do not act as reusable build-identity-only budgets.

Series use `format: DiscordBenchmarkSeries`, `schemaVersion: 1`, `pairs` and
`noisePairs`. Each pair supplies `id`, `order` (`baselineFirst` or
`candidateFirst`), unique `baselineProcess`/`candidateProcess` receipts,
`hostContended`, and inline strict `baseline`/`candidate` common reports. Both
arrays require 5–10 pairs for qualification with alternating order and matching
seed schedules. The entire series is bounded to 32 MiB; policies are bounded to
1 MiB, ten baseline hashes and 64 budgets. Runtime reports require release
optimization; explicitly configured compiler workloads retain debug builds.

Each budget declares a unique `id`, `statistic`, `direction`, `relativeTolerance`
and measured `absoluteNoiseFloor`. Duration statistics (`p50`, `p95`, `p99`,
`maximum`) also select exact `metricID`, `metricVersion` and `outcome` and use
direction `maximum`. Throughput uses `throughput`/`minimum`; resource bounds use
`gauge`/`maximum` and a named `gauge`. Optional `absoluteLimit` is a hard ceiling or
floor. Floors must cover the independently observed no-change deltas, in the
selected statistic's units; existing DSL floors are not defaults for other
workloads. A reviewed p99 budget requires at least 10,000 observations in every
selected population. Calibrate each budget before promoting a workload.

Evaluation classifies `passed`, `regression`, `incompatible`, `insufficientSamples`,
`hostFailure` and `harnessFailure` separately. It retains individual paired
distribution bounds, sample counts, deltas and independent-run spread; it does not
average marginal percentiles or invent operation-level confidence intervals.
Greater-than-10% adverse change reproduced in three matching pairs still requests
investigation. Reporting mode exits successfully after a readable numerical
decision, including unavailable or regression classifications; inspect its JSON.
An explicitly reviewed `required` policy exits nonzero unless its gate passes.
Malformed documents and process failures fail in either mode. The Python wrapper
retains the evaluator JSON decision, exit status and logs without changing policy
or baseline files. Hosted qualification requires completed jobs at the implemented
revision; preparing workflows or local tests does not establish it.
