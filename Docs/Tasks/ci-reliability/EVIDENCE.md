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
and Phase 1 local helper acceptance are recorded below; Phases 2 through 11
remain incomplete.

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
