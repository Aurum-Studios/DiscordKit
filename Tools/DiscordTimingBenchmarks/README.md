<!--
File: Tools/DiscordTimingBenchmarks/README.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Instrumentation overhead benchmarks

This development-only package measures the gross cost of optional runtime timing
and synchronous output. It reuses [DiscordBenchmarkSupport](../DiscordBenchmarkSupport/README.md)
for bounded whole-population histograms, report validation/provenance, release
build receipts, fresh processes and supervised teardown. Runtime products do not
depend on this package. It starts no network request or global logging bootstrap.

## Build, test and bounded smoke

From the repository root:

```sh
swift test --package-path Tools/DiscordTimingBenchmarks --force-resolved-versions --jobs 4
python3 Tools/DiscordBenchmarkSupport/scripts/run_benchmarks.py build \
  --package Tools/DiscordTimingBenchmarks --product DiscordTimingBenchmarks \
  --repository . --receipt .build/timing-phase3/release.json
python3 Tools/DiscordTimingBenchmarks/scripts/run_modes.py \
  --executable Tools/DiscordTimingBenchmarks/.build/release/DiscordTimingBenchmarks \
  --receipt .build/timing-phase3/release.json \
  --output-dir .build/timing-phase3/modes
```

Finish source edits before creating the receipt. The shared supervisor rejects a
changed source fingerprint or executable. The convenience script runs all 19
modes sequentially on macOS, using two workers, 128 warmup iterations per worker,
1,000 measured iterations per worker, one-second warmup and ten-second measured
**caps**, one fresh process per mode. Apple-only modes are skipped on other hosts;
this is explicit absence of platform evidence. Add repeated `--mode` arguments to
select a subset. The script accepts smoke only: standard comparisons use the
shared driver's explicit baseline/candidate commands and receipts, five paired
fresh-process repetitions and counterbalanced order. Compare the same mode and
workload across revisions; different instrumentation identities deliberately fail
ordinary report compatibility checks.

All output directories must be new. The shared supervisor enforces process-group
timeouts, RSS limits, bounded diagnostics/reports and reaping. Native assertion or
flush failures exit nonzero. Cancellation joins structured workers and closes
owned REST/output resources; an interrupted process may lack a native histogram
report. The supervisor preserves available bounded artifacts and diagnostics and
marks the failure instead of inventing counts for unfinished operations.

For one direct local run with retained timeline files:

```sh
Tools/DiscordTimingBenchmarks/.build/release/DiscordTimingBenchmarks \
  --mode combined --concurrency 2 --iterations 1000 \
  --warmup-iterations 128 --warmup-seconds 1 --duration-seconds 10 \
  --output .build/timing-phase3/combined.json \
  --common-report .build/timing-phase3/combined-common.json \
  --artifact-directory .build/timing-phase3/combined-artifacts
```

Direct execution has iteration/time caps but no independent process RSS or signal
supervisor; use the shared driver for performance evidence. `--list-modes` prints
available mode names. Unsupported native adapters fail explicitly. No automatic
benchmark or live Discord run occurs during a consumer build.

## Work and measurement boundaries

Each finite structured worker repeatedly rotates and multiplies 64 integer lanes.
The recorded seed is mixed with worker and operation indices. The immutable
[fixture definition](fixture.txt) has SHA-256
`8d7524e535557da2a0cd19b35883a70b9383e48446f9d48216b6b15faf7cd66b`;
independent known vectors test the implementation. Every run verifies observable
checksums and exact operation/histogram counts. Fixture preparation, output setup,
verification, merging, encoding, artifact writes and flushing occur outside the
individual operation timer. These costs are not subtracted from observed latency.

The interval cases call actual `begin` and once-only `end` around the CPU fixture,
using the model's finite `.rest`/`.operation` tokens as synthetic fixture labels.
These are actual live fixture boundaries, not a replay of completed scalar samples
and not a REST/network latency claim. Scalar modes separately execute a genuine
`RESTClient` HEAD/204 pipeline with an injected, bounded local `HTTPTransport`,
synthetic nonwaiting rate headers, no credentials and no network. They verify one
transport invocation and zero retained admission owners per completed operation;
scalar aggregation receives exactly four real phases per request. CPU fixture and
local REST results use distinct report scenario identities and are not comparable
workloads. The empty-harness control returns the input without the 64-lane work;
clock-read adds one explicit real monotonic read to the ordinary CPU fixture.

