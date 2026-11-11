<!--
File: Tools/DiscordDSLBenchmarks/README.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Independent offline DSL benchmarks

The benchmark package compares direct handwritten routes and real DSL
lowering through the same typed decoder, manual handler, existing `CommandRouter`
and `InteractionResponder`. It is a downstream package; no runtime product selects
it. It starts no listener and uses no credentials, hydration provider, registration
reconciler or remote transport. Synthetic normalized interactions bypass HTTP
signature verification and Gateway ingestion.
The executable sends SwiftLog diagnostics to stderr; stdout or `--output` contains only the JSON report.

Run from the repository root with Swift 6.4 or newer:

```sh
swift test --package-path Tools/DiscordDSLBenchmarks --explicit-target-dependency-import-check error
python3 -m unittest discover -s Tools/DiscordDSLBenchmarks/scripts -p 'test_*.py'
swift run -c release --package-path Tools/DiscordDSLBenchmarks DiscordDSLBenchmarks --output /tmp/dsl-runtime.json
python3 Tools/DiscordDSLBenchmarks/scripts/compile_benchmarks.py --output /tmp/dsl-compile.json
```

The default runtime matrix performs **1,000,000 invocations for each direct/DSL path
at 10, 100 and 1,000 declarations**: six million invocations in total, eight offered
workers, a fixed 64-byte string, and at most 10,000 latency samples per path. Each
worker reuses fixed input snapshots, schemas and the router. A fresh typed argument
value and response owner are created per invocation. Sink validation checks the
exact callback payload, and every child is joined before measurements finish.
No live registration limits or connection counts are inferred from declarations.

| Option | Default | Valid range |
| --- | --- | --- |
| `--invocations` | 1,000,000 per workload | 1...10,000,000 |
| `--handlers` | `10,100,1000` | Unique nonempty subset of those counts |
| `--concurrency` | 8 | 1...64 |
| `--payload-bytes` | 64 | 1...1,024 ASCII bytes |
| `--sample-limit` | 10,000 | 1...100,000 |
| `--minimum-duration-seconds` | 0 | 0...1,800 per workload |
| `--output` | stdout | Explicit local JSON destination |

Duration-floor execution repeats the same population after the invocation floor;
it fails at a hard 100,000,000-invocation ceiling. Memory observations retain at
most 121 checkpoints. A focused sustained handler run is:

```sh
swift run -c release --package-path Tools/DiscordDSLBenchmarks DiscordDSLBenchmarks --handlers 1000 --invocations 1000000 --minimum-duration-seconds 60 --output /tmp/dsl-handler-soak.json
```

Reports identify exact dimensions and hardware/compiler metadata. Plan compilation
measures schema/definition authoring, DSL lowering where selected, and router
admission; fixed interaction preparation is outside that timer. Invocation timing
includes fresh response ownership, decoding, routing, handler execution and callback
validation. Throughput includes all successful invocations and worker-round joins.
Quantiles use a bounded **prefix** sample and nearest rank; they are not an unbiased
full-duration latency distribution. Direct runs precede DSL runs. Runtime warm-up,
allocator history, instrumentation and concurrent host work affect observations;
these measurements do not isolate a causal abstraction overhead.

Accounted state records finite retained JSON bytes and cardinality limits, not every
Swift object or exact heap size. macOS reports actual current/peak RSS and live malloc
blocks/bytes. Linux currently reports actual peak RSS; unsupported current RSS/live
allocator gauges are omitted. Live allocations are not cumulative allocation events.

Linux hardware-model receipts use bounded DMI product-name or ARM device-tree
model evidence. Unsupported, missing and placeholder models remain `unavailable`;
the architecture string cannot qualify a numerical baseline. The shared
[Phase 10 comparison driver](../DiscordBenchmarkSupport/README.md) separately
records the named host and effective CPU/memory allocation. Legacy v1 environment
keys remain unchanged, and historical architecture-only Linux artifacts are not
new controlled-host baselines.
CPU and peak RSS are process-wide, and earlier matrix rows affect later observations.
All owned active handler/worker/acknowledgement counters must be zero after cleanup;
allocator page retention is reported separately.

The compiler script generates six independent executable consumers with concrete
manual or macro handlers, ten declarations per file. The same Swift toolchain and
native SwiftPM build engine measure both paths. Dependency/plugin bootstrap is
reported separately. A clean consumer build deletes only that consumer's outputs,
keeping dependencies and the macro plugin warm; it includes SwiftPM planning,
type checking, code generation and linking. Incremental builds edit one literal in
the first handler file and restore the source even on failure. Each executable
constructs its catalog and verifies the exact declaration/route count without
executing handlers. Compiler maximum RSS is the maximum-resident-set observation reported by `time`
for each build command, not a sum of simultaneous compiler-process RSS or an
instantaneous whole-host memory measurement.

