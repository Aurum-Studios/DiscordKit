<!--
File: Docs/Tasks/ci-reliability/phase-7/IMPLEMENTATION.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 7: complete suite groups and bounded resources

Owner Codex `/root`, branch `ci/phase-7-suite-groups`, sibling checkout
`DiscordKit-ci-phase7`, base Phase 6 handoff `e47b506ce4b619e5a055d248f5c42df3b9f68f2a`.
The exact base is recorded in [validation.json](validation.json); this document
records local implementation acceptance, with hosted qualification remaining open.

## Execution plan and allowance

1. Retain isolated ownership and the original checkout's four planning edits.
2. Derive four deterministic root groups from retained duration observations,
   batch consumer graphs into one group, and preserve separate package/load work.
3. Restore once per component/group, discover once per package, execute whole
   modules serially in bounded processes, and reconcile structured executed leaves.
4. Verify immutable execution receipts against independently selected producers in
   every pre-export/platform/root barrier. Reject omissions, duplicates and skips.
5. Apply compiler CPU/affinity/memory admission, nonoverlapping build waves and
   initial smaller existing pools. Run helper/fault/lint/source checks, independent
   review, retain hashes and commit this phase locally.

Local Python/Node helpers, pinned SDK installation and workflow lint only. No Swift
compilation/native test process, hosted job, push, dispatch, remote artifact write,
publication, deployment, billing/runner change or live Discord access. Paid
jobs/minutes/attempts **0 / 0 / 0**, USD **0.00**. Rollout remains compiler-free
preflight pending reviewed Phase 10 spend admission. The existing independent
human maintenance gate is unchanged. Phase 3 native x64 acceptance remains open.

## Complete deterministic groups

[Duration inputs](../../../../Tools/ci/suite-groups.v1.json) retain source-page
SHA256, job ID, exact step and timestamps for each baseline suite. These are
**mixed restore/discovery/test step durations**, not isolated test latency.
Descending duration with module-name ties feeds deterministic least-total-weight
assignment to stable `root-01` through `root-04`. A new suite uses the maximum
observed platform step duration and explicitly records its unmeasured fallback.
The Windows helper path remains nonqualifying and has fallback weights only.

Linux groups contain 6/9/9/9 modules; macOS groups contain 7/9/9/9. One `consumers`
group retains eight separate example build directories, six discovered test
packages and seven existing offline smokes. Nine package groups remain separate,
including the canonical whole-load canary; no load test replay is added. There are
14 test groups per platform, **28 versus 101 baseline individual jobs**, plus the
same 24 producer jobs: **52 versus 125 native build/test jobs**. This comparison
excludes shared/probe/plan/audit/API/export/barrier/documentation jobs and does not
claim the baseline's 152-job whole workflow is directly comparable to 52.
[Scheduling comparison](scheduling-comparison.json) retains measured baseline
setup/restore, known download/archive bytes and runner minutes. Post-change
runtime/setup/restore/bytes/minutes/wall time remain null until authorized hosted
measurement; no savings percentage or invoice reconciliation is inferred.

Each root group restores its root artifact once and discovers that package once.
Each whole root module runs in its own `--skip-build --no-parallel` subprocess
with the anchored `^Module[./]` filter. Package groups keep complete package
execution, including the whole-load-process confirmation. Every suite retains its
selection, command, log, events, exit and leaf/case counts. All expected suite rows
exist before execution; a failed row is marked failed and later rows remain
`not-run`. Restore failure retains the requested unexecuted selection too.
Compiler fixtures still require their positive builds and expected semantic
negative diagnostics; they remain compiler jobs.

## Structured execution and explicit exclusions

