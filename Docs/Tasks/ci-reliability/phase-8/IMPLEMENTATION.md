<!--
File: Docs/Tasks/ci-reliability/phase-8/IMPLEMENTATION.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 8: reusable verified provisioning

Owner Codex `/root`, branch `ci/phase-8-provisioning`, sibling checkout
`DiscordKit-ci-phase8`, base Phase 7 handoff
`06b2efb14332de764492292eae6380c26224112a`.
This document records the local execution plan and implemented contracts.
Independent review and local helper validation passed; the retained
[validation](validation.json) and [review](review.json) record their precise scope.

## Execution plan and allowance

1. Preserve the original checkout and existing worktrees. Keep workflow/planner
   integration under one owner; delegate the provisioning helper and independent
   review through explicit file ownership.
2. Separate compiler/build prerequisites, native runtime/test-consumer
   prerequisites and browser tooling. Install Node only for actual Node consumers.
   A native runtime consumer still requires the pinned compiler/runtime used by
   `swift test --skip-build` and verifies the actual installation.
3. Reuse authenticated original Swift distribution payloads using exact cache
   identities for distribution/hash, OS/architecture, SDK/image compatibility,
   installer policy and cache schema. Verify and freshly install on every hit;
   shared runner groups alone do not preserve installations between ephemeral
   runners.
4. Validate cache content before use, reject poison/stale/wrong-platform hits,
   and fail explicitly on an invalid hit. Preserve Linux prerequisites,
   signing-key import, trusted
   fingerprint and enabled signature verification. Cache no credentials or build
   outputs. Constrain writes and reuse by workflow source/event trust.
5. Prove local cache-state, profile, trust, deadline and identity contracts using
   deterministic helper faults, workflow lint and the existing helper suites.
   Obtain independent review, retain source/check hashes and commit this phase
   locally. Native cold/hit qualification and measured savings remain hosted gates.

Local Python/Node helpers, official distribution metadata/signature inspection
and workflow lint only. Native
compilation and native test-process attempts **0 / 0**; paid
jobs/minutes/workflow attempts **0 / 0 / 0**, USD **0.00**. No push, dispatch,
remote cache or artifact write, runner/billing change, publication, deployment,
runtime Start or live Discord access. No automatic compiler/assertion/test retry.
The existing compiler-free rollout containment and independent human maintenance
gate remain; Phase 10 must implement reviewed spend admission before expansion.
Phase 3 native x64 acceptance remains open.

## Implemented provisioning and trust contracts

[The versioned provisioning policy](../../../../Tools/ci/provisioning-policy.v1.json)
pins official Swift 6.4.1 distribution URLs and SHA256 values, accepted signing
identities, installer paths, cache schema and a 600-second provisioning allowance.
[native_provisioning.py](../../../../Tools/ci/native_provisioning.py) caches only
the original distribution payload plus its identity JSON and, for Linux, its
detached upstream signature. Installed trees, signing-key state, credentials and
project build outputs never enter this cache. There is one exact image/platform/
SDK/policy key and no prefix restore. The policy includes the payload hash and
installer policy, so changing either changes the key.

Every cold payload and cache hit is SHA256-checked and upstream-signature-checked
before extraction, installation or execution. Linux imports the official
compressed Swift key bundle into a fresh uncached GPG home, checks exact key
fingerprints and accepts only the policy-pinned release signer. macOS requires
the exact Swift Open Source Apple installer signer and Apple notarization.
An invalid cached identity, hash, signature, file set or platform fails explicitly;
it cannot acquire a second allowance or silently trigger another installation
attempt. A miss downloads the official pinned payload and follows the same
verification path.

Linux freshly extracts into the deterministic policy-owned installation location;
macOS freshly installs the official package into the user's Toolchains location.
Actual Swift version, target information and active executable path are observed
before publishing PATH or the successful provisioning receipt. Cache content
cannot supply an installed compiler tree or substitute an older prefix match.

[setup-native](../../../../.github/actions/setup-native/action.yml) offers `build`
and `runtime` prerequisite profiles. Both install the complete pinned compiler:
`swift test --skip-build` may compile SwiftPM manifests. Linux runtime retains
the CRT/header dependencies `libc6-dev`, `libgcc-13-dev` and `libstdc++-13-dev`;
build adds compilation/development prerequisites. Browser preflight and the
artifact SDK own their Node installations; setup-native no longer installs Node
for every native job. Windows caching remains disabled and its existing pinned
installer path remains outside this phase's Linux/macOS qualification.

Only successful default-branch `push` and `workflow_dispatch` executions can save
an exact cache entry. Pull requests, `pull_request_target`, tags, other branches
and missing trust metadata cannot publish entries. Restores use GitHub's branch
visibility plus exact keys and always authenticate the payload independently.
Cache visibility is not compiled-artifact or source trust.

Preparation starts the shared 600-second allowance before Python/prerequisite
installation and cache transport. Every workflow setup-native caller has a
10-minute enclosing step timeout, including restore, verification, installation,
explicit cache save and provisioning evidence upload. Supervised commands share
the remaining allowance and reserve cleanup; transport does not gain a separate
full budget. The explicit save avoids a deferred cache post-step outside this
boundary. Provisioning evidence uses the existing 14-day diagnostic retention;
Phase 10 must price that transfer/storage and the cold installation reserve.

## Acceptance strategy

Provisioning cache content is untrusted input. An exact key selects a candidate,
then verification admits it. Tests must demonstrate that corrupt bytes, stale
schema/policy, wrong distribution/architecture/image/SDK and missing verification
facts cannot become an accepted compiler. A rejected hit must not publish its
PATH, verification state or compatibility identity. Cold installation, verified
hit and poisoned-hit failure retain explicit outcomes and bounded failure data.
The same overall allowance covers prerequisites, cache transport, verification,
installation and cleanup; a cache failure does not create another full allowance.

