# Measuring owned operations

Observe protocol boundaries with fixed categories and numeric durations.

## Overview

Pass one optional ``OperationTiming`` value to cooperating REST, Gateway and
interaction owners. Its synchronous nonthrowing sink may run concurrently and
must return promptly. Construction reads no clock and starts no task. Omitting
`timing` performs no instrumentation-clock reads, timing scopes or observer work;
existing clocks used for deadlines and trusted receipt age remain necessary.
The observer stores no samples, identifiers or correlation registry. The caller
owns any finite aggregation and retention. Do not add payload, route, URL, token,
user, guild or arbitrary error labels to its output.

## Choose the boundary

``OperationTimingSample/Phase`` distinguishes local Gateway queue residence from
shared callback admission. Trusted receipt-to-admission includes earlier socket
and private-input residence; local queue timing begins only when the dispatcher
retains an event. Receipt-to-acknowledgement and admission-to-acknowledgement end
only after the initial response sink confirms success. Public replay events and
public responder receipt offsets cannot supply trusted Gateway provenance.

Initial-response timing includes the call's existing admission release and failure
cleanup. Original-edit timing ends on confirmed sink success or joined failure.
Acknowledgement-to-original-edit covers the first successful original edit after
confirmed initial delivery; handler return or a defer attempt is insufficient.
An uncertain send emits an uncertain outcome and never a successful delivery
sample. These observations grant no authority and authorize no retry.

HTTP exchange admission, transport headers and response-body collection are
separate phases. Headers do not establish API success; body timing includes EOF
or error and joined body cleanup. A shared read emits exchange phases once per
actual flight and a separate subscriber interval for each caller. A cancelled
subscriber does not cancel work still needed by another subscriber. Cache hits
have no exchange phases. Whole-run joined phases cover the full run/call and
its existing cleanup: their cancelled outcome is a milestone after ownership is
released, not a measurement of cancellation-only overhead.

## Connect a bounded destination

```swift
import DiscordTransport
import DiscordLogHandlers

let aggregate = try DiscordTimingAggregate()
let timing = OperationTiming(sink: { sample in
    aggregate.record(sample.observation)
})
// Inject timing, run the workload and join producers before aggregate.snapshot().
```

`DiscordLogHandlers` is an optional application output dependency; the transport
product does not acquire it. Its aggregate retains bounded numeric state without
formatting or I/O in this callback. Snapshot copying, encoding and file writes
belong outside the measured operation. Inspect accepted, invalid, dropped and
row-level censored counts before interpreting the finite histogram ranges.

Pass `timing` to `RESTClient`, `GatewayInteractionAdapter`, a standalone
`GatewayEventHandlerDispatcher`, or `InteractionResponder`. The adapter shares
it with its dispatcher and responders; HTTP clients still require explicit
injection. Use one monotonic origin across cooperating owners when injecting a
clock. Do not subtract percentiles from unrelated samples or pool subscriber and
exchange observations. A local injected peer does not qualify network, native
Linux, Discord-client or production latency. See <doc:TransportOwnership> and
<doc:ImplementingAdapters> for the unchanged ownership contracts.

## Scalar and detailed observations

Scalar samples contain Swift `Duration` values. Their output bridge uses checked
signed integer nanoseconds and marks an unrepresentable duration invalid. The
legacy sample initializer still clamps a negative/regressing elapsed duration to
zero; it does not retain raw endpoints or detailed clock validity. No scalar
sample supplies operation identity, parent context, start/end timestamps or a
historical profiler interval. Do not manufacture these by subtracting a scalar
duration from a later timestamp.

Use the independent `DiscordIntervalTiming` owner option for genuine begin/end
callbacks and numeric parent/attempt propagation. Its shared clock-domain/origin,
invalid-clock rules and once-only explicit termination apply to every detailed
hook. Both observation paths execute synchronously on their caller and may run
concurrently. Observer cost can consume deadline budget; it is present in gross
end-to-end measurements. A terminal callback's own cost is excluded from that
terminal's captured duration but can remain inside enclosing operations.

Applications own all sink lifetimes. Stop/join producers before closing paired
captures, profiler adapters or shared file writers; closing a destination does
not cancel or join its producers. Aggregate-only timing requires no close, while
sampled interval captures require explicit close before serialization. Pair loss,
sampling and capture capacity are separate from the scalar population.
