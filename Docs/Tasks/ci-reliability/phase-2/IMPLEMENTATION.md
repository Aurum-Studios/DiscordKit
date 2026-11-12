<!--
File: Docs/Tasks/ci-reliability/phase-2/IMPLEMENTATION.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 2 event-hub accounting repair

The authoritative requirements are [Phase 2](../PLAN.md#phase-2--repair-event-hub-cancellation-accounting).
The implementation belongs to the benchmark. Public FIFO, iterator post-await
cancellation, residence endpoints, independent subscriptions and queue limits
remain the runtime contract.

## Ownership and local execution sheet

- Owner: Codex `/root`; base `7632bdd3494d8ec7a52edc798ad98e09b5a8c357`,
  branch `ci/phase-2-event-hub`, isolated sibling `DiscordKit-ci-phase2`.
- Preserve the original checkout's planning edits and all existing worktrees.
  [source-preflight.json](source-preflight.json) records identity and local host.
- Scope: phase-2 benchmark repair, deterministic regressions, focused load/runtime
  checks, documentation and local commits. No later-phase implementation.
- Paid jobs/minutes/attempts **0 / 0 / 0**, allowance **USD 0.00**. No remote writes.
- Local macOS ARM64 compiler: installed Apple Swift **6.4**
  (`swiftlang-6.4.0.34.1`). The hosted **6.4.1** pin remains unchanged. These checks
  establish local host behavior, not exact pinned hosted-toolchain qualification.
- Each cold/incremental build: 1,200-second bound; root/load build aggregate at
  most 4,800 seconds; six compiler jobs. Private root/load scratch directories.
- Four compiled CLI smoke commands: 120 seconds each, one attempt per case.
- Each compiled focused test process: 90-second bound, at most two attempts per
  source/experiment before inspection and revision; discovery: 60 seconds.
  No automatic assertion/test/build retry. All commands use Phase 1 supervision,
  retained diagnostics, eight-second POSIX cleanup allowance and process receipts.
- Whole-package load confirmation remains Phase 3/11 work, after Linux diagnosis.

## Plan and acceptance

1. Define queue removal separately from iterator return and consumer acceptance.
   Residence success proves removal only. Preserve setup/measured ownership.
2. Add default-disabled benchmark observation boundaries; cancel synchronously at
   a real residence end without awaiting/reentering the authority. Retain a red
   regression before changing accounting. Fault-inject a driver interruption only
   after waiting children have returned, to verify cleanup retains their results.
   This latter injection tests the cleanup path; it does not establish the exact
   hosted interleaving or claim normal parent cancellation cancels child tasks.
3. Classify eviction and retained cancellation from actual residence outcomes;
   classify cancellation at handoff from the specific pull's removal evidence.
   Join and aggregate each waiting result once, including successful results
   completed before driver interruption. Reject unexplained or duplicate copies.
4. Export independent setup/measured terminal partitions and version incompatible
   native accounting and comparison identity. Preserve historical reports.
5. Verify cancellation before removal, at removal, after returned child result,
   and after acceptance; setup backlog, partial cohorts, multiple hubs/subscribers,
   overflow policies and unaffected runtime subscriptions. Confirm all task joins
   and zero subscriptions, buffered events/bytes and waiting consumers.
6. Run focused checks under supervisor bounds, independently review the diff,
   bind evidence to tested source hashes, and commit implementation followed by
   a documentation receipt carrying the actual commit SHA.

## Results

[validation.json](validation.json) binds the tested inputs, literal commands,
execution receipts, discovery and CLI partitions. All processes exited within
limits and were reaped with their admitted groups gone. No automatic retry or
paid execution occurred.

| Check | Result |
| --- | --- |
| Baseline red regression | Expected exit 1: two tests, four issues; measured/setup dequeue loses one copy, waiting cleanup loses four returned values |
| Final timing/accounting suites | Exit 0: 23 tests, two suites, 2.212 seconds |
| Final public EventHub suite | Exit 0: 21 tests, one suite, 0.008 seconds |
| Nonempty discovered scope | 23 timing/accounting identifiers and 21 runtime identifiers, no duplicates |
| CLI reports | Four successful schema-2 native/schema-1 common round trips; exact partitions and empty cleanup |
| Independent review | Passed; no blocking findings, six Swift input hashes verified |

The [red replay patch](red-regression.patch.gz) is a lossless gzip archive; decompress it before applying. It adds only default-disabled benchmark
fault observation and two regression tests to the Phase 1 base. Its
[input record](red-inputs.json) was reconstructed from those exact additions after
the failing invocation, and its replay hashes are verified. Queue tests cancel
synchronously at an actual successful residence end for measured and setup copies.
The waiting test deliberately injects a driver interruption after all four child
values have returned; it proves cleanup retained no results before the repair.
The exact hosted interleaving remains unproven.

Final tests also cover cancellation before dequeue, after accepted values, at a
waiting consumer handoff and after partial aggregation; multiple hubs/subscribers,
setup backlog, all overflow policies, zero backlog and unchanged healthy FIFO.
The ledger's contradiction tests reject duplicate endpoints, unowned/multiple
removals, incompatible acceptance/cancellation, and unfinished owners. A cancelled
driver cannot suppress an integrity error.

The repair has no public runtime source changes. Residence endpoint/outcomes and
the iterator's post-await cancellation check remain intact. Production residence
IDs tag setup/measured admissions, and one sequential queued pull owns each
successful removal until acceptance or proven handoff cancellation. Direct waiting
admissions are bound to the confirmed parked cohort and joined child results.
Native schema 2 and scheduler/instrumentation identity 2 prevent reinterpreting
historical outcomes or comparing changed bookkeeping overhead as runtime speed.
The ledger retains at most 262144 active residence IDs/tags, independently of the
fixed histograms; envelope-byte receipts exclude instrumentation metadata.

Native smoke reports and their common envelopes are stored as lossless JSON gzip
archives. Validation records both compressed and original-byte SHA256 digests;
command receipts retain the original output paths. Retained logs distinguish the
initial 20-test green implementation from the final 23-test expanded acceptance.
[review.json](review.json) records the independent source-bound review. The
[validation script](validate.py) uses inherited Phase 1 supervision for every
build, discovery, focused test and smoke invocation.

Local acceptance is complete. Whole-package load confirmation, Linux diagnosis,
hosted pinned Swift 6.4.1 and exact-final-source certification remain Phases 3/11.
No remote action or later-phase implementation is included. Implementation commit
`4dbb085521f1977dc40ea5b8818edb9d61cd2f9f` contains the tested executable inputs and
retained evidence. All eight input hashes match that commit. A documentation-only
follow-up records the actual SHA and marks Phase 2 complete; executable inputs and
the 61-file evidence manifest remain unchanged.
