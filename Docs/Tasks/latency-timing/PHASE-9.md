<!--
File: Docs/Tasks/latency-timing/PHASE-9.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 9 — Media, voice, MLS and DAVE timing

Implements [Stage 9](PLAN.md#stage-9--media-voice-mls-and-dave-suites)
from Phase 8 revision `29024533`, under the existing
[measurement contracts](CONTRACTS.md). Completed evidence belongs in
[validation](VALIDATION.md#phase-9-validation).

## Implementation plan

1. Extend only development tools and their common metric catalog. Keep runtime
   dependency direction, ownership, cryptographic implementations and hot paths intact.
2. Add externally timed component batches for resampling, codec encode/decode,
   conceal/recover, jitter, RTP, transport AEAD and DAVE seal/open. Verify observable
   results outside the timer. Cover supported frame/mode/channel combinations.
3. Separate real MLS group create/join/rekey and DAVE signaling queues from steady
   media workloads. Public fixture secrets authenticate no external service;
   native cryptographic entropy is not replaced by a benchmark seed.
4. Exercise actual voice managers/sessions with finite injected signaling and UDP
   fixtures. Preserve separate credential, installation, handshake, readiness,
   heartbeat/reconnect, speaking, failure and joined-shutdown boundaries.
5. Extend the existing paced two-way local UDP runner with opt-in attribution,
   explicit impairment emulation, frame/channel/codec and silence policies, and
   controlled contention. Preserve direct tick, scheduling, memory and closure receipts.
6. Adopt actual Apple audio codec evidence into the common envelope without device
   access during ordinary tests. Retain explicit physical-device procedures.
7. Validate semantic boundaries and outcome accounting, then freeze sources for
   optimized supervised captures. Review scope and commit local evidence with
   hardware, live, cross-platform and numerical-baseline limitations explicit.

## Measurement ownership

The [component tool](../../../Tools/DiscordMediaBenchmarks/README.md) measures
`media.batch` and `mls.transition` as complete external batches. Batch observations
are not per-frame latency percentiles. Setup, correctness checks and report writes
remain outside those timers. Results keep their component, frame, channel and
batch-size identity. Cryptographic timings establish no security property.

The load tool's `voice-timing` command measures `voice.lifecycleJoined` once per
offered terminal lifecycle, with separate child populations. Manager installation
does not imply secure readiness. Scripted transports exercise production owners
without connecting to Discord. A completed termination case may contain the
expected failure population; successful-only percentiles cannot hide that work.

The [duplex tool](../../../Tools/VoiceSessionQualification/README.md) retains real
localhost UDP, codecs, MLS/DAVE and transport authentication. Attribution follows
observable public boundaries: DAVE protection, transport send, receive including
authentication/jitter insertion, and playout including jitter removal/decoding.
These overlapping observations cannot reconstruct an additive waterfall. Component
batches supply finer isolated measurements. The directly measured full tick and
actual selected frame interval remain the processing/scheduling comparison.

Suppression is interpreted against the selected DTX policy's expected send
cadence. Raw dispatch gaps remain visible. Loss/reorder/jitter are explicit local
emulation; contention has a bounded, joined owner. No exporter, JSON serialization,
UUID creation or diagnostic callback is added inside runtime sample processing.

The [Apple audio tool](../../../Tools/AppleAudioQualification/README.md) maps actual
codec observations and resource receipts. Permission, enumeration, capture,
playback, route and unplug remain explicitly invoked device procedures. Codec
processing time excludes hardware render/acoustic delay and cannot qualify it.

## Reports and qualification

Common schema 1 now accepts catalog 9; catalogs 2–8 keep their prior semantics.
New populations cannot claim an earlier catalog. Existing voice defaults retain
their legacy format and profile; attributed/configured runs have distinct versioned
identities. All distributions retain complete outcome/loss/censor accounting.
Sparse P99 remains insufficient data. Warmup owners/populations are separate.

The finite capture driver reuses the shared release-build and process supervisor:
source/pin/executable/fixture receipts, finite deadlines, bounded artifacts, signal
forwarding and child reaping remain enforced. Capture files live in ignored build
output and do not establish numerical baselines. Tests and local captures do not
qualify live Discord, physical audio, other hosts, independent cryptographic review,
universal realtime behavior, publication or later roadmap stages.
