<!--
File: Tools/DiscordMediaBenchmarks/README.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->


The [measurement guide](../../Docs/Measurements.md) connects these workload
recipes to the versioned metric catalog, compact reports, comparison procedure
and qualification ledger.
# DiscordMediaBenchmarks

Release-only timing wrappers for local media, voice cryptography, MLS and DAVE.
The package uses real public implementations without starting a network, audio
device, live Discord connection or background runtime service. Fixed signing
scalars and symmetric inputs are **public fixtures** and provide no confidentiality.
MLS retains native random ephemeral key generation and epoch entropy. The fixture
descriptor hash identifies the selected deterministic inputs, not random key bytes.

```sh
swift build --package-path Tools/DiscordMediaBenchmarks -c release --jobs 4
Tools/DiscordMediaBenchmarks/.build/release/DiscordMediaBenchmarks --list-cases
Tools/DiscordMediaBenchmarks/.build/release/DiscordMediaBenchmarks \
  --case opus.encode.celt.960.stereo --profile smoke --seed 1 \
  --batches 10 --batch-size 4 --warmup-batches 2 \
  --duration-seconds 10 --warmup-seconds 1 \
  --output /tmp/media-native.json --common-report /tmp/media-common.json
swift test --package-path Tools/DiscordMediaBenchmarks --jobs 4
```

The finite 80-case catalog covers bandlimited 16/44.1 kHz to 48 kHz resampling
in mono/stereo; Opus encode/decode/conceal/recover in CELT 120/240/480/960 and
SILK/hybrid 480/960 samples in mono/stereo; reordered jitter insertion/playout with
one explicit lost slot; RTP packetization/serialization/parsing; AES256-GCM and
XChaCha20-Poly1305 transport seal/open; DAVE frame seal/open; MLS group creation,
Welcome join and epoch rekey; and concurrent DAVE transition signaling admission.
CELT recovery intentionally selects the API's documented PLC fallback. SILK and
hybrid fixtures enable in-band FEC. These fixtures do not establish recovered
audio quality or external codec interoperability.

Each timed batch invokes only its selected bounded wrapper and retains the full
results for untimed verification. Codec/resampler cases copy prepared initial or
warmed state per call; their batch includes those value copies and complete output
materialization. Resampling includes process and finish. Jitter covers three
reordered packets and four playout slots. RTP covers packetize, serialize and parse.
Seal/open cases keep transmit/replay state in distinct public actor owners, use
unique counters inside each prepared batch, and verify every plaintext outside
the timer. Only public fixture key domains are restarted between independent
batches; these keys must never protect real media.
CELT uses 64 kbps; SILK/hybrid use 256 kbps to retain a valid bounded stereo FEC
fixture across both frame durations. The executable installs a task-scoped no-op
logger so no synchronous log I/O runs during measured operations.

MLS creation times createGroup on a prepared package; join times addressed Welcome
validation/consumption. Rekey starts with two agreed members, admits a third member's
Add outside the timer, then times fresh TreeKEM commit preparation plus local and
remote acceptance. Untimed oracles check epoch/member/proposal state, shared
exporters and changed key material. Every group/package is explicitly closed.
The DAVE queue batch submits batch-size concurrent repeated prepare-transition
controls against one active sole-member epoch. It includes task scheduling, public
adapter admission and joined ready-command production. Untimed verification
executes the transition and confirms an idle drained queue; closure joins the
owned adapter cleanup. It measures the combined caller/admission workload and
does not isolate queue residence or guarantee a particular queued depth.

The common envelope uses catalog version 9, adapter DiscordMediaBenchmarks.v1 and
media.batch or mls.transition distributions. Histograms/counts represent **batches**;
native completedCalls and normalizedMeanNanoseconds describe wrapper calls.
Normalized means include loop/result-storage/actor-hop work and are not per-call
percentiles. No clock overhead is subtracted. Histogram precision is 10 microseconds
through five seconds; overflow and sparse p99 remain explicit. The native maximum
retains the exact directly observed maximum batch duration.

Fixture preparation, full semantic verification, serialization, resource probes and
awaited closure are outside batch timers. Population elapsed time and common
throughput include per-batch setup, oracles and closure. Process CPU/RSS gauges have
process scope; peak RSS includes startup and warmup. No scheduled playout deadline
exists in this microbenchmark, so zero deadline misses is not a realtime result.
frameIntervalNanoseconds, where present, describes the codec frame duration rather
than a scheduling qualification. Cryptographic timing establishes no security
property or independent cryptographic qualification.

Options use strict key/value pairs. Profiles are smoke/standard/stress/soak; batch
count is 1...10000, batch-size 1...64, warmup batches 0...1000, warmup seconds
0...60, and duration 1...10 seconds for smoke, 1...300 for standard/stress or
1...3600 for soak. Warmup zero admits no batches. Time caps/cancellation are
checked between batches and following preparation; a started bounded native call
finishes. Unknown cases/options, duplicates, invalid integers, aliased report
destinations and nonserial supervisor concurrency are rejected before allocation.
Shared DK_BENCHMARK_PROFILE/SEED/DURATION_SECONDS/WARMUP_SECONDS/CONCURRENCY/ENVELOPE
environment settings are honored; explicit options win. Queue caller concurrency
is separately recorded as batch-size. The combined Phase 9 supervisor declares
that actual queue caller fanout to its process receipt, while passing explicit
`--concurrency 1` to keep this tool's outer batch loop serial. Use external process supervision for signals,
fresh-process runs and a hard wall-clock shutdown bound. Debug tests validate
correctness and timer boundaries with injected clocks; debug timings are not
performance evidence. No baseline, numerical gate, device or hosted qualification
is established by this tool.
