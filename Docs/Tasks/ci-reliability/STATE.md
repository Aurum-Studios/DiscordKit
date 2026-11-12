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
Phase 4 is complete at implementation commit
`4590c5d76c1024d8eec5132a1be343220577cccf` on `ci/phase-4-compatibility`,
with local Python helper acceptance.
Phase 5 has local helper acceptance at implementation commit
`d466d50bc153f2799a33e200d574569958905295` on `ci/phase-5-transfer`; its hosted proof remains Phase 11.
Phase 6 has local helper acceptance at implementation commit
`666f1371224fbe5bda03ec7b54be14a083bb6b09` on `ci/phase-6-preflight-canaries`;
its source remains contained and hosted acceptance stays Phase 11.
Phase 7 has local helper acceptance at implementation commit
`4db6c5e6181d790fd1cd304220059397a501467b` on `ci/phase-7-suite-groups`;
hosted performance and complete native acceptance remain Phase 11.
Phase 8 has local helper/signature acceptance at implementation commit
`db705cb6dade43da579d555461f3f36a13586b48` on `ci/phase-8-provisioning`;
hosted cold/hit compatibility and savings remain Phase 11.
Phase 9 has local shared-documentation helper and real synthetic DocC acceptance at
`b6fe729d61f7355cd8bcfc9ab4dcd93d020f2467` on `ci/phase-9-documentation`; hosted proof remains Phase 11.
Phase 10 has local spend-admission and usage-reporting acceptance on
`ci/phase-10-spend-admission`; its scoped implementation commit receipt is pending.
No hosted qualification, paid execution, external configuration change or publication
is claimed. See [BOOTSTRAP.md](BOOTSTRAP.md) for the zero-paid execution sheet.

| Phase | Status | Implementation commit | Acceptance evidence |
| --- | --- | --- | --- |
| 0 — Baseline and initial limits | Complete; local preparation only | `5808ce32d867622ff6952d0f2057768a8a257f14` | [212 helper tests](baseline/validation.json), [retained capture](baseline/CAPTURE.md), [usage baseline](baseline/COST.md), [zero-paid sheet](BOOTSTRAP.md); hash/link/diff checks passed |
| 1 — Process supervision | Complete; local helper acceptance only | `1bc5de45a6dbeef1ab31bd7f6fbbe85b69771600` | [231 helper tests](phase-1/validation.json), [nine retained fault specimens](phase-1/faults/results.json), [independent review](phase-1/review/results.json), [implementation and limits](phase-1/IMPLEMENTATION.md) |
| 2 — Event-hub accounting | Complete; local macOS Swift acceptance | `4dbb085521f1977dc40ea5b8818edb9d61cd2f9f` | [Red/green, 23 load + 21 runtime tests, four CLI checks](phase-2/validation.json), [independent review](phase-2/review.json), [implementation and limits](phase-2/IMPLEMENTATION.md) |
| 3 — Linux hang repair | Implemented and locally tested; native x64 acceptance pending | `69a21b325c4eaa6181eb31dcc7e78ab083ac6411` | [Stack-supported peer repair, red/green and whole-package checks](phase-3/IMPLEMENTATION.md); [native gate](phase-3/NATIVE-ACCEPTANCE.md) remains open |
| 4 — Compatibility receipts | Complete; local helper acceptance | `4590c5d76c1024d8eec5132a1be343220577cccf` | [270 helpers, six existing Linux-only skips](phase-4/validation.json), [review](phase-4/review.json), [v2 contracts and execution sheet](phase-4/IMPLEMENTATION.md) |
| 5 — Transfer and partial reruns | Implemented; local helper acceptance; hosted proof pending Phase 11 | `d466d50bc153f2799a33e200d574569958905295` | [Contracts and execution sheet](phase-5/IMPLEMENTATION.md); [314 passed, six existing skips](phase-5/validation.json), [review](phase-5/review.json) |
| 6 — Preflight and canaries | Implemented; local helper acceptance; native expansion contained | `666f1371224fbe5bda03ec7b54be14a083bb6b09` | [Contracts and execution sheet](phase-6/IMPLEMENTATION.md); [validation](phase-6/validation.json), [independent review](phase-6/review.json); hosted proof remains Phase 11 |
| 7 — Suite groups and resources | Implemented; local helper acceptance; hosted measurements pending Phase 11 | `4db6c5e6181d790fd1cd304220059397a501467b` | [Grouped suites, leaf coverage and resources](phase-7/IMPLEMENTATION.md); [validation](phase-7/validation.json), [review](phase-7/review.json) |
| 8 — Verified provisioning | Implemented; local helper/signature acceptance; hosted measurements pending Phase 11 | `db705cb6dade43da579d555461f3f36a13586b48` | [Verified distribution reuse and profiles](phase-8/IMPLEMENTATION.md); [validation](phase-8/validation.json), [review](phase-8/review.json), [upstream pins](phase-8/upstream/SOURCES.json) |
| 9 — Shared documentation inputs | Implemented; local helper and real synthetic DocC acceptance; hosted proof pending Phase 11 | `b6fe729d61f7355cd8bcfc9ab4dcd93d020f2467` | [Shared conversions and trust contracts](phase-9/IMPLEMENTATION.md); [validation](phase-9/validation.json), [review](phase-9/review.json), [real DocC counts/routes](phase-9/checks/real-docc/results.json) |
| 10 — Spend admission | Implemented; local acceptance; scoped commit receipt pending | Pending scoped commit | [Contracts and execution sheet](phase-10/IMPLEMENTATION.md); [validation](phase-10/validation.json), [review](phase-10/review.json), [operator proposal](phase-10/OPERATOR-BUDGET.md) |
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
The original planning edits and earlier worktrees remain preserved. Implementation commit `4590c5d76c1024d8eec5132a1be343220577cccf`
contains all six tested input hashes and 17 retained manifest artifacts. The
[commit receipt](phase-4/commit-receipt.json) verifies them against actual Git blobs.
This completion follow-up changes documentation only; tested executable/test/build
inputs remain unchanged. Phase 4 is complete as local helper implementation;
Phase 3 native x64 acceptance and all hosted qualification remain open.