Cold and hit paths must produce the same Phase 4 exact compatibility identity on
the same platform/image. Profile-specific provisioning metadata is diagnostic;
it must not silently relax the conservative compiler/runtime/SDK comparison in
[platform_probe.py](../../../../Tools/ci/platform_probe.py). Its optional
provisioning provenance verifies the successful receipt, current policy/signature,
active PATH/compiler metadata and current image/SDK. That provenance remains
informational, leaving Phase 4 exact compatibility unchanged. Producers and
native consumers continue to verify actual Swift 6.4.1 and target/runtime facts
before compiled work is admitted. Source trust, signing verification and compiled
artifact trust remain separate checks.

Local fixtures can establish control flow and rejection behavior without
installing an actual native compiler. They do not prove a genuine GitHub cache
round trip, hosted image compatibility, macOS installer behavior, Linux package
capacity or real Swift compilation/execution. Evidence must distinguish those
pending platform checks from local helper acceptance.

## Measurement baseline and hosted protocol

[Phase 7 scheduling comparison](../phase-7/scheduling-comparison.json) retains the
historical baseline and the grouped planned topology. Offline certification run
`43146954720` contains **152 whole-workflow jobs**, including **24 native build
jobs and 101 native test jobs**. Phase 7 plans **24 build jobs and 28 grouped test
jobs**, or **52 versus 125 comparable native build/test jobs**. Auxiliary jobs and
the separate documentation workflow are outside that native-count comparison.
Phase 7 itself has no measured post-change hosted run.

The historical certification aggregate records 8,444 setup seconds, 17 separate
restore seconds, 5,800 mixed restore/discovery/test seconds and 21,441 known runner
seconds, or 430 summed per-job-rounded runner minutes. Retained stored archives
total 10,743,621,569 bytes; completed observed download archives cover only a
3,191,057,466-byte subset. None of these aggregates isolates Swift provisioning.
Workflow wall time, total downloaded bytes and wire bytes are unavailable.
The separate documentation run `43146954594` has seven jobs, 344 setup seconds,
16 separate restore seconds, nine mixed test/restore seconds and 982 known runner
seconds, or 21 rounded minutes. Do not blend its totals into certification.

The exact `Run ./.github/actions/setup-native` step is separately enumerable in
[the retained cost detail](../baseline/cost-summary.json): certification has 136
observations totaling 7,701 seconds. Its policy-mapped runner populations are 14
`linux_64_core` jobs / 618 seconds, 53 `linux_8_core` jobs / 2,781 seconds and 69
`macos_xl` jobs / 4,302 seconds. Documentation has five `macos_xl` observations
totaling 308 seconds. These second-resolution composite-step observations include
Python, prerequisites, keys, Swift and Node. They are useful matched-profile
setup baselines, not isolated compiler installation or billing-verified SKU data.

During Phase 11, after explicit hosted authorization and Phase 10 admission,
measure a bounded cold path, exact verified hit and poisoned-hit failure on the same runner SKU,
OS/image/SDK, source, profile and cache-policy identity. Specify each paid job,
attempt ceiling and complete provisioning reserve before dispatch. Retain:

- Repository/source/workflow/run/job/attempt, event trust, platform/SKU and exact
  compiler/image/SDK/cache-policy identities.
- Cache outcome and trusted-content verification result; distinct cache restore,
  verification, prerequisite, installation and final compiler/runtime validation
  elapsed times, plus the total provisioning elapsed time.
- Known cached archive/download sizes and transfer elapsed times with explicit
  gaps. Archive size is not wire traffic. Missing counters remain unavailable.
- Exact Phase 4 compatibility facts from cold and hit, fresh platform probe
  compilation/execution, and actual consumer skip-build behavior.
- Queue/setup, per-job runner seconds and billing rounding, whole-workflow wall
  time where observable, and total admitted/observed spend including failed hits,
  cache transfer/storage and diagnostic/cleanup reserves.

Report matched cold-versus-hit provisioning deltas separately from Phase 7's
group-count changes and from the historical whole-workflow aggregates. Claim
savings only for actually observed comparable populations; a cache hit count or
planned job reduction is insufficient. Preprovisioned images require a separate
measured justification and maintenance decision. This phase provisions no new
runner pool or custom image.

## Review and validation status

Two independent reviewers checked cache authentication/activation, profiles,
provenance, source trust and enclosing deadlines. Their findings repaired the
macOS package suffix, isolated GPG key import, shell continuation, symbolic-link
root handling, SDK overrides and a cross-platform evidence-name collision.
The last issue now has a regression covering reusable static and matrix jobs.
No blocking findings remain; [review.json](review.json) retains scope and limits.

[validation.json](validation.json) records **891 passed / six existing Linux-only
skips** across seven Python/browser groups. The final CI group discovered 484
cases and passed 478; its 22 provisioning faults, six actual workflow-boundary
tests and 19 platform-probe cases are included in that count. All seven workflows
passed actionlint; source policy, 32 displayed DocC listings, Python/embedded
syntax, JSON, links and whitespace checks passed.

The complete official macOS package also passed production `prepare` and
`verify_distribution` with real supervised SDK/pkgutil commands, authenticated
SHA256 and signer. [The retained local check](checks/real-macos-payload/check.json)
uses explicit local image placeholders and performs no installation. Both full
official payloads were authenticated before their pins entered policy; [upstream
provenance](upstream/SOURCES.json) includes macOS notarization and isolated real
GPG verification of the Linux archive. That container ran under emulation and
supplies signature proof only. No installer, native test/compilation, hosted
cache round trip or savings qualification occurred. Their Phase 11 gates remain
open. Phase 9 is the next implementation stage when authorized.
