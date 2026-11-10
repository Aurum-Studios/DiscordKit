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
let capture = try DiscordIntervalCapture(configuration: .init(sampleEvery: 10, seed: 7))
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

## Capture, loss and close

``DiscordIntervalCapture`` retains at most its configured finite record, byte and
active-context budgets. Seeded head selection follows a known parent's decision;
bounded state exhaustion or a missing parent cannot promise a complete trace.
Inspect sampling, capacity, late-record and unmatched/incomplete accounting.
Losing one endpoint must remain visible even when the other endpoint was retained.

Join all producer tasks before calling `close()`. Close is idempotent and prevents
new admission. Export NDJSON and a Chrome trace timeline on the application's
output path after close; serialization and destination writes belong outside the
measured operation. Unmatched and invalid endpoints do not acquire invented
durations. A live snapshot can include work that has genuinely not ended yet.
Producers racing with close can be counted as late; close does not join them.

## Apple profiling

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