SwiftPM discovery function IDs map to Swift Testing ABI **6.4.0** event IDs after
removing the source-location suffix. CLI selector `--event-stream-version 6.4`
plus `--event-stream-output-path` writes the machine-readable stream separately
from console logs. The pinned [SwiftPM command](https://github.com/swiftlang/swift-package-manager/blob/swift-6.4.1-RELEASE/Sources/Commands/SwiftTestCommand.swift)
and [Swift Testing ABI](https://github.com/swiftlang/swift-testing/blob/swift-6.4.1-RELEASE/Documentation/ABI/JSON.md)
define the mapping. Filtering occurs before discovered definitions are emitted:
[plan filtering](https://github.com/swiftlang/swift-testing/blob/swift-6.4.1-RELEASE/Sources/Testing/Running/Runner.Plan.swift#L341-L346),
[runner discovery](https://github.com/swiftlang/swift-testing/blob/swift-6.4.1-RELEASE/Sources/Testing/Running/Runner.swift#L498-L502),
and [ABI streaming](https://github.com/swiftlang/swift-testing/blob/swift-6.4.1-RELEASE/Sources/Testing/ABI/ABI.Record%2BStreaming.swift#L29-L31).

The pinned [SwiftPM forwarding path](https://github.com/swiftlang/swift-package-manager/blob/swift-6.4.1-RELEASE/Sources/Commands/SwiftTestCommand.swift#L787-L806)
preserves `--no-parallel`; [Swift Testing parses it](https://github.com/swiftlang/swift-testing/blob/swift-6.4.1-RELEASE/Sources/Testing/ABI/EntryPoints/EntryPoint.swift#L474-L476)
and the [runner awaits each case](https://github.com/swiftlang/swift-testing/blob/swift-6.4.1-RELEASE/Sources/Testing/Running/Runner.swift#L177-L180).
A nonparameterized discovered function requires one start/end pair. A parameterized
function requires one outer pair and at least one serial, matched argument-case
pair. The stable ABI does not expose argument-value IDs or an independent expected
argument population: case counts are invocation counts within the discovered
function, not independently inventoried argument-value coverage. Repeated runs,
wrong filters, zero execution/argument population, missing/duplicate leaves,
failing issues, cancellation and unexpected function/suite skips fail closed.

Current repository test packages use Swift Testing. Serial XCTest cannot provide
matching structured output through this pinned SwiftPM path; any XCTest discovery
is explicitly rejected pending a separate supported adapter. The implementation
never substitutes a console count or exit zero for leaf results. Pinned-source
fixtures and mocked compiler boundaries are local helper evidence, not native
Swift 6.4.1 wire acceptance; the real producer/consumer runs remain Phase 11.

The single existing optional MLS++ oracle method
`DiscordMLSTests.MLSNativeDAVEInteropTests/initialCandidateAcceptedByMLSpp(_:)`
is an explicit preexecution exclusion in the root producer's compatibility/build
profile. Its native executable is opt-in and outside ordinary offline coverage.
The exact discovered identifier was confirmed in retained Phase 2 discovery.
Other skipped leaves fail. The receipt partitions all selected producer leaves
into executed leaves and these reason-bearing exclusions; excluded leaves cannot
execute. A separate opt-in native oracle run needs its own expected selection.

Dedicated single-member `test-coverage` artifacts retain `group-coverage.json`.
Fresh barriers select each latest successful API job/required step, resolve
immutable producer metadata, digest-verify result ZIPs, compare producer/source/
compatibility/inventory and execution attempt, independently validate every suite
result, and reconcile the complete platform leaf union exactly once. A receipt
contains static `GITHUB_JOB`; the barrier binds it to the numeric REST job selected
by exact platform/group name and attempt. Seals retain numeric job ID, artifact
ID/digest/name and receipt SHA256. Missing/expired/corrupt/ambiguous proof or a
newer failed rerun cannot reuse old success. Diagnostics validate only their
selection and remain incapable of full certification or source export.

## Resources and workflow boundaries

A load canary gates each independent platform. The first build wave owns root,
macros, extensions and tooling. Root runtime groups, tooling audits and macOS API
conversion can follow that wave without the remaining build-matrix barrier.
Other builds form a second wave, then compiler fixtures; Apple module compilation
follows fixtures. Build/fixture waves have max-parallel 2. Remaining runtime groups
wait for the root runtime wave; each runtime matrix has max-parallel 2. The DAG
uses valid static dependencies and explicit matrices, with no dynamic matrix-member
`needs`. Diagnostic scopes deliberately handle absent/skipped waves.

Compiler requests are capped at policy limit 2, visible CPU count, affinity and
memory admission. Initial assumptions reserve 2 GiB and budget 4 GiB per compiler;
these are conservative scheduling inputs, not measured peaks. Linux observes
MemAvailable and cgroup remaining allowance; macOS uses a bounded vm_stat query.
Unknown/insufficient headroom falls back to one job and records the reason; it
cannot promise a memory allocation. Compiler fixtures use the same admission.
The read-only local host observation and policy constants remain in [resource-admission.json](resource-admission.json).

Linux tooling and timing-support use the existing `Linux-x64-8` pool initially.
Baseline tooling used 87 runner seconds/26 mixed compile-step seconds;
timing-support used 50/9 on Linux64. Root remains Linux64 (139/64). These observations
motivate the initial choice without qualifying cold capacity or memory. macOS
retains its existing five-core pool; no runner pool is provisioned or reconfigured.

Per-suite 300-second and whole-load 600-second process limits remain unchanged;
discovery is 60 seconds per package, smokes 120 seconds, plus 120 seconds for final
identity queries. Group aggregate time sums the admitted work. Runtime jobs have
105-minute envelopes, reserving setup 600s, separate restore 600s, diagnostics/
cleanup 60s and four 420s transport totals. Audit jobs have 60 minutes and three
transport totals. The largest current consumer group admits 3,120s + 2,940s
reserves = 6,060s inside 6,300s. Build jobs remain 150 minutes and retain their
separate compile/packaging reserves; fixture jobs remain 90 minutes. Canary's
75-minute envelope still covers its smaller complete load scope. These are finite
prepared ceilings; Phase 10 must price them and Phase 11 must measure capacity.

## Review and validation

Independent review checked grouped restore/discovery, exact filters, leaf proof,
partial-rerun provenance, resource admission, static DAG and enclosing reserves.
It identified Apple compiler overlap and fixture admission, both repaired.
A full helper run also exposed a genuine nested transport deadline leak: restoring
an already-expired parent SIGALRM for one microsecond could interrupt unwinding
and leave a live alarm after supervision. Cleanup now cancels the owned timer,
restores the previous handler before any live parent timer, and handles an expired
parent deadline synchronously while preserving the primary exception. Deterministic
restoration-order and 30-round isolated process regressions cover the repair.

[Review](review.json) and [validation](validation.json) retain final command exits,
tested input hashes, artifact hashes and acceptance limits. Local helper checks
cover complete grouping, consumer batching, partial failures/not-run rows,
wrong-filter/zero/missing/duplicate/skip faults and immutable result validation.
Real native/platform/cost/partial-rerun proof remains Phase 11. Phase 8 is the next
implementation phase; this phase does not enable paid rollout.
