<!-- copyright:begin
File: Docs/Continuous-Integration.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# TeamCity build chains and parallel testing

Use [Aurum Studios TeamCity](https://ci.aurum-studios.com) for CI and
[Aurum Studios YouTrack](https://issues.aurum-studios.com) for issue tracking.
Follow [Testing.md](Testing.md) for test behavior and evidence and
[Dependencies.md](Dependencies.md) for pinned build variants and caches. Use
the selected language guidance to configure the actual toolchain and commands.

## Connect a repository

1. In TeamCity, use a project with a Git VCS root pointing to the actual
   authorized repository. A GitHub remote is suitable for source checkout.
   Set the default branch and branch specification to
   the branches intended for validation. Provide checkout credentials in
   TeamCity and restrict them to the project and repository.
2. Enable **Versioned Settings** using that VCS root and the checked-in Kotlin
   DSL in `.teamcity`. Import the existing repository settings in portable
   (relative ID) format. The starter uses the settings VCS root for agent-side
   checkout. Check for import errors and verify the compatible agents and branch
   selection before the first build. Use the server's own DSL reference to
   confirm compatibility with the starter's `2025.11` DSL. Keep
   `.teamcity/pom.xml` with the settings. TeamCity's hosted settings generator
   uses it to resolve and run the DSL compiler against the server's plugin API.
3. Assign the project's agent pools and qualify the agents against the starter
   requirements below. Use a manual run to confirm the revision and check
   results. Product build and test commands remain unconfigured until the
   project chooses a stack.
4. For issue links, configure the TeamCity project's **Issue Trackers**
   connection to `https://issues.aurum-studios.com`. Use a scoped YouTrack token
   stored in the server connection and the project's verified YouTrack key.
   Verify that a commit mentioning a real issue ID resolves in TeamCity under
   the intended access. Project issue tracking still uses the
   [YouTrack setup guide](YouTrack/README.md).

The starter checks copyright drift and candidate whitespace. YouTrack hosts
published project guidance and task articles through the separately authorized
[documentation workflow](Publishing-Documentation.md).
See JetBrains' [versioned settings reference](https://www.jetbrains.com/help/teamcity/storing-project-settings-in-version-control.html)
and [YouTrack connection guide](https://www.jetbrains.com/help/teamcity/youtrack.html).

## Run platform, build and test phases

Organize product validation into three ordered phases, with independent jobs
inside each phase. Finish all required platform qualifications before admitting
build sections. Finish every required build section before admitting ordinary
test jobs. Reconcile all phases through one required aggregate afterward.

| Phase | Independent work | Required predecessor |
| --- | --- | --- |
| Platform | One bounded qualification per required execution contract | Candidate selection |
| Build | One producer per independently buildable component and compatible variant | All required platform qualifications |
| Test | Disjoint suites/shards and independent helper, fixture and audit checks | All required build producers |
| Aggregate | Reconcile required outcomes, artifacts and complete receipts | All required platform, build and test jobs |

Platform jobs verify the actual environment and perform representative compile
and smoke execution. Build jobs compile production products, test executables and
other required execution inputs without running the ordinary suites. Test jobs
consume those products and execute their assigned work without rebuilding them.
Keep admission smoke tests distinct from ordinary test assignments; qualification
does not run the full suite early or repeat it for every build component.

Split build sections at actual component/build-system boundaries. Several
components can build concurrently on the same required platform when they own
separate mutable output and budgets. If component B consumes generated output
from A, represent that build dependency explicitly or keep them in one producer.
Do not invent sibling dependencies for unrelated components. Include specialized
SDK/device compilation in the build phase so it also finishes before tests start.

Give independent suites, tooling, compiler fixtures and audits separate test
jobs or matrix assignments. They all start after the build barrier and may
overlap; one test family must not wait for another unless it consumes that
family's output. A compiler fixture intentionally testing compilation may invoke
the compiler during its test job. A framework without portable prebuilt test
products needs a documented supported exception; do not claim compile-once reuse
where execution actually rebuilds. Keep packaging and delivery prerequisites
explicit after their required checks.

Use [TeamCity snapshot dependencies](https://www.jetbrains.com/help/teamcity/configuring-dependencies.html)
with revision synchronization to enforce the barriers. Give each build producer
dependencies on all required platform configurations and give each test family
dependencies on all required build configurations. Block dependent phase work
when a required predecessor fails, fails to start or is cancelled. Independent
siblings remain eligible to run and report their own outcomes. For test inputs,
select [artifacts from the same chain](https://www.jetbrains.com/help/teamcity/artifact-dependencies.html)
from the required producers.

The example shows a dependency list for each configuration. Expand each required
platform or variant into its own configuration and include it in every
applicable dependency list.

```text
Platforms      <- candidate selection (one configuration per execution contract)
Build native   <- all platform configurations
Build tools    <- all platform configurations
Test native    <- Build native, Build tools (artifact from Build native)
Test tools     <- Build native, Build tools (artifact from Build tools)
Complete       <- all platform, build and test configurations
```

Put the VCS trigger on the terminal configuration for a required chain. If the
terminal configuration must react to changes detected only by upstream
configurations, enable triggering on snapshot dependency changes. Add separate
triggers only for independently useful work. Keep the manual full-chain path
available for a pinned source revision. See
[TeamCity chain triggers](https://www.jetbrains.com/help/teamcity/run-build-chains.html).

## Separate coverage from capacity

Define each required execution contract: OS/image, architecture, toolchain/SDK,
runtime/ABI and any relevant device, backend or feature variant. Give equivalent
runners a common pool that accepts compatible independent work. Different CPU
sizes add capacity, not a coverage axis. Use one required lane per execution
contract for the current candidate, regardless of core count, configuration name
or number of interchangeable instances. Do not multiply the platform matrix by
8/64/96-core tiers or repeat the complete suite for each pool member. Keep distinct
contracts as explicit required lanes. Reserve specialized or expensive pools for
work that needs their resources, while routing ordinary compatible work through
shared capacity. Do not impose another product's runner names or pool sizes.

For each distinct contract, run one real qualification job before its dependent
pool fan-out: verify observed identity, tool availability, dependency restore,
representative compilation and test execution. Exercise the test framework's
parallel and serialized execution rules when relying on them. Retain a receipt
and block dependent work on failure. Each admitted worker must still verify its
actual OS, architecture, tools and artifact compatibility; qualifying one runner
does not certify every subsequently assigned machine. Requalify when relevant
images, tools, recipes or platform requirements change.

Qualification is a bounded platform phase, not an additional full build-and-test
run. Assign every required test once within that contract, including tests used
for admission. If a smoke test is selected from the ordinary inventory, record
its qualification receipt and exclude it from later assignments. Seal those
assignments before test fan-out. Independent build producers start after all
required qualifications pass; disjoint test partitions start after all required
builds pass. A second required architecture, SDK or runtime variant still needs
its own lane. Each required platform must complete its own work; a Linux result
cannot qualify Windows or macOS merely because its pool has more cores.

TeamCity agent pools govern which agents are available to a project. Build
configuration requirements select compatible agents from those pools. Cloud
profile limits, agent availability and licensing control how many eligible
builds can run at once. Agent CPU, memory and disk determine how much work each
build can accept. Check these constraints separately and measure actual
admission. See [agent pools](https://www.jetbrains.com/help/teamcity/configuring-agent-pools.html)
and [agent requirements](https://www.jetbrains.com/help/teamcity/configuring-agent-requirements.html).

## Select compatible agents during initial CI setup

Use the project's authorized pools and inspect agent compatibility for every
required configuration. Match the actual OS, architecture, image, SDK and
resource needs. Use capabilities reported by compatible agents so any qualified
member can accept the build. Configure explicit requirements for expensive
compilation and large suites when they need more resources than general work.
Reserve general capacity for lint, formatting, copyright, metadata, packaging,
gates, routine documentation and small tests.

The starter uses agent-side checkout and requires a Linux agent with Git and
Python 3.9 or newer available as `python3`. Set `aurum.ci.python=true` in each
qualifying agent's `conf/buildAgent.properties`.

Check the startup logs and agent parameters, then verify the compatibility list.
A configuration with no compatible agents remains a setup issue until its
actual requirements can be met. Assign pools and agents for the actual project.

If TeamCity detects Python 3 on a Linux agent that already has Git, set the
project's Kotlin DSL context parameter `ci.useDetectedPython=true` to run
**Repository checks** with that detected interpreter.

For product-specific work, keep required execution contracts explicit. A Linux
x64 build and a Windows x64 build need distinct qualifications if both are
required. Two Linux x64 agents meeting the same contract add capacity for one
lane. Validate a changed image, SDK or agent capability before relying on it.

## Plan complete work before distributing it

Discover the authoritative inventory of targets, suites and tooling lanes for
the candidate, then seal a deterministic assignment before starting workers.
Each required work item belongs to exactly one shard within its execution
contract. Repeating tests on distinct required platforms is intentional coverage;
repeating an entire compatible suite on every pool member wastes capacity.

Use stable work IDs and disjoint assignments. Check that their union equals the
required inventory and their intersections are empty. Reject unknown targets,
duplicates, missing items and unintended empty shards. New tests must enter the
inventory automatically or fail a reviewed discovery check. A zero-test filter
must not silently qualify required work. Preserve framework isolation and suite
serialization contracts when choosing partition boundaries; balance using
observed duration and memory without weakening assertions or excluding slow tests.

For example, two compatible workers can own `{A, C}` and `{B, D}` from an
inventory `{A, B, C, D}`. Another required architecture needs its own complete
assignment and qualification. Adding a third compatible worker redistributes
the first inventory; it does not require three full copies of the suite.

## Compile once for each compatible variant

When the build system supports it, compile production/test products in each
independent build section once per compatible component, source and build
variant, then distribute immutable executables, runtime dependencies, resources
and discovery metadata to execution workers.
Workers verify the artifact and execute their assignment without independently
rebuilding or resolving a different dependency graph. Keep incompatible OS,
architecture, ABI, toolchain and feature variants separate. If the framework
cannot transport test products safely, document that limitation and use its
supported build/test boundary instead.

Bind execution artifacts and the work plan to source tree, dependency/submodule
revisions, toolchain, build recipe/flags, target variant, discovered inventory,
producer run/attempt and content digests. Verify downloaded bytes before use.
Give each producer a unique artifact identity including its component and
execution contract; concurrent uploads must not overwrite the same artifact.
Preserve executable permissions, resources and required link/layout semantics.
Record stack-specific relocation constraints and compatible checkout paths when
compiled products require them. Test jobs download their declared producer set
and fail on missing or incompatible products rather than silently rebuilding.
Keep mutable output and writable caches separate from sealed products; a worker
must not alter another worker's execution image. Follow the dependency guide for
compatible reusable caches. A cache hit accelerates a build; it does not prove
test success. Routine clean builds must not discard valid dependency caches;
provide an explicit clean path for diagnosis or required clean qualification.

## Budget every level of parallelism

Apply [cache budgets and cleanup](Dependencies.md#cache-budgets-and-cleanup) to
build agent disks as well as local workspaces. Admit work only when existing
managed usage plus all workers' peak additional bytes fits the aggregate ceiling and
leaves the free-space reserve. Count restores, extracted artifacts, build output,
logs and upload staging, including overlapping jobs on persistent agents.
Use bounded retention/tool-supported eviction for persistent caches. Ephemeral
agent teardown does not reclaim separate shared cache/artifact storage. Record
that storage's byte/retention policy separately. Each job cleans owned disposable
scratch on success/failure/cancellation without pruning an active shared cache.

Derive admitted compiler/test width from the process's usable CPUs, affinity,
container/cgroup CPU quotas, available memory or container limit after reserve,
measured per-worker demand and a documented policy ceiling. Use the most
restrictive applicable bound, admit at least one worker only when it fits, and
fail clearly if even one worker cannot run. Validate configurable positive limits
and clamp requests to safe capacity. Unknown or shared capacity calls for a
conservative limit or serialization, with the uncertainty recorded.

Account for all simultaneous work on the same host: TeamCity agents, build jobs,
compiler subprocesses, test processes, framework threads and browsers. Do not
give every nested layer the entire machine. For example, with eight usable CPUs,
12 GiB available memory, a 2 GiB reserve, measured 2 GiB worker demand and a
policy ceiling of six, at most five such workers fit before other concurrent
demand. Two overlapping suites using two workers each consume four slots;
an overlapping compiler or browser must share the remaining budget. The numbers
illustrate admission, not portable defaults.

Apply limits using the actual tools' supported flags and record requested and
admitted widths plus resource observations. Bound build-chain fan-out separately
from within-job fan-out. Let independent lightweight lanes overlap where measured
capacity allows; join them before reallocating their budget to intensive browser
or native work. Preserve deliberately serial timing/resource-sensitive suites.
Increase width using representative measurements, including constrained CPU and
memory conditions; do not relax timeouts or test semantics to mask contention.

Use isolated workspaces, build/output directories, temporary stores, ports and
fixture identities for overlapping work. Share caches only with supported
locking/atomic publication. Bound queue, job, command and aggregate deadlines;
propagate cancellation, stop and join owned child processes, and release resources
before reporting completion. A successful parent exit with unfinished test work
does not qualify the assignment. Never terminate another task's resources.

## Reconcile evidence through one required gate

Emit machine-readable receipts for qualification, compilation and every shard.
Include candidate commit/tree, run and attempt, observed execution contract,
artifact/plan digests, assigned work IDs, discovered and completed tests, outcome,
duration, resource limits and diagnostics locations. Explicitly record retries
and their attempts; preserve failures instead of silently choosing a passing retry.
Check completion and expected test events/counts as supported by the framework;
a zero exit code alone cannot establish complete execution.

Collect bounded logs and receipts on failure as well as success. Use a stable
required TeamCity configuration that depends on every required family. For a
diagnostic aggregate that must execute after a failed or cancelled dependency,
configure snapshot dependency failure handling so it can run with a build
problem, and let the aggregate explicitly reject nonpassing results. Verify its
actual behavior for failed, failed-to-start and cancelled predecessors. Missing,
duplicate, foreign, stale, failed, cancelled, truncated or unexpectedly skipped
required work must fail the gate. Optional and inapplicable work must be
explicitly accounted for by the plan. See
[TeamCity dependency failure handling](https://www.jetbrains.com/help/teamcity/configuring-dependencies.html).

## Validate the current review and merge candidate

Scope the VCS root branch specification and terminal build's trigger to branches
the project accepts for candidate validation. Keep cheap checks available when
expensive validation is deferred. Record deferral as a nonpassing required
result. Request a full validation run when the candidate becomes ready and
validate each subsequent revision. If the repository host provides a review or
merge queue integration, configure its actual branch and event behavior and
verify it with the chosen host.

Record whether a build used the review head, a synthetic merge or another
combined revision. Base movement can change combined behavior. Qualify the actual
combined candidate or use the strict reuse contract below. Scope cancellation to
obsolete candidate builds so unrelated work and shared delivery can continue.
Require the aggregate outcome for the accepted candidate at integration.

## Reuse qualification only with exact provenance

Reuse across runs or after merge is an optimization requiring an implemented,
reviewed verification contract. Match the complete Git tree, pinned dependency
and sibling identities, build settings and recipe, toolchain and target variant.
Verify the authorized source repository and event, successful full required
gate, exact producer run and attempt, and immutable artifact identity and digests.
A matching branch name,
nearby commit, broad cache key or green unrelated run is insufficient. Keep
untrusted review execution separate from privileged publication credentials.

Preserve original evidence bytes and provenance; add an adoption receipt binding
the consumer commit/run to that producer. A new commit with an identical tree may
adopt only under this policy and must not relabel the earlier run as a fresh test.
Different source, dependency, settings or build inputs invalidate affected reuse.
When selection is uncertain or no qualified producer exists, run full validation.
After selecting a producer, missing, corrupt or mismatched evidence fails the
consumer; do not silently substitute another artifact or hide failure with a
different producer. If verified reuse is not implemented, validate in full.

## Measure useful hosted work

Record queue/admission times separately from restore, compile, useful test
execution, artifact transfer and aggregate durations. Compare a representative
baseline and changed run with the same workload and declared environment. Report
wall time, actual overlapping work windows, resource pressure and cost where
available. A larger matrix or higher configured ceiling does not prove speedup.

For queued builds, inspect the VCS trigger and snapshot dependencies, then check
project pool access, incompatible agent reasons, agent authorization and
availability, cloud profile limits and licensing. Retain build, configuration
and assigned agent IDs with timestamps. Keep probes bounded by time and cost
within existing authorization. Escalate unresolved admission with concrete
evidence before changing required validation.

Record local checks, hosted validation of the exact candidate, native platform
execution, artifact adoption, merge, publication and runtime acceptance as
separate facts. A template check proves only the exercised template behavior;
hosted pool capacity and performance require actual hosted evidence.
