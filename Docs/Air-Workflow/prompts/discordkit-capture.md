<!-- copyright:begin
File: Docs/Air-Workflow/prompts/discordkit-capture.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Capture actionable work

Input: observations, intended improvement and the target project. Follow [the contract](../contract.md) and [tracker lifecycle](../state-transitions.md).

Follow [the worktree lifecycle](../worktree-lifecycle.md) for observational
resource closure. Create no branch or checkout merely to enter this stage;
release only resources created by this invocation and preserve the author's
checkout and candidate.

1. Confirm the current repository and configured tracker mode. Read relevant source, documentation and existing task records. Search actual tracker/local backlog for duplicates before creating work. Distinguish reported observations from safely reproduced behavior.
2. Describe the trigger, current result, expected result, impact and observable acceptance criteria. Separate independent changes; preserve existing issue lifecycle when adding to a duplicate. Ask only consequential scope/behavior questions.
3. In YouTrack mode, an express capture invocation authorizes necessary search/create/update for the supplied observations and chosen project. Discover actual schema first, use returned canonical identity and verify writes by read-back. Do not assign people, alter schema or send separate notifications. In local mode or an explicit skip instruction, prepare a local capture using the current task identity without tracker calls.
4. Return canonical issue links or local records, duplicate decisions, evidence quality and next planning action. Capture does not start implementation, create Air tasks or grant commit/publication permission for unrelated files.
5. Stop and join owned investigation workers, release owned temporary resources and report any retained resources. Preserve existing local records, branches and checkouts; capture creates no issue checkout to leave behind.
