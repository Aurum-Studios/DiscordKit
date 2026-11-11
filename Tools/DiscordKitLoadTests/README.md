<!--
File: Tools/DiscordKitLoadTests/README.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->


The [measurement guide](../../Docs/Measurements.md) connects these workload
recipes to the versioned metric catalog, compact reports, comparison procedure
and qualification ledger.
# Local runtime measurements

This development-only Swift package exercises the implemented NIO HTTP adapter
against an owned Python HTTP/1.1 loopback peer. It is separate from runtime
products, root unit tests and Discord's services. It never reads credentials.

Run from the repository root:

```sh
swift test --package-path Tools/DiscordKitLoadTests
python3 -m unittest discover -s Tools/DiscordKitLoadTests/scripts -p 'test_*.py'
swift run -c release --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests --profile accounts-100 --scenario transport
swift run -c release --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests --profile accounts-1000000 --scenario transport --burst
swift build -c release --package-path Tools/DiscordKitLoadTests
python3 Tools/DiscordKitLoadTests/scripts/record_baseline.py
```

Python 3 must be on PATH. The source checkout supplies profiles and the peer
script. The harness creates/reaps its peer, consumes every successful body to
EOF and closes the transport before reporting. HTTP and Gateway policy scenarios
use finite offline scripts with no sockets or credentials. Cache and soak scenarios
exercise fixed-size cache and broadcast recovery workloads locally on macOS 15 or newer.
The executable sends SwiftLog diagnostics to stderr and writes one JSON report to stdout.


## Shared timing sidecars

This tool adopts the development-only [shared harness](../DiscordBenchmarkSupport/README.md).
Set `DK_BENCHMARK_ENVELOPE` to write a separate schema-v1 common envelope while
retaining the native report. New whole-population histograms have distinct metric
identities and explicit precision, censor/loss counts and qualification limits.
Use the shared process driver for release receipts, bounded fresh-process runs and
partial artifacts. Legacy baseline readers remain available.

## Version 1 workloads

The `cache` and `soak` scenarios use these profiles only for their logical population
and bounded payload size. They select 1/2/4 opaque credential scopes for the
100/10,000/1,000,000 logical populations, sharing one process-local authority.
Each scope uses the same 20 entity keys across every round, with at most 16 retained
entries and 64 KiB of accounted bytes. A gated refresh storm admits eight callers
to one loader; 16 offered callers normally, or 64 with `--burst`, expose explicit
fail-fast refusal and coalescing counts. Every round also checks eviction, exact
TTL expiry, local-write invalidation/recovery and one slow broadcast subscriber's
overflow while a healthy subscriber receives all three publications.

```sh
swift run -c release --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests --scenario cache --profile accounts-100
swift run -c release --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests --scenario cache --profile accounts-1000000 --burst
swift run -c release --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests --scenario soak --profile accounts-10000 --rounds 512
swift run -c release --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests --scenario soak --profile accounts-1000000 --burst --duration-seconds 1800
python3 Tools/DiscordKitLoadTests/scripts/record_cache_baseline.py
```

`cache` defaults to eight exact rounds and `soak` to 512; `--rounds` accepts
1 through 1,000,000 for either scenario. The report records configured/completed
rounds and actual wall duration. TTL advances use a deterministic clock without
real-time sleeps. Soak also accepts `--duration-seconds` in 1...3,600 and continues
until both minimum rounds and actual duration have elapsed. At most 121 checkpoints
record actual process RSS/live heap and accounted cache bytes (about every 15 seconds
for a 30-minute run), with initial and final observations retained. A short run
labeled `soak` does not establish 30-minute soak qualification. Accounted cache bytes exclude allocator/task/index overhead; actual
process RSS and live malloc gauges appear separately in `ProcessSample`. These
local scenarios allocate no account population, create at most 64 storm tasks,
use no sockets/credentials and establish no distributed or fleet capacity claim.

Cache/soak measurements and their source/executable checksums are retained
in `Baselines/cache-*.json`, `Baselines/soak-*.json` and the cache/soak environment
records. Repeated finite Gateway lifecycle checks are retained separately
under `Baselines/Gateway`; the original Gateway baseline files and scenario
description below document the original Gateway run. Reproduce new Gateway evidence with
`python3 Tools/DiscordKitLoadTests/scripts/record_gateway_baseline.py --output-dir Tools/DiscordKitLoadTests/Baselines/Gateway`.

The four-scope burst soak completed 238,427 rounds over 1,800.004 seconds:
953,708 loaders served 7,629,664 admitted reads, while 53,407,648 excess offers
were explicitly refused. Peak retained state was 64 entries, 72,512 accounted
bytes, one refresh, eight waiters and two broadcast events; all owned counters
returned to zero. Across 121 checkpoints, process RSS peaked at 9.27 MiB and
remained exactly 8.375 MiB throughout the final five minutes. Live malloc bytes
in that window ranged from 326,784 to 360,960. This measured interval showed no
sustained growth. RSS includes runtime/allocator pools, loaded code and bounded
checkpoint metadata, separately from cache accounting; retention remained above
cold start after owned resources were released. The
[report](Baselines/soak-accounts-1000000-1800s-burst.json) and
[environment](Baselines/soak-1800s-environment.json) preserve executable/source
checksums, final source-drift classification and measurement limits. This run
exercises cache and broadcast recovery; reducers, permissions, handlers, the
Client facade, real shard/network execution and fleet capacity remain outside it.

Accounts mean **served end users**. Bot identities, workers, guilds and shards
are workload dimensions simulated arithmetically inside one client process;
there are no actual bot credentials, Gateway sessions or distributed workers.
Each active logical user contributes 100 GET operations, with a fixed 1,024-byte
response. No full account population is allocated.

| Logical accounts | Bot identities | Simulated workers | Guilds / shards | Active users | Exchanges | Normal task cohort / pool slots |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 1 | 1 | 10 / 1 | 100 | 10,000 | 8 / 8 |
| 10,000 | 4 | 4 | 1,000 / 4 | 1,000 | 100,000 | 16 / 16 |
| 1,000,000 | 16 | 4 | 10,000 / 16 | 1,000 | 100,000 | 32 / 32 |

For transport measurements, all profiles use one origin, no upload, a 1,024-byte response cap, a 4,096-byte
header budget and 1,024-byte read chunks. The response consumer immediately
pulls to EOF; the separate cache/broadcast workload above exercises slow subscribers. Transport admission
is fail-fast: queued count/bytes/age are zero, cache count/bytes are zero, and
pool ownership records are bounded by the configured connection cap. The
`maximumMetadataEntries` budget counts those ownership slots, not every runtime
allocation. Live malloc gauges and process RSS expose the additional overhead.

A burst offers ten times the task cohort while retaining the same socket cap.
The harness creates at most 80/160/320 child tasks, replenished as each completes;
it never creates a task or socket per logical account. Refused requests are
counted separately, without retry. This is a closed-loop saturation test, not
an arrival-rate simulator or a claim about admitted REST/Gateway throughput.

The initial reference-hardware acceptance thresholds for normal runs are p99 at
most **25 ms** over the bounded successful latency sample and at least **5,000
successful exchanges/s**. All runs have **64 MiB peak client RSS** and **32 MiB
end-of-workload live heap** budgets. These are versioned local acceptance
thresholds, not promised runtime capacity. Burst runs measure saturation and
refusals; their latency and throughput do not establish a service level.
Recheck budgets when the workload, hardware, payload, adapter or runtime changes.

## Recorded baseline

The committed release measurements ran on an Apple M3 Max, 14 processors,
36 GiB RAM, macOS 27.0.1 and Swift 6.4. The normal runs met their local acceptance
thresholds, with zero refused or failed requests. Physical accepted and peak
socket counts were exactly 8/16/32, so these runs reused their original sockets.

