<!--
File: Docs/Tasks/ci-reliability/phase-4/IMPLEMENTATION.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 4: compatibility and provenance receipts

## Execution plan and ownership

Implement receipt version 2 before relaxing attempt equality. The work proceeds
through a strict schema, platform facts, compile/restore/test integration,
controlled failure tests, full local helpers, independent review and scoped commits.
The implementation owner is Codex `/root` on `ci/phase-4-compatibility`, in sibling
`DiscordKit-ci-phase4`, based on `9f26e10c` (the retained Phase 3 handoff). The
original checkout's four planning edits and all earlier worktrees are preserved.
The [source checkpoint](source-preflight.json) records identity and preservation.

The authorized experiment is local Python helper implementation/testing on the
existing macOS ARM64 host, with a 300-second supervisor deadline per full helper
invocation and bounded descendant cleanup. No Swift compilation/test execution,
container mutation, hosted run, workflow change or external write is needed.
Paid jobs/minutes/attempts are **0 / 0 / 0**, spend **USD 0.00**. Automatic test or
build retries are zero. Focused checks follow changed inputs or review findings;
full validation runs after those changes settle.

## Receipt contract

[The schema helper](../../../../Tools/ci/native_receipts.py) owns the v2 contract.
[Native job orchestration](../../../../Tools/ci/native_jobs.py) produces and consumes
it. Three records have distinct responsibilities:

- `compatibility.identity` binds exact commit, tracked-content SHA256, explicit
  SHA256 for every tracked dependency pin, canonical absolute checkout, platform,
  architecture, full compiler version/target, native build engine, build environment
  and required OS/runtime/image/Xcode/SDK facts. `compatibility.build` binds component,
  package/test-package inventory, configurations and actual semantic compiler argv.
  CPU job count is normalized to one because it controls resource use; the actual
  bounded count remains in the execution report. Other command options are exact.
- `producer` retains repository ID/name, workflow ref/SHA, run/job/attempt,
  event/ref/PR trust scope, successful compilation/discovery, inventory digest and
  start/end timestamps. The manifest retains exact inventories, build roots and
  payload seal. Discovery is `not-applicable` only for a compilation component
  without test packages. The external compilation receipt also records the final
  archive digest; that digest cannot appear inside its own archive.
- `consumer` retains its own execution identity and selected producer identity,
  archive digest, artifact identity, verified compatibility, discovery, selected
  component/suite and terminal execution results. A failed command, invalid scope,
  discovery mismatch or final identity mismatch produces a failed terminal consumer
  receipt with error and completed timestamp. Restore snapshots and completed suite
  reports remain separate: `restored.json` and `restored-<component>.json` describe
  admission; `consumer.json` and `commands.json` describe final suite execution.

Hosted provenance requires a complete GitHub identity. Partial hosted environments
cannot fall back to local scope. Only independent job ID may differ between producer
and consumer; repository/workflow/event/ref/run/attempt must match exactly. Phase 4
**does not enable earlier-attempt selection**. Version 1, unknown schema fields,
ambiguous JSON keys, malformed identities and failed producer stages require
regeneration; there is no permissive legacy path. Required compatibility values use
canonical JSON comparisons, preserving distinctions such as boolean, integer and
floating-point values at restore, post-compile and post-test boundaries.

`--artifact-id` records an explicit positive immutable GitHub artifact ID when a
caller supplies one. Its source is marked `caller-supplied`; Phase 4 does not claim
API authentication or discovery of that ID. Existing callers lacking a resolver
record `local:sha256:<digest>` with `local-content-address` provenance. Phase 5 owns
remote immutable-artifact resolution, authenticated transfer and partial reruns.

## Exact and informational platform facts

[Platform collection](../../../../Tools/ci/platform_probe.py) uses supervised metadata
queries, inside the caller's aggregate deadline when integrated with native jobs.
Every field under `exact` requires equality; no compatible-version range is inferred:

| Exact input | Policy |
| --- | --- |
| OS | System, kernel release/version; Ubuntu 24.04 distro and full libc identity, macOS product/build version, or Windows UCRT version |
| Compiler/runtime | Full Swift 6.4.1 version, target-info object, target triple and runtime paths |
| Image | Exact `ImageOS` and `ImageVersion`; both required on GitHub; explicit unmanaged identity locally |
| macOS | Active developer directory, Xcode version/build, SDK path/version/build and SDK/developer-directory overrides |
| Build environment | Explicit allowlist of Swift/compiler/linker/SDK/package-lookup overrides and strict NIO setting |

Image release URL, runner name/environment and Python version are informational
and excluded from compatibility comparisons. They remain in probe/command reports.
Unsupported or unavailable required metadata fails closed. A read-only host check
caught an unsupported `sw_vers -plist` query during development; the final collector
uses supported `-productVersion` and `-buildVersion` queries, covered by a regression.
The local system compiler is not the pinned hosted compiler, so read-only metadata
availability does not qualify native Swift 6.4.1 or any cross-runner round trip.

## Archive and inventory boundaries

Restore validates the complete payload seal and all members before extraction.
Permissions, executable bytes, internal links and resource files remain bound by
the seal. It rejects duplicate/aliased paths, special files, absolute or escaping
members/links, link ancestors created by the archive, existing symlink ancestors,
dangling hardlink targets and overwrites. This closes a preexisting link-based
bypass of the overwrite check while preserving valid internal bundle links.
Each expected package must have a nonempty, canonical, unique module/leaf inventory;
consumers rediscover the complete package and require exact equality before tests.
Per-component restore receipts and identity directories preserve all three producers
when the existing API caller restores root/macros/extensions into one evidence folder.

## Validation and handoff

[Validation](validation.json) retains commands, test counts, input hashes and process
receipts. [Review](review.json) records resolved findings and final independent review.
A [retained red regression](exact-types-red.log) proves that Python's loose equality
could accept a changed required JSON type at the final identity boundary; the final
checks use canonical digest comparison and pass the same regression. All full helper
results and artifact hashes are retained, including assertion/timeout/failure tests.

This phase's exit is local helper acceptance of compatibility and producer/consumer
contracts. It supplies no native Linux/macOS compiler qualification, hosted paid
execution, remote artifact-ID authentication, partial-rerun proof, full certification,
release, deployment or live Discord claim. Phase 3's native x64 gate remains open.
Phase 5 can build immutable transfer recovery against these contracts when authorized.
