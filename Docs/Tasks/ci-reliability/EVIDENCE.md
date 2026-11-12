<!--
File: Docs/Tasks/ci-reliability/EVIDENCE.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Incident baseline and evidence requirements

This retains the read-only investigation preceding [PLAN.md](PLAN.md) and the
Phase 0 and Phase 1 implementation receipts below. The incident observations do not qualify
any runtime repair. Original logs/metadata are retained under `baseline/` because
GitHub artifact links can expire.

## Observed certification

- Repository: Aurum-Studios/DiscordKit.
- Run: [43146954720](https://github.com/Aurum-Studios/DiscordKit/actions/runs/43146954720),
  run number 41, attempt 1, push to main.
- Source: `85eac6f3c1d3b17e53596c49e7438efee366c1b3`.
- Created November 12, 2026 at 03:15:22 UTC; completed cancelled at 03:59:39 UTC.
- Inventory: 152 jobs, including skipped and final aggregate jobs; all 24 native
  component build jobs succeeded. This job count excludes the separate
  documentation workflow.
- [Documentation run 43146954594](https://github.com/Aurum-Studios/DiscordKit/actions/runs/43146954594)
  succeeded at the same source. Its builds overlap CI's macOS root/authoring builds.
- The user reported another $40 spent. Exact billing attribution has not been
  independently reconciled and remains Phase 0 work.

| Job | Observed result | Interpretation and limit |
| --- | --- | --- |
| [macOS load 130951994094](https://github.com/Aurum-Studios/DiscordKit/actions/runs/43146954720/job/130951994094) | One issue in 146 tests/27 suites: wallCapHasJoinedPartialPopulation, discardedAdmittedCopies == 0 | Assertion established; exact interleaving requires controlled regression |
| [macOS DSLEvents 130951994277](https://github.com/Aurum-Studios/DiscordKit/actions/runs/43146954720/job/130951994277) | Three tests and smoke passed; CreateArtifact failed ENOTFOUND | Artifact DNS/transport failure; required evidence incomplete |
| [Linux load 130952646908](https://github.com/Aurum-Studios/DiscordKit/actions/runs/43146954720/job/130952646908) | Test command started 03:33:26 UTC; last output near .dslCancelled at 03:34:07.889; cancelled 03:59:20.958 | Exact blocked operation/owner unresolved; timing smokes were not reached |
| [macOS Public API/DocC 130951992794](https://github.com/Aurum-Studios/DiscordKit/actions/runs/43146954720/job/130951992794) | Passed | The API baseline was not this run's failing gate |

DSLEvents downloaded a 2,536,784,274-byte consumer archive. The investigation
observed approximately 22 seconds downloading, 54 seconds restoring and 63 seconds
setting up the toolchain, compared with 0.013 seconds for its three tests and
approximately 0.6 seconds for its smoke. Preserve underlying logs before treating
these approximate durations as comparison inputs. They do not establish a savings
percentage or explain the entire bill.

## Current-source observations and unresolved hypotheses

- The event-hub authority ends queued residence and releases queue accounting on
  dequeue. The iterator checks cancellation after its actor await. Benchmark
  accounting currently derives discard from admitted/setup minus consumed and
  cancelled residence. This exposes a plausible unclassified handoff window;
  Phase 0's complete retained log corrects the initial partial-log observation:
  `report.measurement.discardedAdmittedCopies` was **1**, at
  `2026-11-12T03:32:59.452404Z`. This establishes the count, not its interleaving.
- Waiting benchmark pulls can complete before aggregation; teardown joins pending
  tasks but ignores their final values. Investigate this separate boundary too.
- The synthetic command suite has a one-minute Swift Testing trait, yet the
  observed process remained unfinished for about 25 minutes. Its cancellation
  fixture throws CancellationError directly; it does not acquire the rate
  coordinator or execute network I/O. Last output is not a stack trace.
- native_jobs.py assigns 3,600 seconds to ordinary Swift builds/tests/discovery.
  linux_ci.py already owns POSIX process-group termination and output-pipe bounds.
- Current artifacts bind the whole producer identity, including run attempt.
  Documentation therefore requires Re-run all jobs. OS/SDK/runtime compatibility
  needs stronger explicit identification before relaxing attempt matching.
- Current native planning has 12 builds and 50 suite jobs on Linux, 12 builds and
  51 suite jobs on macOS. Most consumers repeat full provisioning. Suites wait for
  the whole build matrix; Apple module compilation starts before that barrier.

## Evidence to append during implementation

For every phase, add an entry with actual source revision/content hash, owner,
commands and exit status, input/output hashes, receipts and acceptance results.
Keep local, container and hosted native observations clearly identified.

Required final evidence inventory:

- Baseline job/runner-minute inventory, original failure logs and actual rate source.
- Scheduling policy version, bootstrap allowance, approved experiments and attempts.
- Supervisor fault-injection results, stack capture and descendant cleanup receipts.
- Event-hub and Linux failing-before/passing-after deterministic regressions.
- Linux blocked-owner diagnosis and successful bounded whole-package confirmations.
- Versioned compatibility/producer/consumer receipts and rejected mismatch cases.
- Immutable upload retry, artifact-index, corrupt/expired and partial-rerun proofs.
- Exact planned/discovered/executed suite coverage and failed/not-run classifications.
- Both platforms' real producer/fresh-consumer artifact round trips and native runs.
- Provisioning cold/cache identity and measured overhead comparison.
- Documentation invocation counts, site/link validation and publication rejection tests.
- Spend admission/rerun/rounding/unknown-rate tests and actual per-SKU execution data.
- Latest exact-final-source full certification with every required gate terminal.
- Operator budget configuration/read-back if separately authorized; otherwise pending.

No implementation, native verification, push, dispatch, billing change or
publication was performed while authoring the original plan. Phase 0 preparation
and Phase 1 local helper acceptance are recorded below. At that checkpoint,
Phases 2 through 11 remained incomplete; later entries record subsequent work.

## Phase 0 preparation — November 12, 2026 UTC

- Integration owner: Codex `/root`. Selected branch `ci/phase-0-baseline`, sibling
  `DiscordKit-ci-phase0` checkout, base
  `85eac6f3c1d3b17e53596c49e7438efee366c1b3` (matching the remote read).
  [Source preflight](baseline/source-preflight.json) records identity, original
  dirty files, preserved worktrees and zero observed validation processes. The
  original four planning files were copied with their hashes retained; no original
  checkout changes were discarded.
- [Execution sheet](BOOTSTRAP.md): paid jobs/minutes/attempts and experiment/workflow
  allowances are all zero. No push, PR, dispatch, rerun, runner/billing change,
  publication, deployment or live Discord operation occurred.
- [Local environment](baseline/local-environment.json): macOS 27.0.1 ARM64,
  system Swift 6.4, Python 3.14; existing Colima Ubuntu 24.04.4 is aarch64.
  This establishes neither pinned Swift 6.4.1 nor native Ubuntu x64. No VM or
  container was started or changed. Committed dependency-pin and workflow-input
  SHA-256 values are retained.
- The shared versioned policy supplies offline planning and accounting inputs.
  Existing native planner/workflows and product/test sources remain unchanged.
  Full leaf discovery, process supervision, runtime admission and native
  qualification remain later-phase work.

- [Capture notes](baseline/CAPTURE.md) and [coverage](baseline/capture-coverage.json):
  both pages of all 152 CI jobs and all seven documentation jobs, plus metadata
  for 157 CI artifacts and ten documentation artifacts. All 167 records retain
  IDs, digests, sizes and expiries. No archive was expired at capture; no binary
  artifact archive was downloaded. Metadata describes 10,743,621,569 CI bytes and
  775,922,078 documentation bytes, not network traffic or invoiced storage.
- [Log index](baseline/log-index.json): 16 compressed logs, 11 complete and five
  explicitly partial successful-job tails. All six available failed/cancelled-job
  logs are complete; the seventh cancelled export has no runner/steps and returns
  HTTP 404. Its end timestamp precedes its start by one second, so it cannot
  supply a fabricated zero or negative paid duration.
- Failures are classified separately: macOS assertion, macOS DSLEvents upload DNS,
  Linux test cancellation with unresolved blocked owner, three dependent aggregate
  failures, and the unassigned/cancelled export. No provisioning failure or proven
  supervisor timeout is present in this run. The documentation run's seven jobs
  all succeeded.
- [Hosted facts](baseline/native-facts.json) distinguish preinstalled Swift from
  the successfully installed pinned Swift 6.4.1. [Source facts](baseline/source-facts.json)
  retain setup policy and dependency pins. The [capture manifest](baseline/SHA256SUMS)
  verifies 29 capture-owned files, including compressed/raw log hashes via the
  index; root-owned preflight/environment and later usage/validation files are
  explicitly outside that manifest.

- [Usage baseline](baseline/COST.md) and [reproducible JSON](baseline/cost-summary.json)
  sum 451 known rounded runner minutes and USD 35.962 at the dated official
  [GitHub list rates](https://docs.github.com/en/billing/reference/actions-runner-pricing):
  USD 33.980 for CI and USD 1.982 for documentation. This incomplete subtotal
  excludes the unknown cancelled export and all unreconciled storage/transfer,
  account mapping, credits and discounts. Per-SKU job/step/queue-upper-bound data,
  mixed-stage limitations and the observed download-byte subset remain explicit.
- [Validation receipt](baseline/validation.json) binds the five new policy/usage
  code/config/test inputs by SHA-256 and records the full CI helper invocation:
  `python3 -m unittest discover -s Tools/ci -p 'test_*.py'`, exit 0, **212 tests
  passed**, including 25 new focused tests. Execution used the existing process
  supervisor with a 300-second deadline; the compressed local test log is retained.
  These are local helper fixtures, including simulated build/publication calls;
  no native product compilation, hosted execution or publication occurred.
- Policy CLI validation and full native scope pass: 34 declared root targets,
  12 components, 24 builds and 101 suite jobs across Linux/macOS only. This is
  source-anchored planning, not evaluated SwiftPM or discovered test-leaf coverage.
  Unknown/mismatched scopes, stale/unknown prices, unverified strict billing
  mappings and nonzero Phase 0 allowances fail closed. No existing workflow,
  native planner, product, manifest or dependency pin was changed.
- Independent review found no material unresolved issue. The initially detected
  risk of the existing planner's default also including Windows was corrected;
  the full-scope regression explicitly requires Linux/macOS only. Missing-page,
  duplicate, source mismatch, timestamp, rounding and unknown-price cases pass.
- Capture/raw-log hashes verify; regenerated cost JSON is byte-identical; local
  Markdown links and `git diff --check` pass. All four original checkout planning
  files retain their preflight hashes. Implementation commit
  `5808ce32d867622ff6952d0f2057768a8a257f14` contains the tested executable inputs,
  retained evidence and initial execution sheet. This documentation-only ledger
  follow-up records that actual commit; the tested input hashes remain unchanged.
  Phase 0's exit criteria were satisfied. At that checkpoint the ledger left
  all later phases not started, with paid jobs/minutes/attempts and allowances zero.


## Phase 1 supervision — November 12, 2026 UTC

- Owner Codex `/root`; isolated `ci/phase-1-supervision`, sibling
  `DiscordKit-ci-phase1`, based on Phase 0 receipt
  `a74d58a754048ff4058c64a2d75b5bb3b21d04e0`. The
  [source preflight](phase-1/source-preflight.json) retains worktrees, identity,
  remote read and original planning-file hashes. The original checkout and Phase 0
  checkout remain preserved. [Implementation and acceptance](phase-1/IMPLEMENTATION.md)
  supplies the local execution sheet and exact limits.
- Native operation limits and multi-command elapsed deadlines now consume the
  shared policy. Process supervision covers inherited output pipes, shell-free
  argv, receipts, bounded diagnostics, signal interruption and process-group cleanup.
  Discovery stdout remains separate and fails closed on overflow. Workflow
  definitions, Swift/product/test sources and committed dependency pins are unchanged.
- [Final validation](phase-1/validation.json):
  `python3 -m unittest discover -s Tools/ci -p 'test_*.py'`, exit **0**,
  **231 tests passed** in **12.054 seconds** under a **300-second** supervisor.
  The seven executable/configuration/test inputs have retained SHA-256 values;
  [compressed log](phase-1/local-ci-helpers.log.gz) and
  [execution receipt](phase-1/local-ci-helpers.receipt.json) retain complete results.
  Final test-process cleanup reports the process group gone and no reader threads.
- [Nine retained process fixtures](phase-1/faults/results.json) cover normal
  success/assertion failure, silent stall, TERM resistance, inherited stdout,
  debugger failure, forwarding failure, real SIGTERM interruption and exact
  discovery stdout. All expected outcomes, elapsed bounds and cleanup checks pass.
  Failure statuses in these specimens are required failure evidence, not failing
  acceptance. Each fixture command ran once, without an automatic test/build retry.
- [Independent adversarial review](phase-1/review/results.json) also verifies a
  successful parent leaving a TERM-ignoring child with closed output, actual
  supervisor SIGTERM, a blocked real console pipe, bounded no-newline flooding,
  discovery overflow rejection, and a diagnostic child retaining a pipe. A
  deliberate escaped-session case records the process-group boundary honestly;
  the fixture owner killed that escaped child afterward and verified all fixture
  descendants absent. [Binary filename identity](phase-1/review/source-identity-check.json)
  preserves source identity with newline/Unicode names and symlinks.
- Review-driven fixes include signal interruption independent of `InterruptedError`
  (selector retries can swallow that type), bounded console forwarding, exact
  binary Git filenames, bounded sample output and shared symbol-emission limits.
  Final review found no material blocker and verified all seven final input hashes.
  Retained specimens predate final preflight integration; their
  [input note](phase-1/specimen-inputs.json) distinguishes that snapshot from the
  final full-helper acceptance hash.
- [Budget arithmetic](phase-1/job-budget-check.json) fits all 12 compilation
  components and audit/testing aggregates inside existing job deadlines. Consumer
  compilation is capped at 5,400 seconds; discovery, packaging/identity and 840
  seconds of setup/diagnostic/cleanup/upload reserve fit the unchanged 7,200-second
  job. Cold-build capacity is unmeasured. Filesystem archive/hash operations have
  elapsed boundary checks and the enclosing job cap, not hard in-process cancellation.
- This is local macOS Python evidence, including simulated Swift commands. Native
  Swift compilations/tests and paid jobs/minutes/attempts are **0**. No hosted run,
  Linux/macOS native qualification, publication, push, dispatch or runtime repair
  is claimed. The Linux blocked owner and event-hub regression remain later phases.
- Static/link/hash/diff and preservation checks are recorded in the validation
  receipt. Implementation commit
  `1bc5de45a6dbeef1ab31bd7f6fbbe85b69771600` contains the tested inputs and retained
  receipts. This documentation-only follow-up records that actual SHA after
  verifying all seven tested input hashes against it. Phase 1's local exit criteria
  are satisfied; [STATE.md](STATE.md) marks only Phases 0 and 1 complete.

## Phase 2 — Event-hub accounting repair

- Base `7632bdd3494d8ec7a52edc798ad98e09b5a8c357`, owner Codex `/root`, isolated
  `ci/phase-2-event-hub` branch in sibling `DiscordKit-ci-phase2`.
  [Source/host preflight](phase-2/source-preflight.json) and the
  [local execution sheet](phase-2/IMPLEMENTATION.md#ownership-and-local-execution-sheet)
  retain ownership and zero-paid bounds.
- [Controlled red evidence](phase-2/red-tests.log): two test functions, four
  expected issues, exit 1. Queued removal followed by iterator cancellation
  mislabeled one measured/setup copy as discarded. A driver fault injected only
  after four waiting child values returned lost all four in cleanup. This proves
  the unsafe cleanup path, not the exact hosted waiting interleaving. The
  [replay patch](phase-2/red-regression.patch.gz) preserves baseline accounting and
  adds only fault seams/tests; [input hashes](phase-2/red-inputs.json) identify it.
- Copy classifications now use production residence endpoints and specific pull
  results. Setup and measured partitions must independently equal admissions.
  Queue removal, iterator return, consumer acceptance and residence end remain
  distinct; public runtime sources are unchanged. Waiting results are joined
  and aggregated once, including successful values completed before interruption.
  Contradictions fail rather than becoming arithmetic residuals or clamped counts.
- Final [load tests](phase-2/green-tests.log): **23 tests / 2 suites**, exit 0,
  2.212 seconds. Final [runtime tests](phase-2/runtime-tests.log): **21 tests /
  1 suite**, exit 0, 0.008 seconds. Nonempty exact discovery, four CLI round trips,
  red/green/build/smoke receipts and source/report hashes are retained in
  [validation.json](phase-2/validation.json). Every process was reaped with its
  admitted process group gone. No timeout or automatic retry occurred.
- Native schema 2 exports measured/setup dispositions; schema-1 native decoding
  is rejected. Common envelope schema 1/catalog 6 remains, with version-2 scheduler
  and owner-accounting instrumentation identity. Existing historical evidence is
  untouched. Additional bounded instrumentation overhead precludes cross-version
  timing comparisons; no speedup is claimed.
- [Independent review](phase-2/review.json) verifies all six final Swift input
  hashes, passed discovery/test receipts, unchanged public runtime and exact-once
  pending-result aggregation. No blocking findings remain. Local Markdown,
  identity/hash/JSON/replay/diff and original-checkout preservation checks accompany
  the retained evidence manifest.
- Installed compiler is Apple Swift **6.4**, ARM64 macOS. Hosted **6.4.1** pins and
  all workflows/manifests/dependency pins remain unchanged. Whole-package load,
  Linux, pinned hosted-toolchain and final certification are not qualified here.
  Paid jobs/minutes/attempts and spend are **0 / 0 / 0 / USD 0.00**. No push,
  dispatch, billing/runner change, publication, deployment or live Discord action.
- Implementation commit `4dbb085521f1977dc40ea5b8818edb9d61cd2f9f` contains all
  tested inputs and retained evidence. Eight input hashes were checked against
  the actual commit before this documentation-only completion receipt; executable
  inputs and the 61-file evidence manifest remain unchanged. Phase 2 local exit
  criteria are complete; [STATE.md](STATE.md) advances only Phase 2.

## Phase 3 — Stack-supported Linux shutdown repair

- Owner Codex `/root`, branch `ci/phase-3-synthetic-command`, isolated sibling
  `DiscordKit-ci-phase3`, base `07cdea35d6f9ad384bfb42a3005940ca69e76922`.
  [Preflight](phase-3/source-preflight.json) and [execution sheet](phase-3/IMPLEMENTATION.md)
  retain the zero-paid allowance, pinned image/toolchain and original-file hashes.
- The unchanged synthetic suite passed, including `.dslCancelled`. Whole-package
  execution then blocked in the following transport test. A [focused Swift stack](phase-3/diagnostic-assessment.json)
  shows `LocalPeer.stop()` waiting in Foundation while its Python peer has SIGTERM
  blocked and pending. This establishes the local owner/cause; the exact historical
  hosted interleaving remains unproven because that log has no stacks.
- [Peer red](phase-3/peer-red.log) deterministically leaves only the inherited-mask
  peer alive after SIGTERM. [Peer green](phase-3/peer-green.log) passes all ten tests,
  including graceful shutdown, exact metrics, reaping and listener closure for both
  launch variants. The four-line repair unblocks only SIGTERM after handler setup.
- Actual SwiftPM/Foundation descendants had separate PGIDs in one admitted SID.
  [Supervisor red](phase-3/supervisor-red.log) reproduces the old cleanup escape.
  Linux diagnostics/cleanup now cover that session; unknown, malformed or truncated
  final enumeration fails closed. Escaped sessions remain outside the stated boundary.
  [Final Linux helpers](phase-3/supervisor-final-linux.log) pass **237 tests**; macOS
  supervisor compatibility and controlled fault receipts are retained separately.
- [Final validation](phase-3/validation.json) binds nonempty discovery, **161 tests /
  28 suites** in one whole-package process, focused synthetic/transport suites,
  eight fresh direct/DSL scenario processes and both existing REST/loopback smokes.
  [Report checks](phase-3/scenario-report-validation.json) verify exact outcomes,
  response parity, distribution conservation and zero active owners. Deferred parent
  cancellation covers both routes; all eight pre-cancelled callers start no work.
- [Review](phase-3/review.json) and the evidence manifest retain input hashes,
  findings/resolutions and qualification limits. The [owned container cleanup](phase-3/container-cleanup.json)
  disposes fault-fixture zombies without removing unrelated resources.
- Compiler/container: Swift **6.4.1**, Ubuntu **24.04.5**, x64 **under Rosetta** on
  an ARM64 Ubuntu VM. Smokes use the **debug** executable. This is local emulated
  acceptance, not native x64, workflow release, hosted CI or final rollout proof.
  Paid jobs/minutes/attempts/spend remain **0 / 0 / 0 / USD 0.00**. No push or dispatch.
  [Native acceptance](phase-3/NATIVE-ACCEPTANCE.md) remains required; Phase 3 is not
  marked complete in [STATE.md](STATE.md).

- Implementation commit `69a21b325c4eaa6181eb31dcc7e78ab083ac6411` contains all 19 verified
  tested inputs and 168 retained manifest artifacts. Each hash and artifact size was
  checked against the actual Git blob before this documentation-only follow-up.
  The [commit receipt](phase-3/commit-receipt.json) records that verification; the
  native acceptance gate remains open.

## Phase 4 — Compatibility and provenance contracts

- [Implementation plan and local execution sheet](phase-4/IMPLEMENTATION.md) retain
  owner, branch/base, exact compatibility policy and all qualification boundaries.
  V2 separates compatibility, producer and consumer records; same-attempt admission
  remains enforced. Unknown required fields and legacy v1 require regeneration.
- [Validation](phase-4/validation.json) records **270 CI helper tests: 264 passed,
  six existing Linux-only skips**, with a supervised 300-second deadline and clean
  process/reader cleanup. Successful compile/restore/test orchestration is exercised
  through real tar transport and a controlled compiler boundary; no native compiler
  or test suite is executed. Read-only host metadata checks confirm command availability.
- [Retained red](phase-4/exact-types-red.log) and [green](phase-4/exact-types-green.log)
  prove exact JSON-type enforcement at final compatibility checks. Other regressions
  cover source/pins/flags/platform/compiler/SDK/path drift, failed/foreign producer
  scope, empty/duplicate inventories, corrupt/unsafe archives, per-job provenance,
  malformed artifact IDs and terminal failed consumers.
- [Review](phase-4/review.json) records resolved findings and no remaining blocker.
  Per-component restoration receipts preserve all API producers. Existing callers
  use local archive content addresses; caller-supplied immutable IDs are labeled
  honestly. Authenticated GitHub resolution, earlier attempts and partial reruns
  remain Phase 5 work. No workflow or source-export/release barrier changed.
- Paid jobs/minutes/attempts/spend remain **0 / 0 / 0 / USD 0.00**; no push, dispatch,
  native qualification, publication or live Discord claim. Implementation commit
  `4590c5d76c1024d8eec5132a1be343220577cccf` contains all six tested input hashes and
  17 retained manifest artifacts. The [commit receipt](phase-4/commit-receipt.json)
  verifies actual Git blobs; the completion follow-up changes documentation only.


## Phase 5 local transfer and rerun acceptance

Owner Codex `/root` implemented on `ci/phase-5-transfer`, sibling
`DiscordKit-ci-phase5`, based on Phase 4 handoff `b190a963`.
The [execution sheet and contracts](phase-5/IMPLEMENTATION.md) retain zero paid
allowance and the unchanged retention duration, with explicit future accounting
for sidecar/retry storage. The [preflight](phase-5/source-preflight.json) binds
preservation of the original four planning edits and completed phase worktrees.

[Final validation](phase-5/validation.json) records 320 discovered helpers,
314 passed, six existing Linux-only skips, zero failures; actionlint, Node/Python
syntax, scheduling policy and link/diff checks passed. Actual pinned SDK localhost
fixtures verify successful Create/two-block Blob upload/Finalize, byte preservation,
HTTP JSON/HTML faults and no hidden retries. Index/native fixtures prove immutable
source/provenance admission and failed-test rerun without compilation. Earlier
failed full-helper evidence is retained alongside the corrected final result.
[Independent review](phase-5/review.json) found no remaining blockers.

The platform workflow now reconciles all expected producers in an explicit stage,
resolves a fresh selection in each consumer, retries evidence while files remain,
and checks the complete index in the latest platform barrier. The independent
Documentation workflow's helper job only gains the protocol-test SDK prerequisite;
its same-attempt transport/conversion path remains for Phase 9 integration.
No remote upload, push, hosted dispatch/rerun, paid job, native compilation/test,
publication, deployment, runtime or Discord access occurred. Hosted transfer and
partial-rerun acceptance remains Phase 11; Phase 3 native x64 remains pending.

Implementation commit `d466d50bc153f2799a33e200d574569958905295` contains the tested inputs and all
23 retained manifest artifacts. The [commit receipt](phase-5/commit-receipt.json)
compares each input and artifact against actual committed blobs. This receipt
follow-up changes documentation only; executable/test/workflow/dependency inputs
remain byte-for-byte identical to the validated implementation.

## Phase 6 local scoped-preflight and canary acceptance

Prepared from Phase 5 handoff `b759a25e` on isolated `ci/phase-6-preflight-canaries`.
[Execution plan and implementation](phase-6/IMPLEMENTATION.md),
[source preflight](phase-6/source-preflight.json), [final validation](phase-6/validation.json)
and [review](phase-6/review.json) retain ownership, source/artifact hashes and
actual supervised commands. Every helper group, policy/source snapshot, workflow
lint and unchanged human maintenance ledger passed locally. Native expansion and
documentation deployment remain contained pending Phase 10 admission. No native
Swift, hosted/paid execution, remote write, publication or live runtime was used.
Real fresh-runner canary, partial rerun, check context and branch-protection proof
remain Phase 11; Phase 3 native x64 acceptance stays open.

Implementation commit `666f1371224fbe5bda03ec7b54be14a083bb6b09` retains 787 passing
Python/browser tests, six existing Linux-only skips, all source/workflow/maintenance
checks, 16 tested input hashes and 41 retained check artifacts. The
[actual-blob commit receipt](phase-6/commit-receipt.json) verifies those objects;
the completion follow-up changes documentation only.

## Phase 7 local grouped-suite and resource acceptance

Prepared from Phase 6 handoff `e47b506c` on isolated `ci/phase-7-suite-groups`.
[Execution contracts](phase-7/IMPLEMENTATION.md), [final validation](phase-7/validation.json),
[scheduling comparison](phase-7/scheduling-comparison.json) and [review](phase-7/review.json)
retain exact tested inputs, helper/fault results and initial resource assumptions.
Four root groups, one consumer group and separate packages retain 28 native test
jobs versus 101 baseline jobs; 24 producers remain. Full coverage now requires
immutable per-group structured leaves matching the entire selected producer
inventory, with one predeclared optional native-oracle exclusion. Omitted, empty,
wrong-filter, failed, missing, duplicate and unexpectedly skipped work fails.

A real nested SIGALRM leak found during local fault testing was repaired; expired
parent deadlines cannot leak a one-microsecond asynchronous timer during unwind.
Build/runtime waves cap separately at two; compiler CPU/affinity/memory admission
also applies to fixtures. Smaller existing Linux pools are an initial measured-
baseline scheduling choice, not hosted capacity qualification. Post-change time,
bytes, runner minutes and spend remain unknown. No native build/test, hosted or
paid execution, remote write, publication, runner/billing mutation or live Discord
operation occurred. All native rollout remains contained pending Phase 10/11.
