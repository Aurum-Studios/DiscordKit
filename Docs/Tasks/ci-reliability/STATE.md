<!--
File: Docs/Tasks/ci-reliability/STATE.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Implementation ledger

Plan: [PLAN.md](PLAN.md). Evidence: [EVIDENCE.md](EVIDENCE.md).
Starting source: `85eac6f3c1d3b17e53596c49e7438efee366c1b3`.
Only planning/documentation is complete. No implementation phase, native check,
paid execution, external configuration change, or publication is claimed.

| Phase | Status | Implementation commit | Acceptance evidence |
| --- | --- | --- | --- |
| 0 — Baseline and initial limits | Not started; incident observations available | Pending | Pending baseline capture and execution sheet |
| 1 — Process supervision | Not started | Pending | Pending |
| 2 — Event-hub accounting | Not started | Pending | Pending red/green regression |
| 3 — Linux hang repair | Not started | Pending | Cause unresolved |
| 4 — Compatibility receipts | Not started | Pending | Pending |
| 5 — Transfer and partial reruns | Not started | Pending | Pending local and hosted proof |
| 6 — Preflight and canaries | Not started | Pending | Pending |
| 7 — Suite groups and resources | Not started | Pending | Pending coverage/cost comparison |
| 8 — Verified provisioning | Not started | Pending | Pending cold/cache evidence |
| 9 — Shared documentation inputs | Not started | Pending | Pending invocation-count/trust proof |
| 10 — Spend admission | Not started | Pending | Pending |
| 11 — Qualification and rollout | Not started | Pending | Pending exact-final-revision CI |

## First implementation session

1. Complete Phase 0 identity/dirty/worktree/process preflight and select an isolated
   implementation checkout. Retain expiring run evidence and runner-minute data.
2. Freeze the bootstrap limits and supervisor/receipt interfaces. Assign one owner
   for native_jobs.py and workflow integration.
3. Begin Phases 1, 2 and 4 in separate owned changes. Integrate the supervisor before
   any native reproduction. The Linux investigation follows Phase 1.
4. Update this ledger only from actual phase exit evidence. A proposed or reviewed
   implementation is not a passing native qualification.

## Outstanding execution decisions

- Concrete per-experiment/workflow allowance and verified dated runner rates.
- Local matching Ubuntu environment versus separately authorized bounded hosted probe.
- Operator-selected repository budget amount/scope and authorization to configure it.
- Actual implementation branch/worktree and phase owners.

These do not prevent beginning local preparation/helper implementation. Missing
allowances or execution authorization prevent paid scheduling, not source work.

## Handoff fields

For each active phase retain: owner, branch/worktree, base and tested commit/content
hash, owned paths, commands/exits, diagnostic/artifact identities, allowance and
remaining attempts, acceptance criteria still open, and the exact next action.
