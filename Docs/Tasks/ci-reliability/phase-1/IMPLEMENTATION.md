<!--
File: Docs/Tasks/ci-reliability/phase-1/IMPLEMENTATION.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 1 implementation and local acceptance

Phase 1 extends the existing process-group supervisor and connects the Phase 0
operation budgets to the native planner. The authoritative requirements remain
[Phase 1 of the plan](../PLAN.md#phase-1--enforce-process-deadlines-and-retain-stall-evidence).
This work supplies no native Swift, hosted, release or runtime qualification.

## Ownership and execution sheet

- Owner: Codex `/root`; supervisor and native planner work are delegated to
  separate owners. The native planner has one owner; workflow definitions are
  not edited concurrently.
- Base: `a74d58a7`, the completed Phase 0 ledger receipt after implementation
  `5808ce32d867622ff6952d0f2057768a8a257f14`.
- Branch: `ci/phase-1-supervision`, isolated sibling `DiscordKit-ci-phase1`.
  The original checkout's planning changes and the completed Phase 0 checkout
  are retained. See [source-preflight.json](source-preflight.json).
- Authorized local work: supervisor/planner/policy implementation, deterministic
  Python fault injections, helper checks, documentation and scoped local commits.
- Paid jobs/minutes/attempts: **0 / 0 / 0**, USD **0.00** allowance.
  Native Swift compilations and test processes: **0 / 0**.
- No automatic test, build or workflow retry. A changed helper implementation
  may be checked again after inspecting a failed test.
- Each helper validation invocation has a 300-second outer deadline, with
  retained logs. Fault fixtures shorten their command deadlines explicitly;
  production limits remain those in the versioned scheduling policy.
- No push, dispatch, runner/billing change, publication, deployment or live
  Discord access is included in this phase.

## Implementation plan

1. Preserve POSIX session/process-group ownership and TERM/grace/KILL cleanup.
   Supervise the command and its inherited output pipes against one monotonic
   deadline. Bound diagnostic children and close/reap all owned resources.
2. Persist execution receipts and bounded heartbeat/resource/process/stack
   evidence independently of machine-readable discovery stdout. Use safe
   process metadata and debugger stack commands without environment or variable
   dumps. Record missing or denied probes explicitly.
3. Apply operation-specific policy limits to discovery, compilation, compiled
   suites, load confirmation and finite smoke commands. Bound multi-command
   components and suites against a shared aggregate deadline. Keep compilation
   and tests separate and retain committed pins and exact inventory validation.
4. Reconcile aggregate command allowances with existing job deadlines, including
   setup, diagnostics, cleanup, evidence upload and archive/identity allowance.
   Tighten proposed consumer compilation allowance to fit the existing enclosing
   cap; increased cold-build capacity requires retained evidence and a new bound.
5. Inject success, assertion failure, silent stall, TERM resistance, inherited
   output ownership, debugger failure, forwarding failure and interruption.
   Check elapsed bounds, output integrity, receipts and descendant cleanup.
6. Run focused tests, the full CI-helper suite and relevant static checks; review
   the final diff independently, retain validation hashes and commit the phase.
   Record the actual implementation commit in a documentation receipt afterward.

## Acceptance receipts

The final helper invocation is
`python3 -m unittest discover -s Tools/ci -p 'test_*.py'`: exit **0**, **231 tests**,
**12.054 seconds**, with a 300-second outer limit. [validation.json](validation.json)
binds the seven source/configuration/test inputs and compressed log hashes.
The [execution receipt](local-ci-helpers.receipt.json) records the command identity,
deadline, exit and final cleanup: parent reaped, process group gone, zero reader
threads. These tests include 50 supervisor, 30 native planner and 10 policy tests.

[Retained process specimens](faults/results.json) satisfy all required fault cases:

| Fixture | Expected result | Elapsed seconds | Cleanup |
| --- | --- | ---: | --- |
| Normal success | Pass | 0.023 | Group gone; zero reader threads |
| Assertion failure | Fail, exit 7 | 0.023 | Group gone; zero reader threads |
| Silent stuck child | Execution timeout | 0.707 | Group gone; zero reader threads |
| TERM-ignoring child | Execution timeout, then KILL | 5.707 | Group gone; zero reader threads |
| Exited parent, child holding stdout | Inherited-output timeout | 0.705 | Group gone; zero reader threads |
| Failed debugger | Probe failure retained; command timeout | 0.906 | Group gone; zero reader threads |
| Failed forwarding | Forwarding error retained | 0.023 | Group gone; zero reader threads |
| Real SIGTERM interruption | Interrupted receipt | 0.261 | Group gone; zero reader threads |
| Discovery stdout | Exact inventory text, stderr separate | 0.023 | Group gone; zero reader threads |

The [fixture script](faults/retained_faults.py), per-case logs, diagnostic JSONL and
receipts are retained. Each fixture command has one attempt. The
[input snapshot note](specimen-inputs.json) distinguishes these specimens from
final preflight integration; the full suite above validates the final input hashes.

[Independent review](review/results.json) adds adversarial closed-output descendants,
real SIGTERM delivery, blocked OS console pipes, no-newline output flooding,
exact-stdout overflow and diagnostic pipe holders. The deliberately escaped-session
fixture demonstrates the process-group boundary; its owner killed it afterward,
and all fixture descendants were verified absent. [Source identity review](review/source-identity-check.json)
compares the original binary Git algorithm with supervised filename transport using
newline/Unicode filenames, a symlink and binary content. The hashes match.
Final review of all source changes found no material blocker.

[Static acceptance](static-validation.json) records passing policy validation,
zero-paid bootstrap read-back and source-anchored scope (24 builds/101 suite jobs,
Linux/macOS only). It verifies 124 local Markdown links, 29 historical capture
hashes, unchanged workflows/product/manifests/pins, original checkout preservation
and Phase 0 checkout preservation. [SHA256SUMS](SHA256SUMS) binds 53 retained
evidence files; the living implementation notes are outside that manifest.

## Implemented bounds and receipts

- Operation deadlines: discovery 60 seconds, focused reproduction 90 (stack
  checkpoints at 30/60), compiled suite 300, whole load confirmation 600, finite
  smoke 120 and cold compilation 1,200 per command. Existing compiler pins,
  strict imports, source-built dependencies and compiled-test isolation remain.
- Shared aggregate elapsed limits cover serial component commands, symbol emission,
  inventory and final identity. The [job-budget arithmetic](job-budget-check.json)
  includes existing setup/diagnostic/cleanup/upload reserves and packaging/identity
  allowance. Consumer compilation is 5,400 seconds, fitting the unchanged two-hour
  build cap. Audit commands share 300 seconds, fitting the existing 30-minute job.
  Metadata queries have 30-second supervised limits; evaluated package targets
  and leaf discovery share their 60-second inventory boundary.
- POSIX selectors bound the parent and inherited output pipes without reader
  threads. Heartbeats every 30 seconds carry stage, elapsed/deadline, output age,
  PID/group, last observed test and bounded resources/process metadata. Stacks
  inspect at most three owned targets and record omitted targets. Missing, denied
  or failed tools stay explicit; they never turn a timeout into success.
- Diagnostic subprocesses own process groups, share the command deadline and have
  a five-second maximum. Cleanup has an eight-second POSIX allowance, including
  TERM grace, KILL, parent reap and bounded group verification. Unknown/truncated
  process verification remains unknown. Windows keeps a 15-second best-effort
  allowance and helper coverage; no Windows qualification is supplied.
- A command retains at most 8 MiB per output file and a 512 KiB JSONL diagnostic
  ring. Diagnostic probe output is at most 32 KiB. Ordinary logs flag truncation;
  exact machine-readable stdout rejects overflow. Console writes cannot block
  the supervised deadline. macOS sample output goes through the capped pipe.
- Each command writes a `.receipt.json` and `.diagnostics.jsonl` beside its log.
  Receipts retain complete literal argv, start/end, execution/deadline identity,
  exit/signal/error, timeout category, output paths/truncation and final cleanup.
  Machine stdout has its own file and receives no heartbeat/stderr text.
  Nested command failures remain failures even if diagnostic/reporting also fails.

## Acceptance limits and commit receipt

Phase 1's local exit criteria pass. This implements supervision needed for later
native diagnosis; it does not establish a deadlock cause or repair event-hub/runtime
behavior. No native Swift build or test, hosted job, container/VM change or paid
execution occurred. The [execution sheet](#ownership-and-execution-sheet) stays zero.
No workflow definition changed and no automatic test/build retry was introduced.

The process-group guarantee covers the admitted POSIX group. A deliberately escaped
session is outside it. Archive/hash filesystem operations use elapsed checks at
boundaries and the enclosing job timeout; a blocked filesystem operation is not
hard-cancelled by Python. Probe/ptrace availability and cold-build capacity need
later platform evidence; no hosted or Linux qualification follows from these tests.

The scoped implementation commit and final documentation-only receipt are recorded
in [STATE.md](../STATE.md) after the actual implementation SHA exists.
