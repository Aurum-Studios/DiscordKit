<!--
File: Docs/Tasks/ci-reliability/phase-5/IMPLEMENTATION.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 5: immutable transfer recovery and partial reruns

## Execution plan and ownership

Owner Codex `/root` works on `ci/phase-5-transfer` in sibling
`DiscordKit-ci-phase5`, based on Phase 4 handoff `b190a963`.
The original checkout's planning edits and all earlier phase worktrees remain
preserved. [Source preflight](source-preflight.json) binds that boundary.

Implement and test three connected contracts: an explicit component index built
from authenticated immutable GitHub artifacts and successful producer jobs;
bounded transfer recovery that cannot invoke compilation or tests; and native
consumption of an earlier successful producer only with a verified selection.
Integrate those contracts into the existing reusable native workflow, retain its
independent platform pipelines, then run helper and workflow checks, independent
review, and scoped commits. Documentation-site consolidation remains Phase 9.

The authorized experiment uses local Python/Node helper tests and controlled
transport fixtures on the existing macOS ARM64 host. Each full helper invocation
has a 300-second supervised deadline with bounded descendant cleanup. No native
compilation/test execution or hosted job is needed. Paid jobs/minutes/attempts
are **0 / 0 / 0**, spend **USD 0.00**. Build/test/assertion automatic retries are
zero. No push, workflow dispatch, remote artifact upload, runner/billing mutation,
publication, deployment or live Discord operation is authorized or performed.

## Retention and qualification boundary

Keep the existing two-day compiled-artifact retention and fourteen-day diagnostic
retention. The initial supported partial-rerun window is at most 48 hours after
the producer upload and always ends at the API's actual expiry. This keeps the
existing retention duration. New sidecars and immutable retry candidates can add
stored bytes; their actual byte-days must enter Phase 10 admission before paid
execution. No remote artifact bytes are uploaded in this local phase. Expiry or missing
producer evidence requires explicitly scheduling a fresh producer; a consumer
cannot rebuild or select another revision. GitHub's broader rerun window does
not extend artifact availability.

Local fault injection can establish bounded transport behavior and receipt
admission. A real separate-runner round trip, failed-job rerun and complete fresh
hosted barrier remain Phase 11 acceptance work. Phase 3 native x64 acceptance
also remains open. No local helper result closes those gates.

## Implementation contracts

[The index](../../../../Tools/ci/artifact_index.py) reconciles an explicit complete
build matrix in its own job, rather than collecting artifact mappings from matrix
outputs. It verifies run/repository/workflow/event provenance, attempt-specific
successful producer jobs, immutable artifact IDs/API digests and the small sealed
producer sidecars. The selected latest successful producer may be an earlier
attempt of this run. Multiple distinct candidates in that attempt are ambiguous;
expiry, missing bytes or corruption in the selected attempt fails immediately.
An explicitly scheduled newer successful producer supersedes stale older attempts.

Every consumer independently resolves its required components in its current job.
The index retains its exact resolver execution and source commit. The native
helper's `--selection` admission checks the complete index, exact archive SHA256
and embedded metadata before extraction, then checks the full live Phase 4
compatibility and discovery. Consumer receipts retain immutable ID/API digest,
archive/index digests, full selected producer and this consumer's attempt. There
is no caller-supplied artifact-ID bypass or legacy earlier-attempt fallback.
No test or restore path can invoke compilation in response to missing artifacts.

[Transport](../../../../Tools/ci/artifact_transfer.py) prepares one ZIP on disk,
streams downloads to disk and verifies API SHA256 before safe no-overwrite ZIP
extraction. Native tar payloads still undergo their complete existing validation.
Attempts use distinct `-t1`/`-t2`/`-t3` immutable names; matching completed uploads
can be reconciled by exact name and digest, or unchanged bytes go to the next
candidate. No referenced artifact is overwritten or deleted. Permanent failures
(authorization, malformed inputs, unsafe members and bad digests) do not retry.
Terminal transfer/resolution receipts record attempts, limits and incomplete
evidence recovery instructions. Directory evidence is packaged in tarballs.

