<!--
File: Docs/Tasks/ci-reliability/phase-3/IMPLEMENTATION.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 3 synthetic command diagnosis

Requirements: [Phase 3](../PLAN.md#phase-3--locate-and-repair-the-linux-synthetic-command-hang).

## Ownership and execution sheet

- Owner: Codex `/root`; branch `ci/phase-3-synthetic-command`, isolated sibling
  `DiscordKit-ci-phase3`, base `07cdea35` (completed Phases 0–2).
- Preserve the original checkout's four planning edits and all existing worktrees.
  [Source preflight](source-preflight.json) records their hashes and ownership.
- Scope: synthetic command blocked-owner diagnosis, supported repair and controlled
  regressions, focused and whole-package checks, existing offline REST/loopback
  smokes, local documentation and commits.
- Paid jobs/minutes/attempts **0 / 0 / 0**, spend allowance **USD 0.00**.
  Remote writes and hosted execution are outside this execution sheet.
- Local Linux: existing Colima Ubuntu 24.04.4 aarch64 VM, six CPUs / 16 GiB.
  Use one owned Ubuntu 24.04 x64 Swift **6.4.1** container under Rosetta with six
  CPUs / 12 GiB, private scratch storage and a finite four-hour container lifetime.
  Immutable official image manifest:
  `sha256:1a784fc9de712a985020336bbc447c21050777cbe3b76f915eb352fd21b50f3d`.
  This is explicitly emulated exploratory evidence, not native Linux x64 acceptance.
- Image transfer: 120-second attempt, at most three attempts within 420 seconds.
  Cold/incremental compilation: 1,200 seconds per command, 4,800-second aggregate,
  six compiler jobs. Discovery: 60 seconds and required nonempty identifiers.
- Focused compiled tests: 90 seconds with 30/60-second stack snapshots, at most two
  attempts before evidence inspection and experiment revision. Whole load package:
  600 seconds. Existing REST and NIO loopback smokes: 120 seconds each.
- Use Phase 1 supervision inside the Linux process namespace, separate discovery
  stdout, `--skip-build --no-parallel`, committed pins and strict imports. Retain
  command, output, diagnostics and final process-group cleanup receipts. No
  automatic compiler/assertion/test retry or larger timeout to turn a failure green.

## Investigation plan

1. Probe the exact container OS, compiler, architecture, translation and diagnostic
   availability; record them independently from the hosted failure environment.
2. Compile separately, discover nonempty exact identifiers, then run the unchanged
   synthetic suite under the focused deadline. A last printed case is only a lead.
3. Use stacks and bounded development-only stage observations to distinguish
   preparation/admission, handler, response, annotation, worker/group join and
   cleanup ownership. Compare direct/DSL and success/deferred/failure/cancellation
   paths in fresh processes only as needed to refine a blocked-owner hypothesis.
4. If focused execution succeeds, reproduce the whole-package process and inspect
   preceding work. Capture a deterministic failing-before regression for a supported
   cause before applying the smallest fix; keep public cancellation/response
   semantics and every parameterized case.
5. Verify direct/DSL parity, partial cancellation, no replacement cohorts and zero
   active handlers/acknowledgements/bytes. Then confirm the whole load package and
   existing REST/loopback smokes. Obtain independent review and commit owned paths.

## Blocked owner and supported repair

The unchanged focused synthetic suite passed all eight arguments. The unchanged
whole-package process then completed that suite and stalled in the following
transport chunk-control test. Buffered console output made the last synthetic
case an unreliable owner indicator. The historical hosted log has no stacks;
the local cause is supported directly, while an identical historical interleaving
remains unproven.

The [focused red stack and signal assessment](diagnostic-assessment.json) identifies
`TransportTimingRunnerTests.nativeChunkControlsCloseOwnedResources` waiting in
`TimingLocalPeer.stop()` → `LocalPeer.stop()` → `Foundation.Process.waitUntilExit()`.
Its Python peer inherited a signal mask containing SIGTERM. The requested SIGTERM
was pending (`ShdPnd` bit `0x4000`) and still blocked (`SigBlk` contained that bit)
for at least 9.6 seconds. The owner had already closed the NIO transport.

The peer now installs its existing SIGTERM handler, unblocks **only SIGTERM** on
platforms with `pthread_sigmask`, then announces readiness. Other inherited masks
and the existing metrics/exit contract remain intact. This follows the signal-mask
operations in the [Python documentation](https://docs.python.org/3.12/library/signal.html#signal.pthread_sigmask).
The [red regression](peer-red.log) launches ordinary and SIGTERM-masked peers
through a single-threaded exec launcher: only the masked peer needs the fixture's
forced kill. The [green regression](peer-green.log) requires both peers to exit
gracefully, return exact metrics, be reaped and close their listener.

No router, responder, command handler or statistics implementation changed. The
initial synthetic-stage instrumentation proposal was deliberately left unapplied
once completed synthetic stages and the real transport wait were established.
The bounded observations instead cover the blocked owner, process identities,
pending/blocked signal state, all-thread Swift stack and joined cleanup. This
narrows the planned instrumentation based on evidence; it does not omit a
synthetic argument or treat an isolated pass as phase acceptance.

Synthetic test coverage additionally checks deferred parent cancellation for both
direct/DSL routes and pre-cancelled callers for all eight scenarios. Offered,
admitted, completed, callback/edit populations and each handler/acknowledgement
count/byte gauge are asserted. A finishing `AsyncStream` replaces the test's
one-shot continuation so a runner error can release the observer. This independent
fixture improvement is not attributed as the transport or historical hang cause.

## Required supervisor support

The baseline exposed a separate Phase 1 gap: SwiftPM's test executable and the
Foundation peer create their own process groups inside the command's unique
Linux session. The old PGID-only snapshots and cleanup missed them. The baseline
interruption needed explicitly owned manual cleanup, retained in
[baseline-manual-cleanup.json](baseline-manual-cleanup.json).

Linux snapshots, TERM/grace/KILL and final verification now select that admitted
SID and its groups. They never select by executable name, never signal the
supervisor's group, and preserve other platforms' cleanup. Escaped sessions remain
outside this boundary. Unavailable, malformed or truncated Linux session
verification must fail rather than certify unseen descendants. Receipts distinguish
`gone`, `zombies-only`, `alive` and `unknown`.

The [baseline leak specimen](supervisor-red.log) fails before the support repair.
Four real Linux regressions cover separate child/grandchild groups, TERM resistance,
an exited parent holding output, hidden surviving children, supervisor SIGTERM
and an unrelated session that remains alive. A reviewed missing-verification
regression further protects the fail-closed acceptance rule. The first broad
helper run also exposed an existing 50 ms interpreter-startup assumption in its
heartbeat fixture. That test now confirms its marker before measuring the same
cadence and deadline; product deadlines were not increased. The failed run is
retained as [supervisor-linux-initial-failure.log](supervisor-linux-initial-failure.log).

## Execution and evidence

- Pinned compiler: Swift 6.4.1 RELEASE, Ubuntu 24.04.5 x86_64 container on an ARM64
  Ubuntu VM using Rosetta. [Environment](linux-environment.json) and
  [diagnostic assessment](diagnostic-assessment.json) retain the distinction.
- Baseline cold compile: 280.01 compiler seconds, 283.143 supervised seconds.
  Later incremental builds remain separate from test execution. One explicit
  source annotation removed the new `Void?` inference warning before final Swift
  testing; both build logs remain available. The native-build deprecation warning
  is emitted by the pinned toolchain; the required native engine remains selected.
- Nonempty exact discovery: 160 baseline functions, 161 final functions; four
  synthetic functions and 13 transport functions. The compiler exposes parameterized
  function identifiers, not individual argument IDs. Suite filters retain every
  declared argument; no invented selectors or case exclusions are used.
- Focused final synthetic: four functions with 8 ordinary, 2 deferred-cancellation
  and 8 pre-cancelled arguments plus invalid bounds. Focused transport: 13 functions,
  including both formerly blocked native chunk controls.
- Whole load package: **161 tests / 28 suites passed**, including Phase 2 event-hub
  coverage, under the unchanged 600-second execution limit. Final receipts and
  source identities are indexed by [validation.json](validation.json).
- Eight fresh executable processes exercise direct/DSL immediate, deferred,
  provider failure and cancellation scenarios with seven requests, concurrency
  three and no warmup. Both existing REST/loopback smoke cases use 16 measured
  requests, two warmup requests and concurrency two. These use the **debug** product,
  not the workflow's release configuration. Every process/report pair is retained.
- [Report acceptance](scenario-report-validation.json) checks all ten report pairs:
  exact outcome/metric populations, matching common/native evidence, no drops or
  counter overflow, no invented responses and zero remaining owners. Timing
  numbers are informational; no numerical performance acceptance is claimed.
- The first diagnostic experiment used one isolated and one whole-package run,
  followed by evidence inspection. The revised transport experiment used one
  focused debugger-owned process, interrupted intentionally after ten seconds.
  The controlled Python red is separate. Green checks follow source repairs;
  no assertion/compiler failure was automatically retried unchanged.
- Direct ptrace stacks are unusable under this Rosetta environment even when the
  debugger returns zero. A separately verified Rosetta remote-debug path supplied
  the actual Swift frames. Its startup-only diagnostic variable rename prevents
  child peers from inheriting a debugger wait; the driver records that intervention.
  Sacrificial probe failures, including an unsupported debugger expression, remain
  explicit. The owned core was hashed and removed. This path is diagnostic only.
- [Artifact transport](artifact-transport.json) losslessly compresses the raw debugger
  output and [red replay patch](red-regressions.patch.gz). Their emitted receipt
  paths retain the original names; the transport table records stored names and
  both byte hashes. Decompression reproduces the original evidence exactly.
- Successful Swift/scenario/smoke/peer receipts report parent reaping and verified
  empty ownership boundaries. Helper fault suites can retain orphaned zombies under the container's
  non-reaping PID 1; [container cleanup](container-cleanup.json) records disposal of
  the entire owned container. The private build volume and pinned image are retained
  for a later authorized probe; no unrelated Docker resources are removed.

## Acceptance status and next action

Implementation and local emulated acceptance are complete; **Phase 3 native x64
acceptance remains open**. [Independent review](review.json), the complete
[validation index](validation.json), input hashes and evidence manifest bind this
local result. This does not qualify native x64, release configuration, hosted CI,
other platforms, live Discord or final rollout. Paid jobs/minutes/attempts and spend
remain **0 / 0 / 0 / USD 0.00**; no push, dispatch or publication occurred.

Run the committed repair on a verified native Ubuntu 24.04 x64 Swift 6.4.1 host
using the [native acceptance handoff](NATIVE-ACCEPTANCE.md). Native hardware/access
or a separately authorized hosted execution sheet is still required. The ledger
must not mark Phase 3 complete based only on these emulated results.
