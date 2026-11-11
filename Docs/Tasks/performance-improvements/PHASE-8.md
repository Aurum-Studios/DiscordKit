<!--
File: Docs/Tasks/performance-improvements/PHASE-8.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 8 — Media and codec processing

Authorized 2026-11-11 from `57328709` under the
[stage contract](PLAN.md#stage-8--refine-media-and-codec-processing).

## Implementation plan

1. Preserve the original runtime in a detached checkout. Inspect continuous FIR
   resampling, PCM queues, codec FFT/scratch ownership and Apple capture software.
2. Evaluate immutable rational phase plans with a strict memory ceiling and the
   original bounded fallback. Retain coefficient arithmetic, sample-count carry,
   clipping, endpoint extension, channel order and independent value copies.
3. Add independent differential signal tests across complete phase periods,
   irregular chunks, reverse/awkward ratios, reset and finish. Measure cold plan
   construction, continuous processing and final flush as separate populations.
4. Sweep shallow/default/deep PCM queue occupancy before selecting any queue
   change. Review codec scratch with CPU evidence; defer changes without enough
   attribution or a safe ownership boundary.
5. Use identical development harnesses for original and candidate runtimes, five
   independent no-change pairs and five alternating comparison pairs per selected
   workload. Retain full reports, build/source identities, resource observations,
   cleanup and separate diagnostic CPU samples. Builds and captures run serially.
6. Run focused and strict root tests, benchmark/tooling tests, offline consumers,
   inventory/generation/parity, import/API and authored documentation checks.
   Compare local paced duplex processing and scheduling separately from DSP cost.
7. Review and commit the validated implementation locally. Reserved-host numerical,
   allocation-event, other-platform and physical Apple audio qualification remain
   distinct from these software checks.

## Implementation decisions

The converter constructs a complete rational fractional-phase period when its raw
Double taps and normalization sums fit **256 KiB**. The period is
`outputRate / gcd(inputRate, outputRate)`; exact integer remainders address the
stored phases even after history compaction. The original coefficient expression,
increasing-tap accumulation and final normalization division are retained. Taps
are not pre-normalized. Independent whole-signal tests compare exact Float values
against the original direct convolution.

Plans are immutable per-converter values; ordinary value copies share their
immutable array storage while retaining independent audio history and lifecycle.
There is no global cache or mutable shared workspace. Equal rates allocate no
plan. A costly period selects the original direct evaluator before allocating any
taps. The cap includes sums and coefficients, excluding allocator overhead and
fixed metadata. Existing retained-PCM accounting still measures audio history,
so the authored guide separately explains plan storage. Public API and product
imports are unchanged. Reset and finish release audio, retaining the bounded plan
for reuse until the converter itself is released.

PCM queues, PCMFrameStream, Apple capture mailboxes and codec FFT/scratch owners
remain unchanged. Five queue occupancy controls include default depth eight and
maximum depth 4096. Their actor-hop-inclusive times do not show monotonic scaling
in this finite sweep, and no-change variation reaches 43.4%. They do not justify a
queue rewrite or establish Apple callback/lock behavior. CELT already uses an
FFT with immutable precomputed transform data. Its CPU samples show FFT work;
they do not count scratch allocation events. Nested transactional codec value
copies would complicate private mutable workspace reuse, while a shared mutable
reference would violate independent copy/Sendable ownership. Allocation-event
attribution is required before that redesign.

## Correctness and local validation

All local checks ran on macOS arm64 with Apple Swift 6.4, using committed pins and
four build jobs. No build ran alongside a performance capture.

| Check | Result |
| --- | --- |
| Focused media/codec/Apple/software voice tests | 365 tests / 54 suites passed |
| Strict complete root tests | 2,686 tests / 338 suites / 34 test products passed |
| Root build | Passed |
| Media benchmark tests | 18 passed, including all 143 catalog cases and all 45 new cases |
| Measurement support Swift / Python tests | 68 / 47 passed |
| Local voice / synthetic Apple qualification tests | 10 / 15 passed |
| Tooling Swift / Python and CI Python tests | 106 / 234 / 183 passed |
| Offline consumers | VoiceBot and RESTOnly built |
| Inventory, deterministic generation and parity | Passed; generated sources unchanged |
| Dependency/import graph and release record | Passed; 33 products retained |
| Callable documentation | 10,507 callables in 981 Swift files; zero missing comments |
| Public API | Fresh 33-module snapshot identical to phase 7 after JSON decoding; reviewed baseline check passed |
| Authored documentation | Curation, example synchronization and strict DiscordMedia DocC passed |
| Selected Apple SDK compilation | 40 module emissions across macOS, iOS, tvOS, watchOS and visionOS minima |
| Independent source reviews | No blocking implementation, ownership or benchmark-boundary findings |

New differential tests cover every common stored phase, both sides of the exact
plan cap (448 phases / 261,632 bytes accepted; 449 / 262,216 rejected), costly
relatively prime rates, rate extrema, whole and irregular input, signed full-scale
endpoints and divergent copies. Existing tests check DC, anti-alias/image rejection,
channel order, clipping, exact duration carry, endpoint extension, finish/reset,
long-stream bounded history, packet/overlap/PLC/FEC behavior, pacing and queue
cancellation/ownership. Apple tests use synthetic backends and open no devices.

The first benchmark test build failed because a new assertion used an optional
Boolean without comparing it to true. The corrected test-only assertion passed
before the full root run. Its initial failed log remains separately retained;
no product invariant, manifest or compiler policy was relaxed.

## Workload identity and capture method

The media catalog preserves its original 80 cases and 18 version-two cases, adding
45 version-three cases: 20 continuous rate/channel/chunk combinations, ten
constructor endpoints, ten final-flush endpoints and five queue depths. The new
pairs are 16/44.1 kHz to 48 kHz, both reverse directions, and costly fallback
48 kHz to 47,999 Hz, mono/stereo. Continuous fixtures prefill eight 20 ms blocks,
then retain one owner through the whole measured population. Regular calls admit
20 ms of source audio; irregular calls cycle through 1/127/509 source frames.
These are distinct call populations, not an equal-byte fragmentation comparison.

Thirty-one selected media cases each retain five independent candidate/candidate
no-change pairs and five alternating original/candidate pairs: **620 fresh
processes**, 16 measured batches of four calls each, with two warmup batches in
separate owners. Each timer brackets only its declared endpoint; full result
oracles, fixture preparation, resource probes, serialization and cleanup are
outside batch timers. Discarded preparation leaves the live stream unchanged.
Every result, final duration, queue FIFO and zero-owner cleanup is checked.

Original runtime sources are preserved at `57328709` in a detached checkout.
Both arms use identical development harness source hashes, compiler, SDK, target,
release flags and pins. Verified release receipts bind every executable to its
source; every process retains native/common reports, resource observations,
stdout/stderr and reaped process-group receipts. Final documentation edits leave
all **821 frozen executable/test/build inputs** unchanged. The
[capture index](phase-8-observations.json) retains the exact source/build/report
hashes, summaries, failed attempts and local artifact pointers.

## Continuous processing and final flush observations

Tables report medians of five process means, in microseconds. A process mean is
its exact measured batch-duration sum divided by 64 successful wrapper calls.
Ranges describe the five paired relative changes, not confidence intervals.
Histograms and tails describe complete batches, never individual-call tails.
Only 16 batches per process are available, so p99 is unqualified. No populations
are pooled, and separate endpoint percentiles are never added or subtracted.
The host is unreserved with unknown contention/frequency/thermal effects; these
are local descriptive observations and do not pass a numerical acceptance gate.

| Workload | Original mean (µs) | Candidate mean (µs) | Paired change range | No-change range |
| --- | ---: | ---: | ---: | ---: |
| `resample.v3.continuous.16000.48000.mono.regular` | 707.671 | 85.352 | -88.4% to -87.4% | -26.4% to +2.4% |
| `resample.v3.continuous.16000.48000.stereo.irregular` | 479.281 | 68.307 | -86.5% to -85.4% | -1.6% to +1.9% |
| `resample.v3.finish.16000.48000.stereo` | 81.692 | 11.792 | -85.7% to -85.5% | -7.7% to +3.6% |
| `resample.v3.continuous.44100.48000.mono.regular` | 732.779 | 83.916 | -89.0% to -88.3% | -1.4% to +6.9% |
| `resample.v3.continuous.44100.48000.stereo.irregular` | 179.476 | 25.468 | -86.8% to -85.4% | -3.6% to +3.4% |
| `resample.v3.finish.44100.48000.stereo` | 31.042 | 4.624 | -85.8% to -84.2% | -4.2% to +5.0% |
| `resample.v3.continuous.48000.16000.mono.regular` | 724.974 | 80.334 | -89.1% to -88.7% | -1.0% to +2.2% |
| `resample.v3.continuous.48000.16000.stereo.irregular` | 162.096 | 22.527 | -87.8% to -85.9% | -3.2% to +1.1% |
| `resample.v3.finish.48000.16000.stereo` | 81.523 | 11.358 | -86.5% to -85.8% | -5.4% to +3.1% |
| `resample.v3.continuous.48000.44100.mono.regular` | 739.222 | 84.914 | -88.8% to -88.5% | -3.9% to +2.1% |
| `resample.v3.continuous.48000.44100.stereo.irregular` | 166.770 | 23.317 | -86.4% to -85.8% | +1.3% to +3.9% |
| `resample.v3.finish.48000.44100.stereo` | 30.131 | 4.753 | -85.1% to -83.0% | -10.0% to +2.0% |
| `resample.v3.continuous.48000.47999.mono.regular` | 701.200 | 695.758 | -1.2% to -0.2% | +0.2% to +1.4% |
| `resample.v3.continuous.48000.47999.stereo.irregular` | 157.055 | 160.720 | +0.7% to +4.0% | -1.8% to +3.5% |
| `resample.v3.finish.48000.47999.stereo` | 26.235 | 26.585 | -0.4% to +2.4% | +0.0% to +2.5% |

The four table-backed rate pairs reduce continuous processing by roughly
85–89% in these comparisons, and final flush by roughly 83–87%. Fallback mono
processing is nearly unchanged; fallback stereo irregular calls are 0.7–4.0%
slower against a -1.8–+3.5% no-change range. That small adverse observation remains
visible and unresolved; no uniform improvement or portable regression budget is
claimed. Finish keeps the original signal delay and exact duration policy.

## Construction and memory tradeoff

| Rate pair (stereo) | Original constructor mean (µs) | Candidate constructor mean (µs) | Immutable payload bytes |
| --- | ---: | ---: | ---: |
| 16000 → 48000 | 0.025 | 2.287 | 1,752 |
| 44100 → 48000 | 0.029 | 116.049 | 93,440 |
| 48000 → 16000 | 0.027 | 2.385 | 1,720 |
| 48000 → 44100 | 0.031 | 118.444 | 92,904 |
| 48000 → 47999 | 0.029 | 0.060 | 0 |

These are independent constructor calls inside an already running process, with
constructed owners retained until untimed signal verification. They are not cold
process startup measurements. The original constructors perform no coefficient
work, so absolute microseconds are more useful than their very large percentage
changes. No unobserved short-stream endpoint or break-even duration is inferred
by adding independent timings.

The 44.1/48 kHz plans add about 91 KiB per independently constructed owner;
16/48 kHz plans use under 2 KiB. Copies share immutable taps. Near-cap periods stay
strictly within the 256 KiB payload ceiling; awkward periods retain zero plan bytes.
Process peak RSS includes fixture/reference owners, retained results and warmup,
and is separate from coefficient/audio accounting. Some 44.1/48 kHz continuous
process RSS bounds rise by hundreds of KiB; startup/finish batches can retain
several independent plans and rise by about one MiB. Exact paired process CPU,
RSS and gross successful throughput remain in the index. Optional allocator
snapshot fields are empty on this host; no allocator gauges were collected.
Process CPU includes preparation and full oracles, so even a constructor case can
have lower total CPU despite its slower selected constructor endpoint. Peak RSS
does not count allocation events.

## Codec and queue controls

| Workload | Original mean (µs) | Candidate mean (µs) | Paired change range | No-change range |
| --- | ---: | ---: | ---: | ---: |
| `pcm.v3.queue.occupancy1` | 17.359 | 18.202 | -1.0% to +13.0% | -28.6% to +7.7% |
| `pcm.v3.queue.occupancy8` | 17.769 | 17.868 | -5.7% to +11.4% | -43.3% to +24.1% |
| `pcm.v3.queue.occupancy64` | 17.346 | 19.013 | -3.8% to +14.5% | -24.3% to +33.8% |
| `pcm.v3.queue.occupancy1024` | 16.225 | 15.985 | -23.3% to +5.1% | -9.9% to +43.4% |
| `pcm.v3.queue.occupancy4096` | 17.990 | 19.620 | -0.8% to +11.6% | -7.1% to +13.8% |
| `opus.v2.continuous.encode.celt.960.stereo` | 720.396 | 720.571 | -2.2% to +0.8% | -1.0% to +0.5% |
| `opus.v2.continuous.decode.celt.960.stereo` | 702.583 | 693.721 | -5.0% to -0.4% | -4.5% to +1.7% |
| `opus.v2.continuous.encode.silk.960.stereo` | 3299.416 | 2682.937 | -19.7% to -18.4% | -1.9% to +0.7% |
| `opus.v2.continuous.decode.silk.960.stereo` | 390.202 | 392.908 | -1.5% to +1.9% | -2.1% to +0.8% |
| `opus.v2.continuous.encode.hybrid.960.stereo` | 6370.457 | 5627.619 | -11.7% to -10.0% | -0.3% to +1.0% |
| `opus.v2.continuous.decode.hybrid.960.stereo` | 1059.676 | 1057.745 | -0.8% to +1.3% | -0.9% to +1.7% |

SILK and hybrid encoders own this bandlimited resampler for their 48-to-16 kHz
paths. Their direct continuous encoding means decrease 18–20% and 10–12%,
respectively, without a codec/bitstream algorithm change. CELT and decode endpoints
are retained controls; process CPU can also change because untimed preparation
encodes reference packets. It is not an isolated decoder CPU measurement.
Queue means include a read and write actor hop at fixed occupancy. Their broad
no-change range and non-monotonic depth results support retaining the existing
bounded queues in this phase.

Four separate one-second CPU samples cover original/candidate 44.1-to-48 kHz
continuous resampling and CELT encoding in five-second diagnostic runs. Original
filter stacks contain repeated sine/cosine evaluation; candidate filter stacks
use stored taps. Candidate sample sines under fixture generation remain expected.
Profiles include untimed oracle/fixture work and are neither isolated allocation
profiles nor additional paired timing observations.

## Local paced duplex observations

The separate release-built voice executable runs real localhost UDP, two-direction
pacing, Opus, RTP, transport AEAD and synthetic two-member MLS/DAVE. Each measured
population lasts two seconds after a two-second warmup, with independent owners
per fresh process. CELT uses stereo 960-sample frames; the hybrid profile uses
stereo 480-sample frames. Both qualified populations use unimpaired localhost UDP.
Each profile retains five no-change pairs and five original/candidate pairs:
**40 qualified fresh processes**, separate from media microbenchmarks.

| Profile / set | Reference arm median of process p50 (ms) | Candidate median of process p50 (ms) | Reference / candidate processing overruns | Reference / candidate schedule underruns |
| --- | ---: | ---: | --- | --- |
| celt-stereo / no-change | 3.493 | 3.488 | [0, 0, 0, 0, 0] / [0, 0, 0, 0, 0] | [0, 0, 0, 0, 0] / [0, 0, 0, 0, 0] |
| hybrid-stereo / no-change | 2.914 | 2.909 | [0, 0, 0, 0, 0] / [0, 0, 0, 0, 0] | [0, 0, 0, 0, 0] / [0, 0, 0, 0, 0] |
| celt-stereo / comparison | 3.434 | 3.438 | [0, 0, 0, 0, 0] / [0, 0, 0, 0, 0] | [0, 0, 0, 0, 0] / [0, 0, 0, 0, 0] |
| hybrid-stereo / comparison | 3.230 | 2.950 | [0, 0, 0, 0, 0] / [0, 0, 0, 0, 0] | [0, 0, 0, 0, 0] / [0, 0, 0, 0, 0] |

Arrays show the five native observations per arm; missed deadlines remain actual
observations at the selected frame interval. The reference arm is the candidate
runtime for no-change controls and the original runtime for comparisons. The table
uses medians of per-process
p50 values for description, without pooling. Child operations overlap the gross
tick, so their percentiles cannot be summed or subtracted. Native legacy p99
scalars remain in original reports, while common p99 is explicitly unqualified
for these sparse populations. Final delayed media drains outside tick histograms.
Every successful run verifies packet/sample accounting, policy cadence, drained
buffers and joined closure of both pipelines, DAVE owners and UDP sockets.

The first ten native duplex processes completed, but their comparison collection
was rejected because the recipe declared supervisor profile `standard` as the
participant profile. Those reports and the rejected collection remain retained,
excluded from the qualified 40. The corrected wrapper declares supervisor resource/
repetition policy separately from actual `attributed-celt-tone` or
`attributed-hybrid-tone` participant policy, retaining the same strict participant
identity checks. It reruns all four qualified series rather than reclassifying
the rejected collection.

A separate impaired hybrid control (loss every seventh packet, reorder selection
every fifth and 20 ms jitter hold) failed in all ten candidate/candidate processes
with `VoicePacketError.duplicateOrLate`. A fresh supervised original-runtime run
reproduces the same error. These eleven failed native runs remain retained and
excluded from performance comparisons. Their process groups were reaped and UDP
closure was logged; they produced no successful native report, so joined media/
DAVE closure and decoded accounting are not claimed for them. This pre-existing
impaired-profile correctness gap remains open for Stage 9. At measured tick 30,
loss of ordinal 28 and the selected holds make ordinals 29 and 30 arrive together
in reverse order. After empty-buffer PLC, the receive pipeline reanchors its jitter
sequence to the later packet and rejects the still-due earlier packet. The failure
is not established as a harness-only issue. Stage 9 must preserve timestamp and
sequence expectations across empty PLC and a batch of reordered arrivals, with
an integrated regression and joined failure cleanup before impairment acceptance;
the successful unimpaired comparison does not qualify loss/reorder/jitter behavior.
The relevant boundaries are the qualification tool's
[ImpairmentQueue](../../../Tools/VoiceSessionQualification/Sources/VoiceSessionQualification/Attribution.swift),
[VoiceMediaPipeline](../../../Sources/DiscordVoice/VoiceMediaPipeline.swift) and
[VoiceJitterBuffer](../../../Sources/DiscordVoice/JitterBuffer.swift).

## Local completion and remaining gates

Phase 8 implementation and local software validation are complete. Construction
latency and bounded memory buy substantially lower repeated filtering cost in the
selected streams and affected encoder workflows. Codec scratch and queue changes
are deferred for the documented evidence/ownership reasons. The awkward fallback
adverse observation, impaired duplex failure and application-specific short-stream/
memory tradeoffs remain explicit. No numerical regression policy is selected.

Reserved-host acceptance, cumulative allocation-event/executor/lock profiling,
Linux/other-platform runtime, hosted CI, physical Apple capture/render/routing,
acoustic latency, live Discord and long-duration production qualification remain
open. The selected cross-SDK checks establish compilation only. No device, hosted
workflow, push, publication or deployment is performed by this phase. Stages 9–10
remain planned under the existing stage boundaries.
