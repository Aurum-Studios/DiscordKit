<!--
File: Docs/Tasks/performance-improvements/PHASE-1.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 1 — Local admission notifications

Implements [Stage 1](PLAN.md#stage-1--replace-avoidable-local-admission-polling)
from baseline `01c743e4`. The authorized scope includes implementation and local
validation despite the open Phase 0 reserved-host and profiler gates. Local
comparisons remain informational; no numerical regression policy is selected.

## Implementation plan

1. Replace whole-operation ordering polling with actor-owned pending
   notifications. Select the oldest eligible partition head when ownership or
   queue state changes. Preserve identity/partition FIFO, aggregate count/byte
   budgets, independent partition progress and the lease across retries/backoff.
2. Apply notification separately to local rate eligibility. Continue to obtain
   every reservation from the injected authority. Retain authoritative retry
   instants and finite rechecks for shared-store changes outside this coordinator.
   Never infer remote completion, advance quota resets or refund possible sends.
3. Use a shared earliest-wake timer for pending deadlines and authority retries.
   Local ordering completion requires no polling cycle. Bound retained waiters,
   continuations and timer work; fence stale timer callbacks and finish each
   parked continuation exactly once on notification, cancellation or close.
4. Test handoff without advancing an injected clock, independent identities and
   partitions, bounded resources, FIFO/starvation, deadline/cancellation/close,
   and slow/failing authorities. Revalidate after suspended authority calls and
   release late grants before rejecting cancelled, closed or expired callers.
5. Add a versioned held-owner default-policy benchmark through public APIs.
   Preserve historical REST and arrival identities. Compare fresh baseline and
   candidate processes sequentially with identical benchmark code, recording
   caller wait, release-to-successor, clock activity, CPU and complete cleanup.
   Exercise cohorts 1/4/16/64, partition/identity controls and release offsets.
6. Run root and affected consumer checks, offline inventory/generation/parity and
   documentation audits. Review the complete diff and commit the scoped result.

## Validation and measurement

Local implementation, independent review and the checks below completed on
2026-11-11, Apple Swift 6.4, arm64 macOS, SDK 27.0. The
[capture index](phase-1-observations.json) retains exact source/build identities,
fixture hashes, commands, per-process results and raw-artifact hashes. Ignored
raw evidence is retained under `.build/performance-phase1`; it is local evidence,
not a published artifact store.

### Correctness and documentation

- `swift build --force-resolved-versions --jobs 4`: passed.
- `SWIFTNIO_STRICT=1 swift test --force-resolved-versions --jobs 4 --filter
  'AdmissionNotificationTests|AdmissionAuthorityRaceTests|RateLimitTests|RateLimitStoreContractTests|MC29RateAccountingTests'`:
  42 methods in five suites passed. After adding the clock-failure case, the
  notification suite was rebuilt and passed eight methods, including its
  parameterized cohort/offset cases.
- `SWIFTNIO_STRICT=1 swift test --skip-build --jobs 4`: the final run passed
  **2,629 methods in 327 suites across 34 test-target runs**, with zero issues.
  This includes unchanged store contracts and REST ordering/retry/accounting
  integration coverage.
- Load-harness package: **109 methods in 22 suites** passed. The identical new
  harness also compiled and passed its ten relevant methods against the original
  runtime. Python checks passed **234 repository-tooling tests** and **40
  load-harness tests**, including matrix construction and native-result handling.
- Independent RESTOnly and GatewayBot builds passed with pinned dependencies.
  Offline inventory, generated-byte identity and parity checks passed.
- The callable-documentation audit passed: **954 Swift files, 10,229 explicit
  callable declarations, zero missing comments**. Public symbol graphs, DocC
  curation, tutorial/example synchronization and the pre-1.0 API policy check
  (`0.18.0` baseline, `0.19.0` candidate) passed. DiscordHTTP DocC conversion
  passed `--warnings-as-errors --analyze`; existing abstract-coverage notes remain.

The new deterministic cases exercise handoff at unchanged virtual time for
1/4/16/64 callers and multiple release offsets; FIFO, independent identity/class
progress; shared-timer bounds over idle virtual time; earlier-deadline rearming;
cancellation, expiry, close and clock failure; fractional quota retry lower
bounds; external-store capacity fallback; suspended reserve/complete/release;
and late grants after cancellation, deadline, close or authority failure. Late
grants are released exactly once as `.notSent` before local rejection. Queue
counts/bytes, reservations, ordering owners and injected clock registrations
drain after cleanup. Existing active owners remain releasable after fail-closed.

An initial documentation audit found 15 missing private benchmark comments; the
final audit above passed after comment-only corrections. The first baseline
release attempt failed because a copied Clang module cache retained its former
absolute path; removing that generated cache and rebuilding produced a successful
receipt. A first scoped DocC invocation lacked its output parent directory; the
corrected invocation passed. Failed logs/receipts remain indexed.

### Paired local observations

The original runtime is `01c743e4` with only the same eight benchmark/support
files added or updated. No original runtime source changed. Both arms use the
same benchmark source, dependency pins, Swift compiler and release flags. The
candidate was captured before the final evidence-only documentation edits;
executable/test input hashes are unchanged afterward. Receipts retain the exact
dirty source fingerprints at capture time rather than claiming the later commit
was the measured source identity.

All builds and tests finished before serial captures began. Ten priority
configurations each have five independent candidate/candidate no-change pairs
and five alternating original/candidate pairs: **200 fresh timing processes**.
They cover default-policy held-owner cohorts 1/4/16/64, four partitions or four
identities at cohort 16, the retained default ordered REST workload, both default
ordered-mutation arrival controls and the retained tuned GET rate control.
Requests are finite: 64 successors, 32 default REST/arrival requests or 128 GET
arrivals, zero in-process warmup, seed 8111 and a five-second measured cap.
Arrival controls offer 1,000 requests/s at concurrency four; their configured
pending bounds are 32 (default ordering) and 16 (GET). Each arm completed the
same offered population successfully, with no missed/unoffered arrivals,
rejections, failures, timeouts, cancellations or uncertain sends.

The following spans are the minimum lower and maximum upper **per-process p50
bucket bounds across five comparison runs**, rounded outward. They are neither
pooled percentiles nor confidence intervals. All held-owner rows use a requested
2.5 ms release offset. Release-to-successor covers every successful successor,
including its FIFO predecessors; caller wait also includes the pre-release hold.

| Workload / direct endpoint | Original p50 span | Candidate p50 span | Candidate no-change p50 span, ten processes |
| --- | --- | --- | --- |
| Held owner, 1 queued caller: release → successor | 9.34–9.36 ms | 0.03–0.05 ms | 0.02–0.07 ms |
| Held owner, 4 queued callers: release → successor | 9.28–10.20 ms | 0.07–0.09 ms | 0.06–0.09 ms |
| Held owner, 16 queued callers: release → successor | 37.52–54.40 ms | 0.23–0.26 ms | 0.23–0.29 ms |
| Held owner, 64 queued callers: release → successor | 208.49–269.95 ms | 1.51–1.86 ms | 1.52–1.93 ms |
| Default ordered REST: request | 15.3–16.0 ms | 0.5–0.6 ms | 0.5–0.6 ms |
| Shared default ordered arrivals: scheduled → response | 102.4–139.7 ms | 0.6–1.0 ms | 0.6–1.1 ms |
| Independent default ordered arrivals: scheduled → response | 0.9–1.0 ms | 0.5–1.0 ms | 0.5–1.3 ms |
| Tuned GET arrivals: scheduled → response | 2.2–3.5 ms | 0.4–0.7 ms | 0.4–0.9 ms |

Default ordered REST completed 32/32 successes in each process; successful
throughput spanned 89.41–98.97/s originally and 4,477.77–4,749.65/s with the
candidate. Shared ordered arrivals completed 32/32 at 87.77–97.99/s originally
and 990.65–1,017.20/s with the candidate at the same offered rate. Independent
arrivals completed 32/32 and remained near that offered-rate ceiling
(991.11–993.04/s original; 987.71–1,019.24/s candidate). These are fixture rates,
not Discord capacity estimates.

There is a retained CPU trade-off: independent default ordered arrivals used
**12.797–13.350 ms** whole-process user+system CPU with the candidate versus
**11.332–11.745 ms** originally. Candidate/candidate no-change processes spanned
12.545–13.706 ms. Extra eligibility scans, partition-set construction and cleanup
checks are a source-based hypothesis, not a profiler attribution. This control
does not establish a latency improvement beyond its no-change spread. A measured
empty-queue fast path and reserved-host CPU qualification remain follow-up work;
the local handoff improvement must not be described as a universal CPU win.

A further **60 fresh smoke processes** sweep each runtime through 30 held-owner
rows: cohorts 1/4/16/64; requested offsets 0/2.5/7.5 ms; and shared, four-partition
or four-identity controls where the cohort permits. All completed 64 successors,
with zero ownership, observation loss or handoff-histogram overflow. Native
receipts retain actual sleep-invocation phase; invocation alone does not prove
suspension. Peak injected sleeps were at most one for the candidate, versus the
queued cohort for the original. The runner owns at most the declared caller
cohort plus the finite held-partition cohort; exact counters do not enumerate
every runtime/executor task or operating-system wakeup.

### Parked CPU control

The [retained public-API diagnostic](ORDERING-IDLE-PROBE.md) supplies **40 more
fresh processes**: five no-change and five alternating original/candidate pairs
at 1 and 64 queued callers. Exact snapshots confirm one held partition and the
entire queued population before and after a one-second real hold. `getrusage`
user+system deltas exclude the 100 ms setup settle, release, handoff and cleanup.
Its driver uses a separate clock from the instrumented coordinator.

| Queued callers | Original parked process CPU per hold | Candidate parked process CPU per hold | New injected sleep calls during hold, original → candidate |
| --- | --- | --- | --- |
| 1 | 10.686–14.812 ms | 0.065–0.248 ms | 68–72 → 0 |
| 64 | 232.594–333.279 ms | 0.117–0.198 ms | 4,352–4,521 → 0 |

The candidate retained one deadline sleep throughout the hold; final sleep count
and queue/owner counts were zero after joined cleanup. Its no-change parked CPU
spanned 0.069–0.300 ms (one caller) and 0.092–0.218 ms (64 callers), illustrating
the sampling floor. These results support removal of periodic local polling;
they measure process CPU and injected clock calls, not idle power or OS wakeups.

All **300 measured child processes** exited successfully, their supervisors reaped
them, and no owned process group remained. The host was named but its reservation
and contention status were unknown. No numerical regression policy was selected
or evaluated. Per-outcome populations are too small for the retained 10,000-sample
p99 gate; no p99 claim follows. Reserved-host numerical qualification, allocation
and executor/CPU profiles, Linux/hosted CI, live Discord and production capacity
remain separate gates. Phase 0's profiler failures are not repaired or qualified
by these captures.

## Compatibility and ownership

`RateLimitCoordinator.close()` is now explicitly asynchronous and joins its owned
timer before returning. Cross-actor callers already use `await`; callers in an
isolated coordinator context or holding a synchronous method reference must
adopt the asynchronous signature. Closing still rejects pending/new admission
and leaves active reservations and whole operations with their existing owners.
It does not close the injected shared store or wait for application operations.

On ordinary acquisition/operation exit, cleanup joins only the captured obsolete
sleep child when no parked timer demand remains. It does not await a persistent
driver that a new caller could legitimately keep alive. The driver joins every
interrupted child before creating its replacement. Thus one driver and at most
one injected clock sleep cover both queues; completion notifications spawn no
tasks. Cancellation retains the existing small cleanup task per cancelled caller.

Real authority retry instants remain lower bounds. `fairnessInterval` retains its
10 ms default and minimum retry spacing, including capacity rechecks for external
stores or other coordinators sharing a store. Local completion cannot infer their
progress. Slow/failing authorities and late grants are covered by injected
barriers, separately from the local ordering benchmark, which reserves no quota.
