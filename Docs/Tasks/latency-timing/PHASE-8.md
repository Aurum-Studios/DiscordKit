<!--
File: Docs/Tasks/latency-timing/PHASE-8.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 8 — Optional service composition latency

Implements [Stage 8](PLAN.md#stage-8--oauth-rpc-activities-and-service-composition)
from Phase 7 revision `1de88f8d`, under the existing
[measurement contracts](CONTRACTS.md). Completed evidence belongs in
[validation](VALIDATION.md#phase-8-validation).

## Implementation plan

1. Add development-only wrappers around actual OAuth coordinator, RPC, Activities,
   Social, GameServices, Commerce and CertifiedDevices public APIs. Use bounded
   injected storage, transport and backend owners; keep runtime contracts intact.
2. Exercise token lookup/load/CAS, contending refresh readers, conflicts, revoke
   and joined cancellation. Record actual storage and backend calls separately
   from caller-visible latency; do not infer distributed locking guarantees.
3. Exercise fragmented IPC frames, handshake, request correlation, pending limits,
   events/subscribers and joined close with injected RPC and Activity peers. Add
   bridge protocol/boundary regression checks without launching a real browser.
4. Cover implemented service validation, snapshot application, injected waits and
   cleanup. Keep every offered terminal outcome and independent correctness
   assertions; underlying transport and composition populations overlap.
5. Add a finite `service-timing` command and supervised capture matrix, independent
   warmup owners and catalog-eight identities. Reject incomplete populations,
   aggregate loss and retained owners before accepting a capture row.
6. Run relevant Swift, Python and Node suites, root regression checks, callable
   documentation and dependency/inventory audits, then optimized fresh-process
   captures and independent common-envelope validation. Commit reviewed source
   and documentation with local qualification limits recorded explicitly.

## Ownership and timing

The executable adds seven optional runtime products only to its development
manifest. Runtime sources, manifests, dependency directions, observer APIs and
legacy scalar timing contracts retain their existing behavior. No timing work
is added inside pure accessors, codecs, cryptographic loops or runtime callbacks.

Each measured caller uses one full-population primary metric: `oauth.lookup`,
`oauth.install`, `oauth.revoke`, `rpc.request`, `activities.request` or
`service.operation`. Separate finite
storage, I/O, handshake, dispatch, validation and close populations describe
observed wrapper boundaries. Caller wrappers include actor admission and
configured injected waits. Exact internal queue residence cannot be reconstructed
by subtracting child histograms. Fixture preparation, result verification,
diagnostic snapshots and serialization follow or precede caller timers.

`oauth.refresh.joined` is explicitly an external cohort boundary through joined
readers and coordinator close; it includes harness joining and diagnostic work.
It does not claim an unobservable internal refresh-admission timestamp. Storage
load/CAS and refresh/revoke backend method timings are independently observed
after their actor admission; they exclude preceding actor residence. Local
single-flight receipts establish only the measured coordinator's behavior.

Handshake and event/subscription probes use their own populations. RPC/Activities
handshake scenarios still issue a separately timed real public request. Held
support requests establish pending pressure without being counted as primary
calls. Protocol writes, supporting requests and subscriptions remain bounded. Supporting
request tasks are joined, fixture adapter reads complete, and actual public close
contracts are retained before accepting cleanup. Activity public close alone does
not promise a joined reader task.

## Reports and reproducibility

Native format `DiscordKitLoadTests.service-timing`, schema 1, contains each
family's receipts plus a common schema-1/catalog-8 envelope. Earlier formats and
catalogs remain readable; new metric identities require catalog eight. The shared
collector allocates only the selected family within its existing 16 MiB budget.
Outcomes include expected rejection, failure and cancellation. Sparse P99 remains
insufficient data and out-of-range mass remains censored.

The [load guide](../../../Tools/DiscordKitLoadTests/README.md#phase-8-optional-service-timing)
provides listing, direct execution and optimized supervised capture commands.
Configurable injected delay and concurrency/fanout sweeps are explicit identity
fields. Warmup uses independent owners and never contributes measured samples.
The supervisor retains build/source/pin/fixture hashes, bounded process artifacts,
timeouts, signal forwarding and child-reaping evidence.

## Qualification limits

Ordinary suites use public fixture values and injected storage, peers and
backends. They perform no real purchase, browser authorization, desktop-host
access or Discord request. Actual local IPC/desktop and controlled browser
process recipes are separate opt-in qualifications; no browser-process timing
or host-delivery latency is claimed by the injected bridge suite. Node bridge
checks establish protocol boundaries only. Numerical baselines, distributed
OAuth coordination, hosted CI, other platforms, publication and later roadmap
stages require their own evidence.
