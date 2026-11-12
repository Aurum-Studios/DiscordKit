<!--
File: Docs/Tasks/ci-reliability/PLAN.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# CI reliability, cancellation repair, and bounded spending

Status: phased implementation plan. Phase 0 is complete as local preparation at
`5808ce32d867622ff6952d0f2057768a8a257f14`. Phase 1 is complete as
local helper implementation at `1bc5de45a6dbeef1ab31bd7f6fbbe85b69771600`.
Phase 2 is complete as local Swift implementation at
`4dbb085521f1977dc40ea5b8818edb9d61cd2f9f`.
Phase 3 is implemented with local emulated acceptance; native x64 acceptance remains open.
Phase 4 is complete as local helper implementation at
`4590c5d76c1024d8eec5132a1be343220577cccf`; see
[the implementation](phase-4/IMPLEMENTATION.md). Phase 5 is implemented at `d466d50bc153f2799a33e200d574569958905295` with local
helper acceptance; its hosted transfer/rerun proof remains Phase 11 work. See
[the execution plan and contracts](phase-5/IMPLEMENTATION.md). Phases 6 through 11
remain proposed.
See [STATE.md](STATE.md) for the
commit-backed completion record and [BOOTSTRAP.md](BOOTSTRAP.md) for execution limits.
Source inspected: `85eac6f3c1d3b17e53596c49e7438efee366c1b3`.
Failure snapshot: offline certification run `43146954720`, November 12, 2026 UTC.

Use [STATE.md](STATE.md) as the execution ledger and [EVIDENCE.md](EVIDENCE.md)
for the observed failures and implementation receipts. The current implemented
pipeline remains documented in [CI.md](../../CI.md). This plan distinguishes
completed local phases from future changes; it does not establish native
qualification or authorize paid execution, runner/billing changes, publication,
deployment, or live Discord access.

## Outcome and nonnegotiable contracts

Finish with repaired cancellation behavior, useful bounded failure diagnostics,
complete platform coverage, recoverable artifacts, and measured runner costs.
Another full run is the final qualification step, after focused repairs and the
scheduling controls below are proven.

- Preserve Swift 6.4.1, committed dependency pins, native SwiftPM builds, strict
  imports, Swift signing verification, API comparison, strict DocC, and the
  independent human upstream-maintenance gate. Windows qualification stays out
  of scope. Use `msbuild` if any macOS C# build is introduced.
- Preserve public runtime cancellation, admission, ordering, response ownership,
  queue bounds, and zero-owner cleanup. No assertion removal, longer sleeps, or
  fabricated cancellation counts may turn an unexplained failure green.
- Keep Linux and macOS independent after the shared source/helper preflight.
  One platform's failure prevents its expansion without cancelling the other.
- Discovery must be nonempty. Every applicable test leaf and required gate must
  be accounted for exactly once. Failed, missing, cancelled, duplicate, or
  unexpectedly skipped required work cannot pass complete certification.
- Retain the exact `Offline certification passed` check in `ci.yml` as the full
  qualification barrier recognized by release tooling. A diagnostic result must
  never satisfy that barrier, branch protection, source-export qualification, or
  release eligibility.
- No automatic retry of builds, assertions, tests, or the full workflow. Only
  explicitly bounded transport retries are automatic. A timeout is a failure.
- Local checks, Linux-container checks, hosted platform checks, full hosted
  certification, publication, and live/runtime qualification remain distinct.

## Execution order and ownership

| Phase | Deliverable | Depends on | Primary ownership |
| --- | --- | --- | --- |
| 0 | Evidence baseline and initial execution limits | None | Integration owner |
| 1 | Process deadlines and diagnostics | 0 | Supervisor owner |
| 2 | Deterministic event-hub accounting repair | 0; use 1 for native execution | Cancellation owner |
| 3 | Stack-supported Linux synthetic-command repair | 1 | Linux diagnosis owner |
| 4 | Versioned compatibility and producer receipts | 0 | Artifact owner |
| 5 | Immutable transfer recovery and partial reruns | 1, 4 | Artifact owner |
| 6 | Shared preflight, scoped execution, platform canaries | 1, 2, 3, 5 | Integration owner |
| 7 | Complete suite groups and bounded resources | 6 | Integration owner |
| 8 | Reusable verified provisioning | 4, 6; measure against 7 | Provisioning owner |
| 9 | Shared documentation build and conversion inputs | 5, 6 | Documentation owner |
| 10 | Automated spend admission and usage reporting | 0, 6, 7, 8, 9 | Integration owner |
| 11 | Native qualification, partial-rerun proof, rollout | All prior phases | Integration/review owners |

