<!--
File: Docs/Tasks/ci-reliability/STATE.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Implementation ledger

Plan: [PLAN.md](PLAN.md). Evidence: [EVIDENCE.md](EVIDENCE.md).
Starting source: `85eac6f3c1d3b17e53596c49e7438efee366c1b3`.
Phase 0 is complete at implementation commit
`5808ce32d867622ff6952d0f2057768a8a257f14` on `ci/phase-0-baseline`.
Phase 1 is complete at implementation commit
`1bc5de45a6dbeef1ab31bd7f6fbbe85b69771600` on `ci/phase-1-supervision`.
Phase 2 is complete at implementation commit
`4dbb085521f1977dc40ea5b8818edb9d61cd2f9f` on `ci/phase-2-event-hub`
with local macOS ARM64 Swift acceptance.
No hosted qualification, paid execution, external configuration change or publication
is claimed. See [BOOTSTRAP.md](BOOTSTRAP.md) for the zero-paid execution sheet.

| Phase | Status | Implementation commit | Acceptance evidence |
| --- | --- | --- | --- |
| 0 — Baseline and initial limits | Complete; local preparation only | `5808ce32d867622ff6952d0f2057768a8a257f14` | [212 helper tests](baseline/validation.json), [retained capture](baseline/CAPTURE.md), [usage baseline](baseline/COST.md), [zero-paid sheet](BOOTSTRAP.md); hash/link/diff checks passed |
| 1 — Process supervision | Complete; local helper acceptance only | `1bc5de45a6dbeef1ab31bd7f6fbbe85b69771600` | [231 helper tests](phase-1/validation.json), [nine retained fault specimens](phase-1/faults/results.json), [independent review](phase-1/review/results.json), [implementation and limits](phase-1/IMPLEMENTATION.md) |
| 2 — Event-hub accounting | Complete; local macOS Swift acceptance | `4dbb085521f1977dc40ea5b8818edb9d61cd2f9f` | [Red/green, 23 load + 21 runtime tests, four CLI checks](phase-2/validation.json), [independent review](phase-2/review.json), [implementation and limits](phase-2/IMPLEMENTATION.md) |
| 3 — Linux hang repair | Implemented and locally tested; native x64 acceptance pending | `69a21b325c4eaa6181eb31dcc7e78ab083ac6411` | [Stack-supported peer repair, red/green and whole-package checks](phase-3/IMPLEMENTATION.md); [native gate](phase-3/NATIVE-ACCEPTANCE.md) remains open |
| 4 — Compatibility receipts | Implemented; local helper acceptance passed; commit receipt pending | Pending local commit | [270 helpers, six existing Linux-only skips](phase-4/validation.json), [review](phase-4/review.json), [v2 contracts and execution sheet](phase-4/IMPLEMENTATION.md) |
| 5 — Transfer and partial reruns | Not started | Pending | Pending local and hosted proof |
| 6 — Preflight and canaries | Not started | Pending | Pending |
| 7 — Suite groups and resources | Not started | Pending | Pending coverage/cost comparison |
| 8 — Verified provisioning | Not started | Pending | Pending cold/cache evidence |
| 9 — Shared documentation inputs | Not started | Pending | Pending invocation-count/trust proof |
| 10 — Spend admission | Not started | Pending | Pending |
| 11 — Qualification and rollout | Not started | Pending | Pending exact-final-revision CI |

## Phase 1 handoff

The supervisor, native planner and policy inputs passed local acceptance in the
isolated `ci/phase-1-supervision` branch, sibling `DiscordKit-ci-phase1`, owner
Codex `/root`, base `a74d58a754048ff4058c64a2d75b5bb3b21d04e0`.
[Input hashes and the final helper invocation](phase-1/validation.json) bind the
seven executable/configuration/test files. [Implementation notes](phase-1/IMPLEMENTATION.md)
retain the execution sheet, command/aggregate bounds, review and qualification limits.
The Phase 0 checkout and the original checkout's four planning files are preserved.
The implementation commit contains the tested inputs and all retained receipts.
This completion receipt changes documentation only; the seven tested input hashes
match the implementation commit and remain unchanged.

1. Subsequent authorized sessions can prepare Phases 2 and 4 independently.
   Phase 3 uses this supervisor for diagnosis; its blocked owner was unresolved at
   the Phase 1 handoff. No later phase started as part of Phase 1 completion.
2. Re-read source/worktree/process state, existing receipts and zero-paid limits
   before the next implementation. Native experiments still require a concrete
   allowed scope and execution allowance; helper acceptance supplies neither.

## Phase 2 handoff

