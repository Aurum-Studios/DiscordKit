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

The finite catalog preserves its 80 original cases and 18 version-two
continuous cases, 45 version-three Stage 8 controls and 31 version-four Stage 9
secure voice/transition/accounting controls (174 total).
Original cases cover bandlimited 16/44.1 kHz to 48 kHz resampling
in mono/stereo; Opus encode/decode/conceal/recover in CELT 120/240/480/960 and
SILK/hybrid 480/960 samples in mono/stereo; reordered jitter insertion/playout with
one explicit lost slot; RTP packetization/serialization/parsing; AES256-GCM and
XChaCha20-Poly1305 transport seal/open; DAVE frame seal/open; MLS group creation,
Welcome join and epoch rekey; and concurrent DAVE transition signaling admission.
CELT recovery intentionally selects the API's documented PLC fallback. SILK and
hybrid fixtures enable in-band FEC. These fixtures do not establish recovered
audio quality or external codec interoperability.

Version-two cases have distinct IDs and workload dimensions:

- `resample.v2.continuous.{16000,44100}.48000.{mono,stereo}` uses one FIR owner
  across a complete population. Eight 20 ms blocks prefill actual filter history;
  only `process` runs inside batch timers. A final untimed flush checks exact
  stream duration and bounded retained history against an independent owner.
- `opus.v2.continuous.{encode,decode}.{celt,silk,hybrid}.960.{mono,stereo}` retains
  encoder/decoder state after eight contiguous 20 ms prefill frames. Inputs advance
  on the actual sample clock, stereo channels differ, and every packet/PCM output
  is compared with a separately owned continuous reference. Decode packet creation
  stays outside timing; these cases make no loss-recovery quality claim.
- `dave.v2.frame.open.replay{1024,8192}` fills the production-default or supported
  maximum replay window before timing, then keeps the same receive owner while
  unique authenticated frames advance through successive batches. Logical 20 ms
  receive timestamps describe deterministic media progression without pacing.
  Complete plaintext checks and a final exact replay rejection are untimed.

Each warmup/measured population creates and closes its own version-two owner;
individual batch result release does not reset stream state. Cancellation and
failure close the long-lived owner before returning. Preparation that hits a wall
cap can be discarded without advancing DSP reference state. These are new workload
identities, not comparable replacements for the original cold/per-batch cases.
The scheduler identity is `serial-population-stream-v2`; input sizes record fixture
version, prefill and continuous-state policy. Fixture descriptor hashing includes
the exact new case identity and retains the original hash recipe for old cases.

Version-three resampler controls cross mono/stereo with rate pairs 16000→48000,
44100→48000, 48000→16000, 48000→44100 and the relatively-prime 48000→47999
fallback ratio. Each pair/layout has four independent endpoint identities:

- `resample.v3.startup.{input}.{output}.{mono,stereo}` times construction of a new
  empty converter per call. Results remain retained until untimed full-signal
  verification; process and finish stay outside construction timing. This records
  the initialization cost of an eagerly constructed coefficient plan.
- `resample.v3.continuous.{input}.{output}.{mono,stereo}.{regular,irregular}`
  keeps one owner after eight 20 ms prefill blocks. Regular calls admit 20 ms;
  irregular calls rotate 1, 127 and 509 source frames across batch boundaries.
  Only process is timed. Complete outputs are compared with an independently
  constructed owner and final untimed finish checks sample-count carry, finite
  PCM and released history. Small chunks can produce no output while awaiting
  filter lookahead; normalized cost per call therefore has a different input
  population from regular chunks.
- `resample.v3.finish.{input}.{output}.{mono,stereo}` times finish on separately
  constructed and processed 20 ms owners. Initialization, process and the exact
  tail oracle stay outside timing. Each owner must release all history and
  remain idempotently finished after its complete tail comparison.

`pcm.v3.queue.occupancy{1,8,64,1024,4096}` separates queue depth from resampling
and codec service. A population starts full and every timed call performs one
public read plus write, maintaining the selected occupancy. Blocks contain 960
stereo frames at 48 kHz, with distinct interleaved channel values; bytes per block
remain 7680 while depth changes. Depth 8 is the default queue block limit and
4096 is the supported maximum (31,457,280 retained PCM bytes). Two actor hops,
FIFO removal/insertion and result retention are included. Fixture construction,
complete FIFO checks, byte accounting, finish and exact final drain are untimed.
These cases do not establish mailbox residence, producer/consumer contention,
audio pacing or realtime scheduling. Each owner is closed with discard after
verification or failure, and discarded preparation cannot advance its reference.

Version-three continuous/queue cases use scheduler `serial-population-stream-v3`;
startup and finish retain `serial-wrapper-batches`. Existing identities, fixture
hash recipes and scheduler policies remain unchanged. Warmup and measurement
receive independent owners, and the common sidecar retains every measured batch.
Compare only matching endpoint, rates, layout, chunk/occupancy policy and batch
size. Constructor, process and finish percentiles are separate populations and
must not be summed into an inferred whole-stream percentile.

