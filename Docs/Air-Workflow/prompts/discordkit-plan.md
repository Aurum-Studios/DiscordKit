<!-- copyright:begin
File: Docs/Air-Workflow/prompts/discordkit-plan.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Commit a concrete plan

Input: canonical issue or existing local task identity and desired outcome. Follow [the contract](../contract.md) and [tracker lifecycle](../state-transitions.md).

Follow [the worktree lifecycle](../worktree-lifecycle.md) for reuse and stage
closure. Keep one canonical issue branch across stages; create no branch or
worktree merely for a stage transition.

Read the affected [language profiles](../../Languages/README.md), including
**Preferred tools and dependencies**, before proposing tool or dependency choices.
Record applicable preferences and resolve material conflicts with existing choices
in the plan; leave unrelated or unspecified choices open.

Use [the documentation standards](../../Documentation.md) to identify affected
guides, symbol contracts, examples and operational/reference material in each
phase, with concrete documentation acceptance and validation.

For CI or parallel-test changes, read [the TeamCity build chain guide](../../Continuous-Integration.md).
Plan explicit platform/build/test barriers and independent jobs within each
phase: all platforms pass before builds, all builds pass before tests. Include
execution contracts/preflight, complete inventory and disjoint assignments,
compatible build artifacts, nested CPU/memory budgets, receipt reconciliation,
required gates and candidate/reuse evidence. Define baseline and hosted
measurements before claiming capacity or performance improvements.

1. Inspect the complete issue/input, repository instructions, source, existing plans, Git operations, base/branch/worktree and duplicate runs. Reuse the Air task's isolated worktree and existing identity; do not operate in dirty main. Establish one writer and tracker connectivity/mapping when enabled.
2. Investigate actual callers, invariants, baseline behavior and viable approaches. Delegate useful bounded read-only questions. Resolve routine engineering decisions; ask only questions affecting product behavior, material scope, compatibility or data handling.
3. Reuse canonical PLAN.md, STATE.md and EVIDENCE.md; create missing records from [task templates](../../Tasks/README.md). Record stable AC IDs, ordered phases, prerequisites, owned scope, dependencies, real validation, documentation, exit conditions, compatibility/rollout and uncertainties. Add or reuse a short Air plan-view entry linking the canonical plan. No application, dependency, migration or product configuration changes belong to this stage.
4. Commit only the owned plan/task changes with a scoped plan message. If the current concrete plan is already committed, verify and reuse that receipt without manufacturing another commit/run or replaying completed lifecycle writes. Inspect the actual parent and plan-only diff, verify the resulting SHA and record the handoff. In YouTrack mode, synchronize the mapped approval-waiting state with verified read-back; report pending synchronization accurately. Do not push without existing authorization.
5. Stop and join workers, release owned resources and retire disposable stage checkouts under the lifecycle guide. Preserve the canonical issue branch, plan commit and shared task records. Release a clean idle issue worktree through Air when its branch/records survive and no active session depends on it; otherwise record the retained checkout, owner, reason, exact tip, next reuse action and cleanup trigger. Return the concrete plan path, task/run, retained branch, worktree disposition, base and plan SHA, consequential decisions and `discordkit-implement` handoff. Stop before phase one. Existing explicit approval of this exact plan can authorize later implementation, but finishing planning does not itself supply approval.

The implementing coordinator uses the verified handoff to publish the approved
plan at the [approval checkpoint](../../YouTrack/Knowledge-Base.md#publish-an-approved-task).