Phases 1, 2, and 4 can be prepared concurrently after Phase 0. Phase 3 follows
the supervisor. Provisioning and documentation helper work may proceed in
parallel after their interfaces are fixed. One owner integrates
[native_jobs.py](../../../Tools/ci/native_jobs.py),
[ci.yml](../../../.github/workflows/ci.yml), and
[native-platform.yml](../../../.github/workflows/native-platform.yml): matrix,
receipt, and dependency changes must not be edited concurrently by separate
owners. Keep independently reviewable commits for each phase; record the actual
commit and validation result before moving its ledger entry to complete.

## Phase 0 — Capture the baseline and bound the next experiment

1. Re-read repository identity, dirty/staged files, active worktrees, running
   validation processes, HEAD, and remote state. Preserve unrelated work and use
   an isolated implementation branch/worktree. Do not clean existing build or
   baseline worktrees. Record the selected branch, checkout, owner, and base.
2. Retain both pages of the 152-job run inventory, failed/cancelled job logs,
   available artifact IDs/digests, and dependency/toolchain facts before artifact
   expiry. Separate test, timeout, upload, provisioning, and aggregate failures.
3. Capture a cost baseline by runner SKU: job counts, runner minutes, queue/setup,
   compile, discovery, restore, tests, conversion, upload/download time and bytes.
   Include the separately triggered documentation run. The reported additional
   $40 is user-observed spend; do not invent an invoice reconciliation.
4. Define one versioned scheduling policy consumed by planning and cost admission:
   modes, platforms, components, suite inventories, dependencies, deadlines,
   cleanup allowance, concurrency, artifact retention, runner rates, rate date,
   billing rounding, and per-experiment/per-workflow allowances. A new policy
   module/configuration and its tests may be introduced under Tools/ci.
5. Until automated admission exists, retain a reviewed bootstrap execution sheet
   containing exact scope, maximum paid jobs/minutes/attempts and an allowance.
   Prefer a matching local Ubuntu environment for Linux diagnosis. Record CPU
   architecture and virtualization: emulated x64 on Apple Silicon is exploratory
   evidence, not native Linux acceptance. If native x64 is unavailable locally,
   escalate to an explicitly authorized bounded native probe. A paid probe
   requires execution authorization; this planning request supplies none.
   Limit a diagnostic experiment to two native test-process attempts before
   inspecting evidence and revising the experiment. Cold compilation is a separate
   bounded stage. Do not repeatedly pay for an unchanged reproduction.
6. Keep preparation local while the existing push/PR workflows can still fan out.
   If remote review is needed, first prepare and verify a containment-only workflow
   patch for both CI and documentation: the repair branch/PR runs source/helper
   preflight with a distinct noncertifying result and no broad native jobs or
   documentation deployment. Publish only when authorized. Do not let intermediate
   phase pushes repeatedly invoke the old paid matrix. Keep required full
   certification unsatisfied until complete validation is deliberately enabled.

Exit: baseline inventory and initial execution sheet exist; source ownership,
allowed experiments, and stop conditions are explicit. No broad CI dispatch.

Phase 0's concrete local scope is [BOOTSTRAP.md](BOOTSTRAP.md). The initial policy
and source planner are [scheduling_policy.py](../../../Tools/ci/scheduling_policy.py)
and [scheduling-policy.v1.json](../../../Tools/ci/scheduling-policy.v1.json); runner
usage reconstruction is [baseline_usage.py](../../../Tools/ci/baseline_usage.py).
These offline helpers do not yet integrate policy into workflow execution or
enforce runtime admission; those remain Phases 6 and 10.

## Phase 1 — Enforce process deadlines and retain stall evidence

Files: [linux_ci.py](../../../Tools/ci/linux_ci.py),
[native_jobs.py](../../../Tools/ci/native_jobs.py),
[test_linux_ci.py](../../../Tools/ci/test_linux_ci.py), and
[test_native_jobs.py](../../../Tools/ci/test_native_jobs.py).

Extend the existing POSIX process-group supervisor rather than replacing its
TERM/grace/KILL cleanup or separate machine-readable discovery stdout. Its deadline
already covers the parent and inherited output pipes. Add operation-specific
limits instead of the current 3,600-second Swift command default.

Initial policy values below are proposed limits, not measured capacity claims.
Adjust a particular compile budget only from retained cold-build evidence and
recompute its spend bound before execution.

| Operation | Initial execution limit | Additional boundary |
| --- | --- | --- |
| Test discovery | 60 seconds | Nonempty exact inventory required |
| Focused Linux reproduction | 90 seconds | Stacks at 30 and 60 seconds |
| Individual compiled suite | 300 seconds | Own log/result, no rebuild |
| Whole load-package confirmation | 600 seconds | Required until shared-process hang understood |
| Offline timing smoke | 120 seconds | Preserve existing finite smoke scope |
| Debugger/resource probe | 5 seconds each | Never extends command deadline |
| Cold component compilation | 20 minutes per command | Component aggregate budget also required |
| Transport attempt | 120 seconds | At most 3 attempts within a 420-second total |

