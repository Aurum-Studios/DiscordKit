<!-- copyright:begin
File: Docs/Engineering.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Engineering conventions

Use these preferences for new and changed behavior alongside the project's
selected language guidance. In generated repositories, read Docs/Languages/README.md
for the affected components. Preserve established product choices;
apply the relevant contracts without expanding a task into unrelated rewrites.
Record consequential exceptions and the behavior they preserve in the task plan.

## Focused components and explicit dependencies

Give each component a clear responsibility and keep mutable state encapsulated.
Prefer composition and small collaborating types. Use interfaces, protocols and
inheritance where they express a real boundary or substitutable behavior; avoid
speculative abstraction layers and unused extension points.

Keep reusable domain rules separate from application composition, rendering,
platform services, persistence and external provider adapters. Inject dependencies
at useful boundaries so rules can be exercised with offline fixtures. Avoid hidden
service lookups and global mutable managers. Keep the dependency graph acyclic
where practical, and allocate shared libraries independently of consuming products.

## State, compatibility and effects

Identify the authoritative owner of each record and distinguish persisted domain
state, authored configuration, derived views and device-local preferences. Rendering
and diagnostics must preserve domain results. Validate inputs at trust boundaries
and enforce authorization in the operation that owns the effect; a submitted ID
or visible control does not establish authority.

For shared or durable updates, define invariants, conflict/revision behavior and
transaction boundaries before implementation. Preserve compatible readers and
existing data through reviewed schema changes; include migration, restart and
recovery evidence when those behaviors change. Keep partial or uncertain outcomes
explicit rather than substituting empty results or reporting success.

Define retry and idempotency rules for external effects. Reconcile an uncertain
durable result against authoritative state before retrying an operation that may
already have occurred. An offline test or a timeout supplies no permission to
repeat a message, charge or production write.

## Concurrency, lifecycle and limits

Give tasks, subscriptions, handles and native resources explicit owners. Prefer
structured asynchronous work; propagate cancellation, observe failures and join
owned work during shutdown. Release partial initialization on failure, and keep
late callbacks from applying results after their owner or generation has changed.
Document ordering, reentrancy and thread/isolation requirements where relevant.

Bound queues, buffering, retained history, decoded input and concurrent work using
the product's actual constraints. Define overload and recovery behavior. Measure
the relevant workload before adding pooling, caching, parallelism or a different
architecture. Record hardware/runtime, inputs, limits and observed results;
local timing or allocation results qualify only the exercised path. Follow
[Testing.md](Testing.md) for resource-aware compiler and test workers.

## Diagnostics and user-facing behavior

Use stable semantic events and structured safe context for operational diagnostics.
The application owns logging configuration, destinations, filtering and shutdown;
reusable components accept logging without changing process-wide configuration.
Choose severity for the actual outcome, keep cancellation distinguishable from
failure and avoid repeated reports of the same failure at every layer.

Exclude credentials, authorization headers, private payloads and unbounded values
from diagnostics. Capture useful outcome, correlation and duration metadata with
appropriate retention. Exercise important events and redaction with injected
capture sinks. Logging observes behavior and must preserve results and authority.

Give users a clear supported action, result and recovery path. Keep implementation
details in diagnostics or documentation unless they help a user decide what to do.
Use the [documentation standards](Documentation.md) to explain actual contracts,
examples and limits, and [meaningful tests](Testing.md) to verify them.