## Phase 5 handoff

Owner Codex `/root` prepared immutable transfer/rerun recovery on
`ci/phase-5-transfer`, sibling `DiscordKit-ci-phase5`, based on
`b190a963f27fc3910b7226e7d15f386ac97b5498`.
[Contracts and execution bounds](phase-5/IMPLEMENTATION.md) retain same-run/exact-source
successful producer provenance, immutable API IDs/digests, fresh current-attempt
consumer selection and strict native compatibility. Transfer retries never invoke
compilation/tests, and final evidence failure fails its owning job. The full index
is checked in a separate stage and again in the latest platform barrier.

[Validation](phase-5/validation.json) binds 23 source/test/workflow/dependency inputs:
314 helper tests passed, six existing Linux-only tests skipped on macOS, plus
actual pinned SDK localhost success/fault fixtures, actionlint, syntax, policy and
link/diff checks. [Review](phase-5/review.json) has no remaining blockers. The
original planning edits and prior phase checkouts are preserved. The scoped
implementation commit `d466d50bc153f2799a33e200d574569958905295` contains all 23 verified source/test/
workflow/dependency inputs and 23 retained manifest artifacts. The
[commit receipt](phase-5/commit-receipt.json) verifies the actual Git blobs.
This follow-up changes documentation only; tested inputs remain unchanged. No
remote write, hosted run, paid job or native Swift execution occurred.

Phase 5 has local implementation acceptance. Its real hosted round trip, partial
failed-job rerun and complete latest-attempt barrier acceptance remain Phase 11.
Phase 3 native x64 acceptance stays open. The next authorized implementation can
prepare Phase 6 with these bounded transfer interfaces; paid expansion remains
unauthorized pending admission and an explicit allowance.

## Phase 6 handoff

Owner Codex `/root` implemented scoped preflight and platform canaries on
`ci/phase-6-preflight-canaries`, sibling `DiscordKit-ci-phase6`, based on
`b759a25e89cade3494fd91fb14a00030d4286489`. The [execution plan and contracts](phase-6/IMPLEMENTATION.md)
retain the zero-paid allowance and isolated ownership. The original planning
bytes match their earlier handoff hashes; earlier worktrees remain preserved.

[Validation](phase-6/validation.json) binds 16 tested source/test/configuration/workflow
inputs and all retained supervised check logs/receipts. Python, browser, actionlint,
source inventory, displayed examples and maintenance freshness checks passed locally.
[Review](phase-6/review.json) records the repaired coverage/partial-rerun findings
and no remaining blockers. The current rollout permits automatic preflight only;
full/diagnostic native execution and independent documentation deployment remain
contained pending reviewed Phase 10 admission. No native Swift execution, paid
job, push, dispatch, publication, billing/runner change or live Discord operation occurred.