For multi-command components/groups, bound aggregate elapsed time as well as each
command. Enclosing step/job deadlines must include setup, finite diagnostics,
cleanup, and evidence-upload reserve; they must exceed the supervised command
budget enough for cleanup to run. Budget those reserves as paid runner time.

Every 30 seconds emit stage, monotonic elapsed/deadline, last output age, PID/group,
last observed test, CPU/RSS, available memory/disk and child-process status. Use
bounded files/ring buffers and fixed-size snapshots. Silence alone triggers
diagnosis, not an unsupported assertion of deadlock. Before a timeout, capture
process trees and all-thread stacks with platform-appropriate available tools.
Record debugger/ptrace denial or unavailable probes explicitly. Do not expose
credentials, environment dumps, payloads, or unrestricted core dumps.

Persist start/end, complete shell-free argv, exit/signal, timeout category, output
and diagnostic paths, final descendant cleanup, and execution identity. Diagnostic
subprocesses also require deadlines and cleanup. The existing Windows best-effort
cleanup remains covered by helpers without claiming Windows qualification.

Required fault injections: silent stuck child; TERM-ignoring child; parent exiting
while a child retains stdout; failed debugger; failed forwarding; interruption;
normal success and normal assertion failure. Verify reader threads and descendants
finish within the execution limit plus recorded cleanup allowance.

Exit: focused helper tests pass; injected hangs fail promptly with retained
diagnostics; discovery stdout remains parseable; no test/compile retry occurs.

Local implementation and acceptance: [Phase 1 receipts](phase-1/IMPLEMENTATION.md).
The initial limits are active in native helpers. Consumer compilation uses a
5,400-second aggregate so all applicable reserves fit the existing 120-minute
build job. These limits remain unqualified cold-build capacity; no native
reproduction or hosted execution occurred in Phase 1.

## Phase 2 — Repair event-hub cancellation accounting

Files: [EventHubTimingRunner.swift](../../../Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/EventHubTimingRunner.swift),
[EventHubTimingCommand.swift](../../../Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/EventHubTimingCommand.swift),
[EventHubTimingTests.swift](../../../Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/EventHubTimingTests.swift),
[EventHub.swift](../../../Sources/DiscordGateway/EventHub.swift),
[EventHubTests.swift](../../../Tests/DiscordGatewayTests/EventHubTests.swift), and
the [load-tool README](../../../Tools/DiscordKitLoadTests/README.md).

The hosted assertion is established; the exact interleaving still needs a
controlled reproducer. Investigate both source-supported accounting windows:
queued dequeue before the iterator's post-await cancellation check, and a waiting
pull completing before the benchmark driver aggregates its result.

1. Define queue-removal, iterator-return, consumer-acceptance and residence endpoints
   separately. Freeze setup-versus-measured populations and report compatibility.
2. Capture a deterministic red regression before changing accounting. Replace
   sleep-based cancellation coordination with bounded test-owned barriers. Reuse
   the existing synchronous residence observer where sufficient; never await or
   reenter the hub while its atomic operation is executing. Add only the smallest
   internal, default-disabled seam if waiting handoffs cannot otherwise be controlled.
3. Cover cancellation before dequeue, between dequeue and iterator return, after a
   pending pull completes but before aggregation, and after acceptance. Cover
   queued/waiting modes, setup backlog, partial work, multiple subscribers/hubs,
   and an unaffected subscription. Retain every pending task result during join.
4. Account each admitted setup/measured copy once as consumed, explicitly discarded,
   cancelled while retained, or cancelled at a proven delivery handoff. Derive
   categories from owner evidence; an arithmetic residual is an integrity failure.
   Do not mask contradictions with `max(0, ...)` or relabel all loss as cancellation.
5. Preserve the public iterator's post-await cancellation check, actual residence
   endpoint/outcomes, FIFO, independent subscriptions and finite storage. A public
   semantic change needs separate justification; the initial repair belongs in
   benchmark accounting. If report fields/populations change incompatibly, version
   them and update readers/docs without rewriting historical evidence.

Exit: failing-before/passing-after controlled regression; complete measured outcome
partition; zero unexplained copies/double counts; joined tasks and zero subscriptions,
buffered events/bytes and waiting consumers. Pass focused EventHub timing/runtime
tests under Phase 1 limits. Whole-package native confirmation follows Phases 3/11.

## Phase 3 — Locate and repair the Linux synthetic-command hang

Files: [SyntheticCommandTimingRunner.swift](../../../Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/SyntheticCommandTimingRunner.swift),
[SyntheticCommandTimingRunnerTests.swift](../../../Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/SyntheticCommandTimingRunnerTests.swift),
[CommandRouter.swift](../../../Sources/DiscordCommands/CommandRouter.swift), and
[InteractionResponder.swift](../../../Sources/DiscordInteractions/InteractionResponder.swift).