Owner Codex `/root` prepared Phase 2 on `ci/phase-2-event-hub`, sibling
`DiscordKit-ci-phase2`, based on `7632bdd3494d8ec7a52edc798ad98e09b5a8c357`.
The [execution sheet and implementation](phase-2/IMPLEMENTATION.md) separate local
Apple Swift 6.4 evidence from hosted Swift 6.4.1 and Linux qualification.
[Validation](phase-2/validation.json) binds the tested inputs and retained process
receipts. [Independent review](phase-2/review.json) found no blocking findings.
The original checkout's planning changes and completed phase checkouts remain
preserved. Implementation commit `4dbb085521f1977dc40ea5b8818edb9d61cd2f9f`
contains the tested inputs and retained evidence. All eight input hashes match
that commit and remain unchanged; this completion receipt is documentation only.

The Phase 2 handoff required Phase 3 diagnosis using Phase 1 supervision, with its
blocked owner still unresolved at that checkpoint. Whole-package native load
confirmation and final hosted certification remained open. No remote operation or
later-phase implementation occurred as part of Phase 2.

## Phase 3 handoff

Owner Codex `/root` prepared the repair on `ci/phase-3-synthetic-command`, sibling
`DiscordKit-ci-phase3`, based on `07cdea35d6f9ad384bfb42a3005940ca69e76922`.
The [execution sheet and findings](phase-3/IMPLEMENTATION.md) identify transport
peer shutdown as the local blocked owner, supported by real Swift wait stacks and
blocked/pending SIGTERM. The historical last synthetic log line was not proof of
its owning operation. The peer now unmasks only its shutdown signal after installing
its handler. Linux supervision also includes separately grouped descendants in the
admitted session and fails closed on incomplete cleanup verification.

[Validation](phase-3/validation.json) retains deterministic red/green regressions,
237 passing CI helpers, 161 whole-package Swift tests, direct/DSL parity and both
existing debug smokes. [Review](phase-3/review.json), final input/artifact hashes
and owned container cleanup accompany the result. The original planning edits and
all completed phase worktrees are preserved. Implementation commit
`69a21b325c4eaa6181eb31dcc7e78ab083ac6411` contains the 19 verified tested inputs
and 168 retained manifest artifacts. The [commit receipt](phase-3/commit-receipt.json)
records checks against actual Git blobs; this follow-up changes documentation only.

The Ubuntu 24.04 x64 Swift 6.4.1 execution used Rosetta on an ARM64 VM. It is
**emulated exploratory/local acceptance**, not native x64 or hosted qualification.
Phase 3 remains pending native acceptance; the [next action](phase-3/NATIVE-ACCEPTANCE.md)
requires a verified native host/access or a separately authorized bounded hosted
probe. No later phase, push, dispatch, publication or paid execution occurred.

## Phase 4 handoff

Owner Codex `/root` implemented receipt version 2 on `ci/phase-4-compatibility`,
sibling `DiscordKit-ci-phase4`, based on `9f26e10c` (Phase 3 handoff).
[Contracts and execution plan](phase-4/IMPLEMENTATION.md) define exact compatibility,
separate successful producer provenance, and terminal consumer results. Same-run,
same-attempt scope remains enforced. V1 requires regeneration. Immutable artifact
resolution and earlier-attempt recovery remain Phase 5 work.

[Validation](phase-4/validation.json) records 270 CI helper tests: 264 passed and six
existing Linux-only tests skipped on macOS, plus retained red/green exact-type
regressions and policy/hash/link checks. [Independent review](phase-4/review.json)
has no remaining blockers. Metadata command availability was checked read-only on
the host; its Swift 6.4 compiler does not qualify pinned Swift 6.4.1. No native
compilation, hosted CI, paid execution, workflow mutation, push or publication occurred.
The original planning edits and earlier worktrees remain preserved. The actual
implementation commit will be recorded by a documentation-only follow-up after
Git blob/hash verification; until then this entry is not marked complete.

## Outstanding execution decisions

- Paid execution remains unauthorized: experiment/workflow allowances are USD 0,
  and paid jobs/minutes/attempts are zero. Published dated list rates are retained;
  account billing/pool mapping and the reported USD 40 remain unreconciled.
- Native Ubuntu 24.04 x64 host/access versus separately authorized bounded hosted probe;
  the retained local x64 container is emulated and cannot close Phase 3.
- Operator-selected repository budget amount/scope and authorization to configure it.
- Phase 0 uses `ci/phase-0-baseline` in sibling `DiscordKit-ci-phase0`, owner
  Codex `/root`, base `85eac6f3c1d3b17e53596c49e7438efee366c1b3`.
  Phase 1 through Phase 4 ownership and local-only sheets are recorded above. Phases 5
  through 11 owners and paid experiment sheets are not assigned/authorized.

These do not prevent beginning local preparation/helper implementation. Missing
allowances or execution authorization prevent paid scheduling, not source work.

## Handoff fields

For each active phase retain: owner, branch/worktree, base and tested commit/content
hash, owned paths, commands/exits, diagnostic/artifact identities, allowance and
remaining attempts, acceptance criteria still open, and the exact next action.
