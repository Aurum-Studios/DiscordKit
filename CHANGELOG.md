<!--
File: CHANGELOG.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Changelog

## Unreleased

### Performance plan phase 2

- Decode successful unshared REST exchanges once while preserving validated byte
  retention, independent coalesced results and cancellation/deadline behavior.
- Reuse validated initial interaction callback bytes for exact acknowledgement
  admission and built-in inline/REST delivery; preserve public typed custom sinks.
- Bound signed-ingress expiry maintenance with one indexed entry per signature,
  preserving inclusive expiry and atomic authenticated replay admission.
- Remove NIO response FIFO shifts and intermediate body materialization while
  retaining response caps, complete EOF drain and connection lifecycle rules.
- Add typed-size, replay-state and actor-admission measurement controls plus
  deterministic regression coverage. See the [phase record](Docs/Tasks/performance-improvements/PHASE-2.md)
  for validation and the separately open numerical/platform qualification gates.

### Local admission notifications — 2026-11-11

- Replace local order/rate eligibility polling with targeted FIFO handoff and a
  shared timer for queue deadlines and authority retries. Preserve partition and
  identity fairness, finite budgets, exact reservation cleanup and fail-closed
  authority behavior; every rate grant still comes from the shared store.
- Make coordinator `close()` explicitly asynchronous so it joins its owned timer
  before returning; isolated synchronous callers must adopt `await`.
- Add deterministic handoff and suspended-authority race coverage plus a
  versioned held-owner workload with default scheduling and clock diagnostics.
  Retain historical REST/arrival identities and record the local validation and
  separate numerical qualification gates in the
  [Phase 1 record](Docs/Tasks/performance-improvements/PHASE-1.md).

### Performance measurement controls — 2026-11-10

- Add versioned default-policy ordering and arrival workloads, no-op generator
  controls, independent JSON dimensions and continuous media/full-window DAVE
  fixtures while preserving historical cases.
- Add bounded shared/per-worker observer comparisons at cohorts 1/4/16 and direct
  REST execution-entry, signed-verifier admission and Gateway lease-validation
  hooks. Preserve existing public APIs and nil observation-clock behavior.
- Retain peer CPU, available thermal/power and cgroup throttling observations.
  Record local validation and separate the reserved-host numerical gate in the
  [Phase 0 record](Docs/Tasks/performance-improvements/PHASE-0.md).

### Timing baselines and CI — 2026-11-10

- Add versioned policies bound to immutable baseline and no-change evidence,
  per-run paired deltas, measured noise floors and explicit regression,
  compatibility, insufficient-data and harness/host classifications.
- Add supervised paired capture, native release integrity smoke, and separate
  controlled comparison and periodic stress/soak workflows. Keep shared-runner
  numbers informational and numerical gate promotion explicit.
- Repair Linux model evidence and audit the benchmark support dependency without
  extending runtime dependencies. See the
  [Phase 10 record](Docs/Tasks/latency-timing/PHASE-10.md).

### Cache, client and authoring timing suites — 2026-11-10

- Add opt-in cache and client lifecycle hooks with separate caller/owner/loader
  timing, local-ready milestones and joined cleanup. Preserve cache fencing,
  independent runtime products and nil zero-clock behavior.
- Add bounded cache/client workloads, equivalent direct/DSL definition and
  invocation workloads, and fresh-process comparisons. Keep manual/macro compiler
  measurements separate with provenance and versioned report compatibility.
- Record phase 7 measurement contracts and local checks in the
  [implementation record](Docs/Tasks/latency-timing/PHASE-7.md).

### Transport and REST timing suites — 2026-11-10

- Add corrected Foundation/NIO loopback and scripted transport timings with cold
  connections, warm reuse, verified NIO TLS, bounded bodies and explicit cleanup.
- Add opt-in REST construction, ordering, cache, decode and retry-wait hooks,
  preserving existing timing and request policy. Cover 17 bounded policy cases.
- Add independent arrivals, fixed workers and bounded pending work with scheduled
  and submitted response distributions, overload counts and recovery. Reuse shared
  release supervision and preserve report catalogs. See the
  [Phase 5 record](Docs/Tasks/latency-timing/PHASE-5.md).

### Foundation CPU timing suites — 2026-11-10

