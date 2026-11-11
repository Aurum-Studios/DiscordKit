<!--
File: Docs/Tasks/latency-timing/PHASE-7.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 7 — Cache, client and authoring latency

Implements [Stage 7](PLAN.md#stage-7--cache-client-and-authoring-suites) from
Phase 6 revision `2181ab7f`, under the [measurement contracts](CONTRACTS.md).
Completed checks and their limits are recorded in
[validation](VALIDATION.md#phase-7-validation).

## Implementation plan

1. Add optional cache and client lifecycle observations at actual owner boundaries,
   retaining nil zero-clock behavior, bounded state, stale-fetch fencing and joined
   shutdown. Keep pure permission arithmetic under an external benchmark wrapper.
2. Extend the existing load executable with a separate cache/client command,
   complete measured populations, independent warmup owners and a finite matrix
   of working sets, identities, contention, hit ratios and subscriber pressure.
3. Extend the existing authoring executable with definition/lowering and equivalent
   direct/DSL invocation measurements. Attribute argument preparation, policy,
   middleware, handler and response work at observable boundaries.
4. Counterbalance direct/DSL fresh processes. Retain manual/macro clean and
   incremental compiler measurements in a separate driver with fixture, dependency
   and build receipts; never mix compiler duration into runtime latency.
5. Check virtual-clock endpoints and semantic/fencing regressions, complete package
   tests, optimized supervised workloads, dependency isolation, documentation and
   report compatibility before committing.

## Owner boundaries

`EntityCache` uses the existing `DiscordLogging` foundation for opt-in lookup,
merge, event projection, invalidation, refresh and loader intervals. It gains no
Transport, Gateway, HTTP, benchmark or output-handler dependency. External caller
wrappers start before the actor hop. Owner time begins inside the actor, and
refresh includes its existing owned suspension and cleanup. One shared loader
produces one loader observation; each waiting caller retains its own call/refresh
observation. A stale load cannot replace a newer event observation.

Expiry is triggered by a public lookup after advancing the injected freshness
clock; eviction is triggered by an ordinary apply against the selected full
working set. These are profiles of genuine public operations, not invented
expiry/eviction APIs. Real monotonic clocks measure elapsed time independently of
virtual freshness time. Pure permission resolution has no fabricated actor phase.

The client benchmark measures the complete constructor call after caller
dependency allocation. The optional runtime construction hook observes the narrower
initializer body; the tool ignores that endpoint to avoid counting it twice. Discovery includes budget reservation, typed discovery and task-free
shard preparation. Local start runs from accepted run entry to projection and
publication of each selected shard's first READY and a snapshot confirming all
selected shards are currently locally ready. Ingestion measures one
actual event's package receiver, optional projection and publication. Lifecycle
runs through joined cleanup; shutdown measures each requesting caller's actual
wait for completion. All peers are injected and credential-free. Local readiness
is not live Discord READY qualification.

Caller, owner, loader and child histograms overlap. No queue residence is inferred
by subtracting percentiles. Begin and child callbacks consume time in enclosing
operations; endpoint capture precedes the ending callback. Applications own
observers, storage, output and teardown. Nil observers read no instrumentation
clock and invoke no sink. Legacy scalar phases remain unchanged.

The detailed operation/stage enums gain cases and the cache/client initializers
gain defaulted observer parameters. Ordinary existing calls remain usable;
exhaustive downstream detailed-enum switches and references to exact initializer
signatures require compatibility review. The existing unpublished pre-1.0 0.20.0
candidate remains the compatibility boundary; no release identity is created.

## Development suites

The [load suite guide](../../../Tools/DiscordKitLoadTests/README.md#phase-7-cache-and-client-timing)
describes `cache-client-timing`. Legacy load/cache/soak and phase 5/6 commands keep
their identities. Fixed working sets and cohorts bound entries, refresh flights,
waiters and event copies. Healthy broadcast consumers drain normally; held slow
subscribers exercise explicit overflow/resynchronization. Post-close snapshots
must prove that owned resources were released.
Lookup prepares its unchanged working set once per run. The 4,096-entry capture
uses explicit 60-second setup-inclusive warmup and measurement caps in a single
process; it does not establish sustained-soak qualification.

The [authoring guide](../../../Tools/DiscordDSLBenchmarks/README.md) describes the
separate `authoring` command and compiler driver. Definition work ends after
validated lowering. Synthetic invocation bypasses signed ingress and trusted
Gateway receipt; direct and DSL definitions have equivalent typed arguments,
policies, middleware, handler results and exactly counted response ownership.
Fresh processes isolate process-lifetime peak RSS and counterbalance mode order.
Manual/macro compiler workloads remain independently labeled and exclude fixture
mutation and prepared dependency setup from their gross supervised build interval.
That interval includes bounded output collection, RSS probes, process-group cleanup
and reap; receipt serialization follows it.

Common envelope schema stays at version 1. Catalog revision 7 registers new
populations while revisions 2–6 remain readable. Runtime histograms cover all
measured terminal outcomes using the shared bounded statistics ceiling; missing,
lost and out-of-range observations cannot become passing finite tails. Sparse
P99 remains insufficient data. Compiler histograms declare their own longer range
and coarser precision. Process CPU and peak RSS include their documented process
scope and do not establish per-operation allocation counts.

Local smoke establishes fixture correctness, measurement integrity and ownership.
It does not qualify hosted CI, other platforms, live Discord, compiler numerical
regression budgets, controlled-host baselines, production capacity or later phases.
