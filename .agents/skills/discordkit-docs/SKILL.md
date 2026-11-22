---
name: discordkit-docs
description: "For discordkit: Update documentation and changelog for a reviewed repository candidate and record readiness."
---
<!-- copyright:begin
File: .agents/skills/discordkit-docs/SKILL.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->


# discordkit Docs

Use the `discordkit` repository's existing Air task and Git root. Confirm `.air/project.json` identifies project slug `discordkit` before acting; this repository-local skill does not select another product or worktree.

Read [the operating contract](../../../Docs/Air-Workflow/contract.md), [tracker lifecycle](../../../Docs/Air-Workflow/state-transitions.md) and [this stage prompt](../../../Docs/Air-Workflow/prompts/discordkit-docs.md). Resolve configuration and task records from that Git root, not the skill directory.

Use [the documentation standards](../../../Docs/Documentation.md) for project-wide
coverage, Markdown, symbol contracts, guides, examples and verification.
Read [the documentation publication guide](../../../Docs/Publishing-Documentation.md)
for reader-facing YouTrack articles and linked Git evidence. Verify affected
Markdown, examples, native reference output where applicable, and article
navigation and access for any authorized publication.

When this checkpoint includes authorized task publication, refresh the issue's
existing [task article](../../../Docs/YouTrack/Knowledge-Base.md#publish-an-approved-task)
from the verified readiness checkpoint. Run `$discordkit-kb-sync` for an
explicitly requested library refresh after reviewing its inventory and audience.
Preserve article owners' changes and record publication evidence separately from
issue readiness.

Follow [the worktree lifecycle](../../../Docs/Air-Workflow/worktree-lifecycle.md)
for canonical-branch reuse and this stage's closure. Do not create a branch or
checkout merely because the stage changes. Preserve the standard checkout and
report resources retained for the next action.

Follow the selected stage's authorization and stopping point. Existing user scope and authorization govern writes; implicit skill selection alone grants no tracker, commit or external publication permission. Local tracker mode or an explicit instruction to skip all tracker operations means no tracker calls. Use actual available tools and report missing capability without inventing a connector or successful result. If required repository references are missing, identify them and preserve the task rather than substituting an unrelated workflow.
