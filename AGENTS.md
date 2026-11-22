<!-- copyright:begin
File: AGENTS.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Repository instructions

These instructions apply throughout this repository. Read [the documentation index](Docs/README.md) and the relevant plan before changing behavior.

Read [selected language guidance](Docs/Languages/README.md) for the affected
components before designing, implementing, reviewing or documenting changes.
Consult its **Preferred tools and dependencies** before choosing tools, packages
or source repositories. Record project-specific preferences in those profiles;
preserve explicit instructions and established project choices.

## Company identity

- Follow [the identity contract](Docs/Identity.md) for every authored language,
  package, module, service, storage key and tooling identifier. The company domain
  is `aurum-studios.com`; its exact reverse-domain root is `com.aurum-studios`.
- This allocation is `com.aurum-studios.libraries.discordkit`. Read `.air/project.json` under
  `identity` for its immutable key, UUID and ecosystem spellings. Preserve the
  allocated identity through repository/display-name changes. Use an independent
  company `libraries` allocation for code shared across products.
- Confirm company allocation and final ecosystem limits before publishing names.
  Generation leaves allocation unverified. Use documented language-safe spellings
  where hyphens are illegal, and retain third-party/API-defined identifiers.

## Workflow and ownership

- Inspect current Git status, branch, worktrees, ongoing Git operations, task records and active writers before editing. Preserve unrelated work and staging.
- Use the current Air task's isolated worktree. A new session under that task shares its files; stop the previous writer before replacing it. Do not create a nested checkout simply to refresh context.
- Follow [the worktree lifecycle](Docs/Air-Workflow/worktree-lifecycle.md): reuse one issue branch/run across stages, release owned disposable resources at every handoff and close idle checkouts safely while preserving unmerged history. Record retained checkouts/refs and the next reuse action. Preserve the standard checkout's branch, work and staging outside authorized target integration.
- Use the repository's `discordkit-*` skills for named workflow stages. Read [the operating contract](Docs/Air-Workflow/contract.md) and the selected stage prompt. Existing user authorization and explicit scope restrictions take precedence.
- Commit a concrete implementation plan before application changes when using `discordkit-plan`; planning stops after its plan-only handoff. After implementation is authorized, complete every agreed phase, validate it and commit coherent phases without asking again at each phase.
- Ordinary tasks do not acquire permission to commit merely by reading these instructions. Stage and commit only within the authorized task or invoked workflow. Use explicit owned paths and inspect the staged diff.
- Give workers bounded questions or non-overlapping owned paths. Keep compiler, browser, server and integration resources separate. Use actual available capacity; a configured number does not establish admitted concurrency.
- Follow the configured tracker mode in `.air/project.json`. Explicit instructions to skip all tracker operations override it. Keep the supplied local task identity and never fabricate an issue.
- Preserve the distinction between implementation, independent review, integration, delivery and acceptance. Push, remote review requests, merge, deployment and production activity require their corresponding authorization.

## Design and documentation

- Follow [the engineering conventions](Docs/Engineering.md) for focused components, explicit dependencies, state authority, joined lifecycle, bounded work and structured diagnostics. Apply relevant preferences to the affected behavior without speculative layers or unrelated rewrites.
- Apply [the documentation standards](Docs/Documentation.md) throughout authored Markdown, source, configuration, tooling and examples. Documentation is part of each affected phase's completion, including private/internal symbols, tutorials, architecture and operations where implemented.
- Keep reusable domain behavior separate from rendering, platform composition and external adapters. Make concurrency, cancellation, lifecycle and resource ownership explicit where relevant.
- Document every callable, including private helpers, initializers and tests, using the language's documentation conventions. Explain purpose and observable behavior; include meaningful parameters, results, failures, preconditions and side effects. Do not widen access just to document or test a method.
- Document types, properties and invariants sufficiently to make the API understandable. Comments must add information beyond the declaration's name.
- Update API documentation, guides, examples, roadmap status and verification evidence alongside affected behavior. Distinguish implemented, planned and unverified functionality.
- Follow [the documentation publication guide](Docs/Publishing-Documentation.md) for reader-facing YouTrack articles and versioned Git evidence. Review intended content and access before authorized publication. Configure product validation and native reference generation for the actual stack.
- Record consequential design decisions, compatibility and migration implications. Choose persistence and dependencies for the actual product; this template imposes no universal database or hosting provider.

## Testing and tooling

- Follow [the testing guide](Docs/Testing.md). Configure real project checks in `.air/project.json` under `validation.commands`; an empty command list is unconfigured, not a passing suite.
- Follow [TeamCity build chain guidance](Docs/Continuous-Integration.md) for product CI. Complete all platform jobs, then independent build sections, then independent test jobs after all builds pass. Keep sibling jobs parallel, partition complete work once per required contract, bound nested workers, verify artifact provenance and require complete current-candidate receipts. Measure actual hosted overlap before claiming capacity or speedup.
- Write meaningful behavior tests for applicable success, error, boundary, empty, invalid and repeated-call cases. For concurrent behavior, exercise deterministic cancellation, ordering, cleanup and competing callers. Assert observable outcomes rather than copying implementation details.
- Keep ordinary tests offline with injected dependencies, scripted peers and isolated temporary persistence. Separate local test evidence, native platform execution, external integration and production acceptance.
- Choose checks appropriate to the changed behavior. Build affected documentation, resolve warnings and broken links, inspect rendered navigation, and validate examples when relevant. Documentation-only edits do not automatically require an unrelated product build.
- Run `git diff --check` before handoff. Report exact checks, tested revision, outcomes, baseline failures and unavailable environments; never turn skipped or unconfigured checks into passes.

## Repository hygiene

- Edit [COPYRIGHT.md](COPYRIGHT.md) for copyright fields and ownership exclusions.
  Stage intended new files, run `python3 Scripts/sync_copyright.py --apply`,
  review the diff and commit the policy and affected notices together within
  the authorized workflow. CI checks drift. Preserve independent licenses.
- Follow [dependency and build guidance](Docs/Dependencies.md): commit exact tool/dependency pins and build variants, prefer pinned Git submodules for supported upstream source dependencies, and reuse only compatible caches. Review selected ignore fragments against actual component paths; keep restore inputs visible.
- Apply [cache budgets and cleanup](Docs/Dependencies.md#cache-budgets-and-cleanup) before heavy work: share one aggregate disk budget across agents/worktrees/repositories, preserve free space, reuse compatible caches with supported locking and keep mutable output isolated. Release owned scratch each phase and at failure/cancellation/handoff; never purge active, unknown or another task's caches.
- Keep secrets, runtime stores, downloaded dependencies, build output, caches, generated documentation and personal IDE state out of Git. Commit dependency pins, source assets, intended fixtures and reproducible project configuration.
- Do not blanket-stage, reset, clean, stash or switch another task's work. Inspect CI triggers before any authorized push because a push can publish or deploy.
- Use the approved GitHub repository or other Git VCS root for source and TeamCity for CI and deployment. Use YouTrack for issues and published documentation when enabled. Keep publication within the authorized project, content and audience. [TeamCity](https://ci.aurum-studios.com) · [YouTrack](https://issues.aurum-studios.com)
- Reconcile an uncertain external write against authoritative current state before retrying. Record receipts without credentials or private customer data.
- Release only owned resources. Verify process identity, branch inclusion and preserved evidence before cleanup; use Air for Air-managed task/worktree deletion.