Both platforms retain independent probe → load producer → immutable upload →
fresh consumer → discovery → complete load tests/smokes before expansion. Canary
work is counted once; exact full manifests and fresh root API/producer evidence
protect certification and release. Source export requires full platform coverage.
Implementation commit `666f1371224fbe5bda03ec7b54be14a083bb6b09` contains all 16
verified tested inputs and 41 retained check artifacts; the [commit receipt](phase-6/commit-receipt.json)
verifies actual Git blobs. This completion follow-up changes documentation only.
The next implementation phase is Phase 7. Phase 3 native x64 acceptance and
Phase 11 real runner/rerun/check-context/branch-protection qualification remain open.

## Phase 7 handoff

Owner Codex `/root` implemented deterministic root grouping, batched consumers,
structured leaf receipts, immutable full-inventory reconciliation, explicit core/
remaining producer waves and CPU/affinity/memory compiler admission on
`ci/phase-7-suite-groups`, sibling `DiscordKit-ci-phase7`, base `e47b506c`.
[Execution contracts](phase-7/IMPLEMENTATION.md), [validation](phase-7/validation.json),
[comparison](phase-7/scheduling-comparison.json) and [review](phase-7/review.json)
retain actual local acceptance and qualification limits. A nested transport timer
leak found during fault validation is repaired with deterministic cleanup regressions.
Original planning changes and all earlier worktrees remain preserved.

The prepared topology has 24 producers and 28 test groups versus baseline 24/101.
Post-change runtime, transfer bytes, runner minutes and savings remain unmeasured.
No native Swift execution, hosted/paid job, remote write, billing/pool mutation,
publication or live runtime occurred. Current native rollout stays contained.
Phase 3 native x64 acceptance and Phase 11 hosted/cost/rerun acceptance stay open.
Implementation commit `4db6c5e6181d790fd1cd304220059397a501467b` contains all 24 verified tested
inputs and 50 retained manifest artifacts. The [commit receipt](phase-7/commit-receipt.json)
verifies actual Git blobs. This completion follow-up changes documentation only;
all tested source/configuration/workflow/test bytes remain identical.
Phase 8 is the next authorized implementation stage when requested.

## Phase 8 handoff

Owner Codex `/root` implemented verified signed-distribution reuse and explicit
build/runtime prerequisite profiles on `ci/phase-8-provisioning`, sibling
`DiscordKit-ci-phase8`, base `06b2efb14332de764492292eae6380c26224112a`.
[Execution contracts](phase-8/IMPLEMENTATION.md), [validation](phase-8/validation.json)
and [review](phase-8/review.json) retain exact tested source, bounded helper results
and two independent reviews. Official pinned payloads were authenticated locally;
real production verification checked the complete macOS package without installing
it. Cold/hit/fault fixtures preserve Phase 4 exact compatibility, while cache
provenance is informational and checks the active compiler path.

All 891 Python/browser checks passed, with six existing Linux-only tests skipped
on macOS. Every native setup caller has an explicit prerequisite profile and
10-minute total step bound, including exact cache transport and trusted save.
Every hit rechecks upstream signatures and pinned bytes before installation.
Cross-platform provisioning artifact names are unique. Original planning changes
and earlier phase checkouts remain preserved; current native rollout is contained.
No compiler installation/native compilation/tests, hosted/paid job, remote cache
write, push, dispatch, publication, billing/pool change or live Discord occurred.
Hosted cold/hit performance and platform compatibility remain Phase 11, as does
Phase 3 native x64 acceptance. Phase 9 is the next implementation stage when
requested. Implementation commit `db705cb6dade43da579d555461f3f36a13586b48` contains all 20
verified tested inputs and 94 retained manifest artifacts. The [commit receipt](phase-8/commit-receipt.json)
verifies actual Git blobs. This completion follow-up changes documentation only;
all tested executable/configuration/workflow/test bytes remain identical.

## Outstanding execution decisions

- Paid execution remains unauthorized: experiment/workflow allowances are USD 0,
  and paid jobs/minutes/attempts are zero. Published dated list rates are retained;
  account billing/pool mapping and the reported USD 40 remain unreconciled.
- Native Ubuntu 24.04 x64 host/access versus separately authorized bounded hosted probe;
  the retained local x64 container is emulated and cannot close Phase 3.