`--samples` accepts 1...5 (default 1), `--jobs` 1...32 (default 4), and per-build
`--timeout` 1...3,600 seconds (default 1,800). The workspace must be empty or marked
by the runner; it defaults to the ignored root build directory. Use `--workspace`
and `--cache-path` for isolated writable paths. Pinned dependencies must already be
available to the selected cache; resolution and dependency updates are disabled.
Measurements use the native backend without its optional explicit-import checker;
the repository's independent graph/import audit checks product isolation separately.

Record observations **before** choosing tolerances:

```sh
python3 Tools/DiscordDSLBenchmarks/scripts/baseline.py record --compile-report /tmp/dsl-compile.json --runtime-report /tmp/dsl-runtime.json --output /tmp/dsl-baseline.json
python3 Tools/DiscordDSLBenchmarks/scripts/baseline.py budgets --baseline /tmp/dsl-baseline.json --output /tmp/dsl-budgets.json
python3 Tools/DiscordDSLBenchmarks/scripts/baseline.py check --baseline /tmp/dsl-baseline.json --budgets /tmp/dsl-budgets.json --compile-report /tmp/dsl-compile.json --runtime-report /tmp/dsl-runtime.json --output /tmp/dsl-check.json
```

After inspecting the first recorded submillisecond invocation observations, the
reviewed budgets use 10% relative tolerances, a 1 microsecond absolute timing floor
and a 1 MiB RSS/live-byte floor. The timing floor is an observation tolerance,
not a clock-resolution claim. Every collected cost metric receives a finite
bound; throughput has a minimum and time/state/memory have maxima. Hard functional
invariants are checked separately and are never relaxed by tolerances. Baseline
and budgets are hash-bound; hardware, compiler, configuration, compiler fixture and
resolution identities must match. The complete six-row matrices are required.
Reduced CI smoke runs cannot substitute for the qualified default matrix.
A single overrun fails the local check. Three matching runs are required before
attributing a >10% regression to a change. A first baseline self-check validates
budget wiring; it does not establish a comparison against a previous implementation.

The committed [benchmark evidence](../../Docs/Release/dsl-benchmarks-validation.json) records
actual commands, sources, executable identities, timings and limitations. The
existing [cache/broadcast 30-minute soak](../DiscordKitLoadTests/README.md) and the
new handler soak remain independent evidence. Neither establishes production/fleet
capacity, live Discord, HTTP/Gateway host throughput, another platform, hardware,
independent crypto review or full release certification.


## Shared timing sidecars

This tool adopts the development-only [shared harness](../DiscordBenchmarkSupport/README.md).
Set `DK_BENCHMARK_ENVELOPE` to write a separate schema-v1 common envelope while
retaining the native report. New whole-population histograms have distinct metric
identities and explicit precision, censor/loss counts and qualification limits.
Use the shared process driver for release receipts, bounded fresh-process runs and
partial artifacts. Legacy baseline readers remain available.

`--mode direct` or `--mode dsl` selects one path per fresh process;
`--warmup-invocations` selects up to 1,000,000 unmeasured same-plan calls before
measurement, bounded by 60 seconds. Defaults retain the paired matrix and zero
explicit warmup. Native counters exclude these warmup calls; process-wide memory
peaks still include them. The sidecar records the declared warmup population.

## Stage 7 authoring populations

The opt-in `authoring` subcommand produces catalog revision 7 evidence with a
native details object and a validated common envelope. The existing executable
options, v1 paired reports and baseline readers retain their original behavior.
Each process selects one direct/DSL mode, declaration count and module fan-out.
Both paths execute the same schema decoder, real `CommandPolicies` authorization
and middleware, manual handler, exact initial callback oracle and fresh response
owner. The handwritten path is explicitly adopted through `ExistingCommandFamily`.

```sh
swift run -c release --package-path Tools/DiscordDSLBenchmarks DiscordDSLBenchmarks authoring --mode dsl --handlers 10 --modules 2 --invocations 128 --definitions 3 --warmup-invocations 16 --common-report /tmp/authoring-common.json --output /tmp/authoring-native.json
```

Definitions and runtime invocations are separate populations. `dsl.definition`
measures schema/declaration creation, explicit module lowering, policy application
and validated catalog output. It excludes router admission, fixed input
parsing, response-sink construction, process probes and compiler-process costs.
The final catalog handles every measured invocation without another schema capture.
Warmup uses separate owners, finishes before definition and invocation populations,
and contributes no phase histogram or measured response counter.