| Logical accounts | Successful exchanges/s | p50 / p95 / p99, ms | Client CPU, one-core % | Peak client RSS, MiB | EOF live heap / settled live heap, MiB | Actual peak sockets |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 16,559.6 | 0.391 / 0.918 / 1.386 | 275.2 | 15.17 | 3.98 / 0.76 | 8 |
| 10,000 | 18,626.2 | 0.743 / 1.424 / 1.931 | 285.0 | 16.50 | 4.63 / 0.98 | 16 |
| 1,000,000 | 20,133.8 | 1.402 / 2.539 / 4.018 | 298.3 | 17.52 | 5.28 / 1.05 | 32 |

With ten times the offered task cohort, admitted/refused counts were
112/9,888, 1,200/98,800 and 1,216/98,784 respectively. These runs had no failed
requests and kept physical socket peaks at 8/16/32. Burst p99 values were
6.332/10.198/24.893 ms; burst latency is recorded without a service-level gate.
All six runs closed every client-owned pool slot. JSON evidence retains exact
CPU, byte, latency, deadline and counter values; settled gauges were sampled one
second after cleanup. Peak RSS in this table includes that settling interval.

## Measurement scope

Each JSON result reports offered/admitted/refused/failed work, actual payload
bytes, wall duration, successful exchanges/s, sampled pool slots, p50/p95/p99,
client CPU and peak/current RSS. The peer separately counts accepted, active and
peak physical TCP connections. Its active count is captured immediately before
process termination, so it may include sockets whose client FIN has not yet been
observed; the process is then reaped. Latencies cover headers plus full body EOF and
retain at most the first 4,096 successful samples. The `steady` memory field
is an **end-of-workload snapshot**, not proof of a steady-state process.

On Darwin, malloc-zone live block/byte gauges expose live heap retention; they
are not cumulative allocation events, allocation call stacks or a substitute
for an Instruments allocation trace. CPU/RSS exclude the Python peer and other
processes. CPU percentage is relative to one core and can exceed 100%. Pool
slot peaks are sampled after headers and can miss transient peaks; the fixed
configured cap and zero active/idle slots after shutdown are reported separately.

The committed environment record names hardware, OS, compiler, configuration,
time and source-commit basis. The working tree was dirty because these are
measurements of the change being prepared. A short local baseline does not
qualify a distributed fleet, a million simultaneous identities/connections,
Gateway control delay, request reduction, minimum-OS behavior or a 30-minute
fixed-working-set soak. Later scenario sections and cache/soak records
provide evidence for their independently measured subsets.

Allocation diagnostics preserve the same workload and allow isolation without
network sockets or deadline races:

```sh
swift run -c release --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests --profile accounts-100 --scenario transport --portable
swift run -c release --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests --profile accounts-100 --scenario transport --without-deadline
swift run -c release --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests --profile accounts-100 --scenario transport --portable --settle-seconds 12
```

The optional wall-time settling delay is a performance diagnostic; deterministic
unit tests use no sleeps. Disabling deadlines is an explicit diagnostic and is
never the ordinary baseline configuration.

The diagnostics found a cancelled native `ContinuousClock.sleep` allocation
history that persisted until its original ten-second deadline. The transport
deadline helper now checkpoints continuous-clock waits at most 100 ms ahead,
preserving clock semantics while shortening that retention window. In the
portable diagnostic, increasing work from 10,000 to 100,000 exchanges left
21.29/24.00 MB of live heap at EOF and 0.79/1.43 MB after one second. These
decimal-byte figures and the original isolation runs are preserved in
`Baselines/deadline-allocation-regression.json`; they are diagnostics, not socket
capacity results. Allocator RSS can stay elevated after live blocks are freed.

## Offline HTTP policy measurements

The HTTP scenario exercises the HTTP execution pipeline with an entirely local
scripted HTTP adapter: zero credentials, zero network requests and zero sockets.
It measures policy overhead separately from the existing loopback transport
measurements. Run all three logical populations in normal and tenfold-burst modes:

```sh
swift test --package-path Tools/DiscordKitLoadTests
swift build -c release --package-path Tools/DiscordKitLoadTests
swift run -c release --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests --scenario http --profile accounts-100
python3 Tools/DiscordKitLoadTests/scripts/record_baseline.py --scenario http
```

The numeric HTTPProfiles are separate from transport profiles. Logical accounts
still mean served end users. They allocate only 2/4/16 actual opaque credential
partitions, each with one client, inside one process. No population-sized user
array, distributed worker or Discord connection is created.

| Served-user dimension | Actual identities | Logical requests | Normal / burst task cohort | Queue / in-flight caps | Queued bytes | Cache entries / payload bytes | Rate metadata cap |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 2 | 2,000 | 8 / 80 | 16 / 8 | 32 KiB | 16 / 32 KiB | 256 |
| 10,000 | 4 | 10,000 | 16 / 160 | 32 / 16 | 64 KiB | 32 / 64 KiB | 512 |
| 1,000,000 | 16 | 20,000 | 32 / 320 | 64 / 32 | 128 KiB | 128 / 256 KiB | 2,048 |

The mix is 40% explicit 60-second TTL reads, 30% eligible coalesced read storms,
10% hot-bucket reads, 10% independent reads and 10% reads rejected once with a
429 before succeeding. Returned successes contain exactly 256 bytes. Artificial
wire latency is 1 ms; hot buckets announce a 2 ms reset and rejected retries a
1 ms delay. The synthetic initial global allowance is 1,000,000/s solely to
isolate policy overhead; it is never a Discord quota or recommended setting.

All profiles require normal successful p99 at most 100 ms and peak process RSS
at most 128 MiB. Burst runs retain the same resource caps; refusals are expected
and have no latency service-level gate. Reports retain the first 4,096 successful
latencies, request savings, retry responses, per-identity success extrema and
sampled queue/cache/metadata/active peaks. Configured caps and deterministic root
tests establish hard bounds; sampling may miss a transient peak. Every run closes
coalesced work, the coordinator and cached entries before reporting cleanup.
These local measurements do not qualify Discord quota throughput, distributed
fairness, simultaneous user connections or a 30-minute soak.

The recorders execute one process at a time. Final HTTP and Gateway captures run
serially after release compilation and validation finish, with all six HTTP runs
followed by all six Gateway runs. These finite scripts measure bounded local
policy and lifecycle work; sustained deployment capacity remains unqualified.

The final release measurements below were recorded serially on 2026-10-16 using
Apple Swift 6.4 on an Apple M3 Max (38,654,705,664 bytes RAM). The checked-in
[HTTP environment](Baselines/http-environment.json) records the source revision
basis and exact source fingerprints used for this run. Each JSON report
in [Baselines](Baselines) includes raw counts, CPU time, latency quantiles for successful requests,
configured budgets and sampled resource peaks.

| Served-user dimension | Mode | Successful / refused requests | Wire exchanges | Avoided exchanges | Sampled p99 (ms) | CPU (s) | Peak RSS (MiB) |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | Normal | 2,000 / 0 | 1,053 | 1,147 (57.4%) | 10.939 | 0.482 | 9.97 |
| 100 | Burst | 1,235 / 765 | 166 | 1,095 (88.7%) | 30.515 | 0.242 | 12.34 |
| 10,000 | Normal | 10,000 / 0 | 5,089 | 5,911 (59.1%) | 10.080 | 1.276 | 11.50 |
| 10,000 | Burst | 6,645 / 3,355 | 978 | 5,816 (87.5%) | 56.618 | 1.310 | 14.48 |
| 1,000,000 | Normal | 20,000 / 0 | 10,020 | 11,980 (59.9%) | 4.616 | 2.202 | 13.61 |
| 1,000,000 | Burst | 14,386 / 5,614 | 2,889 | 11,979 (83.3%) | 83.184 | 3.262 | 17.45 |