| Mode | Measured instrumentation/output |
| --- | --- |
| `disabled` | Nil detailed observer; outer harness timers remain enabled |
| `noop` | Genuine begin/end with a truly empty sink |
| `aggregate` | Numeric bounded aggregate, including finite key selection and lock |
| `sampled` | Seeded coherent head sampling, one root in sixteen, bounded numeric endpoints |
| `filtered` | Existing `DiscordLog.withOperation` with trace below the logger threshold, including UUID/context/clock work |
| `callback` | Safe SwiftLog timing records delivered synchronously to a numeric counter |
| `callbackContention` | Same callback counter shared by at least two bounded workers |
| `console` | Existing SwiftLog stderr stream handler, retaining real formatting/write cost |
| `rotatingFile` | Existing synchronous NDJSON sink, three 16 KiB slots and an 8 KiB record limit |
| `sinkFailure` | The same file output closed before producers start; every endpoint must be counted as dropped/failed |
| `saturation` | Three retained endpoints; all remaining endpoints are explicitly dropped and incomplete pairing retained |
| `unifiedLog` | Existing private Apple unified-log handler; unavailable outside supported Apple hosts |
| `signposts` | Genuine live `OSSignposter` interval state with bounded pairing and explicit close |
| `combined` | Numeric aggregate, sampled capture and synchronous callback output together |
| `clockRead` | CPU fixture plus one extra real monotonic read |
| `emptyHarness` | Input return and outer timer/checksum bookkeeping control |
| `scalarDisabled` | Genuine local REST owner with nil legacy scalar observer |
| `scalarNoop` | Same REST owner with a truly empty scalar callback |
| `scalarAggregate` | Same REST owner forwarding real scalar observations to numeric aggregation |

Warmup has independent outputs, IDs, histograms and counters. A zero warmup-second
cap skips warmup operations even if an iteration cap is configured. Otherwise each
population stops when either its per-worker operation cap or its time cap is
reached; this is an operation-limited microbenchmark, not a promise of sustained
offered load. Warmup actual elapsed time and operation count remain separate from
measurement. The native report records actual elapsed time, all finite caps and
independent flush duration. Disabled timing preserves the runtime's nil observer
semantics; it does not disable the benchmark's necessary measurement clock.

Individual gross duration stops after synchronous observer/output callbacks return.
Per-worker whole-population histograms have **100 ns absolute buckets across
0...2 ms**. Longer observations retain censored overflow mass; p99 stays
insufficient-tail-data below 10,000 observations. The new metric is
`instrumentation.operation.gross` version 1 under catalog revision 3, with
instrumentation, scenario, concurrency, iterations, seed, warmup and histogram
configuration defining its identity. This is an individual-call distribution,
not the earlier planned normalized `instrumentation.batch` metric.

Wall throughput starts at cohort submission and stops after all worker tasks join.
It includes per-call clock reads, loop/deadline checks, histogram/checksum updates
and scheduling. It excludes final histogram merging, REST authority shutdown,
verification, flush and export. CPU delta spans the native `getrusage` reads and
therefore also includes the remainder of baseline RSS/malloc sampling before the
wall timer. Final RSS and Darwin live allocator blocks/bytes are process gauges;
peak RSS covers the **whole process**, including warmup/setup. Live footprint is
not an allocation-event count. Unsupported probes and allocation-event counts are
explicitly unavailable, never zero.

## Output ownership, loss and qualification

The native v1 report retains each adapter's counts, checksums, separate warmup,
flush time and the validated common v1 envelope. Common report catalog revision 2
continues to read for earlier tools; the new metric requires revision 3. Runtime
aggregation preserves finite scalar/interval populations independently of sampled
capture. Aggregate acceptance, callback delivery, file success/failure and sampled
retained/excluded/dropped endpoints must reconcile before a run succeeds. Real
signpost begun/ended counts must equal completed operations, with zero remaining
state. Log sink failure degrades output accounting without changing fixture results.

Capture retains at most 65,536 endpoints and 8 MiB numeric storage, and at most
256 active decisions. Sampled-out endpoints are distinct from loss. The saturation
case retains only three endpoints so an endpoint pair is deliberately broken;
no duration is manufactured for that incomplete interval. File/callback outputs
are synchronous; there is no queue, exporter, timer or task per observation.
Only the fixed cohort creates tasks. Neither output belongs on realtime callbacks.

With `--artifact-directory`, end-of-run output includes applicable
`aggregate.json`, `intervals.ndjson`, `timeline.json` and bounded rotating log
files. Chrome trace JSON can be opened in a local trace viewer. These artifacts
are named local output, not hash-qualified common-envelope trace artifacts. Their
serialization/write cost is in flush duration. Without explicit retention,
outputs live in an exclusively owned temporary directory and are removed after
close. Existing artifact directories are rejected, preserving another run's data.

Source/compiler/executable/dependency and host allocation receipts remain in the
shared orchestration/build artifacts. The executable's conservative provenance
marks receipts it cannot establish as unavailable. A completed smoke means
integrity, accounting and cleanup passed. It does not qualify Instruments capture,
Linux execution, live Discord, production, a controlled host, numerical regression
thresholds or statistically qualified p99. Signpost emissions alone do not prove
that Instruments was recording; profiler qualification is an explicit separate run.
