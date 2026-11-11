<!--
File: Examples/LoggingApp/README.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Offline logging and timing consumer

```sh
swift build --package-path Examples/LoggingApp
swift test --package-path Examples/LoggingApp
swift run --package-path Examples/LoggingApp
```

The standalone process bootstraps SwiftLog exactly once. It multiplexes an info-level
console with a trace-level rotating NDJSON file, injects a dynamic metadata provider,
applies dotted component thresholds and scoped context, emits semantic `info`/`notice`
events and triggers one synthetic transport deadline inside a correlated operation.
It also observes actual `EntityCache` projection, nested lookup/merge, caller lookup
and invalidation. One observer forwards genuine endpoints to a bounded aggregate,
all-root capture and trace-level logging adapter. No credentials, network or devices
are used. Runtime products do not select output handlers.

Before exit it joins/closes the cache, verifies zero entries/bytes/refreshes/waiters,
closes capture, and verifies five complete intervals, ten endpoints and no lost,
invalid, sampled-out or incomplete observations. It closes the diagnostic writer
and verifies semantic/subsystem records, provider/scoped context, trace/span
correlation and monotonic completion timing. Default runs remove temporary output.
Tests exercise owner ancestry, exports, argument parsing and exclusive output
admission without reconfiguring process-global SwiftLog.

## Retain a trace file

Run from the repository root. The output directory's parent must exist and the
selected directory must be new. Atomic admission rejects existing paths before
opening a writer, so a repeated command preserves an earlier capture:

```sh
capture_root=$(mktemp -d)
swift run --package-path Examples/LoggingApp LoggingApp \
  --output-directory "$capture_root/run"
```

The four artifacts have different consumers:

| Artifact | Interpretation |
| --- | --- |
| `discordkit.ndjson` | SwiftLog diagnostics and fixed timing records, with scope/provider metadata. |
| `aggregate.json` | Full terminal histogram population with finite range and loss/invalid counters. |
| `intervals.ndjson` | Capture summary, parent IDs, exact nanosecond endpoints and paired/incomplete evidence. |
| `timeline.json` | Chrome Trace Event format for a compatible local viewer; `ts`/`dur` use microseconds, exact nanoseconds remain in args. |

The example selects every root within finite budgets: 64 endpoints, 32 KiB numeric
payload and eight active decisions. Its uptime source and run-local clock domain
are shared by owner hooks. Application diagnostic UUIDs and numeric interval IDs
remain independent. Synchronous trace formatting/file writes add observer cost;
these durations are a functional demonstration, not a baseline. The aggregate's
logarithmic histogram buckets describe ranges and cannot supply exact p99s.

For bounded slow-operation investigation, retain a short all-root window, then
inspect complete records above a chosen threshold after close. This prints the
capture accounting and any projection taking at least 100 microseconds:

```sh
python3 - "$capture_root/run/intervals.ndjson" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    records = [json.loads(line) for line in stream]
print(records[0])
for record in records[1:]:
    if (record.get("complete") and record.get("stage") == "cacheProjection"
            and record["durationNanoseconds"] >= 100_000):
        print(record)
PY
```

Keep the full capture and parent/child evidence. This is head capture followed by
threshold inspection; the adapter offers no tail sampler or rolling buffer.
Increasing `sampleEvery` selects roots before latency is known and can miss slow
operations. Capacity loss is separate from intentional sampling. Export and writes
occur after measured work; closing outputs does not join producers.

## Apple Instruments

`--instruments` explicitly adds bounded live signposts on Apple hosts. It still
verifies portable artifacts. Run a separate profiler capture:

```sh
swift build --package-path Examples/LoggingApp -c release
binary_dir=$(swift build --package-path Examples/LoggingApp -c release --show-bin-path)
capture_root=$(mktemp -d)
xcrun xctrace list templates
xcrun xctrace record --template 'Points of Interest' \
  --output "$capture_root/LoggingApp.trace" \
  --launch -- "$binary_dir/LoggingApp" --instruments \
  --output-directory "$capture_root/run"
```

Use an installed template containing signposts. Select `DiscordKit.LoggingApp`,
category `Intervals` and name `DiscordInterval`. Genuine completed intervals
qualify; `incomplete` labels identify cleanup. Profiler times are live callback
delivery times, including observer/scheduling delay, and cannot be backdated to
numeric uptime offsets. Adapter pairing success does not establish that OS
recording was enabled or visible. The short demo may require timeline zoom.

See [logging adoption](../../Docs/Logging.md), [runtime timing recipes](../../Sources/DiscordLogHandlers/DiscordLogHandlers.docc/Guides/TimingOutputs.md)
and the [measurement guide](../../Docs/Measurements.md) for population, observer
cost/loss, comparison and qualification contracts. Local example success does not
qualify hosted CI, live Discord, physical devices or production capacity.