Version-four DAVE controls cover windows 64, 1024 and 8192. The nine
`dave.v4.open.{steady,reorderDuplicate,authenticationFailure}.replay{64,1024,8192}`
identities each authenticate a complete replay window before timing and retain
the same receiver through every population batch. Steady wrappers authenticate
one frame. Reorder/duplicate wrappers authenticate two unique frames in reverse
nonce order, then reject an exact duplicate. Authentication-failure wrappers
reject a corrupted tag before accepting the valid frame with that exact nonce;
this exercises authenticate-before-replay commit without replacing real verification
budgets. Every plaintext and rejection classification is checked outside timing.
Logical 20 ms receive clock advancement is deterministic progression, without
audio pacing. Timed wrappers include all documented opens, actor hops and result
retention, so compare matching policies rather than treating them as equivalent
single-open populations. Failure populations retain the real 131072 failed-open
limit per generation; choose finite batch counts below that limit or the run fails
with the ordinary verification budget error. Warmup has an independent owner.

`dave.v4.expiry.replay{64,1024,8192}` isolates a different endpoint: one actual
generation expiry/prune plus authenticated current-generation open per call.
Every call has an independently prepared receiver with a complete generation-zero
window near the nonce boundary. Public ratchet, AES-GCM and frame APIs construct
these public inputs; no production transmit counter is reset or overridden.
Preparation authenticates generation one at logical time zero and a previously
unseen generation-zero frame at nine seconds. The timed open at eleven seconds
passes the immutable ten-second deadline and expires the old generation. Untimed
verification rejects a second withheld old frame using the ordinary modulo-generation
and future-distance policy, then rejects the timed frame's replay. Prefill and
all expiry endpoint construction stay outside batch timers. Population elapsed
time/throughput include that preparation and must not be compared to continuous
receiver throughput as if their setup populations were identical.

The twelve MLS identities
`mls.v4.{add1.dense,remove1.dense,remove3.dense,remove1.sparse}.members{4,8,16}`
prepare bounded groups with real native entropy. Dense groups start with the
named member count. Sparse groups first remove an interior leaf outside timing,
retaining a hole and one fewer live member than the original tree allocation.
Addition controls cache one authenticated Add and advance N to N+1 members;
the addressed Welcome recipient joins outside timing before complete agreement
checks. Removal controls cache one or three authenticated Remove proposals outside timing.
Each timed wrapper prepares a fresh commit and accepts it at every live peer,
including owners removed by that commit. Untimed checks require exact outcomes,
epochs/member counts, empty proposal/candidate state, changed and agreed exporters,
agreed epoch authenticators, and closed removed owners whose exporters fail.
These controls measure commit processing with cached proposal counts; they do not
measure proposal admission latency.

`mls.v4.mixed.dense.members8` joins a one-removal eight-member transition with
64 DAVE opens on an independent receiver whose default 1024-frame replay window
was prefilled outside timing. Every call starts two bounded asynchronous jobs
and joins both before retaining its complete outcomes. Media and MLS use separate
key domains; this is a local contention/control-progress workload without network
pacing, MLS-to-DAVE manager installation or secure-ready timing. Its scheduler is
`joined-concurrent-transition-media-batches-v4`, concurrency two; other MLS and
expiry endpoints keep `serial-wrapper-batches`. Continuous DAVE policies use
`serial-population-stream-v4`. Existing IDs and fixture hash recipes are preserved.

Six matched accounting controls cross payload sizes 80, 1200 and 16000 bytes:
`rtp.v4.accounting.serialize.payload{80,1200,16000}` serializes eight immutable
packets solely to obtain their exact lengths, matching the work removed from
jitter accounting. `jitter.v4.accounting.insertPop.payload{80,1200,16000}` inserts
the same eight packets in reverse order into an empty capacity-eight jitter
buffer and pops all of them. Every packet includes two CSRCs, an eight-byte
extension and four padding bytes; exact wire size is payload plus 36 bytes.
Untimed oracles check every byte count and every complete popped packet across
wrapping sequence counters. Jitter wrappers include construction, insertion,
accounting and retained playout results. The serialization control has a different
operation population and its percentile must not be subtracted from jitter's;
use matched before/after jitter captures to assess the internal accounting change.

For example, capture a matched full-window steady population with:

```sh
Tools/DiscordMediaBenchmarks/.build/release/DiscordMediaBenchmarks \
  --case dave.v4.open.steady.replay8192 --profile standard --seed 1 \
  --batches 1000 --batch-size 64 --warmup-batches 10 \
  --duration-seconds 30 --warmup-seconds 5 \
  --output /tmp/dave-steady-native.json --common-report /tmp/dave-steady-common.json
```

Use independent fresh processes and the same binary/toolchain/profile/seed/batch
policy for before/after captures. Expiry and MLS fixtures can consume substantial
preparation time, so use smaller batch sizes and retain actual completed counts;
a time-cap-discarded fixture is closed and contributes no timed sample.

Each timed batch invokes only its selected bounded wrapper and retains the full
results for untimed verification. Original codec/resampler cases copy prepared initial or
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
