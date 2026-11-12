<!--
File: Docs/Tasks/ci-reliability/phase-10/IMPLEMENTATION.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 10 spend admission and usage reporting

Owner: Codex `/root`; branch `ci/phase-10-spend-admission`, sibling checkout
`DiscordKit-ci-phase10`. Base: `f94520e3` (Phase 9 local acceptance receipt).
[Source preflight](source-preflight.json) preserves the original checkout's four
planning edits and all previous phase checkouts.

## Plan and local execution sheet

1. Expand the same scoped platform partitions used by execution. Read enclosing
   deadlines directly from the workflows, count each matrix runner separately,
   and reject unaccounted jobs, runner mappings or matrix expansion.
2. Compute a complete maximum, including shared bootstrap/helpers, both platform
   waves, provisioning, command limits, diagnosis/cleanup, transport, documentation,
   aggregation and optional publication. Round each job and attempt separately.
3. Reserve every allowed job/attempt centrally. Require fresh verified rates,
   bounded additional charges, a safety allowance and explicit authorization.
   Recompute at each job entry; stale successful upstream outputs grant nothing.
4. Restrict automatic pushes to the maintained default branch, retain PR and
   manual entry points, and guard the separate manual documentation requester.
5. Retain estimates and observed execution separately. Report unresolved pricing,
   missing coverage, failed commands and unavailable timing explicitly.
6. Run focused and complete helper suites, source/workflow checks and independent
   review. Commit locally. Leave native qualification and operator settings open.

| Boundary | Authorized local scope |
| --- | --- |
| Paid jobs / minutes / attempts | 0 / 0 / 0 |
| Spend allowance | USD 0.00 |
| Native compilations / native test processes | 0 / 0 |
| Checks | Python/browser helpers, source inventory/examples, actionlint, synthetic admission/report fixtures |
| Local helper limit | 300 seconds per supervised group with existing cleanup |
| Remote mutations | None: no push, dispatch, rerun, billing change, publication or deployment |

## Implemented boundaries

The execution expansion reads each workflow's literal outer timeout and uses
`platform_plan` for exact build and test groups. Whole-job limits conservatively
include cold/cache provisioning, all command/transport attempts, evidence and
cleanup reserves. Concurrent runners add to the maximum. A changed workflow job,
runner group or static helper/fixture matrix requires reconciliation before any
native scheduling. The manual documentation request has its own five-minute
bootstrap reservation; its downstream full CI run has a separate complete plan.
There is no shared allowance across different workflow runs or billing cycles.

The admission policy is checked in with zero allowances and unverified account
runner mappings. Unknown additional charges also prevent authorization. The
bootstrap produces a refusal plan and summary; source/helper/native fanout cannot
expand. This deliberately also contains automatic helper fanout until its own
bootstrap/runner pricing and allowance are reviewed. No repository variable or
manual full/diagnostic selection overrides these checks. The native rollout switch
remains closed for Phase 11 even after admission implementation.

Non-runner prices use an explicit operator-verified per-job/attempt envelope, with
dated evidence covering complete retention liability and retries. The helper checks
its arithmetic and freshness; it does not enforce an uploaded-byte quota. A real
positive rollout therefore still requires retained proof that configured storage/
transfer units bound actual artifact/cache traffic, or an applicable verified billing
exemption. The current unknown fields refuse that unqualified assumption.

Every runner job checks its current job/group/attempt after checkout and before
costly setup. Native evidence steps that run on failure additionally require a
successful entry guard. No automatic test/build/workflow retry is introduced.
Fixed disjoint attempt reservations never reset when GitHub retains a successful
earlier scope or producer. A partial consumer rerun rechecks current source,
selection, policy, runner and attempt without borrowing another platform's balance.

Checkout/startup precedes the guard and incurs possible provider usage even on
refusal. It is included in admitted job maxima and reported separately on denied
entry. An offline guard cannot stop an operator from repeatedly starting rejected
jobs or promise a provider-enforced dollar cutoff. The proposed repository budget
is a separate backstop, documented in [OPERATOR-BUDGET.md](OPERATOR-BUDGET.md).

Automatic CI uses PR validation and pushes to `main`, the current remote default
branch, plus explicit manual runs. Branch pushes no longer duplicate PR runs.
Manual full requests still require full exact-source qualification; a merged commit
cannot borrow a PR's certification. Documentation requests do not create another
automatic compilation graph. The exact `Offline certification passed` check and
independent human maintenance gate remain intact.

Usage reports expose maximum and observed per-SKU minutes, attempts, known queue/
setup/transfer durations, command outcomes, missing coverage and admission reasons.
Local native summaries accompany ordinary diagnostic artifacts. Jobs without an
ordinary diagnostic upload retain a small separate spend artifact, with ten extra
minutes explicitly included in their outer reserve. Snapshots precede their own
upload and cannot contain that upload's final receipt. The final aggregation reads
all available GitHub attempts; its own running job and later optional publication
remain visibly unfinished. Usage reports never satisfy certification or represent
an invoice. Provider billing and complete terminal usage require later read-back.

## Acceptance and handoff

[Validation](validation.json) binds tested input hashes, commands and retained
check receipts. [Independent review](review.json) records findings and resolutions.
The retained synthetic admission/report fixtures exercise fail-closed rates,
allowances, runner/trigger drift, cumulative attempts, reservation integrity and
incomplete usage. They do not establish actual account rates or hosted execution.

Phase 3 native x64 acceptance and Phase 11 hosted qualification, real partial-rerun
proof and final exact-revision certification remain open. No hosted cost savings
or runtime compatibility is inferred. Operator budget configuration remains pending.
