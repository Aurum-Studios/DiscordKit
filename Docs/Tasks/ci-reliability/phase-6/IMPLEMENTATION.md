<!--
File: Docs/Tasks/ci-reliability/phase-6/IMPLEMENTATION.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 6: shared preflight, scoped execution and platform canaries

Owner Codex `/root`, branch `ci/phase-6-preflight-canaries`, sibling checkout
`DiscordKit-ci-phase6`, base Phase 5 handoff `b759a25e89cade3494fd91fb14a00030d4286489`.
Preserve the original checkout's four planning edits and all existing worktrees.

## Execution plan

1. Validate full/preflight/diagnostic selections before scheduling; partition
   concurrency and check names by scope. Keep checked-in rollout contained until
   Phase 10 implements spend admission. Manual native requests cannot override it.
2. Move source policy, bounded Python/browser helpers, workflow lint and independent
   maintenance freshness ahead of native expansion. Keep Swift manifest evaluation
   explicitly native. Contain automatic documentation compilation/deployment too.
3. Per platform, retain probe, separately uploaded load producer, separate consumer
   restore/discovery/complete load tests and existing smokes. Gate each platform's
   broad work on its own canary; count load work once in the expected manifest.
4. Reconcile explicit expected jobs and required steps against authenticated
   same-run API evidence in a fresh barrier, then require both full platform
   manifests and all shared gates for full certification. Preserve immutable
   producer selection/compatibility validation and successful earlier-attempt jobs
   for partial failed-job reruns. Phase 7 owns executed-leaf reconciliation.
5. Test scope rejection, coverage faults, platform isolation, release discovery,
   transfer identity, workflow syntax, and the existing helper suites. Obtain an
   independent review, retain hashes/results and commit this phase locally.

## Execution sheet and limits

Local Python/Node helpers and workflow lint only; no Swift builds or native suites.
Each helper group uses the existing process supervisor with a finite aggregate
budget and bounded cleanup. Paid jobs/minutes/attempts: **0 / 0 / 0**, USD **0.00**.
No push, remote dispatch, artifact upload, billing/runner mutation, publication,
deployment, Start or live Discord access. No build/test/assertion retries.

Phase 3's emulated Linux evidence remains separate from native x64 acceptance.
Real separate-runner canaries, GitHub check-context/branch-protection behavior and
partial-rerun hosted proof remain Phase 11 gates. Phase 6 local mocks and workflow
lint establish implementation behavior only. Automatic native and documentation
expansion remains disabled; Phase 10 must implement and test admission before
rollout. The existing two-day compiled retention and 14-day evidence retention
remain unchanged; Phase 5 transport job bounds apply to canary transfers too.

## Implemented contracts

`workflow_scope.py` delegates selections to the shared source-anchored policy and
partitions load canary work out of the remaining build/test matrices. Diagnostic
scope always includes its explicitly reported load canary prerequisite; no focused
replay enters canonical full coverage. Its full manifests include exact work-step
names for probes, plans, producers, suites, smokes, audits, fixtures, API/DocC,
Apple modules and source packaging/upload. PRs explicitly validate the full-scope
export guard without producing bundles. No expected matrix may be empty except
an intentionally absent diagnostic remainder, which has distinct skipped names.

`preflight.py` balances the original seven helper suites into four bounded groups:
CI Python, tooling/load Python, benchmark/timing Python, and browser. Source policy
and displayed examples are compiler-free; actionlint 1.7.12 is checksum-pinned in
CI. The independent maintenance ledger is read only and remains required. The
native planner separately evaluates SwiftPM and rejects drift from source inventory.

