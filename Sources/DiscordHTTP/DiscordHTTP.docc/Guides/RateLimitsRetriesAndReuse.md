[//]: # "File: Sources/DiscordHTTP/DiscordHTTP.docc/Guides/RateLimitsRetriesAndReuse.md | Created by Carson Rau. | Copyright (c) 2026 Aurum Studios. | https://aurum-studios.com"

# Coordinating rate limits, retries and read reuse

Share server authority across consumers and reduce requests only where the descriptor allows it.

## Overview

### Admission follows credential, route and resource

``RateLimitCoordinator`` learns bucket headers and composes credential-global, route/major-resource, shared-resource and egress restrictions. Startup limits are conservative configuration, not permanent replacements for server-reported limits. FIFO queues and metadata are finite. Cancellation removes queued work; a possibly submitted request does not refund quota.

Unsafe operations retain their ordered partition through retry and backoff. Sharding does not increase REST quotas. Cross-process atomic quota reservation is insufficient to serialize business mutations; assign one ordering owner when multiple workers can update the same resource.

Local ownership release notifies the oldest eligible waiter without an ordering poll. One shared timer covers queued deadlines and shared-authority retries. A retry that is already eligible when that timer starts wakes immediately and rechecks the authority; it does not wait for the queue deadline. The authority still decides every rate grant; local notifications never shorten its retry instant or refund quota. ``SchedulingPolicy/fairnessInterval`` bounds minimum authority retry spacing, including rechecks for changes outside this coordinator. Close wakes queued callers to reject them while active operations retain cleanup ownership.

Authority exhaustion or an unavailable store fails closed. Do not respond by creating an independent fresh coordinator that forgets restrictions. External stores must translate clock domains, reserve applicable quotas atomically and survive crashes without minting allowance. Run the reusable `RateLimitStoreContract` test harness and backend-specific transaction/failure tests.

### Replay only documented safe operations

``RetryPolicy`` bounds attempt count and backoff. Explicit 429 rejection passes through learned admission again. Transport failures and 5xx can replay only descriptors marked safe. Unsafe ambiguous sends and unsafe 5xx return an indeterminate result, even for a familiar PUT or DELETE; HTTP method alone does not prove safe replay.

A deadline bounds admission, backoff, transport and body EOF. An expiry or cancellation after possible submission cannot recall network bytes. Preserve that uncertainty in application state and reconcile against a fresh authoritative read.

### Opt into reuse with exact authorization scope

``RequestCoalescer`` shares one eligible in-flight read among subscribers. Cancelling one subscriber preserves others; the final subscriber cancels and awaits the exchange. A shared flight has a finite exchange lifetime independent of one subscriber's shorter deadline.

``ReadCache`` stores successful response bytes only when a descriptor supplies a TTL and the host injects a cache. GET alone does not enable reuse. Keys include opaque authorization identity, path, ordered queries, representation, response type and relevant execution/freshness bounds. Streaming bodies cannot enter reuse keys. Share reuse owners only across clients with the same authorization interpretation and transport backend.

The default coalescer caps 128 flights and 1,024 subscribers in aggregate. The default read cache caps 256 entries and four MiB of payload, with smaller per-identity bounds. Those limits describe local retained work, not deployment capacity. Cache directives and response age can shorten endpoint TTL; conditional revalidation is not implemented.

### Invalidate when observations change

Successful local writes invalidate declared tags. Explicitly invalidate when permissions, credentials, visibility or externally observed state changes. Rotate read scope on credential changes. TTL bounds unobserved staleness, and cached bytes never prove current authorization. HTTP response caching and DiscordCache entity projections have distinct ownership and invalidation policies.

### Test request reduction and failure boundaries

Use injected peers and clocks to assert one send for concurrent equivalent reads, independent cancellation, expiry, invalidation racing completion, finite retry counts, fractional reset handling, blocked unrelated identities and fail-closed outages. Assert actual send counts and released body ownership rather than merely observing a returned value.

### Retain learned headroom without refunding sends

A consumed provisional startup token is distinct from learned exhaustion and an
explicit 429 restriction. Discovering another route alias does not import its
startup zero into an existing bucket. Every possible send not acknowledged by its
own valid remaining header stays charged across alias migration, including
uncertain or not-sent release under the existing no-refund contract. The bounded
store uses scalar counters, not a new send-history registry. Proven elapsed
windows roll before completion metadata is merged. Admission time cannot prove
the server window of a delayed response; ambiguous or out-of-order observations
may conservatively lower allowance or retain a later reset. Existing credential,
major-resource, shared-resource and egress protections and metadata ceilings apply.

### Observe exchange and subscriber ownership

The optional `OperationTiming` observer from DiscordTransport separates rate
admission, headers, body EOF/close, coalesced subscriber wait and joined execution.
A successful headers sample says nothing about final API success. Shared flights
emit one set of wire samples; individual subscribers have independent waits.
Omitting the observer adds no timing-clock reads, tasks or registry. A sink must
be prompt, thread safe and bounded; only fixed categories and numeric durations
are supplied. Timing never changes retry, deadline or single-send policy.
