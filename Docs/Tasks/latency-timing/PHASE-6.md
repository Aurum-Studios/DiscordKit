<!--
File: Docs/Tasks/latency-timing/PHASE-6.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 6 — Gateway, interactions and command latency

Implements [Stage 6](PLAN.md#stage-6--gateway-interactions-and-command-latency-suites)
from Phase 5 revision `45c82163`, under the [measurement contracts](CONTRACTS.md).
Actual completed checks and qualification limits are recorded in
[validation](VALIDATION.md#phase-6-validation).

## Implementation plan

1. Extend the existing opt-in detailed observer at real Gateway frame, retained
   queue, heartbeat, reconnect and shutdown owners. Preserve independent control
   authority, bounded subscriptions, duplicate fencing and private receipt trust.
2. Observe signed body read/close, Ed25519 verification, replay admission, typed
   decode, router admission/preparation/handler, confirmed first response and
   complete joined workflow. Preserve acknowledgement deadlines and uncertainty.
3. Add bounded scripted JSON WebSocket and genuinely signed HTTP workloads to
   the existing development executable, with complete terminal populations,
   explicit provider/policy waits and exact cleanup receipts.
4. Measure trusted Gateway interactions through the public client and bot runtime.
   Compare handwritten and DSL-lowered routes with equivalent typed input and
   response checks under separately labeled synthetic caller origins.
5. Reuse bounded histograms, release receipts and subprocess supervision; keep
   warmup separate, counterbalance synthetic process order, and sweep actual
   offered Gateway rates and callback cohorts through saturation and recovery, including confirmed heartbeat progress while
   a handler permit is held.
6. Run deterministic endpoint/trust/deadline tests, root and tool regressions,
   optimized supervised cases, dependency and documentation checks, then commit.

## Runtime boundaries

All new runtime hooks use the existing `DiscordLogging` interval model. Nil options
perform no interval clock reads or observer calls. Runtime products gain no
benchmark, histogram, subprocess or optional output dependency. Applications still
own observation storage, output configuration and shutdown.

The detailed operation/stage enums gain cases, and owner initializers gain
defaulted observer parameters. Existing ordinary calls remain usable; downstream
exhaustive detailed-enum switches and references to exact initializer signatures
need compatibility review. All fourteen legacy scalar phases remain unchanged.
The existing unpublished 0.20.0 candidate supplies the conservative pre-1.0 minor
compatibility boundary; this work creates no release identity or publication.

The shard begins receipt observation immediately after each supported transport
read and before generation fencing/JSON decode. Duplicate frames still have decode
cost, but never acquire new application dispatch authority. Shard ingestion and
per-subscription hub retention use actual enqueue/remove endpoints; eviction,
refusal and cancellation terminate their own retained copies. Hub publication is
actor-owner time and excludes the preceding caller hop. Queue/handler measurements
are distinct populations, without a manufactured per-event waterfall.

Heartbeat ACK observation starts after a confirmed heartbeat write. An ACK already
handled before that confirmation supplies no fabricated duration. Reconnect starts after previous-generation cleanup and retry eligibility,
immediately before the reconnect transition and bounded retry wait; it ends
at local READY/RESUMED or failure; shutdown measures actual joined owner cleanup
after supervised siblings finish. Neither metric claims service-side delivery.

HTTP body timing includes bounded read and close. Signature and replay admission
are separate synchronous owners; cryptography uses exact timestamp and body bytes.
Router call timing starts before its actor hop; route admission, synchronous typed
preparation and admitted execution remain separate nested boundaries. Explicit
fixture provider wait and policy wrappers do not infer time by subtraction; policy
can include its enclosed handler.

HTTP workflow starts at application entry after constructing its original response
clock. The first-response interval starts next, after the workflow begin callback;
it ends at confirmed inline sink return. Observer callbacks consume the original
three-second acknowledgement budget. A confirmed response remains successful if
later handler/edit work fails. Full workflow waits for the handler, timers and
existing cleanup. A definite `notSubmitted` response failure differs from uncertain
submission; neither permits an invented replacement acknowledgement.

There is no listener-owned receipt token for this injected HTTP adapter, so
`ingress.trustedResponse` remains unavailable. Application-entry timing never
claims socket ingress time. Trusted Gateway receipt/admission/acknowledgement
metrics use existing private scalar provenance; public replay and numeric interval
context cannot establish it. Scalar ages never become historical detailed begins.

## Development suite and reports

The [load suite guide](../../../Tools/DiscordKitLoadTests/README.md#phase-6-gateway-and-command-timing)
describes the explicit `command-timing` subcommand and reproducible capture commands.
Legacy commands and Phase 5 `timing` retain their existing identities and readers.
Common schema remains version 1; catalog revision 6 introduces distinct Gateway,
ingress, command, interaction and synthetic metrics. Catalog revisions 2–5 remain
readable and cannot silently accept the new populations.

Each runner allocates only its selected finite metric set under the shared 16 MiB
statistics ceiling. The complete expanded catalog need not fit one collector.
Optional runtime outputs retain their existing explicit key cap and count excess
new keys as loss. Numeric key lookup and signpost mappings cover the new identities.

All terminal outcomes contribute to bounded whole-population histograms. Histogram
range is 0...1 second at 100-microsecond precision; longer waits remain censored.
Sparse P99 is explicitly insufficient data. Overflow, invalid clocks and lost
observations cannot become finite passing tails. Phase percentiles overlap and
cannot be added/subtracted. Process CPU includes setup/warmup/teardown; maximum
RSS is process-lifetime evidence, not isolated per-operation memory.

Fixtures use uncompressed JSON and injected, credential-free protocol peers.
Signed HTTP cases perform real Ed25519 signing and verification; signing and input
construction precede measured caller entry. Exact replay reuses the original
signature and body. Webhook durable profiles use the existing processor and
measure the actual injected transaction closure separately from replay-window
admission. Primed duplicate shortcuts invoke no transaction; retryable storage
failure never claims a successful commit. Synthetic direct/DSL cases bypass ingress and use the same
typed schema, provider behavior and independently validated response sinks.

The matrix wrapper serially supervises fresh processes, retains source/executable
and fixture hashes, and records completed rows before starting the next. Rate
sweeps use absolute monotonic deadlines on a bounded source; source backpressure
and scheduling cost remain inside gross elapsed time. This is a paced bounded
protocol source, not an unbounded independent-arrival capacity model.

Local scripted/injected results establish measurement semantics and resource
ownership. They do not establish real Discord latency, rendering, live READY,
native WebSocket network throughput, controlled-host baselines, hosted CI,
other-platform qualification, publication or later roadmap completion.
