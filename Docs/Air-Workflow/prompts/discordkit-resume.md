<!-- copyright:begin
File: Docs/Air-Workflow/prompts/discordkit-resume.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Recover an existing task

Input: interrupted task/run or existing Air branch/worktree. Follow [the contract](../contract.md) and [tracker lifecycle](../state-transitions.md).

Follow [the worktree lifecycle](../worktree-lifecycle.md) for reuse and stage
closure. Keep one canonical issue branch across stages; create no branch or
worktree merely for a stage transition.

1. Inspect current plans, STATE/EVIDENCE, commits, index/worktree changes, ongoing Git operations, worktree inventory, active writers/resources, YouTrack issue, TeamCity results and delivery receipts. Reuse the existing identity, canonical issue branch and checkout. If the idle checkout was safely released, reconstruct it through the available Air capability from that retained branch and verified exact SHA; reconcile any tip movement rather than creating a replacement issue/stage branch or replaying commits. Do not infer an interrupted command failed from an absent chat response.
2. Reconcile what actually completed, the exact candidate and last authorized stage. Read authoritative current state before retrying uncertain commits, issue writes, Knowledge Base publication, TeamCity runs, merge or delivery operations. Preserve unrelated work and unexplained state changes; do not steal stale-looking ownership.
3. Continue the authorized unfinished stage at its next exact action. A resume invocation does not approve a pending plan, reopen completed work, authorize new scope or add integration/delivery permission. If only a material decision remains, finish independent concrete preparation and ask only for that decision.
4. Update durable state with truthful evidence and synchronize only necessary mapped lifecycle changes when tracker coordination is authorized. Reconcile prior article and issue backlink intents using the [task publication recovery](../../YouTrack/Knowledge-Base.md#publish-an-approved-task) before refreshing an approved checkpoint. Honor local mode and explicit skips. Report pending transitions and article outcomes accurately.
5. Complete the recovered stage's normal handoff and lifecycle closure: stop and join workers, release owned resources and preserve required issue history and shared recovery records. Apply that stage's rules for retaining or retiring the canonical branch. Report removed/retained checkouts, any retention owner/reason/trigger, recovered identity, verified progress, current candidate and exact next reuse action without replaying a fictitious stage history.