1. Confirm Ubuntu 24.04 x64 and Swift 6.4.1 with a retained native probe, recording
   virtualization/emulation and the qualification limit from Phase 0. Compile
   separately under a cold-build budget. Verify nonempty discovered identifiers
   before executing the synthetic suite with `--skip-build --no-parallel`.
2. Use the 90-second supervisor, with stacks at 30/60 seconds. Capture SwiftPM and
   test-process trees so a pipe/startup problem can be distinguished from a task
   blocked inside the test executable. Apply the Phase 0 attempt allowance.
3. Add bounded development-only stage observations around admission/preparation,
   handler entry/exit, response confirmation, error annotation, group join and
   cleanup snapshots. The last printed `.dslCancelled` case is a lead, not proof
   of the owning blocked operation. Cancelled synthetic handlers throw directly;
   this fixture does not use the rate coordinator or network.
4. Compare direct/DSL failure/cancellation scenarios in fresh processes, then
   controlled instrumentation modes. Use parameterized identifiers actually
   exposed by the pinned compiler. If necessary add narrowly scoped case selection
   or split regressions without omitting parameterized coverage.
5. If isolated tests pass, reproduce the whole-package process/settings and bisect
   preceding suites/order. Investigate shared-process contamination, fixture,
   product, or runtime ownership only as supported by stacks and stage evidence.
6. Identify the blocked task/continuation/owner and implement a deterministic red
   regression followed by the smallest supported fix. A confirmed compiler/runtime
   defect needs a minimal reproducer and explicit dependency/toolchain decision;
   no silent toolchain downgrade or cancellation-case exclusion.

Exit: evidence-backed cause; red/green regression; direct/DSL success, failure,
cancellation and deferred-response parity; no invented callbacks or post-cancellation
replacement cohorts; zero active handlers and acknowledgment count/bytes after
join. Pass focused tests, the full Linux load package and its existing REST/loopback
smokes. Isolated repetition, larger timeouts, or a smoke alone cannot close this phase.

## Phase 4 — Separate compatibility from producer and consumer provenance

Files: [native_jobs.py](../../../Tools/ci/native_jobs.py),
[test_native_jobs.py](../../../Tools/ci/test_native_jobs.py), and
[platform_probe.py](../../../Tools/ci/platform_probe.py).

Define receipt version 2 before relaxing attempt equality. Keep three records:

- Compatibility: exact commit and tracked-content hash, explicit dependency-pin
  digests, component/package/build flags/configuration, platform/architecture,
  compiler/target, native build engine, canonical absolute checkout path, relevant
  OS/runtime/image compatibility, and Xcode/SDK facts on macOS.
- Producer: repository/workflow identity, run, job, attempt, event/trust scope,
  successful compilation/discovery, inventories, payload/archive hashes, schema,
  and timestamps. Producer attempt is retained, not erased.
- Consumer: its own run/job/attempt, selected producer and immutable artifact ID,
  verified digest/compatibility, discovery, selected scope and execution results.

Specify which image fields require exact equality and which are informational;
never use a broad compatible-version range without native evidence. Reject unknown
required identity fields. Update both restore admission and post-test identity
checks, which currently compare the whole identity including attempt. Preserve
path/member safety, link handling, no-overwrite extraction, full payload validation,
permissions, resource files and nonempty exact discovery.

Exit: tests reject changed source/pins/flags/platform/compiler/SDK/path, unsafe
archives and invalid producer scope. Version 1 remains same-attempt only or fails
with a clear regeneration requirement. No permissive legacy fallback.

## Phase 5 — Recover transfers and rerun failed jobs without rebuilding

Files: [native_jobs.py](../../../Tools/ci/native_jobs.py),
[native-platform.yml](../../../.github/workflows/native-platform.yml),
[test_native_jobs.py](../../../Tools/ci/test_native_jobs.py); introduce focused
artifact index/transfer helpers and tests under Tools/ci as needed.

1. Add an explicit artifact resolver/index stage. Matrix outputs are not a safe
   component-to-artifact map: multiple matrix writers can overwrite output names.
   Reconcile exactly expected components against per-producer receipts and GitHub
   artifact IDs/digests. Reject ambiguous candidates or incomplete indices.
2. Initially permit earlier successful producer attempts only within the same run
   and exact source revision. Validate successful producer provenance and Phase 4
   compatibility; record the selected attempt explicitly in every consumer.
   An expired/missing artifact requires an explicitly scheduled fresh build. Never
   select a different revision, prefix cache hit, or unrelated workflow artifact.
