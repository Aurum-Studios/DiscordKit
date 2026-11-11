<!--
File: Docs/Tasks/performance-improvements/PHASE-6.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 6 — Optional protocol and service workflows

Authorized 2026-11-11 from `035cf9f02f5955552f5b0357a0e0abf90cdc6729` under the
[stage contract](PLAN.md#stage-6--refine-optional-protocol-and-service-workflows).
Reserved-host numerical, allocation and target-platform qualification remain open.

## Implementation plan

1. Preserve the original runtime in a detached checkout. Audit OAuth refresh,
   RPC correlation, Activity subscriptions and Social, Commerce, GameServices
   and Certified Devices composition. Distinguish local bookkeeping from injected
   storage/backend/peer waits and real Unix adapter work.
2. Evaluate actor-confined OAuth refresh-flight storage to avoid subscriber
   dictionary copies, exact Activity subscription-owner accounting to avoid
   group-wide recounts, and RPC queue membership to avoid scanning unrelated
   queued writes when already-sent requests finish. Preserve public contracts,
   bounded ownership, cancellation, late-response fencing and joined close.
3. Preserve authoritative storage/generation/parent/revocation checks, consent,
   capability and entitlement checks, one-use flows, exact complete device
   arrays and partial progress. Retain existing provider orchestration unless
   a separate discriminating experiment justifies changing it.
4. Add deterministic regression tests and versioned service workloads separating
   storage/backend delay, same-key subscriber contention and subscription-group
   dimensions. Keep historical cases and identities intact. Run original and
   candidate runtimes with identical development harnesses.
5. Run focused tests, strict root build/tests, benchmark/tooling and browser bridge
   tests, independent optional-protocol consumers, inventory/generation/parity,
   API and authored documentation checks. Run host builds and captures serially.
6. Retain five no-change and five alternating original/candidate fresh-process
   pairs per selected workload, exact outcomes, reports, source/build receipts,
   resource gauges and cleanup. Keep native Unix integration captures separate
   from injected IPC and browser fixtures. Do not qualify desktop, browser or
   provider latency from injected peers.
7. Review the final changes, record implementation decisions and truthful local
   evidence, commit locally and verify the resulting commit and working tree.

## Implementation and decisions

OAuth refresh flights become private reference owners confined to the coordinator
actor. Previously, copying a flight out of its dictionary and writing it back
shared its waiter dictionary during every join/cancellation; mutation could copy
that dictionary. The reference owner lets those synchronous actor operations
mutate the same bounded table. It costs one object per active identity. Task and
generation ownership, admission limits and all storage operations remain intact.
Invalidation releases each subscriber before cancellation; close still joins the
original task handles. A completed flight is removed as before. There is no
cross-process refresh lease, token cache or bypass of child/parent authority reads.

Activities maintains an exact token total alongside its existing bounded groups.
Admission and diagnostic snapshots no longer reduce every group's token count.
Insertion, release, canceled acquisition, failed admission and terminal cleanup
update the total in the same actor turn as ownership. Shared upstream groups,
READY's local subscription behavior and last-owner UNSUBSCRIBE stay unchanged.
Command admission also captures its existing diagnostic correlation once for the
pending operation and queued write. No browser bridge or origin policy changes.

The proposed RPC queued-ownership flag was deferred after measurement. It let
sent replies skip scans of unrelated queued writes. Screening gains required
much larger configured pending budgets; low-backlog 64-reply cohort controls were
slower and default benefit remained unproven. Restored-code controls also vary,
so a marker-specific small-queue cost is not established.
The runtime patch was reversed; regression tests, versioned workloads and rejected
candidate receipts remain. The final runtime keeps the existing nonce dictionary,
FIFO representation, framing, controls and generation fences. See the separate
decision evidence below; no RPC speedup ships in this phase.

Social's sorted relationship projections remain unchanged: retaining another
projection/index needs an independent working-set/revision experiment. Commerce
continues to fetch current entitlements and never reuses receipts as authority.
Certified Devices continues to publish the complete exact ordered array, including
empty replacement; coalescing or change-only writes would change the contract.
GameServices retains its existing snapshot-based change-only helper, sequential
chunk writes and acknowledged partial progress. Provider waits, capabilities,
consent, purchases and externally delivered responses are not optimized by these
local bookkeeping changes.

## Correctness and native adapter scope

OAuth tests exercise 128 joined readers, 64 independent cancellations, capacity
reclamation and replacement readers under one failed physical refresh. An unrelated
grant still progresses. Repeated child resolutions must reload both child and
parent authority and fail after external parent removal. A 32-reader revocation
test proves independent cancellation and rejection of late refresh resurrection.

Activity tests combine READY, independent groups, duplicates, overload, repeated
release, removal in progress and repeated churn. Failed admission with unrelated
live owners and terminal cleanup must restore exact zero ownership. RPC tests park
the actual writer, complete its sent request with an unsent backlog, cancel only
one queued request, then verify remaining wire order, ignored old replies and
empty pending bytes. Existing protocol/capability/authority suites remain relevant.
Independent source reviews found no blocking lifetime, reentrancy, accounting or
generation defect in the evaluated candidates; the RPC decision is a measured
performance tradeoff.

Three separate fresh `swift test --skip-build --filter UnixRPCIntegrationTests`
process captures use actual Unix sockets, the production Unix adapter and a
simulated local RPC v1 peer. Each verifies handshake, GET_GUILDS, opaque ping/pong,
admitted GET_CHANNELS cancellation, native EOF, zero client ownership and temporary
socket-directory removal. Their wall-time scope includes SwiftPM, test runners,
fixture setup and event-loop teardown; RSS samples cover only the leader process
and exclude descendants. Per-child CPU is unavailable. Those gauges are not per-request
latencies and supply no RPC speedup or actual Discord desktop qualification.

## Validation and observations

Final local checks passed on Apple Swift 6.4, arm64 macOS 27.0.1 with the
macOS 27.0 SDK. Builds and captures ran serially with four build jobs. The strict
root run completed 2,681 test methods in 337 suites across 34 target runs after a
strict build; focused OAuth/Activity/RPC/native tests passed 20 methods. Load
tests passed 142 methods in 26 suites, shared benchmark support 68 in seven and
repository tooling 106 in eight. Python suites passed 234 tooling, 45 load,
47 benchmark-support and 183 CI tests. Browser bridge/network/example Node tests
passed 38. Independent OAuthApp, RPCApp, ActivityHost and SocialApp builds passed.

Inventory, generation byte-identity, parity, documentation examples and curation
passed. The callable audit found zero missing comments across 976 Swift files and
10,469 explicit callable declarations. Normalized symbol graphs and strict DocC
conversions for DiscordOAuth, DiscordRPC and DiscordActivities passed. The public
API snapshot is byte-identical to phase 5 and passes the 0.19.0 release policy
against the retained 0.18.0 baseline. A first callable audit found two missing
accessor comments in a new test; the corrected audit and final rerun passed.

### Workload and evidence boundaries

The final [observation index](phase-6-observations.json) binds release receipts,
source and fixture hashes, retained binaries, commands, checks, raw reports,
resource observations and exact endpoints. Ignored raw evidence remains under
`.build/performance-phase6`, with accepted comparison evidence in its `accepted`
directory. A detached original runtime at `035cf9f0` and the candidate use an
identical development harness, dependency pins, optimized flags and build jobs.
The original runtime, tests and root manifests are unchanged in that checkout.
After captures, only documentation changes; every recorded executable/test input
and both harness copies are rehashed before commit.

Each of 23 workloads, including unchanged RPC controls, has five fresh-process
candidate/candidate no-change pairs
and five alternating original/candidate pairs: 460 accepted processes. OAuth
uses 4,096 callers and 256 warmup callers, except independently injected 2 ms
storage/backend cases use 1,024 measured callers. Shared widths are 1/64/128/256;
unrelated and half-cancelled cohorts use 128/256. Width 128 fits the default
128 waiters per identity and 128 identities; width 256 is an enlarged-budget
control. Fixtures explicitly allow 256 waiters even in smaller populations,
so they do not qualify default-limit overload behavior. Actual loads, refreshes
and CAS
operations are verified once per authoritative owner. Half-cancelled results
include exactly half successful and half cancelled readers in the lookup mean.

Activities uses eight measured sessions and one warmup session. The default-sized
256-token sweep uses groups/duplicate owners per group 1/255, 16/15, 64/3 and
128/1. A separate enlarged-budget 4,096-token sweep uses 1/4095, 16/255,
256/15, 1024/3 and 2048/1. The default maximum subscriptions is 256; the fixture
sets its cap to the selected total. These are distinct workload families. Initial
owners are untimed; exact successful duplicate
admissions normalize the reported mean. Their count varies with group count;
only identical dimensions are paired. Exact upstream subscribe/unsubscribe
counts, overload rejection and complete release are checked. The later generic
`activities.request` and common throughput are control observations.

RPC uses unchanged baseline runtime code in both arms, with four measured and one
warmup session. Every target is exactly 64 public
already-sent replies with an actual 65th send parked and 0/64/1024/4096 unsent
support requests admitted. Only the queued depth changes. The target starts
before submission of prepared reverse replies and ends when every selected
public caller returns. Pending counts prove admission before the target; exact
66 writes/65 delivered frames per session and cancelled support calls prove no
unsent support bytes escape. Cancellation/close and integrity checks follow the
target. Ancillary `rpc.request` durations include prefill/setup and are separate.
The configured pending caps are 65/129/1089/4161; the production default is 128,
including sent, writing and queued requests. One cohort percentile is never
divided into a per-call percentile.

The new `oauth.refreshCohortV2` and `rpc.queuedReplyCohortV1` batch metrics have
their own [catalog contracts](../latency-timing/METRICS.md#implemented-optional-service-durations--catalog-eight).
OAuth cohort submission-to-terminal-join timing excludes subsequent close;
legacy `oauth.refresh.joined` retains its inclusive-close flight boundary.
Caller, I/O, batch and later control populations overlap or differ and are never
added together or subtracted as inferred internal CPU work. Backend admission
gates, final subscriber snapshots and task scheduling perturb enclosing lookup
durations; they are explicit fixture controls, not isolated actor CPU attribution.

### Informational local observations

The table uses the median of five process means for each arm. Means come from
exact native duration sums and exact populations, not histogram midpoints.
Ranges are the observed minimum and maximum across five paired relative mean
changes, not confidence intervals; the last column retains the
corresponding candidate/candidate variation. RPC units are microseconds per
complete 64-reply cohort; OAuth units are per terminal public lookup and Activity
units per successful duplicate admission. Comparisons across those populations
are invalid. The host was unreserved; contention, thermal/frequency state and
background work were not controlled. These are observations, not a passed
numerical acceptance gate or a portable speedup claim.

| Workload | Original mean (µs) | Candidate mean (µs) | Paired change range | No-change range |
| --- | ---: | ---: | ---: | ---: |
| oauth-shared-c1 | 32.882 | 32.683 | -2.1% to +0.7% | -1.8% to +0.4% |
| oauth-shared-c64 | 833.825 | 825.358 | -2.0% to -0.5% | -1.7% to +2.5% |
| oauth-shared-c128 | 1592.634 | 1592.670 | -1.7% to +0.4% | -2.7% to +1.3% |
| oauth-shared-c256 | 3444.754 | 3139.291 | -9.8% to -6.2% | -1.8% to +1.4% |
| oauth-unrelated-c128 | 3164.383 | 3549.154 | -1.0% to +14.8% | -2.0% to +3.5% |
| oauth-cancellation-c128 | 1881.516 | 1791.440 | -5.7% to -3.1% | -2.4% to +0.9% |
| oauth-unrelated-c256 | 6502.793 | 6873.627 | -11.4% to +10.5% | -5.1% to +5.7% |
| oauth-cancellation-c256 | 4141.674 | 3610.157 | -16.9% to -11.8% | -1.1% to +2.4% |
| oauth-storage2000-c256 | 6739.309 | 6668.036 | -3.1% to +4.9% | -5.1% to +2.9% |
| oauth-backend2000-c256 | 6604.509 | 6325.375 | -7.6% to -3.2% | -0.3% to +2.8% |
| activity-g1-tokens256 | 13.194 | 13.821 | -3.1% to +9.3% | -3.8% to +2.8% |
| activity-g16-tokens256 | 13.406 | 13.309 | -3.6% to +2.1% | -7.5% to +2.1% |
| activity-g64-tokens256 | 14.474 | 13.081 | -14.0% to -9.0% | -3.0% to +0.5% |
| activity-g128-tokens256 | 16.528 | 13.026 | -22.9% to -19.0% | -2.5% to +5.8% |
| activity-g1-tokens4096 | 17.971 | 18.741 | +4.1% to +9.8% | -3.3% to +1.0% |
| activity-g16-tokens4096 | 14.211 | 13.171 | -10.4% to -1.9% | -2.3% to +6.2% |
| activity-g256-tokens4096 | 19.497 | 12.535 | -39.1% to -28.2% | -5.1% to +1.9% |
| activity-g1024-tokens4096 | 41.878 | 12.372 | -71.0% to -70.2% | -3.7% to +2.7% |
| activity-g2048-tokens4096 | 67.202 | 12.296 | -82.5% to -81.5% | -10.6% to +1.4% |
| rpc-queue0 | 842.875 | 875.906 | -1.5% to +16.1% | -10.9% to +12.7% |
| rpc-queue64 | 855.104 | 912.646 | +2.8% to +9.3% | -2.8% to +6.9% |
| rpc-queue1024 | 1173.927 | 1138.344 | -8.0% to +3.7% | -9.4% to +3.9% |
| rpc-queue4096 | 2298.146 | 2313.948 | -2.4% to +2.1% | -2.4% to +18.5% |

The Activity group sweep shows large local gains as groups increase. Its final
4,096-token one-group control is 4.1% to 9.8% slower, beyond its observed
no-change range;
that cost is retained as an unresolved tradeoff rather than dismissed. OAuth's
width 256 shared/cancellation means improve; default-sized width 128 sharing is
roughly unchanged and cancellation improves by 3.1% to 5.7%. Unrelated-owner
candidate medians are higher at both widths, including 12.2% at 128, with mixed
paired changes. The extra object per active identity is a retained resource
tradeoff; its isolated contribution is not measured. These higher unrelated-owner
medians remain an unresolved qualification issue. Width1/64 and injected waits
remain separate controls. These observations support the selected scaling paths,
not uniform improvement across all optional-service configurations. At the
default-sized 256-token Activity budget, 64/128-group admissions improve by 9.0%
to 14.0% and 19.0% to 22.9%, respectively; one/16-group controls remain mixed.

The accepted RPC rows use unchanged RPC source and measure cross-build/control
variation; none establishes an RPC implementation gain. The queue64 candidate
mean is higher even after marker removal, with some paired changes overlapping
the no-change range. Screening deltas therefore do not isolate a marker-specific
small-queue cost. Fixture setup and queued-support cancellation also contribute to process CPU, outside the selected RPC target.
These are narrow local observations; reserved-host acceptance remains open.

### Deferred RPC proposal

A separate completed screening set tested the additional queued-ownership flag
alongside the OAuth and Activity candidates. Its 320 processes, binaries, exact
source manifest, reversed patch, reports and six diagnostic profiles remain in
`final`, indexed separately as rejected-proposal evidence. Its RPC target was the
same 64-reply cohort. Three-second-capped screening profiles include exit-one
`localScenarioFailed` reports; underlying cancellation/error causes were not
disambiguated by that wrapper. They are diagnostic traces, not completed
benchmark populations. The observed paired changes were:

| Unsent queue depth | RPC marker paired change range | Candidate/candidate range |
| --- | ---: | ---: |
| 0 | +0.2% to +14.4% | -5.7% to +9.6% |
| 64 | +4.3% to +8.5% | +1.4% to +4.9% |
| 1024 | -29.1% to -19.9% | -8.5% to +6.9% |
| 4096 | -61.9% to -58.9% | -16.2% to -1.4% |

The screening candidate's low-backlog cohort cost remains unresolved; those
controls are not ordinary single-request measurements. The restored-code controls
above also vary, so the marker is not established as the cause. Large-backlog
wins require explicit pending budgets well above the default 128, and default
configuration benefit and the crossover are not established. The proposal
was deferred and the runtime patch reversed. The entire accepted comparison was
then rebuilt and repeated with original RPC code. Scheduling, code generation,
layout and host effects remain possible contributors; the cohort interval does
not isolate the marker mutation itself. No screening means are pooled with
accepted means, and unchanged RPC controls do not qualify real-adapter latency.

All accepted paired reports have exact expected terminal outcomes, authority
counts, zero residual ownership, reaped process groups and no histogram
underflow, overflow, drops or counter overflow. The complete service matrix
passed 39 distinct cases across 90 supervised rows, including all retained
Social/Commerce/GameServices/CertifiedDevices cases, contention/fanout/wait
controls and all new cases. Its 256-caller rows select the one-process `soak`
cap profile with explicit 10 s measurement/1 s warmup ceilings; this is finite
matrix coverage, not soak qualification. Matrix cohorts, public callers and
composite service operations are retained as distinct populations in the index.

### Resources, profiles and limitations

Across accepted paired processes, peak process RSS ranged from 13.3 to 82.5
MiB and process CPU from 21.7 to 5175.8 ms. These gauges include fixture
setup, warmup, measurement, validation and joined shutdown. Higher group/backlog
cases have different setup/release work; gauge totals are not isolated per-call
allocation costs. Raw arm/workload ranges are retained with every summary. The
OAuth change adds one object per active identity, Activity adds one actor scalar,
and RPC retains its existing runtime representation.

Six separate one-second CPU stack samples at 1 ms intervals cover both runtimes'
OAuth width 256, Activity 1024-group and unchanged RPC 1024-backlog controls. Each
diagnostic
workload has a finite 30-second cooperative cap and independently reaped
process ownership. All six workloads completed their requested populations,
returned exit zero and
reported zero actual resource ownership. Reports, exit codes and logs are
retained. These profiles are
outside paired captures. Cleanup checks join public callers, the top-level close
wrapper and actual I/O ownership. Two RPC peer cancellation handlers schedule
idempotent actor-close callbacks without retaining those wrapper task handles;
zero actual reader/writer ownership does not prove that every callback wrapper
has finished. Executor-wide quiescence is not qualified. Stack sampling does not
establish allocation counts, retained-object growth or precise actor/lock wait
attribution. Allocation-event,
controlled-host and target-platform profiling remain open.

The initial release-build command resolved a relative package against the active
checkout and failed during harness editing; it is excluded from baseline evidence.
An initial paired set was superseded when review found that the new OAuth cohort
interval reused the legacy joined-close metric ID. Its final queue4096 series was
deliberately interrupted, retained with cancellation/cleanup evidence and excluded.
The corrected metric uses a separate identity, and the entire accepted set was
rebuilt and repeated. The later valid RPC-marker screening set is separately
retained as decision evidence; final accepted captures use the restored RPC source
in the `accepted` namespace. No superseded measurements are combined
with the final means.

Local implementation, regression coverage and validation are complete. Reserved
host numerical/tail gates, allocation-event/retained-growth and executor/lock
qualification, other supported platforms, real browser/Discord desktop and
provider behavior, production critical paths and live Discord remain unqualified.
No push, merge, hosted CI dispatch, publication or deployment is performed.