- Add 77 development-only JSON, identifier/bitset, model, builder, permission and
  RPC-framing cases with prepared fixtures, independent semantic checks and exact
  expected rejection counts.
- Reuse shared release supervision and versioned reports for batch distributions,
  normalized mean and size-scaling evidence. Preserve prior report catalogs and
  runtime dependencies. See the [Phase 4 record](Docs/Tasks/latency-timing/PHASE-4.md).

### Timing outputs and observer overhead — 2026-11-10

- Add optional bounded numeric aggregation, safe SwiftLog timing records, sampled
  interval capture with NDJSON/local timeline export, and Apple signposts driven
  by actual lifecycle hooks. Expose loss and incomplete intervals at explicit close.
- Add a development-only timing benchmark using shared reports and process
  supervision. Keep warmup, gross observation cost and output teardown separate.
- Preserve legacy scalar phases and runtime ownership. See the
  [Phase 3 record](Docs/Tasks/latency-timing/PHASE-3.md) for limits and validation.

### Runtime interval timing — 2026-11-10

- Add opt-in numeric lifecycle intervals to DiscordLogging with checked monotonic
  endpoints, explicit clock domains, parent/attempt context and once-only completion.
- Expose optional hooks on REST, Gateway dispatch and interaction response owners.
  Separate shared exchanges from callers and subscribers; preserve existing scalar
  timing phases, outcomes and ownership behavior.
- Add deterministic clock, cancellation, cleanup, deadline, retry, cache and trust
  coverage. See the [Phase 2 record](Docs/Tasks/latency-timing/PHASE-2.md) for exact
  boundaries and the remaining attribution and performance qualification limits.

### Discord API documentation update — 2026-11-05

- Add guild and channel member/role permission endpoints, including optional
  channel masking and exact arbitrary-width permission responses.
- Add attachment/embed content-scanning flags and typed scan metadata for
  component media, including results delivered in later message updates.
- Support Components V2 messages when starting forum and media threads.
- Recognize channel-position and role-position audit events, and document merged
  audit counts and Gateway notification behavior.
- Support audit reasons when reordering guild channels. Stop sending the removed
  channel-position `flags` field; the deprecated initializer accepts only absent
  flags. Use channel modification for supported flag changes.
- Stop sending audit reasons for single-message deletion. The deprecated overload
  ignores its reason; use the overload without that argument. Bulk deletion keeps
  its documented audit-reason support.
- Refresh OAuth issuer, linked-role, guild availability, voice-status and native
  Social SDK guidance against the official documentation. Preserve existing
  access boundaries and the November 16 channel-obfuscation transition.
- Record pinned source hashes, supplemental parity contracts, migration notes,
  regression coverage and updated API documentation.

### Initial publication

Original DiscordKit material is now licensed under the [Apache License, Version
2.0](LICENSE), allowing use, modification and redistribution in open source and paid
products with the required license and attribution notices. [NOTICE](NOTICE)
credits Carson Rau and Aurum Studios; third-party material retains its own terms.

DiscordKit's initial publication includes independently adoptable Swift libraries
for Discord applications and bots:

- Typed REST models, validated requests, bounded uploads and explicit workflows for
  messages, channels, guilds, moderation, expressions, events, applications, users,
  webhooks, interactions, monetization and game-account resources.
- Supervised sharded Gateway sessions, typed dispatches, bounded subscriptions and
  ordered handlers, optional entity caching and permission resolution.
- Signed HTTP interactions, explicit response ownership, command routing and
  registration reconciliation.
- Modular Swift authoring for typed commands, messages, components, policies,
  Gateway events and bot applications, with an optional separate macro package.
- OAuth authorization and token ownership, public game-account services and
  server-authoritative entitlement verification.
- Local RPC, Certified Devices, an Activity client and browser bridge, and
  explicit Social provider composition.
- Optional media processing, Opus coding, voice transport, MLS and DAVE products.
- Structured diagnostics, independently compiled examples and DocC guides and
  tutorials.

REST/Gateway v10, Voice v8, RPC v1, MLS 1.0/ciphersuite 2 and DAVE v1 are versioned
independently of the package. Platform, live-service, device, cryptographic review,
interoperability and production-capacity limitations are described in the
[platform](Docs/PlatformSupport.md) and [voice](Docs/Voice.md) guides. This entry
describes unpublished source and does not establish a release tag or completed
external qualification.
