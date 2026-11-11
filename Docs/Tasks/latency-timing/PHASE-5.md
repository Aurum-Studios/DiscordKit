<!--
File: Docs/Tasks/latency-timing/PHASE-5.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 5 — Transport and REST timing suites

Implements [Stage 5](PLAN.md#stage-5--transport-and-rest-timing-suites) from
Phase 4 revision `efa7e6d5`, under the frozen [contracts](CONTRACTS.md).
Completed commands and actual limitations belong in the
[validation record](VALIDATION.md#phase-5-validation).

## Implementation plan

1. Extend the existing load executable with an explicit `timing` subcommand.
   Preserve legacy closed-loop cohorts, reports, readers and artifact meanings.
2. Add corrected native Foundation/NIO and scripted transport cases. Stop each
   whole-request timer after validated EOF and awaited close, before diagnostics.
   Declare cold connection, warm reuse, verified TLS and unavailable internals.
3. Add optional content-free REST phase hooks at actual construction, ordering,
   enabled cache lookup, decoder and accepted retry-backoff ownership boundaries.
   Measure logical callers, shared exchanges and subscribers independently.
4. Cover cache miss/fresh/expiry, same-key contention, independent keys, ordering,
   small/streamed/large payloads, delayed headers/body, bounded retry, malformed
   responses, cancellation and uncertain mutation without altering policy.
5. Add independent scheduled arrivals using one scheduler, fixed workers and a
   bounded queue. Record scheduled/submitted response, lateness, missed/deferred
   arrivals, every outcome, queue peaks and post-offer recovery.
6. Validate deterministic boundaries and ownership, optimized supervised native
   and scripted cases, concurrency/rate sweeps, root regressions, catalog/report
   compatibility, API/DocC/dependencies and a clean scoped commit.

## Implemented behavior

The [existing load package](../../../Tools/DiscordKitLoadTests/README.md#phase-5-transport-and-rest-timing)
now selects 12 transport cases, 17 REST cases and an independent arrival policy.
No executable, listener, timer or benchmark dependency is added to runtime
products. The development package selects the existing Foundation transport.

`transport.request` starts immediately before adapter invocation; construction is
separate. It ends after caller byte validation and awaited close. Headers includes
pool acquisition, upload and connection/TLS work the adapter performs before
response headers. Body consumption and explicit close have separate observed
intervals. Their histograms overlap and must not be combined arithmetically.
Adapters expose no honest DNS, TLS, pool-acquire or final upload-write timestamps;
those phases are explicitly unavailable. Cold cases use fresh adapters serially;
warm cases reuse one prepared adapter. TLS uses the existing test certificate and
full hostname/trust verification through NIO. Foundation has no injected test
trust path and rejects this TLS fixture selection.

`RESTTiming` is a separate opt-in content-free observer. Its nil path reads no
instrumentation clock. Existing scalar and correlated interval meanings remain
unchanged. New hooks measure request construction after admission, ordering
acquire, enabled cache lookup, each actual decoder invocation, and accepted retry
backoff. Existing scalar hooks supply admission, headers/body, exchange-joined and
subscriber observations. A fresh cache hit emits no exchange; one coalesced
exchange has independent caller/subscriber observations. 429 waits remain rate
admission; uncertain mutation is never replayed. Fixture coordination, cache
priming and expiry waits are declared separately from operation timers.

The arrival driver allocates at most one scheduler and the configured persistent
worker cohort. It retains no record/task per offered arrival. Pending capacity is
separate from active capacity; together they are capped at 1,024. Full queues count
missed arrivals as terminal rejection without fabricated submission latency.
Queued cancellation is similarly counted without inventing a submission. Actual
submission precedes the service owner hop. `arrival.service` covers the fixture
operation closure, including any REST admission; actual owner admission remains
unavailable unless explicitly supplied. Timestamp ranges are constant-space
summaries. Complete response timestamps follow joined operation cleanup.

Catalog revision 5 registers corrected transport, REST and arrival metric IDs;
common schema remains version 1 and revisions 2–4 stay readable. All outcome
histograms cover the whole observed population, using 100-microsecond buckets
over 0...1 second with explicit censor/loss. P99 requires 10,000 observations in
its outcome population; smoke is normally insufficient. New metric identities
cannot be assigned to historical prefix-only or diagnostic-inclusive reports.

The [capture wrapper](../../../Tools/DiscordKitLoadTests/scripts/run_timing_suites.py)
uses existing release receipts and supervised serial fresh processes. It separates
adapters/connection modes/TLS and sweeps 1/4/16 workers against 200/2,000/20,000
arrivals per second with bounded pending work. Full reports retain outcome counts,
latencies, queue growth, recovery, throughput, process scopes and final ownership.
The compact matrix links full evidence; no numerical baseline or gate is promoted.

Local loopback/scripted results do not establish real Discord latency, Linux or
other-platform behavior, controlled-host stability, fleet capacity or later
roadmap completion. Documentation and runtime hooks preserve that boundary.