3. Implement at most three transport attempts within the Phase 1 aggregate limit.
   Retry only classified transient errors; malformed input, unsafe archives,
   authorization failures and bad digests fail immediately. Use unique immutable
   upload-attempt names. Reconcile an ambiguous completed upload by exact identity
   and digest, or upload the unchanged bytes to a fresh bounded candidate name.
   Never blindly overwrite/delete a successfully referenced artifact ID.
4. Require final verified upload/download success. Earlier failed transfer steps
   may be recoverable internally, but `continue-on-error` cannot bypass the final
   evidence gate. Tar DocC/API evidence to preserve colon-containing filenames.
5. Retry evidence upload while the original job still has its files; do not rerun
   tests or compilation for that retry. If all uploads fail and the runner is
   disposed, lost local files cannot be recovered magically: report incomplete
   evidence and specify the minimum explicit regeneration required.
6. Preserve producer outputs across partial reruns and run a fresh complete barrier
   in the latest attempt. Current two-day retention must cover the planned retry
   window or be explicitly revised with storage cost included.

Exit: injected first-upload failure recovers without test/build execution;
ambiguous upload selects valid immutable provenance; corruption/expiry/wrong-source
fail closed; partial failed-test rerun uses the successful producer. Hosted proof
is reserved for Phase 11; helper mocks alone are insufficient.

## Phase 6 — Gate expansion with cheap preflight and native canaries

Files: [ci.yml](../../../.github/workflows/ci.yml),
[native-platform.yml](../../../.github/workflows/native-platform.yml),
[native_jobs.py](../../../Tools/ci/native_jobs.py),
[github_release.py](../../../Tools/ci/github_release.py), and their existing tests.

Wire this architecture behind the Phase 0 containment/rollout setting. Automatic
paid expansion stays disabled until Phase 10 admission is implemented and tested;
earlier native diagnostic probes use the separately bounded bootstrap allowance.

1. Add explicit full, preflight and diagnostic scope to the existing CI entrypoint
   and shared planner. Validate all selections before scheduling. Diagnostic modes
   select platform/component/suite and never automatically expand to full mode.
   Partition concurrency keys by full versus scoped mode and selected scope so a
   same-branch diagnostic cannot cancel or supersede full certification. Retain
   cancellation of superseded full runs within the full-mode concurrency group.
2. Run balanced Python/browser helper jobs, workflow syntax/actionlint, policy and
   source-only checks, and maintenance freshness ahead of paid native expansion.
   Root manifest evaluation may require Swift: do not mislabel it compiler-free.
   Documentation/inventory/generation/parity audits invoking compiled tooling stay
   native and follow their smallest sufficient producer.
3. Per platform, run probe → load producer → immutable upload → separate fresh
   consumer job → restore/discovery → complete load suite including repaired tests
   → existing smokes. Scoped diagnosis may run focused tests separately; budget
   those replays explicitly and exclude them from canonical full-run coverage.
   The actual separate-runner round trip is required, even
   when the platform probe passes. Keep the canary's valid producer and suite
   receipts; exclude its completed work from the remaining full plan.
4. Gate remaining builds, fixtures, API/DocC, Apple selected-module compilation and
   exports behind that platform's canary. No Linux-to-macOS dependency or global
   cancellation on a single platform failure. Use gated waves and bounded in-flight
   work: matrix fail-fast only cancels siblings in that matrix, not other jobs.
5. Use an explicit expected-coverage manifest to aggregate canary, remaining builds,
   suite groups and native/shared gates. Full certification requires scope=full,
   exact revision and complete current execution/approved producer evidence.
6. Make the final job's displayed check name scope-dependent. Only validated full
   mode emits the exact `Offline certification passed` name; scoped runs emit a
   distinct diagnostic/preflight name, including for failed or skipped aggregation.
   The full-named check itself verifies scope=full and complete expected coverage.
   A diagnostic may succeed in its own scope without creating a successful, skipped
   or failed full-named check that could supersede an existing required check on
   the same SHA. Verify release discovery and branch-protection behavior before
   rollout; a partial run alone must leave full qualification unsatisfied.

Exit: helper/maintenance failure prevents native expansion; wrong-source/path,
corrupt archive, empty discovery and hung canary stop only their platform's broad
work. Valid canary work is counted once; focused diagnostic replays remain separate.
Same-branch diagnostics neither cancel full execution nor emit its check context.
Partial/failed/cancelled/missing coverage cannot qualify release or source exports.
Both platform groups remain visible.

## Phase 7 — Group complete suites and right-size resources

Files: [native_jobs.py](../../../Tools/ci/native_jobs.py),
[native-platform.yml](../../../.github/workflows/native-platform.yml), and planner tests.

- Start with four deterministic root-suite groups per platform, one consumer group,
  and separate package groups. Balance by retained duration data; use stable names
  and conservative fallback weights for new suites. These are initial settings,
  subject to the measured aggregate runtime budget.
