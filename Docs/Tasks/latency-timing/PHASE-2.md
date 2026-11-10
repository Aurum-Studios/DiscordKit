<!--
File: Docs/Tasks/latency-timing/PHASE-2.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 2 — Runtime interval hooks

Implemented 2026-11-10 from Phase 1 revision `2cbe0e10`. This record follows
[Stage 2](PLAN.md#stage-2--runtime-interval-hooks-and-deterministic-timing-semantics)
and the frozen [contracts](CONTRACTS.md). Completed results belong in the
[validation record](VALIDATION.md); this document does not establish a numerical
baseline, output-adapter qualification or live Discord behavior.

## Implementation plan

1. Add an independently usable detailed interval model to the existing
   `DiscordLogging` target. Use finite operation/stage/outcome values, ephemeral
   numeric correlation, an injected monotonic clock with explicit domain identity,
   and synchronous optional sinks. Keep all fourteen scalar timing phases and
   four outcomes, their initializers, their clamp and their existing endpoints.
2. Make every owner-started interval emit one terminal event under concurrent
   completion. Public handles require an explicit end; abandoned handles remain
   incomplete rather than inventing completion during deallocation.
   Capture endpoint timestamps before calling the sink, invoke sinks outside
   internal locks and retain no sample history. Flag clock regression, integer
   conversion overflow and mixed clock domains. Disabled owners bypass the new
   clock and sink entirely.
3. Carry bounded context through structured children and explicit owner boundaries.
   Keep a REST logical call, each actual exchange attempt and each coalesced
   subscriber separate. Shared work carries its exchange owner's context; a later
   subscriber cannot replace it. Cache hits create no wire attempt. Do not derive
   historical starts, operation identities or profiler events from scalar samples.
4. Add hooks to REST execution, Gateway dispatcher ownership and interaction
   response ownership. Retain real join, cancellation, uncertainty and confirmation
   boundaries. Scalar samples remain independently configurable; collection cost
   remains part of enclosing observed work where it actually executes.
5. Prove exact boundaries and ownership with virtual clocks and barriers; run root
   and affected consumer/load checks, declaration and documentation audits, and an
   independent review before the requested scoped commit.

## Model and boundaries

The detailed model is in
[DiscordIntervalTiming.swift](../../../Sources/DiscordLogging/DiscordIntervalTiming.swift).
`DiscordIntervalTiming` owns clock-domain identity, an injected offset clock and
the caller's nonthrowing observer. `begin` creates a `DiscordInterval`; the handle
exposes its bounded `DiscordIntervalContext`, and `end` records its terminal
outcome once. `DiscordIntervalScope` carries explicit task-local parent context.
Begin and end records contain finite operation/stage identities, ephemeral numeric
identities and checked timestamps. Each configured observer has a random numeric
namespace and a lock-protected nonwrapping sequence; copied observers share their
allocator. Context includes an optional direct parent and retry attempt. Same-domain
children inherit the attempt; a foreign-domain parent is detached and marks the
measurement invalid. Diagnostic UUID/string metadata remains separate.

Offsets must be nonnegative and representable as signed 64-bit nanoseconds. Each
endpoint truncates its fractional nanoseconds toward zero. A valid terminal reports
the difference between those checked endpoints. Raw clock comparison also detects
subnanosecond regression. Invalid observations retain an explicit validity category
and absent elapsed value rather than a fabricated valid zero duration. The first
`end` caller alone reads the clock and invokes the terminal sink; concurrent later
callers return without awaiting that first caller's delivery.

| Owner / stage | Actual endpoints and cleanup |
| --- | --- |
| REST logical operation | `execute` owner entry through result/error after its existing structured joins; each caller owns one interval |
| HTTP exchange operation | One `send` attempt, including rate admission, request preparation, headers, body close and rate completion; retries have distinct IDs and one-based attempt numbers |
| HTTP admission / headers / body | Real existing admission, adapter and body-collection boundaries; headers exclude later successful request-body cleanup, while failure retains its existing joined cleanup |
| HTTP subscriber | One coalescer caller's wait through result/cancellation; a surviving shared exchange retains its initiating logical parent and is not duplicated for later subscribers |
| Gateway dispatch operation | Dispatcher owner entry through all callback/input children and subscription cleanup; includes terminal diagnostic/callback costs that precede its endpoint |
| Gateway local queue | Retention in the dispatcher's pending array through removal for callback scheduling; discarded pending entries end after joined failure/cancellation cleanup |
| Gateway admission | Actual optional shared-authority acquisition wait, excluding callback execution and later permit release |
| Gateway handler | Admitted callback through the callback's joined return/error; shared-authority permit release follows this stage and remains inside the enclosing dispatcher operation |
| Interaction initial response / original edit | Actor owner entry through result/error and existing sink, admission/continuation and failure-capture cleanup; preceding caller-to-actor residence is excluded |
| Interaction admission / handler | Initial-response authority acquisition, or `runWithAutoDefer` through joined operation/timer children; distinct from a complete trusted interaction workflow |

Scalar boundary recording remains in its original relative position. Where both
modes are enabled, a later detailed endpoint includes preceding synchronous scalar
observer cost. A detailed start callback and nested/earlier terminal callbacks can
also be included in a later endpoint. Every endpoint excludes its own synchronous
sink invocation. These are gross observed intervals; callbacks are not treated as
free or subtracted after the fact.

Gateway queue, shared-admission and handler intervals are siblings under the
dispatcher-run interval. Handler descendants have their actual callback parent,
but there is no per-event operation identity linking that event's earlier queue
and admission stages to its handler when events overlap. These hooks cannot
reconstruct an individual event waterfall. Bounded per-event attribution remains
Stage 6 work.

The runtime model has no report writer, histogram, automatic sampling buffer,
exporter or process-global service. Applications own any retention and must honor
the frozen finite-capture ceilings. Sinks must return promptly, accept concurrent
calls, avoid reentry into their owners and avoid recursively logging themselves.
There is no task per observation. Calling a synchronous sink still consumes caller
time and can affect scheduling or deadlines.

`OperationTimingSample` remains a scalar observation. Its missing start timestamp,
identity and clock provenance cannot be reconstructed by subtracting its duration
from a later clock read. Detailed intervals begin only at an actual observed owner
boundary. Trusted Gateway receipt age remains available through its existing
private scalar path; it does not authorize a fabricated detailed socket-receipt
begin event. Public or replayed Gateway events retain their existing inability to
forge that receipt.

REST request construction, cache/decode/retry-wait attribution, transport pool/body
close metrics and corrected load-runner timer identities remain Stage 5. Gateway
decode/hub/heartbeat/reconnect, signed HTTP ingress, command routing and complete
interaction workflow attribution remain Stage 6. Stage 2 hooks establish runtime
ownership semantics without claiming those later catalog metrics are implemented.

Existing scalar observers remain the direct scalar-to-aggregation seam: an
application can consume `OperationTimingSample` without constructing a detailed
interval or pretending that it has correlated endpoints. Built-in timing outputs,
aggregate adapters, bounded capture/flush ownership,
Apple signposts and instrumentation-mode performance comparisons remain Stage 3.
No SwiftLog bootstrap, file/console output, optional voice dependency or development
benchmark package is added to a runtime product.

## Validation

Executed deterministic evidence includes exact elapsed intervals, once-only terminals, nested/concurrent and
explicit-boundary context, retries versus logical calls, cache hits, shared
subscribers, trusted-receipt restrictions, cancellation before/during work, joined
cleanup, failure/uncertainty, deadline races, invalid clocks and disabled zero-clock
and zero-callback behavior. Resource/sleeper counters return to their fixture
baseline. The full strict root run passed 2,556 tests across 34 executable summaries;
the load package passed 28 tests, and offline HTTP/Gateway smokes passed existing
accounting and cleanup validators. Reproduction commands and documentation/tooling
results are in the [validation record](VALIDATION.md#phase-2-validation).
Local semantic and fixture results do not establish observer overhead,
hosted CI, Linux, physical devices, live Discord delivery or deployment.

Independent read-only review checked the interval model, REST, dispatcher,
responder and trusted adapter changes against their new and existing semantic
tests. It found no blocking clock-arithmetic, callback-under-lock, duplicate
terminal, error-propagation or shared-exchange ownership defect. Review added
explicit documentation of the Gateway per-event limitation and prompted exact
scalar/detailed callback-cost and enabled auto-defer context/cleanup coverage.
The validation record supplies actual process results separately.
