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
No native check, paid execution, external configuration change or publication
is claimed. See [BOOTSTRAP.md](BOOTSTRAP.md) for the zero-paid execution sheet.

| Phase | Status | Implementation commit | Acceptance evidence |
| --- | --- | --- | --- |
| 0 — Baseline and initial limits | Complete; local preparation only | `5808ce32d867622ff6952d0f2057768a8a257f14` | [212 helper tests](baseline/validation.json), [retained capture](baseline/CAPTURE.md), [usage baseline](baseline/COST.md), [zero-paid sheet](BOOTSTRAP.md); hash/link/diff checks passed |
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

## Next implementation session after Phase 0

The implementation commit contains the tested policy/accounting inputs and all
baseline receipts. This ledger follow-up changes documentation only; the tested
input hashes still match the implementation commit. Its completion does not
advance any later phase or authorize a native experiment.

1. Re-read identity/dirty/worktree/process state and the Phase 0 baseline receipts.
   Retain the isolated implementation branch and keep intermediate commits local.
2. Preserve [bootstrap limits](BOOTSTRAP.md) and define supervisor/receipt
   interfaces. Keep one owner for native_jobs.py and workflow integration.
3. Begin Phases 1, 2 and 4 in separate owned changes. Integrate the supervisor before
   any native reproduction. The Linux investigation follows Phase 1.
4. Update this ledger only from actual phase exit evidence. A proposed or reviewed
   implementation is not a passing native qualification.

## Outstanding execution decisions

- Paid execution remains unauthorized: experiment/workflow allowances are USD 0,
  and paid jobs/minutes/attempts are zero. Published dated list rates are retained;
  account billing/pool mapping and the reported USD 40 remain unreconciled.
- Local matching Ubuntu environment versus separately authorized bounded hosted probe.
- Operator-selected repository budget amount/scope and authorization to configure it.
- Phase 0 uses `ci/phase-0-baseline` in sibling `DiscordKit-ci-phase0`, owner
  Codex `/root`, base `85eac6f3c1d3b17e53596c49e7438efee366c1b3`.
  Later phase owners and paid experiment sheets are not assigned/authorized.

These do not prevent beginning local preparation/helper implementation. Missing
allowances or execution authorization prevent paid scheduling, not source work.

## Handoff fields

For each active phase retain: owner, branch/worktree, base and tested commit/content
hash, owned paths, commands/exits, diagnostic/artifact identities, allowance and
remaining attempts, acceptance criteria still open, and the exact next action.
