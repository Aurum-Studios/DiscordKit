<!--
File: Tools/DiscordFoundationBenchmarks/README.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->


The [measurement guide](../../Docs/Measurements.md) connects these workload
recipes to the versioned metric catalog, compact reports, comparison procedure
and qualification ledger.
# Foundation, model and permission CPU benchmarks

This development executable implements [Stage 4](../../Docs/Tasks/latency-timing/PHASE-4.md)
using [shared statistics, reports and process supervision](../DiscordBenchmarkSupport/README.md).
Runtime manifests, imports and accessors gain no instrumentation or dependencies.
All inputs are local fixtures. No network, credential, desktop RPC connection or
logging bootstrap is involved. JSON operations remain synchronous.

## Build and run

From the repository root, finish source edits before preparing a release receipt:

```sh
swift test --package-path Tools/DiscordFoundationBenchmarks --jobs 4 --force-resolved-versions
python3 -m unittest discover -s Tools/DiscordFoundationBenchmarks/scripts -p 'test_*.py'
python3 Tools/DiscordBenchmarkSupport/scripts/run_benchmarks.py build \
  --repository . --package Tools/DiscordFoundationBenchmarks \
  --product DiscordFoundationBenchmarks --receipt .build/timing-phase4/release.json
python3 Tools/DiscordFoundationBenchmarks/scripts/run_cases.py \
  --executable Tools/DiscordFoundationBenchmarks/.build/release/DiscordFoundationBenchmarks \
  --receipt .build/timing-phase4/release.json --output-dir .build/timing-phase4/cases
```

The wrapper runs all 101 cases sequentially, in separate processes. Repeated
`--case` options select a subset. Defaults are 100 measured batches, 16 calls per
batch, eight warmup batches and one fresh process per case. Finite native limits
for `--batches` / `--batch-size` / `--warmup-batches` are 100,000 / 1,024 / 10,000.
Supervised smoke caps warmup at one second and measurement at ten seconds.
A cap or cancellation stops admission of the next batch; a started synchronous
batch completes. No mid-parse cancellation is promised.

The shared supervisor enforces source/executable receipts, process-group timeout,
1 GiB sampled RSS and bounded diagnostics/report artifacts. Wrapper SIGINT/SIGTERM
is forwarded to the active supervisor, whose teardown is awaited before exit.
No later case starts after cancellation. Unexpected failure or forced termination
may leave only bounded supervisor diagnostics and incomplete status; counts are
never fabricated. Histogram storage is checked against the shared 16 MiB budget.
Fixtures have fixed case bounds; exact retained heap is not an allocator gauge.

All output directories must be new. Compact `scaling.json` retains dimensions,
calls/rejections, normalized mean, batch quantile evidence, censor/loss counts and
paths to full native/common reports. Different size cases are distinct workloads,
not interchangeable baselines. To compare revisions, use the shared driver's
baseline/candidate arms, five paired standard repetitions, and identical case,
seed, batch and fixture policies. Native standard/stress/soak time caps follow
shared profiles; the convenience wrapper deliberately selects smoke.

`--list-cases` lists the matrix. Direct execution supports the same case/batch
options, `--profile`, `--seed`, `--duration-seconds`, `--warmup-seconds`, `--output`
and `--common-report`; shared-driver environment requests are honored. Concurrency
is exactly one. Direct execution lacks independent signal/RSS/time supervision;
use the shared driver for retained performance evidence.

## Workload matrix