Avoided exchanges equal successful logical requests minus non-retry wire
exchanges; percentages use successful logical requests as their denominator.
Normal runs exercised exactly 200/1,000/2,000 explicit retry responses, and every
identity completed its equal request share. All twelve final HTTP/Gateway captures
passed their recorder gates. The six HTTP runs had zero unexpected failures,
zero cancellation and zero retained active requests, queued requests, coalesced
flights or cache entries after shutdown. Burst refusals preserve the configured
resource caps and change the successful request mix, so their savings percentages
describe admitted work rather than the entire offered workload.

The separate Gateway scenario exercises finite local session scripts and owned
shard groups without opening sockets or reading credentials:

```sh
swift run -c release --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests --scenario gateway --profile accounts-100
swift run -c release --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests --scenario gateway --profile accounts-1000000 --burst
python3 Tools/DiscordKitLoadTests/scripts/record_gateway_baseline.py
```

HTTP and Gateway scenarios reject transport-only portable/deadline/settling flags;
all recorded control traffic and responses are script-produced.

Each selected shard now completes three ready-session rounds separated by two
scripted reconnects. Every round sends production presence and voice-state
commands, then completes member, soundboard and channel-info requests through
the production correlation registry. Member responses arrive as two chunks in
reverse order; all four response events per round pass typed dispatch decoding.
The report requires exactly three completions per request family, twelve typed
response events and fifteen application writes per selected shard. The raw
dispatch target remains a separate count controlled by the selected profile.

The scenario shares command authority across each synthetic bot's shards, uses
at most four pending requests and 65,536 response bytes per shard, and retains
at most eight response events per request and 32 correlation keys per shard.
It reports aggregate configured ceilings alongside actual pending request and
application write counts after shutdown; both must be zero, together with owned
connections and leases. Producer credits bound raw ingress while each request
round runs, and reconnect gates wait for that round's replies before replacing
the socket. Each socket requests at most one extra heartbeat after eight raw
events, bounding control-delay samples to three per shard while respecting
production send-rate admission. These finite scripts qualify local recovery and correlation only;
they do not establish real Discord quotas, network throughput, distributed
coordination or sustained production capacity.

## Phase 5 transport and REST timing

The explicit `timing` subcommand implements the [Phase 5 plan](../../Docs/Tasks/latency-timing/PHASE-5.md)
without changing the legacy entry points or reports above. It lists finite transport,
REST, independent-arrival and held-owner ordering cases:

```sh
swift run --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests timing --list-cases
swift run --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests timing \
  --case rest.cacheFresh --requests 64 --concurrency 4
swift run --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests timing \
  --case arrival.rest --requests 128 --rate 20000 --concurrency 4 --pending 8
```

The native report is `DiscordKitLoadTests.timing` version 1, containing the selected
native family and a common version-1 envelope with catalog revision 5. Optional
`--output` and `--common-report` destinations must differ. Shared-driver environment
requests are honored. Cases are deterministic; the recorded seed remains a
comparison dimension. Fixture contents and exact source/build pins are bound by
the release supervisor, outside operation timers.

For retained optimized smoke, finish source edits before preparing the receipt:

```sh
python3 Tools/DiscordBenchmarkSupport/scripts/run_benchmarks.py build \
  --repository . --package Tools/DiscordKitLoadTests --product DiscordKitLoadTests \
  --receipt .build/timing-phase5/release.json
python3 Tools/DiscordKitLoadTests/scripts/run_timing_suites.py \
  --executable Tools/DiscordKitLoadTests/.build/release/DiscordKitLoadTests \
  --receipt .build/timing-phase5/release.json --output-dir .build/timing-phase5/matrix
```

The wrapper runs serial fresh processes, captures all finite cases, separates
scripted/NIO/Foundation adapters, adds cold serial and verified NIO TLS cases, and
sweeps arrivals at 200/2,000/20,000 per second with 1/4/16 workers. Each queue is
bounded at twice its worker count. Repeated `--case` options select subsets;
`--scripted-only` excludes native socket cases. Default request count is 128 and
warmup count eight; the shared smoke supervisor bounds wall time, RSS, output,
process groups and teardown. The compact matrix links full reports. Failed or
interrupted captures remain available and stop the sequence. Wrapper signals are
forwarded to the active supervisor and its cleanup is awaited.

Direct settings include `--adapter scripted|nio|foundation`,
`--connection-mode cold|warm`, `--tls true|false`, `--requests`, `--concurrency`,
`--pending`, `--rate`, `--delay-microseconds`, `--warmup-requests`, `--profile`,
`--seed`, `--duration-seconds`, `--warmup-seconds`, and output options. Smoke admits
at most 64 workers; other shared profiles allow 256. Requests cap at 100,000,
warmup requests at 10,000, and active plus pending arrivals at 1,024. Native cold
runs require one worker and a fresh adapter for every exchange. Non-native cases
use the scripted adapter and warm policy. Foundation requires a supported native
host; it has no injected test-root path. Verified fixture TLS is NIO-only and
never disables hostname/certificate validation.

Transport cases cover empty, 256-byte, 64-KiB streamed and 1-MiB response/upload
bodies, delayed headers/body, malformed content, cancellation and timeout.
Construction is separate from adapter invocation. Whole requests include byte
validation, EOF and awaited close; diagnostic snapshots occur afterward. Headers
include unavailable pool/connect/TLS/upload internals. Producer chunks describe
source pulls, not actual socket write boundaries. Explicit close can be an
idempotent join after automatic EOF cleanup. No unavailable subphase is inferred
by subtraction. Transport child distributions use the final caller outcome.

REST cases cover no cache, misses, fresh hits, expiry, exact same-key coalescing,
independent keys, streamed/large bodies, delayed headers/body, ordered mutations,
429 and server retry, exhausted retries, malformed responses, cancellation and
uncertain mutation. The real RESTClient owns rate/retry/order/cache/coalescing.
New optional [REST phase hooks](../../Sources/DiscordHTTP/RESTTiming.swift) expose
construction/order/cache/decode/backoff; existing hooks retain their meaning.
Phase distributions retain boundary-local outcomes. Fresh hits exchange nothing;
coalesced subscribers each retain a logical result while sharing one exchange.
Setup priming and expiry waits are outside individual request timers. Inter-wave
gaps remain in the whole throughput denominator.

Stage 0 adds explicit versioned scheduling controls. `rest.orderedMutationDefaultV1`
uses an unmodified `SchedulingPolicy()` (10 ms fairness interval, one-second provisional
window, initial global allowance 50 requests/second, and the production capacity
limits). `rest.orderedMutation` retains its tuned policy and workload name: 100 µs
fairness interval, 1 µs provisional window and enlarged allowance. Every new REST native
receipt includes the complete constructed scheduling policy; scripted peer rate
headers remain injected fixture behavior and do not establish Discord quotas.
The default closed-loop variant injects the configured header-service delay.

`arrival.orderedMutationDefaultSharedV1` exercises POST mutation ordering in one
partition with the actual default scheduler. `arrival.orderedMutationDefaultIndependentV1`
uses the configured worker count of major-resource partitions, selected by ordinal
modulo worker count, while retaining one shared identity and its global budgets.
Both preserve cold discovery in each measured/warmup fixture. They directly record
RESTClient.execute entry through a bounded task-local cell and the opt-in admission
callback, in the same uptime clock domain as driver submission. This is entry to RESTClient.execute
after descriptor construction, before ordering/rate admission; it does not claim
wire-service admission.
`arrival.rest` retains its tuned GET rate-admission control and unknown owner entry.

