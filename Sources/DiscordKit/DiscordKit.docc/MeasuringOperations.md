[//]: # "File: Sources/DiscordKit/DiscordKit.docc/MeasuringOperations.md | Created by Carson Rau. | Copyright (c) 2026 Aurum Studios. | https://aurum-studios.com"

# Measure operations and investigate slow stages

Collect bounded timing evidence with explicit clocks, outcomes and output ownership.

## Overview

Select <doc:/DiscordLogging> for optional detailed lifecycle hooks and
<doc:/DiscordLogHandlers> for aggregate, capture and profiler adapters. Your
application owns the sinks and their lifetime. Runtime products never select the
development benchmark packages or start an exporter.

### Choose the measurement boundary

Scalar timing reports elapsed `Duration` at documented owner boundaries. It has
no original start timestamp or correlation identity. Detailed intervals carry
finite operation/stage tokens, ephemeral numeric contexts and offsets in one
monotonic clock domain. Structured work can inherit context; detached work,
callbacks and shared readers require deliberate propagation. Wall time and
different clock domains cannot be subtracted to obtain elapsed latency.

Measure an entire caller workflow directly. Nested stages overlap, coalesced
exchanges can serve independent subscribers, and success-only milestones omit
failed work. Never add phase percentiles into a waterfall. Interpret terminal
outcomes, rejection, deadlines and cleanup together with the latency distribution.

### Inspect one bounded capture

Build and run the credential-free logging example from the repository root:

```sh
swift run --package-path Examples/LoggingApp LoggingApp
```

It demonstrates actual local cache owner intervals, independent numeric
aggregation and bounded detailed capture, with joined shutdown. The example's
README describes artifact export and opt-in live Apple Instruments capture.
Head sampling selects roots before their duration is known. For a slow-operation
investigation, capture a finite selected window and inspect its retained intervals;
exhausted capacity or a missing endpoint cannot yield a complete tail trace.

Callbacks consume synchronous execution time. Nil detailed timing performs no
instrumentation clock reads; enabled aggregate, trace, logging and profiler modes
have distinct gross costs. Compare matching modes on a controlled host and keep
loss counters alongside the result. Export files after producers join and
application-owned capture/signpost adapters close. Keep output work outside
realtime sample loops.

### Reproduce a comparison

The repository's
[measurement guide](https://github.com/Aurum-Studios/DiscordKit/blob/main/Docs/Measurements.md)
indexes workload recipes, metric catalog, schema reference, compact summaries,
controlled-machine comparison and troubleshooting. Development tools use release
receipts and bounded fresh processes; deterministic virtual-clock tests prove
semantics rather than performance. Compiler workloads retain their separately
versioned build configuration.

The compact `DiscordBenchmarkReports summarize` view validates a common envelope
and retains each metric/outcome's histogram bounds, sparse p99, loss, resources
and qualification notes. A readable summary cannot qualify a failed, incompatible
or contended comparison. Five independent measured pairs and independent
no-change evidence precede reviewed budgets. Offline correctness and loopback
timing establish only their recorded scope; hosted, device and live-service
qualification require their own completed runs.
