[//]: # "File: Sources/DiscordLogHandlers/DiscordLogHandlers.docc/Guides/TimingOutputs.md | Created by Carson Rau. | Copyright (c) 2026 Aurum Studios. | https://aurum-studios.com"

# Timing output ownership

Choose bounded timing outputs explicitly, and export after producers join.

## Composition

The optional output product consumes `DiscordLogging`'s finite numeric values.
Runtime owners never select these adapters. A scalar observation contains an
elapsed duration and finite phase/outcome only; it cannot create a historical
begin, operation identity, parent or Instruments interval. Transport provides
`OperationTimingSample.observation` for application composition.

```swift
import DiscordLogging
import DiscordLogHandlers
import DiscordTransport

let aggregate = try DiscordTimingAggregate()
let capture = try DiscordIntervalCapture(configuration: .init(
    maximumRecords: 4_096, maximumBytes: 1_024 * 1_024,
    maximumActiveIntervals: 128, sampleEvery: 10, seed: 7))
let intervals = DiscordIntervalTiming(clockDomain: 1, sink: { event in
    aggregate.record(event)       // Full terminal population.
    capture.record(event)         // Independently selected detailed population.
})
let timing = OperationTiming(sink: { sample in
    aggregate.record(sample.observation) // Separate scalar rows; no invented trace.
})
// Inject intervals and/or timing into the runtime owners you compose.
// After all producer tasks join:
capture.close()
let summary = aggregate.snapshot()
let ndjson = try capture.ndjson()
let timeline = try capture.chromeTrace()
// Encode/write summary and returned Data on your application's output path.
```

Aggregate all observations independently from selecting a detailed trace. Capture
and aggregate recording perform numeric updates without file writes. SwiftLog
records, callback output, rotating files and signposts consume synchronous caller
time; do not call them from realtime audio or cryptographic sample loops.
No adapter bootstraps SwiftLog, starts a task, exports over the network or owns
the observed operation's cancellation/result.

``DiscordTimingAggregate`` preallocates finite histogram/key capacity, with
separate scalar and detailed rows and explicit invalid, censored and dropped
counts. Its 64 logarithmic buckets describe ranges. Finite extrema cannot qualify
a complete tail when censored/lost observations exist. Snapshot and JSON encoding
are explicit end-of-run work; retained IDs never become aggregate dimensions.
``DiscordTimingLogAdapter`` emits only fixed timing events and finite/numeric
metadata. The supplied logger's label, base metadata and provider remain the
application's privacy responsibility, and filtering happens before rendering.

## Recipe: aggregate-only timing

Collect a full terminal population without retaining interval identities or enabling
SwiftLog. Select scalar samples or detailed owner hooks according to the boundary:

```swift
let aggregate = try DiscordTimingAggregate(configuration: .init(
    lowerBoundNanoseconds: 0, upperBoundNanoseconds: 60_000_000_000,
    maximumKeys: 236, maximumObservationsPerKey: 1_000_000))
let intervals = DiscordIntervalTiming(clockDomain: 1, sink: { aggregate.record($0) })
let timing = OperationTiming(sink: { aggregate.record($0.observation) })
// Inject the selected option into cooperating owners and run the workload.
// Stop and join every producer before taking the final snapshot.
let data = try JSONEncoder().encode(aggregate.snapshot())
// Write data outside the measured operation; the aggregate has no close or file handle.
```

Import `Foundation` for `JSONEncoder`. Detailed begins increment `ignoredBeginCount`
without retaining pairing history. Scalar and detailed rows can overlap in meaning;
retain their separate populations and denominators. The 64 logarithmic buckets
establish ranges, not exact p95 or p99 values. Report `invalidCount`, `droppedCount`,
counter saturation and each row's underflow/overflow beside its distribution.
This aggregate cannot detect missing terminal hooks: reconcile workload
admitted/completed counts or use a bounded paired capture.

## Recipe: one correlated operation

For a short investigation choose `sampleEvery: 1` and inject the same observer into
every participating owner. The offline `LoggingApp` exercises actual cache
projection, nested lookup/merge, caller lookup and invalidation. Its application
diagnostic scope uses this pattern:

```swift
let adapter = DiscordTimingLogAdapter(logger: DiscordLog.makeLogger("example.logging"))
let intervals = DiscordIntervalTiming(clockDomain: 1, sink: { event in
    aggregate.record(event)
    capture.record(event)
    adapter.record(event)
})
```

Construct the adapter's logger inside `DiscordLog.withOperation` to copy that
diagnostic context. Diagnostic `dk.trace_id`/`dk.span_id` UUIDs identify logging
scopes; numeric interval namespace/operation/parent IDs identify owner boundaries.
They are independent. `withOperation` does not install a numeric parent. Owners
install `DiscordIntervalScope.context` around their children; capture and restore
that context explicitly across shared-reader or unrelated callback work.
Every observer using one `clockDomain` must share its exact monotonic source and
origin. Actor intervals normally start after actor admission, excluding preceding
caller wait unless the owner documents a wrapper around that wait.

## Recipe: bounded slow-operation investigation

Use a finite incident window with all roots selected (`sampleEvery: 1`), bounded
concurrency and explicit endpoint/byte/active limits. Join producers, close capture,
then inspect complete records whose `durationNanoseconds` exceeds the chosen
threshold. Keep the unfiltered summary and parent/child records beside the slow
records. If the window exceeds capacity, split it into shorter, independently
owned captures and preserve each window's loss counters.

This is bounded head capture followed by slow-record inspection. Selection occurs
at root begin, before latency or outcome is known. `sampleEvery: 10` hashes the
recorded seed and ephemeral root identity; tracked descendants inherit that choice.
The seed alone cannot reproduce choices across runs with newly random observer
namespaces. No duration-triggered tail sampler, rolling buffer or guarantee of
retaining every slow operation is provided. Enabling capture after a slow terminal
cannot recover earlier endpoints. Correlate a sampled slow trace with the
independent full aggregate; do not present that sample as the full latency tail.

## Recipe: trace files

The standalone example retains a verified, credential-free capture. Run from the
repository root; the selected output directory must not already exist:

```sh
capture_root=$(mktemp -d)
swift run --package-path Examples/LoggingApp LoggingApp \
  --output-directory "$capture_root/run"
```

Outputs are `discordkit.ndjson` (rotating SwiftLog diagnostics), `aggregate.json`
(full numeric histogram rows), `intervals.ndjson` (summary plus paired or incomplete
evidence), and `timeline.json` (Chrome Trace Event format). Open the timeline in a
compatible local trace viewer. These formats are separate; SwiftLog NDJSON is not
an interval timeline. The example verifies cache cleanup, loss, correlation and its
diagnostic writer before exit. Without `--output-directory` it removes temporary
output after verification. See the repository's measurement guide for workload
selection, report interpretation and compatible-machine comparisons.

Numeric endpoint offsets and durations are signed integer nanoseconds from a
monotonic origin, never wall-clock timestamps. Chrome trace `ts` and `dur` use
microseconds; exact nanosecond values remain in event arguments. Clock domains
occupy separate tracks. Do not combine origins or reconstruct starts by subtracting
scalar durations from later timestamps. Aggregate histogram bounds are nanoseconds;
`dk.duration_ns` is decimal nanoseconds.

## Capture, loss and close

``DiscordIntervalCapture`` retains at most its configured finite record, byte and
active-context budgets. Seeded head selection follows a known parent's decision;
bounded state exhaustion or a missing parent cannot promise a complete trace.
Inspect sampling, capacity, late-record and unmatched/incomplete accounting.
Losing one endpoint must remain visible even when the other endpoint was retained.
Excluded roots still consume bounded active-decision state so descendants follow
the same choice. Recording takes a lock; active lookup cost is linear in the
configured concurrent ceiling. `maximumBytes` bounds numeric payload, including
reserved active decisions; bounded container/allocator overhead is additional.
Exports have a separate 32 MiB ceiling and can fail explicitly.

Join all producer tasks before calling `close()`. Close is idempotent and prevents
new admission. Export NDJSON and a Chrome trace timeline on the application's
output path after close; serialization and destination writes belong outside the
measured operation. Unmatched and invalid endpoints do not acquire invented
durations. A live snapshot can include work that has genuinely not ended yet.
Producers racing with close can be counted as late; close does not join them.

## Recipe: Apple Instruments

On an Apple host, add the convenience adapter to genuine live callbacks:

```swift
#if canImport(os)
let signposts = try DiscordIntervalSignposts(
    maximumActiveIntervals: 128, subsystem: "MyApplication", category: "Intervals")
let intervals = DiscordIntervalTiming(clockDomain: 1, sink: { event in
    aggregate.record(event)
    signposts.record(event)
})
// Run and join producers, then signposts.close() and inspect its snapshot.
#endif
```

Build the offline example as a release executable and launch a separate profiler
run. Check installed template names with `xcrun xctrace list templates`:

```sh
swift build --package-path Examples/LoggingApp -c release
binary_dir=$(swift build --package-path Examples/LoggingApp -c release --show-bin-path)
capture_root=$(mktemp -d)
xcrun xctrace record --template 'Points of Interest' \
  --output "$capture_root/LoggingApp.trace" \
  --launch -- "$binary_dir/LoggingApp" --instruments \
  --output-directory "$capture_root/run"
```

In Instruments select `DiscordKit.LoggingApp` / `Intervals` and the fixed
`DiscordInterval` name. Inspect numeric operation/stage/parent metadata and compare
genuine completed intervals. `incomplete` cleanup marks missing/invalid ends;
exclude it from completed-duration analysis. Inspect adapter begun/ended/active,
dropped, unmatched and incomplete counters even when the profiler has no visible
events. A short demo can be hard to see at the default timeline zoom.

``DiscordIntervalSignposts`` pairs actual begin/end callbacks with bounded active
signpost state. Its explicit close releases remaining profiler state as incomplete.
Numeric export preserves the recorded monotonic endpoint offsets. Instruments
records live callback delivery time, including scheduling and preceding observer
delay; the adapter cannot backdate a profiler interval to a supplied offset.

Use a separate Instruments capture run. Profiler availability and enablement are
different from portable report correctness. See Apple's
[recording performance data](https://developer.apple.com/documentation/os/recording-performance-data)
and [OSSignposter](https://developer.apple.com/documentation/os/ossignposter)
guides. Other platforms retain numeric outputs without requiring Apple frameworks.

## Benchmark interpretation

The development timing executable compares gross costs of explicit modes, including
filtered diagnostic scopes. Warmup and close/export have separate boundaries.
Do not subtract the empty harness or clock-read row from every operation, add
overlapping percentiles, or treat a normalized batch tail as an individual-call
tail. Loss, output failures, concurrency, CPU and resource availability accompany
latency and throughput. A successful local smoke establishes integrity and
bounded cleanup, not a numerical baseline or a deployment qualification.
