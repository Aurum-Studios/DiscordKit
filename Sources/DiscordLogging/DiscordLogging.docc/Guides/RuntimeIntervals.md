[//]: # "File: Sources/DiscordLogging/DiscordLogging.docc/Guides/RuntimeIntervals.md | Created by Carson Rau. | Copyright (c) 2026 Aurum Studios. | https://aurum-studios.com"

# Runtime intervals

Observe actual owner boundaries with optional, content-free numeric lifecycle hooks.

## Configuration and lifetime

Create one ``DiscordIntervalTiming`` and pass it through the `intervals` option of
cooperating REST, Gateway shard/hub/dispatcher, signed ingress, command router,
interaction response, entity cache and client lifecycle owners. It works
without configuring SwiftLog. `clockDomain` identifies one run-local monotonic
origin and clock source; every observer accepting the same domain must use that
exact origin/source. Custom clocks and sinks must be prompt and concurrent-safe.
The default clock returns system uptime. Nil owner options perform no interval
clock reads, identity allocation or sink callbacks.

```swift
let intervals = DiscordIntervalTiming(clockDomain: 1, sink: { event in
    // Update application-owned, bounded numeric observation storage.
    // Keep callbacks prompt, concurrent-safe and free of owner reentry or I/O.
})
```

The value starts no tasks and retains no event history. Each ``DiscordInterval``
handle holds fixed-size state and permits at most one terminal event. Explicitly
call `end` after the operation's existing cleanup. Repeated/concurrent calls do
not read the clock again; the first caller owns delivery. Dropping an unfinished
handle leaves an incomplete interval. It never invents a successful terminal or
cancels the operation. Consumers must account for missing endpoints and their own
retention losses. Automatic output, sampling, histograms and signposts are separate
adapters, not enabled by constructing this value.

## Correlation and clocks

``DiscordIntervalScope/context`` carries one fixed-size numeric context. Structured
children inherit it. At an actor, callback or shared-reader boundary, the owner
captures and restores that context explicitly where needed. Detached tasks and
unrelated later callers cannot be assumed to share context. Public `begin` accepts
an explicit parent or nil for independent work. A different clock domain detaches
the parent and marks the observation invalid; a duration is not manufactured.
Numeric IDs use a random observer namespace and a nonwrapping local sequence;
copies share the allocator. IDs are ephemeral correlation, never metric labels,
persistent Discord identity, permissions or receipt trust. Existing diagnostic
trace/span UUIDs remain independent.

Context does not propagate merely because two calls reach the same actor. Capture
the current context when handing off work and restore that exact value around its
later owned callback. Pass `parent: nil` to `begin` when work is deliberately
independent. A shared operation can retain its initiating ancestry after that
subscriber has cancelled; ancestry does not transfer cancellation ownership.

Checked nonnegative signed 64-bit nanosecond offsets identify actual begin/end
boundaries. Endpoints truncate fractional nanoseconds toward zero; elapsed time
is their difference. Raw clock regression, including subnanosecond regression,
negative/overflowing offsets and mixed-domain parents have explicit validity
categories and no qualifying elapsed duration. No invalid observation silently
becomes valid zero latency.

## Owner boundaries and callback cost

One REST caller owns its logical operation. Each actual send has a distinct
one-based exchange attempt and admission/header/body children. Coalesced callers
have independent subscriber intervals; wire work runs once. The shared exchange
retains its initiating context even if that subscriber cancels, and can outlive
that caller while another subscriber remains. This ancestry grants no cancellation
ownership. A fresh cache hit has no fabricated exchange. Wire success means the
wire boundary completed; a complete HTTP error response can still fail API acceptance.

Gateway queue, shared admission and callback intervals are siblings under the
joined dispatcher run. Handler descendants inherit their handler context. Queue
and handler stages do not yet carry a shared per-event identity, so these hooks
cannot reconstruct a per-event waterfall. Queue cancellation closes after joined
cleanup. Callback timing ends before shared permit release; the run includes that
release and subscription cleanup. Response intervals start at actor owner entry,
excluding preceding actor residence; initial response and edit intervals include
existing owned release and cleanup. An auto-defer handler includes its timer join.

Timestamps are captured before each synchronous sink. Begin callback cost, child
callbacks and earlier terminal callbacks can remain inside later/enclosing
intervals. Legacy scalar callbacks run in their existing order before detailed
terminal callbacks. Observer time can consume a deadline and remains visible in
gross end-to-end observations. Sinks run outside internal identity/terminal locks,
may interleave across intervals, must not recursively log themselves, and must
not control or reenter the observed owner. There is no task per observation.

## Existing scalar observations and qualification

`OperationTimingSample` retains all fourteen phases, four outcomes, duration clamp
and existing boundaries. Its synchronous `OperationTiming` sink remains the direct
scalar-to-aggregation seam. A scalar sample has no start, operation identity or
explicit clock provenance; never reconstruct a detailed begin or profiler interval
by subtracting its duration from a later timestamp. Trusted Gateway scalar receipt
age remains private provenance. Public receipt offsets and replay events cannot
create trusted detailed socket-receipt intervals.

Gateway shard hooks now cover supported JSON receipt/decode, retained ingestion,
confirmed-write heartbeat ACK, reconnect and joined shutdown. Hub hooks cover
owner publication and each subscription's retained copy until removal/discard.
These remain separate from dispatcher queue/admission/handler observations.

Signed HTTP owners accept the observer independently on the verifier, ingress and
application. Body read/close, signature verification, replay admission, typed decode,
first confirmed inline response and complete workflow have distinct boundaries.
Application entry is not trusted listener receipt. Command routing wraps caller
entry before the actor hop, then observes admission, complete preparation and
execution. A successful initial response can precede a later workflow failure.

The first HTTP response clock is constructed before interval callbacks. Workflow
begin precedes first-response begin, so its begin callback is excluded from that
child interval while still consuming the original acknowledgement budget.
Observers never extend deadlines or supply permission to retry uncertain sends.

Entity cache hooks distinguish lookup, sparse merge, event projection, invalidation,
refresh subscriber and shared loader. They start inside the owning actor, after
admission. One projection can emit nested lookup/merge intervals; one shared loader
can serve several refresh subscribers. Local client construction, discovery,
ingestion, local-ready and joined shutdown are separate boundaries. Local readiness
does not establish live Discord READY or successful remote work.

All detailed boundaries use the same nanosecond endpoint and validity contract
above. Each terminal outcome classifies that boundary only. Parent/child intervals
can overlap; summing them or subtracting percentile rows cannot establish a new
latency. Include invalid data, missing endpoints and adapter loss beside any
derived distribution. For complete end-to-end distributions, time the caller's
actual entry through joined result directly and reconcile workload populations.

These hooks establish local timing semantics. Optional bounded outputs and local
benchmarks have separate explicit lifetimes. Controlled performance baselines,
hosted/platform and live Discord qualification remain separate work.