- Operator-selected repository budget amount/scope and authorization to configure it.
- Phase 0 uses `ci/phase-0-baseline` in sibling `DiscordKit-ci-phase0`, owner
  Codex `/root`, base `85eac6f3c1d3b17e53596c49e7438efee366c1b3`.
  Phase 1 through Phase 4 ownership and local-only sheets are recorded above. Phase 5
  owner is Codex `/root` on `ci/phase-5-transfer`, sibling `DiscordKit-ci-phase5`,
  based on `b190a963`; its [local execution sheet](phase-5/IMPLEMENTATION.md) keeps
  all paid allowances at zero. Phase 6 owner is Codex `/root` on
  `ci/phase-6-preflight-canaries`, sibling `DiscordKit-ci-phase6`, base `b759a25e`;
  its local execution sheet likewise keeps paid allowances at zero. Phase 7 owner
  is Codex `/root` on `ci/phase-7-suite-groups`, sibling `DiscordKit-ci-phase7`,
  base `e47b506c`; its local sheet retains zero paid execution. Phase 8 and 9
  ownership/local execution sheets are recorded in their implementation documents.
  Phases 10 and 11 paid experiment sheets remain unassigned/unauthorized.

These do not prevent beginning local preparation/helper implementation. Missing
allowances or execution authorization prevent paid scheduling, not source work.

## Handoff fields

For each active phase retain: owner, branch/worktree, base and tested commit/content
hash, owned paths, commands/exits, diagnostic/artifact identities, allowance and
remaining attempts, acceptance criteria still open, and the exact next action.

## Phase 9 handoff

Owner Codex `/root` prepared shared documentation inputs on
`ci/phase-9-documentation`, sibling `DiscordKit-ci-phase9`, based on `e37ad2bc`.
[The local plan/contracts](phase-9/IMPLEMENTATION.md) retain zero paid execution.
MacOS root/macros/extensions build and graph producers are shared with full CI;
strict conversion runs once per component, then the site consumes sealed archives.
Read-only site preparation is required by full certification. Manual Documentation
requests obtain the same producers; overlapping automatic builds are removed.
Publication is a separate optional job with independent trusted-current-source,
fresh full-gate/site and immutable-artifact admission. Earlier site attempts cannot
publish on a deploy-only rerun; fresh site preparation and full barrier are required.

[Validation](phase-9/validation.json) records 938 passing tests plus six existing
Linux-only skips, actionlint/source checks and a supervised real DocC fixture.
Its three tiny strict conversions feed one consumer merge/static transformation;
all four landing/module routes and five base-path assets exist. No native Swift
compilation or full production-catalog conversion is claimed. [Review](phase-9/review.json)
closed the DocC lookup and newer-failed-producer fallback findings.
The original four planning edits and prior worktrees remain preserved.

Actual hosted producer/consumer and partial-rerun proof, pinned Swift 6.4.1
production documentation conversion, site qualification and measured savings
remain Phase 11. Phase 10 spending admission remains unimplemented and native
expansion stays contained. No push, paid execution, dispatch or publication occurred.

Implementation commit `b6fe729d61f7355cd8bcfc9ab4dcd93d020f2467` contains all 13 verified tested
input blobs and 65 retained manifest artifacts. The [actual-blob commit receipt](phase-9/commit-receipt.json)
verifies these objects and current bytes. This completion followup changes documentation
only; executable/test/workflow inputs remain unchanged.


## Phase 10 handoff

Owner Codex `/root` prepared spend admission on `ci/phase-10-spend-admission`,
sibling `DiscordKit-ci-phase10`, based on `f94520e3`. The
[local plan/contracts](phase-10/IMPLEMENTATION.md) preserve zero paid allowances,
all earlier phase checkouts and the original checkout's four planning edits.
The exact execution partitions and workflow deadlines now produce central disjoint
job/attempt reservations. Every current consumer checks its own source/scope/group/
attempt before provisioning; retained earlier outputs cannot grant fresh work.
Unknown/unverified/stale rates, unknown additional charges, over-budget plans,
duplicate-trigger and matrix/runner drift fail closed. Default-branch push, PR and
manual entry points avoid branch-push/PR duplication. Native rollout remains closed.

[Validation](phase-10/validation.json) records 984 passing helper tests and six
existing Linux-only skips on macOS, all seven workflows passing actionlint,
source/example checks, actual local CLI refusal and retained synthetic rerun/usage
specimens. [Review](phase-10/review.json) has no remaining blockers. JSON/step
summaries retain rounded SKU minutes, command/transfer outcomes and missing coverage.
They remain estimates and unfinished snapshots rather than invoices or certification.

Operator selection/authorization/read-back of the proposed repository budget is
pending. No hosted dispatch, paid job, billing change, native compilation or
publication occurred. Phase 3 native x64 acceptance and Phase 11 real partial-rerun,
final hosted qualification and measured savings remain open. The implementation
commit and actual-blob receipt will be recorded after the scoped commit exists.
