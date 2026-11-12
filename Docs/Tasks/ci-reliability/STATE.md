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
Phase 2 has passed local macOS ARM64 Swift acceptance; its commit receipt is pending.
No hosted qualification, paid execution, external configuration change or publication
is claimed. See [BOOTSTRAP.md](BOOTSTRAP.md) for the zero-paid execution sheet.

| Phase | Status | Implementation commit | Acceptance evidence |
| --- | --- | --- | --- |
| 0 — Baseline and initial limits | Complete; local preparation only | `5808ce32d867622ff6952d0f2057768a8a257f14` | [212 helper tests](baseline/validation.json), [retained capture](baseline/CAPTURE.md), [usage baseline](baseline/COST.md), [zero-paid sheet](BOOTSTRAP.md); hash/link/diff checks passed |
| 1 — Process supervision | Complete; local helper acceptance only | `1bc5de45a6dbeef1ab31bd7f6fbbe85b69771600` | [231 helper tests](phase-1/validation.json), [nine retained fault specimens](phase-1/faults/results.json), [independent review](phase-1/review/results.json), [implementation and limits](phase-1/IMPLEMENTATION.md) |
| 2 — Event-hub accounting | Local acceptance passed; commit receipt pending | Pending | [Red/green, 23 load + 21 runtime tests, four CLI checks](phase-2/validation.json), [independent review](phase-2/review.json), [implementation and limits](phase-2/IMPLEMENTATION.md) |
| 3 — Linux hang repair | Not started | Pending | Cause unresolved |
| 4 — Compatibility receipts | Not started | Pending | Pending |
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
   Phase 3 uses this supervisor for diagnosis; its Linux blocked owner remains
   unresolved. No later phase starts as part of Phase 1 completion.
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
preserved. The actual implementation SHA will be recorded after committing.

The next authorized implementation phase is Phase 3: diagnose the Linux synthetic
command hang using Phase 1 supervision. Its blocked owner remains unresolved.
Whole-package native load confirmation and final hosted certification remain
later-phase work. No remote operation or later-phase implementation occurred here.

## Outstanding execution decisions

- Paid execution remains unauthorized: experiment/workflow allowances are USD 0,
  and paid jobs/minutes/attempts are zero. Published dated list rates are retained;
  account billing/pool mapping and the reported USD 40 remain unreconciled.
- Local matching Ubuntu environment versus separately authorized bounded hosted probe.
- Operator-selected repository budget amount/scope and authorization to configure it.
- Phase 0 uses `ci/phase-0-baseline` in sibling `DiscordKit-ci-phase0`, owner
  Codex `/root`, base `85eac6f3c1d3b17e53596c49e7438efee366c1b3`.
  Phase 1 and Phase 2 ownership and local-only sheets are recorded above. Phases 3
  through 11 owners and paid experiment sheets are not assigned/authorized.

These do not prevent beginning local preparation/helper implementation. Missing
allowances or execution authorization prevent paid scheduling, not source work.

## Handoff fields

For each active phase retain: owner, branch/worktree, base and tested commit/content
hash, owned paths, commands/exits, diagnostic/artifact identities, allowance and
remaining attempts, acceptance criteria still open, and the exact next action.