| Family | Cases | Dimensions and independent semantic oracle |
| --- | ---: | --- |
| Lossless JSON | 17 | Parse/serialize × 1/16/256 KiB × ASCII/Unicode; paired depths 1/8/64, widths 4/32/256. Authored canonical bytes and trees preserve huge numbers, exponent spelling and negative zero. Five exact malformed/size/depth rejections include parser offsets. |
| Independent JSON v2 | 24 | One-factor controls around 16 KiB/depth 2/width 4/16 string leaves: bytes 1/16/256 KiB, depth 2/8/32, width 4/32/128, string leaves 1/16/128, escaped-content byte share 0/25/100%, or ASCII/Unicode. Every control changes one dimension and retains exact document bytes. |
| Identifiers/bitsets | 14 | Snowflake parse/format includes zero, leading zeroes and UInt64 maximum. Parse/serialize/algebra/mutation × 64/256/4096 bits. Decimal-digit doubling and position sets independently prove every bit. |
| Models | 9 | Message decode, lossless model encode, field/unknown roundtrip × three sizes. Mentions 0/4/32, embeds 0/2/10, unknown fields 1/16/64, nesting 1/8/16; absent/null/value references and future numeric tokens remain distinct. |
| Builders | 10 | Legacy messages and V2 components × three sizes, plus contribution/node/row/text-size rejections. Independent wire trees, component grammar and safe mention policy accompany every case. |
| Permissions | 10 | Allow/deny × paired 1/16/128 assigned roles and overwrites, 64/256/4096-bit width. Owner/admin bypass and resource-limit/unknown-overwrite refusals have independently known results. |
| RPC frames | 17 | Encode × 1/16/256 KiB; incremental decode × those sizes × 7/256/4096-byte fragments. Independent little-endian wire bytes plus malformed-opcode, announced-size, append-size, truncation and encode-size rejections. |

The 24 new `json.v2.parse.*` / `json.v2.serialize.*` cases keep all 77 original
case identities and fixture bytes. Root member count, nesting, string leaf count,
escaping and literal Unicode vary independently at fixed 16 KiB; byte controls
keep the baseline shape fixed. The root contains numeric markers, one nested
string array and numeric filler members. `escapePercent` assigns that share of
each leaf's encoded content bytes to two-byte quote escapes, rounded down per
leaf; remaining bytes use ASCII or literal Unicode plus exact-byte ASCII padding.
Full tree equality, canonical bytes and inspected shape/escaping are correctness
evidence. These cases do not select an optimization or numerical budget.

Each case rotates four prepared variants using the recorded seed and wrapping
call index. SHA-256 binds prepared inputs; dimensions retain actual sizes/caps.
Timed code consumes a minimal checksum. Independent expected checksums and exact
rejection totals are checked after warmup and measurement. Full trees, bits, wire
bytes and public semantic results are asserted before warmup and after measurement.
Rejected cases count one expected rejection per call and use the rejected batch
population; unexpected errors fail the process.

Only the selected fixture family is constructed; only the selected case is
retained during measurement. Preparation includes model/tree parsing, wire
construction, fragment splitting and expected results. Measured decode includes
actual new parser/model/decoder state. Builders include one public
`message.jsonValue()` projection for minimal consumption; model encode uses the
supported lossless `jsonValue().serialized()` API. Preparation, full verification,
histogram updates, probes and writes stay outside individual batch timers.

## Report semantics

Native `DiscordFoundationBenchmarks` version 1 contains exact batch/call/rejection
and warmup counts, checksum/expected checksum, normalized batch mean and the common
version-1 report. Catalog revision 4 admits `pure.batch` version 1; readers retain
revisions 2/3. Common counts/histograms represent **batches**; native counts represent
**calls**. Throughput is completed calls per wall second.

Whole-population histograms use 1,000 ns absolute buckets over 0...100 ms. Values
outside range retain censored mass. P99 requires 10,000 **batches**, so smoke
normally reports insufficient tail data. Normalized mean is gross summed batch
duration divided by calls. A divided batch percentile is never presented as a
call percentile. No clock subtraction or percentile waterfall is performed.

Batch timing includes the call loop, closure dispatch, operation allocations and
minimal checksum/rejection consumption. Wall throughput also includes clocks,
cancellation/cap checks, histogram updates and counters. It excludes preparation,
full verification, resource probes and writes. CPU spans measurement plus baseline
resource probes; current RSS is after-population and peak RSS covers the process
lifetime including setup/warmup. Unsupported gauges are explicit unavailable values.
Allocation-event and exact retained-heap probes are not installed.

Completed smoke establishes local correctness, accounting and process cleanup.
Controlled-host stability, numerical baselines/budgets, individual-call tails,
other-platform performance and live Discord remain separate qualifications. See
the [validation record](../../Docs/Tasks/latency-timing/VALIDATION.md#phase-4-validation).