Each platform's `build` job produces only load; `canary` consumes its immutable
artifact in a separate job using Phase 4 compatibility and Phase 5 source/trust/
ID/digest validation. Whole-load discovery, complete suite and existing smokes run
under the existing supervisor. Only its own valid canary unlocks `build-remaining`,
other tests, audits, compiler fixtures, API/DocC or Apple module work. Existing
remaining matrices have explicit max-parallel 2; full suite grouping remains Phase 7.
The index admits `build-remaining` only for non-load producers and retains the exact
producer job identity. No transfer retry can execute a build or test.

`workflow_coverage.py` reads authenticated attempt-specific GitHub job inventories
under one bounded 420-second operation, verifies run/repository/workflow/event/source
provenance, and requires every expected job/step exactly once and terminal-successful.
Missing, duplicate, failed, cancelled, skipped or newer unfinished work fails closed.
Unexpected canonical suite/build/helper rows fail; explicitly named diagnostic
replays remain outside certification. Every selected job ID/attempt is retained.

A pre-export barrier checks full native coverage and immutable producers before
packaging. Each platform's final barrier includes its applicable source export.
The root full barrier validates both platform summary seals, including an unaffected
platform's earlier successful attempt after a partial failed-job rerun, then freshly
re-resolves both producer indices and validates one complete combined current-attempt
job manifest. API-observed head SHA must agree across both platform summaries and the
fresh combined barrier, including the documented PR head/merge distinction.
Full certification therefore cannot rely only on an all-success matrix aggregate.
The root receipts and both producer indices receive bounded durable evidence upload.

Only validated full scope creates the exact required check context. Preflight and
diagnostic runs have separate final names even on failures/skips; concurrency keys
include mode, platform, component and suite. Release discovery additionally requires
the completed successful `Verify full scope and complete coverage` step. Newer scoped
runs cannot replace an older fully certified run on the same source. The original
push/manual release trust restrictions remain.

## Prepared execution envelopes

Existing Phase 5 job limits, 120-second transport attempts, three attempts within a
420-second operation, and two-day/14-day retention remain. Canary producer uses the
existing 150-minute build envelope; its fresh consumer uses the 75-minute suite
job envelope, including resolver/download/evidence operations. Pre-export coverage
has 25 minutes for the 420-second job snapshot plus 420-second producer index.
The platform final barrier has 35 minutes for both checks, SDK provisioning and
420-second durable upload. The root final barrier has 40 minutes for two producer
indices, one combined job snapshot, bounded SDK provisioning, evidence upload and
checkout/source/cleanup reserve. These are containment-prepared upper bounds,
not measured capacity or spending authorization. Phase 10 must price these jobs,
setup/reserves, sidecars/retry bytes and retention before enabling native work.

## Review and validation

The independent review identified missing required-step checks and source-head
comparison, and an unaffected-platform partial-rerun bug. Deterministic regressions
cover their repairs. A final review found no remaining blocking findings; see
[review.json](review.json). [validation.json](validation.json) binds the final tested
source/configuration/workflow hashes and retained supervised helper logs/receipts.
[Source preflight](source-preflight.json) proves that the original planning bytes
still match the earlier handoff and records the isolated checkout boundary.

No local result establishes a real fresh-runner round trip, GitHub check replacement
semantics, branch protection, native x64 acceptance, or full hosted certification.
These remain explicit Phase 11 acceptance items before rollout. No Phase 7 or later
implementation was included.

Primary semantics checked against [GitHub workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax),
[expression contexts](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts),
and [attempt-specific job evidence](https://docs.github.com/en/rest/actions/workflow-jobs#list-jobs-for-a-workflow-run-attempt).

Final local checks: **749 Python tests and 38 browser tests passed**; six existing
Linux-only CI tests skipped on macOS (793 discovered total). The CI group itself
discovered 380 tests, with 374 passing and six skips. All 10 supervised helper/source/
workflow commands exited zero with no remaining reader threads or descendants.
Maintenance freshness passed as of November 12, 2026, with nextReviewDue November 12;
the human-authored record was not changed. Actionlint, Python syntax, source
inventory/snapshots and Markdown link/diff checks passed.
