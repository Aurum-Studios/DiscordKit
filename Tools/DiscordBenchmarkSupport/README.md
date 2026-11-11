<!--
File: Tools/DiscordBenchmarkSupport/README.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Shared development measurements

This dependency-free Swift package supplies bounded whole-population statistics,
strict common reports and a Python process driver. Load, DSL and local voice
tools adopt it; runtime products do not. It implements latency-plan
[Stage 1](../../Docs/Tasks/latency-timing/PHASE-1.md).

## Collection and reports

`BoundedHistogram` uses checked integer nanoseconds, fixed absolute bucket widths
and mergeable counts. Underflow and overflow retain censored mass. An affected
quantile or maximum reports a bound; unknown loss blocks numerical estimates.
P99 requires at least 10,000 observations. `SeededReservoir` optionally retains at
most 4,096 seeded Algorithm R examples across the entire input stream. Reservoirs
never stand in for full-population histograms. Profiles validate the combined
16-MiB aggregate budget before allocation.

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