- Restore/discover once per component per group; run each whole suite in its own
  bounded subprocess with `--skip-build --no-parallel` and anchored root-module
  filters. Preserve per-suite logs, selection, exit and test counts. A failed group
  records unexecuted suites explicitly. No silent omission or duplicate root work.
- Reconcile executed leaf identifiers/outcomes against the selected producer
  inventory using structured test events/results. Define the pinned compiler's
  XCTest/Swift Testing and parameterized-case mapping explicitly. Nonempty package
  discovery plus exit 0 and a count is insufficient: wrong-filter, zero-execution,
  missing-leaf and unexpected-skip fault injections must fail. Record genuinely
  permitted platform exclusions in the expected inventory before execution.
- Batch the tiny consumer checks to avoid repeatedly downloading/restoring the same
  multi-gigabyte consumer archive. Split artifacts by example only if batching's
  measured cost remains unacceptable; preserve separate package build directories.
- Keep load diagnostics isolated. Preserve a whole-load-package process confirmation
  until the shared-process Linux failure is understood. Compiler-positive/negative
  fixtures remain compiler jobs requiring expected semantic diagnostics.
- Replace the global build-matrix barrier with explicit component dependencies where
  feasible; tests/audits need their own producer, API needs root/macros/extensions.
  GitHub dynamic `needs` cannot resolve a single matrix member: use explicit
  component jobs/reusable component calls or deliberate waves, not an invalid DAG.
- Initially cap paid builds at two concurrent jobs per platform. Bound runtime
  group concurrency separately in policy. Choose smaller existing runner SKUs for
  lightweight graphs from measured wall time and runner minutes. Do not provision
  new runner pools implicitly. Keep CPU affinity caps and add memory-aware compiler
  admission; a nominal 64-core pool is not a reason to launch 64 compiler processes.

Exit: scheduled/discovered/executed leaf reconciliation equals expected platform
inventory with no duplicates; omitted/empty/failed groups fail full coverage.
Compare measured job
count, setup/restore time, bytes, runner minutes and wall time against Phase 0.
No numerical product-latency qualification is inferred from shared-runner smokes.

## Phase 8 — Reuse verified provisioning

Files: [setup-native action](../../../.github/actions/setup-native/action.yml),
[platform_probe.py](../../../Tools/ci/platform_probe.py), associated tests/workflows.

Split build/compiler prerequisites, runtime/test-consumer prerequisites, and browser
tooling. Node is installed only where needed. Every native consumer still needs
the runtime/compiler required by `swift test --skip-build` and verifies it.

Prefer a pinned verified compiler-installation cache as the first implementation;
use preprovisioned images only if measured cache performance warrants their
separate maintenance/configuration cost. Key caches by toolchain distribution/hash,
OS/architecture, SDK/image compatibility, installer policy and cache schema. A shared
runner group does not share ephemeral installations. Reject corrupt/incompatible
cache hits and fall back to fresh verified installation within the same overall
budget, or fail explicitly. Retain Linux prerequisite/key import, fingerprint and
signature checks. Do not cache credentials or treat build-output caches as trusted
compiled artifacts. Constrain cache trust for PR versus default-branch execution.

Exit: cold and hit paths produce compatible Phase 4 identities; poisoned/stale/
wrong-platform cache fixtures cannot pass; signing remains enabled; savings are
measured without exceeding the planned provisioning allowance.

## Phase 9 — Share documentation compilation and conversion

Files: [documentation.yml](../../../.github/workflows/documentation.yml),
[native-platform.yml](../../../.github/workflows/native-platform.yml),
[build_documentation_site.py](../../../Tools/ci/build_documentation_site.py),
[build_docc.py](../../../Tools/ci/build_docc.py),
[test_documentation_site.py](../../../Tools/ci/test_documentation_site.py), and
[github_release.py](../../../Tools/ci/github_release.py).

1. Produce macOS root/macros/extensions compilations and symbol graphs once in the
   full CI graph. Perform strict API comparison/DocC conversion once and export
   validated archive inputs. Extend site generation to consume those inputs without
   rebuilding or reconverting them; preserve routes, hosting base path and links.
2. Make documentation validation a consumer of those receipts. Prefer reusable
   same-run consumer jobs; retain a manual standalone path that explicitly obtains
   producers when requested. Remove overlapping automatic documentation compilation.
3. Keep Pages upload/deploy separate from read-only qualification. Preserve existing
   publication permissions/environment and trusted-default-branch policy; this task
   does not authorize deploying during implementation. PR/scoped/incomplete/untrusted
   runs cannot publish. If a cross-run publication consumer is required, validate
   original repository/event, exact default-branch source, successful full gate and
   immutable input IDs before using them. Never execute untrusted PR code with
   publication privileges through `workflow_run`.
