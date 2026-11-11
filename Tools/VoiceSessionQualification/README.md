<!--
File: Tools/VoiceSessionQualification/README.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->


The [measurement guide](../../Docs/Measurements.md) connects these workload
recipes to the versioned metric catalog, compact reports, comparison procedure
and qualification ledger.
# Local Voice session qualification

This independent executable uses actual localhost UDP sockets and continuous-clock
20ms pacing for two audio directions. Synthetic 48kHz mono PCM passes through the
owned Opus encoder, a real two-member MLS/DAVE epoch, RTP, transport AEAD, the
opposite UDP socket, both authentication layers, bounded jitter, and PCM decoding.
Both synthetic senders share the single same-key transport nonce authority.
The executable sends SwiftLog diagnostics to stderr and writes JSON to stdout and the optional `--output` file.

```sh
swift run --package-path Tools/VoiceSessionQualification -c release \
  VoiceSessionQualification --seconds 600 --output /tmp/voice-session-600s.json
```

Use `--seconds 2` for a smoke check. The default is 600 measured seconds; accepted
durations are 0.02 through 3,600 seconds. A separate 100-frame/two-second warmup
precedes measurement while preserving the same codec, RTP, DAVE and AEAD owners.
A report includes measured and lifetime packet/sample counts, processing
percentiles for each full two-direction tick (concurrent sends, both receives,
authentication and PCM decoding) excluding the explicit main pacing wait, missed 20ms processing and
schedule deadlines, pre-warmup cold and post-warmup initial/final/sampled-high
resident bytes, a once-per-second RSS trace, first/last-minute median RSS, signed
growth after warmup, and post-closure RSS. It also records the explicitly accounted
timing-sample storage, configured media/UDP buffer bounds, peak/final retained
jitter bytes, sampled DAVE queue counts, and awaited resource closure. The report
applies no invented RSS plateau or realtime pass threshold; the raw observations
and deadline misses remain visible.
Observed software scheduling delays are reported; their cause is not inferred.
They provide no real-time audio guarantee. Any socket/cryptographic/codec failure
exits nonzero after cleanup.

The private signing scalars and credentials are public fixtures. The tool performs
no DNS, authenticated Discord requests, WebSocket connection, device access, audio
playback, microphone capture, or persistence beyond the explicitly requested JSON.
The two-member signaling is synthetic even though MLS/DAVE cryptography and UDP
I/O are real. A successful run supplies local software-duplex evidence; it does
not establish hardware/acoustic, live Discord, independent-client interoperability,
cross-platform qualification, or independent cryptographic review.


## Shared timing sidecars

This tool adopts the development-only [shared harness](../DiscordBenchmarkSupport/README.md).
Set `DK_BENCHMARK_ENVELOPE` to write a separate schema-v1 common envelope while
retaining the native report. New whole-population histograms have distinct metric
identities and explicit precision, censor/loss counts and qualification limits.
Use the shared process driver for release receipts, bounded fresh-process runs and
partial artifacts. Legacy baseline readers remain available.

## Attributed and impaired profiles (native schema 3)

The default command retains the native schema-2, 20ms mono CELT, 64kbps path and
legacy sidecar identity. Select `--profile attributed` or any new media-policy
option to use the distinct native schema-3 runner. Its codecs use 96kbps for CELT and 256kbps for SILK/hybrid; profiles
with different frame geometry, mode, signal, impairment, DTX or contention have
separate common-envelope dimensions and cannot be compared interchangeably.
No new dependencies enter the runtime products.

```sh
swift run --package-path Tools/VoiceSessionQualification -c release \
  VoiceSessionQualification --profile attributed --seconds 3 \
  --dtx on --signal talkspurts --common-report /tmp/voice-attributed-common.json

swift run --package-path Tools/VoiceSessionQualification -c release \
  VoiceSessionQualification --seconds 2 --frame-samples 480 --channels 2 \
  --mode silk --loss-every 7 --reorder-every 5 --jitter-ms 20 \
  --contention-workers 1 --output /tmp/voice-impaired.json
```

| Option | Accepted values and policy |
| --- | --- |
| `--profile` | `attributed`; selects schema 3 explicitly |
| `--frame-samples` | 120, 240, 480, 960 at 48kHz: 2.5, 5, 10, 20ms |
| `--channels` | 1 or 2, fixed interleaved layout |
| `--mode` | `celt` (all sizes), `silk` or `hybrid` (480/960 only); SILK wideband, other modes fullband |
| `--dtx` | `on` or `off`; default off; on uses -80dBFS, 200ms hangover and the codec's 400ms refresh |
| `--signal` | `tone`, `silence`, or `talkspurts` (alternating one-second tone/silence) |
| `--loss-every` | 0 disables; otherwise drop every Nth offered measured packet interval, 1...1000 |
| `--reorder-every` | 0 disables; otherwise hold every Nth measured packet interval by at least one frame, 1...1000 |
| `--jitter-ms` | 0...100; deterministic receiver-side holds rounded to selected whole frames |
| `--contention-workers` | 0...4 bounded CPU tasks; canceled and awaited on every exit |
| `--common-report` | Catalog-9 common envelope path; also selects attributed mode; environment fallback `DK_BENCHMARK_ENVELOPE` |
| `--seed` | UInt64 fixture identity, default 1; attributed environment fallback `DK_BENCHMARK_SEED` |