Stage 1 adds `ordering.heldOwnerDefaultV1`, a versioned public-API handoff fixture
using the actual `SchedulingPolicy()`. A wave first holds each selected ordering
partition, submits its measured successor cohort, confirms the public queued/held
counts, then releases the owners. One caller means one queued successor behind
one held setup owner. The measured population excludes those setup owners.

```sh
swift run -c release --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests timing \
  --case ordering.heldOwnerDefaultV1 --requests 256 --concurrency 64 \
  --ordering-partitions 2 --ordering-identities 2 --release-offset-microseconds 2500 \
  --warmup-requests 16 --output .build/ordering-native.json \
  --common-report .build/ordering-common.json
```

Sweep `--concurrency` over 1/4/16/64, `--ordering-partitions` over 1...8 per
identity and `--ordering-identities` over 1...64 (their product is at most 64).
Each wave uses at most its caller count of partitions. Offsets 0/2500/7500 µs
probe different release phases; `--release-offset-microseconds` accepts 0...10000
and delays from confirmation that the full cohort is queued. The native receipt
retains the actual phase from the first observed clock-sleep invocation when one
exists. A sleep invocation does not prove suspension, and the notification
implementation may queue callers without invoking a sleep. These options apply
only to the held-owner case; older workload identities retain their dimensions.

The common `rest.orderWait` histogram ends at actual successor operation entry
or acquire error. The separate native `releaseToSuccessor` histogram measures
release signal through every successful successor entry, including predecessor
service for later same-partition callers; it uses 10 µs buckets over 0...1 second
and retains censor/loss counts. The first 64 per-partition causal samples keep
signal/owner-exit/owner-return offsets; owner-return offsets stay signed because
the successor can enter before its predecessor caller resumes. These diagnostic
samples are bounded and do not form a full-population percentile distribution.

Native successful throughput divides successful successors by first submission
through final terminal, including driver barriers, offsets and inter-wave setup.
The common throughput field counts all terminal outcomes, as in the other timing
families. Exact injected-clock invocation/completion/cancellation/peak-active
counters and maximum caller/holder task counts expose fixture and sleep bounds;
they do not count scheduler wakeups, allocations or all internal runtime tasks.
Post-close clock-quiescence checks happen after terminal timestamps. Existing
process CPU gauges include setup, warmup and joined cleanup. Separate profiler
captures remain necessary for CPU stacks, allocations and actual executor wakeups.
This fixture invokes no rate-store reservation or remote authority; slow/failing
authority and genuine quota/retry/reset checks remain separate admission controls.
The serial wrapper adds 30 held-owner rows: 1/4/16/64 successors, three release
offsets, and separate four-partition or four-identity controls where the cohort
can fill them. Its supervisor hashes the held-owner fixture source and retains
successful throughput, handoff observation count and clock counters alongside
the full native report. Historical transport/REST/arrival sweep dimensions stay
unchanged.

`arrival.noopV1` substitutes an immediate successful service for REST at identical
worker/queue/rate settings. It ignores the configured peer delay. Every versioned
arrival control additionally records actual offer-time lateness and headroom until
the next configured slot, using two bounded native histograms. The offer timestamp
is captured on driver-owner entry; headroom ends after bounded offer bookkeeping.
An offer completing after its next slot records zero headroom and increments an
explicit count. The final configured slot has no next-slot sample. All offered
slots, including queue-overflow misses, contribute generator lateness. These
controls expose driver deadline pressure independently of service/queue lateness;
they do not turn generator ceilings into service-capacity claims. The original
arrival identity incurs no generator-clock reads. The serial wrapper sweeps all
arrival controls over the same 1/4/16 workers and 200/2,000/20,000 arrivals/second.

Arrival policy uses one scheduler and persistent fixed workers. It retains no
task or timestamp record per offered arrival. Queue overflow counts a missed
arrival as terminal rejection; it has no invented submission/latency. Queued
cancellation is counted likewise. Metrics separately retain scheduled→response,
submitted→response, lateness and closure service. Optional actual owner admission
is unavailable in the legacy REST fixture and directly captured by the versioned
mutation controls. Service includes the REST owner hop
and any admission. Native counts distinguish submitted completions, missed and
rejected work, deferred arrivals, queue peaks, recovery/drain and unoffered slots
after cancellation. Driver admission means a slot was assigned to a worker;
`admittedTimestamps` counts directly observed service-owner entries separately. Common throughput counts all terminal outcomes, including missed
rejections; native completion throughput counts submitted service returns.

Histograms cover every observed outcome with 100-microsecond buckets over
0...1 second. Out-of-range/lost data and insufficient tails remain explicit;
P99 needs 10,000 observations per outcome. Distributions overlap and must not be
summed or subtracted. Operation timers exclude final snapshots, statistics updates
and report writes. Throughput spans first submission to last terminal (scheduled
origin for arrival); driver elapsed separately includes final joining/diagnostics.
Process gauges include setup, warmup and teardown; peer CPU/RSS are excluded.
Warmup stays outside measured histograms. Async time caps stop new admission and
join started work; underlying deadlines and cooperative cancellation remain in
force. Direct invocation has no external RSS/signal supervision.