4. Preserve release eligibility's exact commit and fresh latest-attempt full check.
   Source graphs/DocC success alone are insufficient. Keep historical release and
   validation records intact; update current CI documentation after implementation.

Exit: invocation-count evidence shows one build/graph/conversion per required input
for a full CI+site preparation; rendered-link/base-path checks pass; diagnostic,
failed, fork and wrong-revision receipts cannot trigger publication. Deployment
remains a separately authorized step.

## Phase 10 — Admit spending before work is scheduled

Files: shared scheduling-policy/planner helpers from Phase 0,
[ci.yml](../../../.github/workflows/ci.yml),
[native-platform.yml](../../../.github/workflows/native-platform.yml),
[documentation.yml](../../../.github/workflows/documentation.yml), and tests.

1. Have the exact execution planner produce the cost plan; do not maintain a second
   approximate job list. Include bootstrap/preflight, provisioning, every command,
   diagnostic/cleanup/upload reserves, transport attempts, final aggregation and
   any documentation preparation. Account for billing rounding per runner job.
2. Compute conservative maximum spend as the sum of each permitted job's billed
   maximum minutes × verified applicable runner rate, plus bounded storage/transfer
   charges where applicable and an explicit safety allowance. Concurrent jobs still
   add cost; a concurrency cap does not by itself bound total cost. Missing/unknown
   SKU rates, stale rates, invalid allowances or excess estimates reject expansion.
3. Validate initial scope on the smallest known-cost bootstrap runner and reserve its
   cost in advance; admission itself is not free. Reevaluate remaining allowance
   before each platform wave. Reserve allowances centrally in the plan: Linux and
   macOS must not each independently spend the same remaining balance. Count retry
   authorizations across attempts; a partial rerun does not reset the allowance.
   Successful preflight outputs survive partial reruns, so add a current-attempt
   admission guard inside every paid job after minimal checkout and before costly
   provisioning. Start with fixed disjoint platform/job/attempt reservations and a
   policy maximum run attempt; reject attempts outside those reservations. An
   adaptive shared allowance would instead require an atomic persistent ledger.
   Budget startup/checkout even for a job rejected at entry. No upstream-only guard
   may authorize unlimited later consumer reruns from stale successful outputs.
4. Change triggers to PR validation plus default-branch pushes and explicit manual
   runs. Add release-branch pushes only for actual maintained branches. Eliminate
   duplicate branch-push/PR jobs and default-branch documentation recompilation.
   Retain full exact-source certification after integration; PR and merged commits
   can differ and must not borrow each other's qualification.
5. Expose plan/allowance, maximum and observed runner minutes by SKU, queue/setup,
   archive transfer, command results, remaining coverage and failure classification
   in retained JSON and the step summary. Actual billing is reconciled separately;
   never label the local estimate an invoice or exact provider-enforced dollar cap.
6. Prepare a repository-scoped GitHub stop-usage budget and threshold alerts as an
   operator checklist with a concrete selected amount, affected runner SKUs, scope,
   billing-cycle behavior and complete read-back. Changing settings needs explicit
   authorization. GitHub's budget is a backstop, not an immediate exact per-run
   cutoff; document provider reporting/first-cycle overrun limitations.

Exit: unknown-rate, stale-rate, over-budget, duplicate-trigger and rerun-budget
fixtures reject paid expansion; independent platform reservations cannot overspend
the shared allowance; summaries reconcile observed execution and stored receipts.
Partial consumer reruns must recheck their current attempt, cannot reset allowance,
and cannot bypass admission by retaining successful earlier preflight outputs.
Operator settings remain explicitly pending until actually authorized and verified.

## Phase 11 — Qualify the final revision and roll out

1. Finish local helper/workflow/docs checks and independent review. Re-read exact
   HEAD/dirty state and regenerate plans/coverage/cost from that revision. Check the
   pure planning path before any paid native work. Record every tested revision.
2. On both native platforms, prove real producer → archive → fresh consumer → exact
   discovery → tests. Prove cancellation regressions, full load package and required
   smokes under hard deadlines. Local macOS/helper or synthetic tar tests do not
   substitute for actual hosted Linux/runtime compatibility.
3. In the smallest diagnostic scope, intentionally fail a cheap consumer after a
   successful producer; perform a partial rerun and prove no valid producer rebuild,
   correct earlier-attempt artifact selection and fresh consumer evidence. Do not
   repeat this fault experiment across the full matrix. Scope checks must prevent
   that diagnostic run from becoming full certification.
4. Exercise transient upload recovery and timeout/cleanup failure cases cheaply.
   Injected assertion, corrupt receipt and missing coverage must still fail. Verify
   release tooling refuses a diagnostic/partial run and accepts only the intended
   exact-source fresh full barrier.