The [Node adapter](../../../../Tools/ci/artifact-sdk/README.md) pins official SDK
dependencies and disables their internal RPC/Blob retries. A local JavaScript
action receives the runner's runtime artifact credentials and passes them only
to its transport descendants. A shell-only invocation cannot obtain those
credentials. The actual pinned protocol receives a local HTTP fault test; no
hosted endpoint is mutated. The two current Unix callers retain process and wall
deadlines; Windows remains outside this phase's qualification scope.

The reusable native workflow requires all final uploads to succeed, re-resolves
the complete expected producer index in the latest platform barrier, and retains
the existing full certification dependency gate. Earlier successful job outputs
can survive a partial rerun, while every rerun consumer selects its own authenticated
producer evidence. The independent documentation/Pages workflow retains its current transport path;
its helper job also installs the pinned SDK so protocol tests execute. Its
compile/conversion consolidation belongs to Phase 9.

## Transfer and enclosing execution bounds

The resolver has one shared 420-second aggregate across all metadata/receipt
requests, with three transient attempts of at most 120 seconds. A producer upload
shares one 420-second aggregate for payload and sidecar; evidence has a separate
420-second operation. SDK installation is supervised for 180 seconds with package
fetch retries disabled. Native compile/test limits are unchanged.

| Job | Enclosing minutes | Added transfer capacity |
| --- | --- | --- |
| Platform / plan | 30 / 25 | One upload, SDK installation and setup reserve |
| Build | 150 | Payload + sidecar (420 s), diagnostics (420 s), SDK installation; compile budget unchanged |
| Resolve / complete | 15 / 15 | Complete 420 s index plus checkout/Python reserve |
| Suite / audit | 75 / 45 | Resolve + one download + evidence (1,260 s), SDK installation |
| Public API / DocC | 165 | Resolve + three downloads + two uploads (2,520 s), SDK installation |
| Apple compilation / source export | 45 / 25 | One upload, SDK installation and existing native/setup reserve |

These limits are preparation bounds, not measured runner capacity or spend
authorization. The shared scheduling policy's initial 180-second upload reserve
remains a historical placeholder; this phase explicitly budgets the actual
operations above. Phase 6/10 scheduling and spend admission must consume these
larger enclosing bounds before any paid expansion. Retention duration is unchanged. Sidecar/retry
storage overhead remains an explicit Phase 10 accounting input; no hosted storage
usage or charge is claimed from local fixtures.

Primary behavior references: [GitHub rerun semantics](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs),
[immutable artifact IDs/digests](https://docs.github.com/en/rest/actions/artifacts),
and [attempt-specific jobs](https://docs.github.com/en/rest/actions/workflow-jobs).

## Validation and handoff

[Final validation](validation.json) binds 23 source/test/workflow/dependency inputs
and the supervised commands. The full CI helper run discovered 320 tests:
314 passed, six existing Linux-only session tests skipped on macOS, zero failed.
This includes 16 index tests, 25 transport tests and five composite/workflow tests.
The installed pinned SDK executes localhost protocol tests, including two Azure
blocks, ordered block commit, Create/Finalize, unchanged ZIP bytes and provenance;
HTTP authorization/service faults include both JSON and HTML bodies. It also
tests first-upload recovery, ambiguous completion, corruption/expiry/wrong-source,
partial failed-test rerun without compilation, cancellation and safe extraction.

Workflow actionlint v1.7.12, Node worker/launcher syntax, scheduling-policy
validation, Python syntax, Markdown links and diff checks passed.
[Independent review](review.json) has no remaining blockers. It records resolved
runtime credential, HTTP classification, SDK constructor, pagination, streaming,
deadline and cancellation findings. The first full helper run exposed a scheduling
test still tied to the previous enclosing job limit; its [original failed log](helpers-initial.log)
is retained. The test now rejects exhaustion of the actual enclosing budget while
preserving the unchanged 5,400-second consumer compute-policy assertion.

The isolated implementation commit will contain these inputs and receipts. A
documentation-only follow-up records its actual Git identity and verifies every
input/artifact against the committed blobs. Next authorized work is Phase 6
preflight/canary integration. The separate Phase 3 native x64 acceptance and
Phase 11 hosted immutable round trip, failed-job rerun, expiry/regeneration and
fresh full barrier proof remain open. No workflow was dispatched or published;
the existing push/PR triggers remain. Phase 6/10 containment and paid admission
are required before publishing intermediate work or enabling expansion.