All pairs, codec geometry and distinct standardized/symlink-resolved output
destinations are validated before keys, sockets or CPU workers are opened. Warmup is a separate two-second uninterrupted tone using the same
codec, RTP, cipher and MLS/DAVE owners. Signal policy and emulated impairment start
at measurement. Durations still range from 0.02 through 3,600 seconds; the selected
frame interval determines offered frames and deadline budgets. Attributed runs
honor `DK_BENCHMARK_DURATION_SECONDS` when `--seconds` is absent. Warmup remains
fixed at two seconds: attributed runs reject `DK_BENCHMARK_WARMUP_SECONDS` values
other than 2, and the common identity records requested and actual warmup and
requested duration independently. The recorded seed is an identity dimension;
this fixed tone/impairment recipe does not consume a random generator.

Impairment happens **after actual localhost UDP receipt**. It is explicitly
receiver-side emulation, with at most 64 pending adapter-bounded datagrams per
direction (262,144 payload bytes each). The fixed playout delay is the maximum
configured whole-frame hold. When delayed packets become due together, a later
packet is delivered first to exercise the production reorder window. Depending
on the combined loss/hold policy, a reorder selection need not produce an actual
inversion; the report labels it a selection. Final delayed media drains outside
the measured tick distributions. Decoded/concealed totals include this drain.
Peak pending counts/bytes are the sums of each direction's independently observed
maxima, a conservative retained bound rather than a simultaneous-peak claim.

The full `voice.tick` is directly timed around both send/receipt/available playout
paths, excluding the explicit main pacing wait and including any internal pipeline
pacing. This gross tick also retains the legacy-style buffer snapshots and PCM
frame/count/finite correctness checks; diagnostic work can perturb its duration.
`voice.pacingLate` measures scheduled tick to actual start. Full-tick
processing overruns and schedule underruns use **the selected frame interval**.
Child populations are observed public boundaries and overlap the full tick:

| Common metric | Exact observed boundary |
| --- | --- |
| `voice.encode` | Synchronous production Opus encoding, including DTX decisions |
| `voice.encrypt` | DAVE seal only; concrete transport AEAD remains in the integrated tick |
| `voice.send` | Actual UDP adapter send, excluding crypto and receipt |
| `voice.receiveDecrypt` | Public pipeline receive: transport AEAD, DAVE open, RTP/Opus validation, jitter insertion and actor scheduling |
| `voice.decode` | Public playout: jitter selection, Opus decode/PLC, PCM saturation and actor scheduling; no sinks |

No isolated pipeline jitter time is invented: the media component batch suite
measures exact jitter operations separately. These percentiles cannot be added or
subtracted to reconstruct full-tick latency. Early delayed ticks can have no
playout; final drain child observations are outside measurement. No per-frame
logs, UUIDs, media export, serialization or exporter callbacks run in the media
path; collection keeps bounded numeric histograms.

The native report reuses production pipeline encoding-deadline/max and raw
40ms-dispatch-gap counters, including warmup. It also independently checks each
actual transmission decision against the selected DTX policy using media-frame
time, reporting suppression, silence refreshes, talkspurt restarts and policy
cadence decision mismatches. It reports the largest expected dispatch gap from
the frame-policy schedule alongside the production maximum and its nonnegative
excess; observed scheduling delay is not inferred to be a lost packet. An intentionally suppressed frame is never a receive timeout
or lost-packet failure. Raw dispatch gaps remain visible and may intentionally
exceed 40ms during silence refresh periods. Counted refreshes and restarts describe
the input/transmission policy; they do not establish perceptual quality.

RSS, final retained media bytes, sampled DAVE queues and awaited closure receipts
remain present. The common envelope distinguishes sampled-high RSS from unavailable
process-lifetime peak RSS. Pipeline, DAVE, sockets and contention tasks close
before report serialization. All results remain local informational software
qualification, with no baseline regression, universal realtime, other-platform,
hardware/acoustic, live Discord or independent cryptographic qualification claim.

Run configuration, bounded-emulation, actual codec DTX policy, attribution-failure
and owned-task checks with:

```sh
swift test --package-path Tools/VoiceSessionQualification
```