5. Admit and execute one full certification at the final implementation commit only
   after the earlier gates pass and paid execution is authorized. Observe terminal
   results, required evidence uploads and both platform/full barriers. A new failure
   returns to the smallest affected scope; never automatically rerun all jobs.
6. Compare Phase 0 and final runner minutes, artifact/setup overhead and wall time.
   Record measured cost changes without promising an unmeasured savings percentage.
   Reconcile Docs/CI.md with actual behavior, phase commits, latest CI/run/artifact
   identities and remaining operator work. Ensure source export requires complete
   per-platform receipts and release still requires complete shared qualification.
7. Check branch-protection/required-check behavior and subsequent ordinarily required
   runs for scope/status regressions. Do not launch extra full runs merely to collect
   observations. Keep any publication or runtime claims separate.

Completion: all required local/native gates, partial-rerun proof and one exact-final-
revision full certification pass with complete evidence within its admitted envelope.
Repository-budget setup is a separate recorded operator subtask; if pending, report
it explicitly rather than claiming that spending protection is fully configured.

## Verification commands and handoff rules

Existing helper entrypoints usable before implementation:

```sh
python3 -m unittest discover -s Tools/ci -p 'test_linux_ci.py'
python3 -m unittest discover -s Tools/ci -p 'test_native_jobs.py'
python3 -m unittest discover -s Tools/ci -p 'test_github_release.py'
python3 -m unittest discover -s Tools/ci -p 'test_*.py'
node --test Browser/DiscordActivityBridge/*.test.mjs
git diff --check
```

Run relevant helper modules during each change; run the complete helper suite at
integration. Run actionlint against changed workflows with the repository's custom
runner configuration; record whether ShellCheck was available. Full helper suites
may contain meaningful subprocess fixtures, so apply finite supervisor/job budgets.

The following command shapes are for already-built tests and must run through the
Phase 1 supervisor. They are not substitutes for a supervised cold compile:

```sh
SWIFTNIO_STRICT=1 swift test --package-path Tools/DiscordKitLoadTests \
  --build-system native --jobs 2 --force-resolved-versions \
  --disable-experimental-prebuilts --skip-build --no-parallel \
  --filter EventHubTimingTests
SWIFTNIO_STRICT=1 swift test --package-path Tools/DiscordKitLoadTests \
  --build-system native --jobs 2 --force-resolved-versions \
  --disable-experimental-prebuilts --skip-build --no-parallel \
  --filter SyntheticCommandTimingRunnerTests
SWIFTNIO_STRICT=1 swift test --build-system native --jobs 2 \
  --force-resolved-versions --disable-experimental-prebuilts \
  --skip-build --no-parallel --filter EventHubTests
```

Before each handoff, record actual source commit/content hash, owner/owned files,
commands and exit results, evidence hashes/locations, next action, remaining budget,
and unresolved claims. Do not list proposed helper flags as already implemented.
Failed or incomplete receipts remain visible; completion is never inferred from a
started command, quiet logs, successful upload, green partial check, or exhausted
allowance.

## Recovery and rollback

- Land supervisor/receipt logic with reviewed compatibility tests before enabling
  new scheduling. Keep schema handling explicit; do not silently accept legacy
  artifacts after narrowing/expanding identity policy.
- For cache/provisioning regressions, fall back to the verified cold path within the
  admitted limit. For artifact incompatibility, explicitly rebuild only the needed
  producer at the exact source revision under a revised admitted scope.
- For scheduling/coverage regressions, stop new platform waves and retain receipts.
  Restore the last reviewed complete coverage definition if necessary, but keep
  the new process limits and spend checks. Do not restore uncontrolled paid fanout.
- For a renewed cancellation hang, preserve stacks and stop at its attempt allowance.
  No source export or complete qualification while required work is unresolved.

## Primary references

- [Original cancelled certification](https://github.com/Aurum-Studios/DiscordKit/actions/runs/43146954720).
- [GitHub partial-rerun semantics](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs): successful producer outputs remain available across partial reruns.
- [Artifact immutability and upload outputs](https://github.com/actions/upload-artifact): use immutable IDs and bounded recovery; do not blindly overwrite selected artifacts.
- [GitHub workflow timeout semantics](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax): outer job limits remain necessary around supervised processes.
- [Swift test time limits](https://developer.apple.com/documentation/testing/limitingexecutiontime) and [cooperative task cancellation](https://docs.swift.org/latest/documentation/swift/task/cancel()/): task cancellation is not a process deadline.
- [Budget configuration](https://docs.github.com/en/billing/how-tos/set-up-budgets) and [budget limitations](https://docs.github.com/en/billing/concepts/budgets-and-alerts): verify scope and stop-usage behavior without promising an exact instantaneous cost cutoff.
