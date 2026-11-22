<!-- copyright:begin
File: Docs/Air-Workflow/prompts/discordkit-docs.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Prepare documentation readiness

Input: completed task/candidate and its review evidence; issue optional in local mode or an explicit tracker skip. Follow [the contract](../contract.md) and [tracker lifecycle](../state-transitions.md).

Follow [the worktree lifecycle](../worktree-lifecycle.md) for reuse and stage
closure. Keep one canonical issue branch across stages; create no branch or
worktree merely for a stage transition.

Apply [the documentation standards](../../Documentation.md) to the affected
Markdown, all-visibility symbol contracts, architecture, tutorials, configuration,
tooling, examples and operations. Documentation updates belong in each affected
implementation phase; this checkpoint verifies their completeness and readiness.
Read [the publication guide](../../Publishing-Documentation.md) for YouTrack
articles and versioned evidence. Confirm the intended article and audience
for authorized publication.

1. Inspect current code/history, approved scope, candidate identity, independent review receipt and existing documentation. Reconcile historical plans against implemented behavior. Preserve unrelated draft/plan edits and staging. Do not claim ready-to-integrate without accepted current-candidate review.
2. Update affected API/method documentation, guides, setup/examples, architecture/operations notes, roadmap, verification and changelog. Document every callable at every access level. For Swift libraries, maintain curated DocC articles, tutorials and symbol/member navigation. Distinguish implemented, planned and unverified behavior and preserve historical evidence.
3. Run relevant source-coverage, file-link/fragment and sample checks. Inspect Markdown structure and navigation. Build affected native reference when applicable and resolve new diagnostics. Record baseline and unavailable checks explicitly. Public reference output cannot verify private/helper/test coverage. Avoid unrelated product builds for prose-only changes. Inspect the complete diff before reusing earlier code evidence for a documentation-only descendant. Behavior or build-input changes require authorized implementation repair and affected tests and review again.
4. An invoked documentation checkpoint may commit its coherent owned documentation and task records. Respect narrower review-only/no-write/no-commit instructions. Record current readiness, tested revision and remaining qualification. In YouTrack mode, synchronize readiness only after its evidence exists and verify read-back.
5. At the committed readiness checkpoint, refresh the issue's existing article using the [task publication runner](../../YouTrack/Knowledge-Base.md#publish-an-approved-task) within the approved scope. For an explicitly authorized guide or library refresh, review its scope and audience before editing the relevant guide or invoking `kb-sync`. Verify the task publication outcome independently of issue readiness.
6. Stop and join owned workers, release stage-owned resources and retire disposable documentation checkouts under the lifecycle guide. Preserve the canonical issue branch, documentation candidate and shared readiness records. Release a clean idle issue worktree through Air when safe while preserving its branch; otherwise record the retained canonical checkout, owner, reason, exact tip, next action and cleanup trigger. Return exact documentation scope, commit if authorized, checks, candidate/readiness receipt, worktree disposition and explicit integration handoff. Merge and deployment require their existing authorization.