`dsl.invoke` includes fresh responder/context construction, routing and exact
response/state validation. Existing real owner hooks produce `command.route`,
`command.arguments`, `command.handler` and `interaction.initialResponse`.
`dsl.policy` spans the complete applied policy including authorization, middleware,
handler/response and joined continuation cleanup. `dsl.middleware` spans its body
through the awaited handler/response continuation. These intervals nest and overlap;
their percentiles cannot be added or subtracted. Every histogram covers its entire
measured population and retains explicit censor/loss counts. Successful runs require
exact definition, decode, policy, middleware, handler and response counts, unchanged
runtime schema counts, and zero remaining workers/handlers/acknowledgement owners.

The authoring CLI accepts modes `direct`/`dsl`, handlers `10`/`100`/`1000`, modules
`1...min(handlers,100)`, definitions `1...100`, invocations `1...1000000`, warmup
invocations `0...1000000`, and concurrency `1...64` no greater than invocations.
`--profile`, `--seed`, `--duration-seconds`, `--warmup-seconds`, `--output`, and
`--common-report` integrate with the shared supervisor. Warmup has a 60-second cap;
measured caps are 10 seconds for smoke, 300 for standard/stress, and 3600 for soak.
In-process caps are cooperative between finite rounds; the shared supervisor adds
an enforced process timeout and awaited group teardown.

Use the wrapper for process memory comparisons and counterbalanced order. Build
the release receipt after finishing source edits, then use its executable path:

```sh
python3 Tools/DiscordBenchmarkSupport/scripts/run_benchmarks.py build --package Tools/DiscordDSLBenchmarks --product DiscordDSLBenchmarks --receipt .build/authoring-release.json --repository .
python3 Tools/DiscordDSLBenchmarks/scripts/run_authoring.py --executable "$(swift build -c release --package-path Tools/DiscordDSLBenchmarks --show-bin-path)/DiscordDSLBenchmarks" --receipt .build/authoring-release.json --output-dir .build/authoring-smoke
```

`--profile standard` runs five paired fresh-process repetitions and alternates the
first mode. Smoke runs one seeded pair, so it checks integrity without establishing
order-independent numerical performance. Process RSS/CPU include setup, definition
builds, warmup and invocation execution within the selected mode; they never mean
per-row allocation counts. Retained plans and allocator pages can affect gauges.
No optional module-extension package is imported or qualified by this suite.

## Separate Stage 7 compiler receipts

The compiler script retains its native v1 format and adds catalog7 integer
`wallNanoseconds`, generated manifest/source and dependency pin hashes, build
command and target receipts. Manual/macro clean and incremental builds stay in
separate populations. `--handlers 10` selects a reduced functional smoke matrix;
`--modules N` partitions concrete ten-handler files into `N` inert modules, up to
`smallestSelectedHandlerCount / 10`. Every source is restored after the controlled
incremental edit, including failures. Module-aware generated fixtures require new
fixture-bound baselines; historical reports remain readable.

```sh
python3 Tools/DiscordDSLBenchmarks/scripts/compile_benchmarks.py --handlers 10 --modules 1 --output /tmp/compiler-native.json
swift run -c release --package-path Tools/DiscordDSLBenchmarks DiscordDSLBenchmarks compiler-report --input /tmp/compiler-native.json --mode manual --handlers 10 --output /tmp/compiler-manual-common.json
swift run -c release --package-path Tools/DiscordDSLBenchmarks DiscordDSLBenchmarks compiler-report --input /tmp/compiler-native.json --mode macro --handlers 10 --output /tmp/compiler-macro-common.json
```

The converter selects exactly one mode/population and uses shared bounded
histograms with one-second cells over zero through one hour. Raw integer duration
observations, including censored values, supply `compiler.clean` and
`compiler.incremental`; legacy percentiles or floating summaries cannot substitute.
The dependency/plugin bootstrap and fixture mutation/restoration remain outside
these timers. Gross supervised duration includes bounded output collection, RSS
probes, process-group teardown and reap. Receipt serialization follows its endpoint.
The shared supervisor owns finite diagnostics and signal/timeout cleanup, including
descendants; the compiler driver restores temporary signal handlers afterward. The native compiler
artifact retains per-sample binary hashes and full build/target evidence. Its
source hash is not claimed as a complete dirty-tree fingerprint. One to five
samples cannot qualify p99 tails or a numerical regression baseline. Optional
extension-package installations remain outside this compiler fixture.
