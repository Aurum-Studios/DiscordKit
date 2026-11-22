<!-- copyright:begin
File: Docs/YouTrack/Launch-Checklist.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# New-project launch checklist

Use this checklist to connect a new repository to the native **Air Development**
YouTrack template described in [the setup guide](README.md). It is for a project
owner who can review YouTrack configuration and a repository coordinator who can
verify the generated foundation. You need an appropriate account, the chosen
repository identity and permission for any instance changes you intend to make.
The checklist runs no API calls itself. The explicit
[automatic setup command](Automatic-Setup.md) can configure a supplied empty
project within requested scope; it creates no project or delivery authority.

## Prepare the native project

- [ ] Confirm the intended YouTrack instance, project name, short name and owner.
  Check for an existing project before creating one. If access or identity is
  unavailable, preserve pending setup while independent repository work proceeds.
- [ ] Choose [automatic setup](Automatic-Setup.md) for an existing empty standard
  project, or create from a preconfigured native **Air Development** template.
  Automatic setup needs trusted REST authentication; it previews first and saves
  actual IDs only after read-back. Missing credentials retain pending local work.
- [ ] For the native-template route, if **Air Development** is not yet available, have the authorized project
  administrator build and convert the seed project following [the setup guide](README.md)
  and [the configuration specification](project-template.json). The JSON is a
  portable reference, not a supported native template import.
- [ ] Create the project using the chosen route: an empty standard project for
  automatic setup, or the native **Air Development** custom template. Record the
  actual returned project identity and URL; do not guess
  instance IDs from project names or reuse the seed project's IDs.
- [ ] Audit inherited access: project owner/team, roles and permissions. Confirm
  the intended people can read issues and the designated coordinator can perform
  the required issue writes. Preserve unrelated project access.
- [ ] Review every copied board and attached workflow. Confirm board scope,
  columns, defaults and workflow actions suit the destination project; remove or
  adapt copied assumptions only within authorized configuration scope. A copied
  board or workflow does not prove the Air evidence gates are enforced.
- [ ] Inspect the actual State field and its values. For a fresh full-fidelity
  template, verify Backlog is the default and Done is the sole resolved state.
  Existing schemas can map several logical stages to one real value. Check the
  full mapping against [the lifecycle](../Air-Workflow/state-transitions.md).
- [ ] Review optional fields and defaults against the actual project. Type,
  Priority, Assignee, estimates and versions are not extra Air prerequisites.
  Check any inherited required fields before creating the first issue.
- [ ] Add project-specific onboarding content deliberately. Native templates do
  not copy issues or Knowledge Base articles. Keep [the issue body](Issue-Description.md)
  and [handoff text](Stage-Handoff.md) available from this repository or recreate
  the intended guidance in YouTrack through an authorized content action.

## Establish the repository foundation

- [ ] Inspect the requested folder, existing Git root/status/worktrees, task
  identity and project files before generation. Preserve existing product choices,
  unrelated edits and staging. Review conflicts instead of overwriting them.
- [ ] Preview the `new-repo` generator with the real project name, purpose and
  selected language guidance. Use the verified project short name when known;
  use `--youtrack-pending` while identity/access is incomplete. An explicit
  tracker-free request uses `--local-only` and skips all tracker reads/writes.
- [ ] Apply the reviewed generation and inspect its files. Only explicit
  `--configure-youtrack --apply` provisions the supported empty-project schema;
  ordinary copying proves no connectivity. Review repository-local stage
  names, documentation, selected language guidance and publication settings.
- [ ] Make `Docs/Plans/Repository-Initialization.md` concrete for the intended
  product. Establish the Git repository if needed and commit that finalized plan
  alone before product implementation. Verify the resulting commit and its
  plan-only diff; record the SHA afterward rather than inventing a self-reference.
- [ ] Configure actual build/test/lint/documentation commands in
  `.air/project.json` as the real stack is established. An empty command list is
  unconfigured. Copying a language profile supplies no installed toolchain or
  passing product checks.
- [ ] Validate generated links and skill manifests, inspect affected documentation
  and run the actual configured checks. Record commands, environment, exact tested
  revision, outcomes and limits in `Docs/Verification.md`. Report local rendering,
  hosted documentation packaging and publication as separate results.

## Verify tracker mapping and begin the first task

- [ ] Discover an available authenticated connector/API using read-only access.
  Verify the canonical project, real project-specific State field/value IDs and
  necessary issue permissions. Do not claim this verification from generation,
  a populated short name or a copied board.
- [ ] Record the verified project short name and logical-to-real mapping in
  `.air/project.json`. Use [the mapping example](state-mapping.example.json) as
  documentation only; replace its null identifiers with actual discoveries.
  Automatic setup stores this mapping shape only after verified schema read-back;
  it does not execute issue transitions.
  Keep unknown mappings empty/pending and record the missing capability or input.
- [ ] Search for duplicate work before an authorized first issue capture. Use
  [the issue description](Issue-Description.md), replace its placeholders, retain
  stable AC identifiers and use the canonical identity returned by YouTrack.
  The template does not create a starter backlog automatically.
- [ ] Establish one coordinator and the current task/run. Use
  [the task record templates](../Tasks/README.md) for canonical PLAN/STATE/EVIDENCE,
  and link the plan from Air's plan-view entry. Preserve existing task identity
  and owned worktree when resuming work.
- [ ] Commit the first task's concrete plan before implementing its phases.
  Record actual approval or existing authorization for that exact scope; a
  completed planning stage alone is not implementation approval. Follow the
  verified state mapping and [handoff procedure](Stage-Handoff.md), recording
  authoritative read-back or truthful pending synchronization.

## Define completion before delivery

- [ ] Agree the actual acceptance policy. For source-only work, identify when
  the exact merged commit/tree is the delivery artifact, explain why runtime
  deployment does not apply, and define source acceptance. For runtime work,
  identify the required artifact, environment and acceptance checks.
- [ ] Keep local validation, independent review, hosted CI, merge/source inclusion,
  artifact delivery, publication, service startup and live acceptance separate.
  A local pass or queued hosted run establishes no later receipt. Prepare a
  concrete candidate before any required approval for an external action.
- [ ] Perform integration and delivery only within their existing authorization.
  Record actual results and reconcile uncertain durable effects before retrying.
  Mark Done only after the acceptance policy is satisfied; record cleanup
  separately and preserve verified merge/delivery facts if later work fails.

## Knowledge Base library

After schema setup and local Git initialization, run the generated kb-sync skill
within requested documentation setup. Follow [the sync guide](Knowledge-Base.md),
verify all rendered Markdown and record the actual root link, access and complete
read-back. Keep conflicts and source drift pending. Native templates do not copy
articles; ordinary generation performs no publication.