Local smoke proves case semantics, bounded overload and cleanup. It does not
qualify controlled-host numerical baselines, Linux or other platforms, Discord
requests, production capacity or later roadmap stages. Actual completed checks
belong in the [validation record](../../Docs/Tasks/latency-timing/VALIDATION.md#phase-5-validation).

## Phase 6 Gateway and command timing

The explicit `command-timing` subcommand implements the
[Phase 6 plan](../../Docs/Tasks/latency-timing/PHASE-6.md). It uses the shared
catalog-six envelope with separate native details. Existing load commands and
Phase 5 `timing` keep their current meanings and readers.

```sh
swift run --package-path Tools/DiscordKitLoadTests -c release \
  --force-resolved-versions DiscordKitLoadTests command-timing --list-cases
swift run --package-path Tools/DiscordKitLoadTests -c release \
  --force-resolved-versions DiscordKitLoadTests command-timing \
  --case interaction.manualDefer --requests 64 --concurrency 4 \
  --warmup-requests 8 --delay-microseconds 2000 --duration-seconds 10 \
  --output .build/timing-phase6/manual-defer.json
```

| Family | Finite scenarios | Actual origin and terminal boundary |
| --- | --- | --- |
| `gateway.*` | `burst`, `slowSubscriber`, `slowHandler`, `reconnect`, `callbackError`, `cancelled`, `overloadRecovery` | Scripted uncompressed JSON transport through real shard/hub/dispatcher; includes actual runtime frame, retained queue and control intervals; whole run includes startup and joined teardown |
| Trusted `gateway.*` | `trustedInteraction`, `trustedDeferred`, `trustedUncertain` | Public client and bot runtime install the private authenticated receiver; existing scalar receipt-to-admission and confirmed acknowledgement metrics retain private provenance |
| `interaction.*` | `immediate`, `manualDefer`, `automaticDefer`, `duplicate`, `invalidSignature`, `malformed`, `uncertain`, `cancelled`, `admissionRefusal`, `callbackError`, `handlerFailureAfterAcknowledgement`, `deadlineRace`, `durableAdmission`, `durableDuplicate`, `durableFailure` | Real Ed25519-signed injected HTTP request, bounded body/verification/replay/decode/route, first response and joined workflow |
| `synthetic.*` | `directImmediate`, `dslImmediate`, `directDeferred`, `dslDeferred`, `directFailure`, `dslFailure`, `directCancelled`, `dslCancelled` | Caller immediately before real typed routing through handler and response ownership; explicitly bypasses signed ingress and trusted Gateway receipt |

All fixtures are local and use synthetic credentials. They open no real WebSocket
or HTTP listener. Gateway binary/ETF/compression is unsupported and excluded.
Signed request fixtures use a fixed development signing key, never a Discord key.
Durable profiles run the existing webhook processor with an explicit bounded
transaction fixture: admission measures its actual consumer hook, durable duplicate
priming is excluded and later duplicate hints invoke no transaction, and durable
backend failure returns retryable 503 without claiming a completed commit. These
profiles do not invent interaction decode or first-response hooks for webhooks.
Exact duplicate cases reuse the signature and body that primed replay admission.

`interaction.workflow` covers every logical terminal outcome directly, including
HTTP refusal, cancellation and uncertainty. Its outcome partition matches native
counts. Runtime child boundaries retain their own result: a confirmed first
response can succeed before a later workflow failure. Application response timing
starts after the workflow begin callback and stops at the inline sink completion.
It excludes earlier listener/socket time; no trusted HTTP receipt metric is
available. Deadlines are constructed before observer callbacks. `deadlineRace`
selects an already-expired caller deadline; deterministic runtime tests separately
prove in-flight deadline/observer ordering. `cancelled` uses an explicitly cancelled
caller; parent cancellation tests separately prove joined partial results.

The manual defer case sends one acknowledgement and completes it with one edit.
Automatic defer waits for a real acknowledgement before editing, including when
provider delay is zero. Callback errors distinguish positive no-submission from
uncertain submission and perform no replacement initial response. Explicit
provider waits and policy wrappers are measured directly; policy includes its
nested handler. Histogram rows overlap and cannot be added into a waterfall.

Configuration bounds match the shared finite profiles: at most 100,000 requests,
256 workers (64 in smoke), provider delay at most one second, one finite warmup
population and a cooperative duration cap. The Gateway rate setting applies to
`slowHandler` and `overloadRecovery`; their source follows absolute monotonic
arrival deadlines with bounded backpressure. Other cases have no rate-controlled
source. The overload recovery case also confirms a heartbeat write while the first
callback still owns its handler permit, then proves subsequent recovery.
Every retained queue, active handler, initial response slot, stream,
connection and lease is checked after awaited cleanup. Refused/discarded input
remains visible in outcome counts without invented handler service latency.

Release capture uses the existing build receipt and serial process supervisor:

```sh
python3 Tools/DiscordBenchmarkSupport/scripts/run_benchmarks.py build \
  --repository . --package Tools/DiscordKitLoadTests --product DiscordKitLoadTests \
  --receipt .build/timing-phase6/release-final.json
python3 Tools/DiscordKitLoadTests/scripts/run_command_timing_suites.py \
  --executable Tools/DiscordKitLoadTests/.build/release/DiscordKitLoadTests \
  --receipt .build/timing-phase6/release-final.json \
  --output-dir .build/timing-phase6/matrix-final --requests 32 --warmup-requests 8
```

The wrapper sweeps 1/4/16 handlers against 200/2,000/20,000 offered Gateway
frames/second for slow handlers and overload recovery. Synthetic cases run in
forward and reversed order in separate fresh processes; this is informational
counterbalancing, without controlled-host numerical comparison. The full reports
retain provenance, all outcome distributions, CPU/RSS scope and cleanup. Each
completed row becomes a retained checkpoint, and failures cannot silently pass as
successful throughput. The compact matrix links its complete native reports.

Selected metric sets fit the shared 16 MiB statistics ceiling; requesting the
entire expanded catalog can fail budget admission. Histograms use 100-microsecond
buckets over 0...1 second, preserve censor/loss and require sufficient observations
for tails. Smoke does not establish individual-call P99, production capacity,
live Discord response delivery, real WebSocket/network throughput, hosted CI or
other-host support. Completed evidence belongs in the
[validation record](../../Docs/Tasks/latency-timing/VALIDATION.md#phase-6-validation).

## Phase 7 cache and client timing

The separate `cache-client-timing` subcommand measures cache caller/owner/loader
populations and local client construction, discovery, ingestion, local-ready and
joined shutdown. It uses bounded local state and injected peers without Discord
credentials. Construction starts no runtime work; local-ready is an injected
session milestone, not live Discord READY qualification. See the
[phase record](../../Docs/Tasks/latency-timing/PHASE-7.md).

```sh
swift run --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests \
  cache-client-timing --list-cases
swift run --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests \
  cache-client-timing --case cache.singleFlight --requests 32 --concurrency 8 \
  --warmup-requests 4 --output .build/cache-single-flight.json
python3 Tools/DiscordBenchmarkSupport/scripts/run_benchmarks.py build \
  --repository . --package Tools/DiscordKitLoadTests --product DiscordKitLoadTests \
  --receipt .build/timing-phase7/load-release.json
python3 Tools/DiscordKitLoadTests/scripts/run_cache_client_timing_suites.py \
  --executable Tools/DiscordKitLoadTests/.build/release/DiscordKitLoadTests \
  --receipt .build/timing-phase7/load-release.json \
  --output-dir .build/timing-phase7/cache-client-matrix --requests 32 --warmup-requests 4
```

Cache cases cover fresh lookup, sparse merge, event projection, pure permissions,
lazy expiry, capacity eviction, invalidation, stale-fetch fencing, refresh,
refresh single-flight and broadcast. Finite options select `--working-set`
16/256/4096 entries per identity, `--identities` 1...32, `--hit-percent` 0/50/100,
`--fan-out` 1...32 and `--slow-subscriber` true/false. Cohorts remain finite;
refresh waiters cannot create tasks beyond the selected concurrency. The matrix
sweeps these dimensions in separate processes and retains each completed row.
Lookup fills its fixed working set once per run. The 4,096-entry row uses the
single-process `soak` profile with both warmup and measured wall caps lowered to
60 seconds to include its public-API setup; other rows use smoke caps. This
finite row does not establish sustained-soak qualification.

Expiry measures its triggering lookup after virtual freshness advancement;
eviction measures its triggering apply. Real elapsed clocks remain independent.
Single-flight gates wait for every bounded subscriber before releasing one loader.
Broadcast includes actual publication and healthy delivery; held subscribers use
explicit overflow behavior. Caller and owner intervals overlap; their percentile
difference is not queue time. Permission arithmetic uses an external wrapper.

The client cases cover construction, successful lifecycle, cancelled discovery,
failed discovery/projection and a held subscriber. Each client has private finite
HTTP, lease, budget, event and connection owners. Dependency construction precedes
the benchmark constructor-call stopwatch. The narrower runtime initializer-body
hook is excluded from that population. Shutdown awaits owner completion, and read-back
receipts prove the run tasks, connections, bodies, subscriptions, leases and
reservations have been released.

`--warmup-requests` uses independent owners and is excluded from measured
histograms. Shared profile/seed/wall-cap options and `--common-report` follow the
existing supervised timing commands. Schema 1/catalog 7 keeps every measured
outcome, bounded histogram precision and loss/censoring. Sparse P99 remains
insufficient data. A passing local smoke establishes integrity and cleanup; no
controlled performance budget, hosted CI, live Discord or other platform is
qualified. Direct/DSL runtime and manual/macro compiler comparisons are in the
separate [authoring tool](../DiscordDSLBenchmarks/README.md).

## Phase 9 media and voice timing

The `voice-timing` command exercises real manager/session control ownership with
finite injected credentials, WebSocket, discovery and E2EE fixtures. Installation,
secure readiness and the primary joined lifecycle retain separate populations.
Runtime heartbeat/retry deadlines use an explicitly advanced fixture clock;
elapsed measurements use real `ContinuousClock`. This measures local orchestration,
not network RTT, real DAVE acceptance, live Discord or device delivery.

```sh
swift run --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests voice-timing --list-cases
swift run --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests voice-timing \
  --case voice.lifecycleJoined --requests 8 --warmup-requests 1 --concurrency 2
```

Every offered terminal lifecycle is retained, including expected terminal-close
failures. Separate warmup owners join before measurement. Child intervals overlap;
cleanup receipts independently cover manager/session/adapter/task ownership.

The independent [media component tool](../DiscordMediaBenchmarks/README.md)
provides 80 real DSP, codec, jitter, RTP, AEAD, MLS and DAVE batch cases.
The [existing duplex runner](../VoiceSessionQualification/README.md) adds opt-in
public-boundary attribution, supported frame/channel/codec profiles, DTX cadence,
receiver-side impairment emulation and bounded CPU contention. The
[Apple tool](../AppleAudioQualification/README.md) maps actual codec observations
into the common envelope while retaining explicit physical-device procedures.

Freeze source edits before preparing optimized supervised captures:

```sh
swift build --package-path Tools/DiscordBenchmarkSupport --product DiscordBenchmarkReports
python3 Tools/DiscordBenchmarkSupport/scripts/run_benchmarks.py build \
  --repository . --package Tools/DiscordKitLoadTests --product DiscordKitLoadTests \
  --receipt .build/timing-phase9/load-release.json
python3 Tools/DiscordKitLoadTests/scripts/run_media_voice_timing_suites.py \
  --family voice --executable Tools/DiscordKitLoadTests/.build/release/DiscordKitLoadTests \
  --receipt .build/timing-phase9/load-release.json \
  --validator Tools/DiscordBenchmarkSupport/.build/debug/DiscordBenchmarkReports \
  --output-dir .build/timing-phase9/voice-matrix --operations 8 --warmup-operations 1
```

For components, prepare `Tools/DiscordMediaBenchmarks` / `DiscordMediaBenchmarks`,
then select `--family media` with its executable and receipt. The driver lists every
finite case by default; repeat `--case` to select cases. It sweeps queue batch size
and lifecycle concurrency, requires exact input/seed/outcome identity, validates
common envelopes independently, compares native/common bytes semantically, and
retains completed rows if a later capture fails. Sparse P99 remains insufficient
data. These local smoke captures establish no numerical baseline, universal
realtime behavior, hardware, independent crypto or live-service qualification.
See [Phase 9](../../Docs/Tasks/latency-timing/PHASE-9.md) for the metric contracts.

## Phase 8 optional service timing

Performance phase 6 adds versioned controls while retaining the earlier cases:

- `oauth.sharedRefreshV2`, `oauth.unrelatedRefreshV2` and
  `oauth.partialCancellationV2` share one coordinator per finite cohort, with up
  to 256 callers. The unrelated case gives each caller a distinct root grant;
  the other cases join one grant. `--storage-delay-microseconds` and
  `--backend-delay-microseconds` independently select zero through one second.
  `--delay-microseconds` must be zero for these cases and defaults to zero when
  omitted. The legacy cases retain their coupled `--delay-microseconds` policy.
  Every expected backend owner and subscriber is admitted at a deliberate gate
  before release. Partial cancellation joins half the admitted readers before
  releasing the one refresh to surviving readers. This gate is a coalescing
  experiment, not an arrival-capacity measurement. Backend arrival notification
  avoids polling during injected storage waits; final subscriber snapshots can
  still perturb caller scheduling. Native `measuredLookupNanoseconds` is the
  exact sum of public caller durations, with `counts.completed` as its population.
  The separate `oauth.refreshCohortV2` batch interval starts at cohort submission
  and stops after every terminal reader joins, before subsequent coordinator
  close and diagnostic snapshots. It has one observation per cohort, including
  unrelated-grant cohorts with multiple refresh owners. V2 cases never emit
  `oauth.refresh.joined`; the legacy metric retains its flight population and
  inclusive coordinator-close endpoint.
- `activities.subscriptionGroupsV1` independently varies
  `--subscription-groups` and `--owners-per-group` in 1...4096, with at most
  65,536 total tokens. One acknowledged token per distinct group is seeded
  outside subscription timing. Every additional duplicate acquisition is then
  timed while all groups remain active. Total tokens are
  `subscriptionGroups * (ownersPerGroup + 1)`: a fixed 4096-token sweep can use
  groups/duplicate-owners 1/4095, 16/255, 256/15 and 1024/3. Exact successful
  admission nanoseconds/count are native `subscriptionAdmissionNanoseconds` and
  `subscriptionAdmissions`; rejected capacity probes are separate histogram
  outcomes. Compare this admission population for the count optimization. The
  later generic `activities.request` primary and common throughput measure a
  control request after subscriptions have been released. Provider subscription
  and final full release remain exactly counted and verified.
- `rpc.queuedRepliesV1` varies `--queue-depth` from zero through 4096 while one
  synthetic write is held. A fixed cohort of 64 already-sent public requests
  receives correlated replies while that unrelated backlog remains queued.
  `rpc.queuedReplyCohortV1` starts before reply submission and ends when every
  cohort caller returns. This is one **batch** observation per session; its
  percentile is never a per-call percentile. Native
  `queuedReplyCohortNanoseconds`/`queuedReplyCohorts` preserve the exact total
  and population. Separate `rpc.request` durations retain public-call setup
  residence. The fixture implements `RPCConnection`; it does not exercise IPC
  framing or a native adapter. The existing request and framing cases retain
  those distinct controls.

For example, run each row in a fresh prebuilt process; keep warmup, policy and
dimensions identical between baseline and candidate:

```sh
DiscordKitLoadTests service-timing --case oauth.sharedRefreshV2 --requests 1024 \
  --concurrency 256 --storage-delay-microseconds 0 --backend-delay-microseconds 0 \
  --warmup-requests 256 --duration-seconds 10 --output oauth-shared.json
DiscordKitLoadTests service-timing --case activities.subscriptionGroupsV1 --requests 4 \
  --concurrency 1 --subscription-groups 1024 --owners-per-group 3 \
  --delay-microseconds 0 --warmup-requests 1 --output activity-groups.json
DiscordKitLoadTests service-timing --case rpc.queuedRepliesV1 --requests 8 \
  --concurrency 1 --queue-depth 4096 --delay-microseconds 0 \
  --warmup-requests 1 --output rpc-queue.json
```

These synthetic workloads do not qualify native/browser/provider latency. The
root `UnixRPCIntegrationTests.nativeUnixRPCHandshakeRequestControlAndCancellation`
test separately exercises the actual `UnixIPCTransport` against a local Unix
socket simulated peer, including handshake, correlation, control and cancellation.
A timed test-process receipt includes test setup, framework work and cleanup; it
is not an isolated adapter-latency distribution.

The service matrix driver records all new dimensions and rejects a mismatched
participant/native/common identity. Versioned OAuth caller sweeps explicitly
select two cohorts at 1/64/256 callers with one cohort of warmup. The 256-caller
rows select the supervisor's `soak` cap profile to permit one process with that
cohort size; they retain explicit 10-second measurement and one-second warmup
caps. This profile selection supplies no sustained-soak qualification. Fixed-4096-token
Activity and parked-queue rows use two measured sessions and one warmup session
to keep fixture setup and cleanup bounded; those row counts override the matrix
driver's generic `--requests`/`--warmup-requests` values and remain explicit in
the matrix receipt. Legacy rows retain their earlier request policy.
Parent cancellation after reply release explicitly cancels and joins all primary
and supporting public RPC/Activity callers before closing and joining actual
fixture reads. Deterministic tests park the first released reply at the adapter
read boundary, cancel the owner, then verify cancellation returns after cleanup.

The separate `service-timing` command runs actual OAuth, RPC, Activities, Social,
GameServices, Commerce and CertifiedDevices APIs with bounded injected storage,
peers and backends. No credentials, desktop application, browser authorization or
purchase operation is required. See the
[phase record](../../Docs/Tasks/latency-timing/PHASE-8.md) and
[catalog-eight boundaries](../../Docs/Tasks/latency-timing/METRICS.md#implemented-optional-service-durations--catalog-eight).

```sh
swift run --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests \
  service-timing --list-cases
swift run --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests \
  service-timing --case oauth.singleFlight --requests 32 --concurrency 8 \
  --delay-microseconds 2000 --warmup-requests 4 --output .build/oauth-single-flight.json
python3 Tools/DiscordBenchmarkSupport/scripts/run_benchmarks.py build \
  --repository . --package Tools/DiscordKitLoadTests --product DiscordKitLoadTests \
  --receipt .build/timing-phase8/load-release.json
python3 Tools/DiscordKitLoadTests/scripts/run_service_timing_suites.py \
  --executable Tools/DiscordKitLoadTests/.build/release/DiscordKitLoadTests \
  --receipt .build/timing-phase8/load-release.json \
  --output-dir .build/timing-phase8/service-matrix --requests 32 --warmup-requests 4
```

OAuth cases distinguish valid lookup, install/load/CAS, refresh, contending
single-flight readers, generation conflicts, revoke and cancelled readers followed
by joined owner close. Coordinator storage and backend counts are actual receipts;
a local coordinator never establishes distributed locking. `oauth.lookup` applies
to access-token readers; install/revoke have separate primary metric identities.
The inclusive joined-refresh population contains harness joining/diagnostic work
and cannot identify exact internal admission or refresh CPU time.

RPC cases use production IPC framing over an injected byte stream, including
single-byte fragmentation. Both protocol families cover READY handshake, reversed
reply correlation, bounded pending pressure, event drains, cancellation, mismatched
commands and close. Activity subscriptions test shared upstream ownership and the
last release. Each independent session contributes one primary request; supporting
correlation/pressure/subscription calls have separate native write/ownership counts.
Handshake/event/subscription/close populations remain distinct from primary calls.

Service cases cover Social profile/snapshot validation and lifecycle admission,
GameServices filtered lobby members and snapshot-based descriptor comparison, Commerce entitlement
validation, and CertifiedDevices publication through an injected backend. Expected
invalid input, injected failure and cancellation stay visible in outcome counts.
Underlying REST/RPC observations and outer service observations overlap.

`--requests` is bounded to 1...100000, `--concurrency` to 1...64, `--fan-out` to
1...32 and `--delay-microseconds` to 0...1000000. Delay is an injected fixture
wait, not a measured service latency assumption. The matrix sweeps contention
1/4/8/32, event/subscriber fanout 1/2/8/32, and injected waits 0/2000/10000 µs in
separate fresh processes. Default warmup and measured wall caps remain finite;
warmup uses independent owners and never enters measured histograms.

Native schema 1 embeds the common schema-1/catalog-8 envelope. Every primary
terminal outcome is histogrammed with explicit precision, loss and censored tails.
Incomplete populations, dropped aggregates or retained owners fail capture.
Sparse P99 is insufficient data. The driver retains each successful matrix row
before advancing and enforces process timeout, bounded artifacts and child reaping.

Bridge boundary checks run separately with `node --test` from
[DiscordActivityBridge](../../Browser/DiscordActivityBridge/README.md). Those Node
checks do not measure a browser process. Actual browser timing requires a separate
controlled browser owner using the documented bridge origin/source policy, with
browser-side timestamps and independent close evidence; do not compare it to the
injected bridge profile. Actual desktop IPC qualification likewise requires an
explicit desktop host and remains separate from injected-byte-stream framing.
Local captures establish fixture integrity and cleanup; numerical capacity,
hosted CI, live Discord and other platforms require their own qualification.

## Performance phase 2 controls

The versioned `timing` cases `rest.typedDecode1KiBV1`,
`rest.typedDecode16KiBV1` and `rest.typedDecode256KiBV1` run unshared successful
responses with exact 1/16/256 KiB JSON bodies. A Foundation `JSONDecoder` validates
a finite content/sequence model. Native `requestWork` records exact payload bytes
and the actual decode-observer invocation count; the endpoint still returns the
original bytes after validation. Payload generation precedes caller timing. Legacy
cases retain their existing policies and payloads; `rest.decode` always records
actual invocations, so an optimized unshared runtime has one instead of two.

The `command-timing` case `interaction.replayNearCapacityV1` primes 4095 unique
real signatures before opening its measurement gate. It accepts at most 256
measured requests; capacity is exactly 4095 plus that count. The initial/final
entry counts and capacity are retained in the native report. Other outcomes retain
their existing fixture semantics. A separate native `verifierActorAdmission`
histogram (0...100 ms, 1 µs buckets) observes genuine caller-to-verifier entry;
`ingress.admission` continues to measure replay service. Observation loss and
histogram overflow stay explicit. Durable-event cases retain their separate
transaction fixtures and omit this native actor histogram.

The `timing` cases `transport.body64KiBChunk257V1` and
`transport.body64KiBChunk65536V1` hold the immediate peer body at 65536 bytes while
varying only the adapter's emitted chunk bound. Both Foundation and NIO are
supported. Legacy transport scenarios keep their original chunk and peer policies.

Use the shared release-build and fresh-process comparison driver. Process CPU/RSS
includes setup, signing, replay prefill, warmup and cleanup; caller/workflow
histograms exclude initial setup. Do not subtract phase percentiles or interpret
these local fixtures as reserved-host, production, DNS/TLS or capacity evidence.

## Performance phase 3 event delivery controls

The separate `gateway-hub-timing` command runs four finite, versioned public
`GatewayEventHub` experiments. It uses replay events and in-process hub owners;
socket ingestion, lease validation, decoder, dispatcher, cache, provider and
trusted interaction work remain separate controls in `command-timing`.

```sh
swift run --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests \
  gateway-hub-timing --list-cases
swift run -c release --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests \
  gateway-hub-timing --case gateway.hubQueuedV1 --requests 128 \
  --subscriptions 8 --hubs 1 --queued-depth 16 --payload-bytes 128 \
  --warmup-requests 8 --output .build/hub-queued.json \
  --common-report .build/hub-queued-common.json
```

| Case | Finite work and terminal evidence |
| --- | --- |
| `gateway.hubQueuedV1` | Prefill `queued-depth` copies per subscriber, then publish and pull once per subscriber on each iteration. Capacity is depth plus one, so backlog remains fixed independently of request count. Final drain checks every retained sequence. |
| `gateway.hubWaitingV1` | Park and confirm one consumer task per subscription before each publication, then join all tasks. Direct handoffs create no retained-residence interval. |
| `gateway.hubOverflowV1` | Hold consumers until all publications finish, then drain or observe each terminal resynchronization error. Capacity is `max(1, queued-depth)`. |
| `gateway.hubCancelledV1` | Hold consumers through publication, then explicitly cancel every subscription and retain cancellation and cleanup receipts. Capacity matches overflow mode. |

`--subscriptions` (1...256 per hub), `--hubs` (1...8), `--queued-depth`
(0...4096), `--payload-bytes` (0...65536), and `--policy` (`resynchronize`,
`dropNewest`, `dropOldest`) are independent inputs. All hubs share one authority.
Total subscriptions are limited to 512, retained envelope slots to 262144,
conservative retained envelope charges to 64 MiB, and measured offered copies to
10000000. These joint bounds may reject an otherwise individually valid option.
`--requests` accepts 1...100000; `--warmup-requests` accepts 0...10000.
`--delay-microseconds` accepts 0...1000000: queued mode holds each published copy
before pulling, while overflow/cancelled modes hold the completed retained cohort
before final drain/cancellation. Waiting mode has no injected hold.

There is one sequential publisher, recorded as concurrency **1** and scheduler
`sequential-publication-fixed-backlog-v1`; subscriber fan-out and hub count do not
claim additional publisher concurrency. Warmup uses separate owners and its own
finite cap. The measured cap is 1...300 seconds, warmup 0...60 seconds; cooperative
interruption joins every waiting task and releases all retained ownership before
returning partial counts. Driver profile, seed, duration, warmup and common-report
environment variables are accepted, with explicit options taking precedence.

Native schema 1 (`DiscordKitLoadTests.gateway-hub-timing`) embeds common
schema-1/catalog-6 evidence. `gateway.publication` measures immediately before
each public `publish` call through its return, excluding event construction,
prefill, consumer work and final drain. Its histogram uses 1 µs buckets over
0...100 ms. `gateway.hubResidence` receives actual production interval endings,
including prefill, failed eviction and cancelled teardown, using 100 µs buckets
over 0...10 seconds. Censored observations and timing loss remain explicit.
Native `pullCall` uses the same fast precision and includes actual `next` calls,
setup returns and final drain; waiting pulls include suspension and driver barriers.
These boundaries overlap and their percentiles must not be added or subtracted.

Common counts partition measured **subscriber copies**; publication distributions
count actual calls. Success requires measured-copy consumption, while explicit
retained cancellation and other unconsumed work retain separate terminal outcomes.
Native counters distinguish publication drops, terminated subscriptions,
resynchronization errors, admitted copies discarded before consumption, cancelled
retained copies, setup copies and final cleanup. `dropOldest` evictions are admitted
copies discarded before consumption; the public API does not count them as
publication drops. Setup copies never become logical offered work, including on
interruption. Retained cancellation receipts can include setup copies.

Gross duration includes prefill, injected holds, task barriers, final FIFO drain
and joined shutdown. CPU includes setup and separate warmup; peak RSS covers the
process lifetime. Buffered byte receipts describe retained envelope charges, not
queue metadata allocations, unique payload allocations or process memory.
Use identical public-API harness sources and release settings against baseline
and candidate runtimes, followed by serial fresh-process no-change controls and
alternating comparisons. Local observations remain informational; reserved-host
noise-floor and profiler qualification, hosted CI, live Discord and production
capacity require their own evidence. See the
[phase record](../../Docs/Tasks/performance-improvements/PHASE-3.md).

## Performance phase 4 cache scaling controls

The `cache-scaling-timing` command adds versioned public-API experiments for
both `EntityCache` and HTTP `ReadCache`. Existing `cache-client-timing`
identities continue to cover sparse merge, projection, single-flight subscribers
and superseded-loader fencing. Refresh cancellation has functional test coverage;
there is no dedicated cancelled-loader timing case. The new command isolates
lookup and retention scaling with one sequential caller.

```sh
swift run --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests \
  cache-scaling-timing --list-cases
swift run -c release --package-path Tools/DiscordKitLoadTests DiscordKitLoadTests \
  cache-scaling-timing --case cache.hotHitV1 --owner entity --requests 256 \
  --working-set 4096 --identities 1 --payload-bytes 128 --churn-updates 0 \
  --warmup-requests 8 --duration-seconds 300 --warmup-seconds 30 \
  --output .build/cache-scaling.json --common-report .build/cache-scaling-common.json
```

| Case | Selected call and exact checks outside its timer |
| --- | --- |
| `cache.hotHitV1` | Lookup a prefilled key and verify the complete retained payload. |
| `cache.missV1` | Lookup an absent representation while the fixed working set remains full. |
| `cache.updateV1` | Replace an existing key with a prepared equal-size payload; verify the new value and unchanged entry count. Entity serialization and byte charging remain inside the actual write call. |
| `cache.expiryStormV1` | Advance deterministic freshness to the inclusive TTL and time the lookup that prunes the whole working set. Refill before each selected call; verify zero survivors and one final untimed recovery read. |
| `cache.capacityV1` | Insert a new key into a full cache. Maintain an untimed exact LRU model and verify the expected per-identity/global victim, retained payload and constant entry count. |
| `cache.invalidationV1` | Invalidate one local-write entity key or one uniquely tagged HTTP representation. Verify absence, then restore and verify recovery outside the timer. |

`--owner entity|read`, `--working-set` (1...4096 **aggregate** keys),
`--identities` (1...min(32, working-set)), `--payload-bytes` (0...65536), and
`--churn-updates` (0...64) are independent. Identity sweeps partition a fixed
aggregate key count instead of multiplying it. Entry limits equal the aggregate
working set and its ceiling per identity. Byte limits use `payload-bytes + 1024`
per slot, allowing actual payload size to vary without unintentionally switching
to byte-driven eviction. The combined fixture retained-charge guard is 16 MiB;
key/index/allocator overhead and the two prepared variants need separate process
memory observations. The HTTP cache charges raw response bytes, while the entity
cache performs conservative JSON/metadata charging, so their byte receipts have
different meanings. Prepared `Data`/string payload storage is shared across keys;
accounted bytes do not measure unique payload allocations.

Churn performs exactly the configured number of existing-key replacements before
each selected call, outside call/owner timers. This exercises repeated expiry-index
updates without changing the key count or offered lookup population. Prepared
payloads, key strings/tags, prefill, HTTP generation acquisition, exact equality,
LRU-model updates, diagnostics and recovery are outside selected call intervals.
The entity write still includes its production JSON serialization, accounting,
expiry and eviction work. HTTP writes use prepared `Data`. Profile serialization
separately before inferring its allocation contribution or changing byte semantics.

`--requests` is 1...100000 and `--warmup-requests` is 0...10000. The combined
setup/churn/recovery guard is ten million untimed writes, including each active
owner's initial fill and expiry recovery. Warmup uses separate owners.
Measured/warmup caps are 1...300/0...60 seconds; a cooperative cap
joins cleanup and aborts export instead of accepting a partial population. Shared
driver profile, seed, cap, warmup and sidecar environment defaults are supported;
explicit options take precedence. Concurrency is always one and ignores the
driver's concurrency default.

Native schema 1 embeds common schema-1/catalog-7 evidence. Common identities append
the owner, for example `cache.hotHitV1.entity` and `cache.hotHitV1.read`, preventing
cross-owner pairing. `cache.call` spans immediately before the public operation
through its return. Entity `cache.owner` uses the actual owner hook after actor
admission and excludes all setup work through a task-local filter. The HTTP read
cache has direct caller timing only. These distributions overlap and cannot be
subtracted to infer queue residence. Histograms use 100 µs buckets over 0...1 second
with explicit censoring; a shared bucket cannot distinguish small-call changes,
and insufficient samples leave P99 unavailable. Freshness time stays fixed except
for explicit expiry advances; wall durations use a separate real clock. Native
`retainedBeforeCleanup` and `accountedBytesBeforeCleanup` are sampled after the
selected population but before the final untimed expiry recovery. Cleanup itself
checks every restored entry is released. Gross throughput and CPU include setup,
churn, array LRU-model work, equality checks, diagnostics, recovery and teardown;
they do not isolate cache service capacity. Maximum RSS covers the process lifetime.

Use identical harness sources and release settings against both runtime revisions.
Start with hot-hit/miss working sets 16 and 4096, capacity 256 and 4096, identity
counts 1 and 16 at fixed 4096 keys, payloads 128 and 4096 at fixed 256 keys, and
churn 0 and 32 at fixed 256 keys. Keep expiry request counts small enough for its
explicit refill budget. Run serial fresh-process no-change controls and
alternating baseline/candidate pairs. Local distributions remain informational;
reserved-host noise-floor/profiler qualification and existing tail-population rules
remain required before accepting numerical performance budgets.
