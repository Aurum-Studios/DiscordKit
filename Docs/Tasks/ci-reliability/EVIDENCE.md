<!--
File: Docs/Tasks/ci-reliability/EVIDENCE.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Incident baseline and evidence requirements

This records the read-only investigation preceding [PLAN.md](PLAN.md). It does not
claim that any repair or proposed scheduling policy has been implemented. Retain
original logs/metadata separately; GitHub artifact links can expire.

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
  the failing test emitted no numeric report proving its exact lost-copy count.
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
publication was performed while authoring this plan.
