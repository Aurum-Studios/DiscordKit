<!-- copyright:begin
File: Docs/Air-Workflow/prompts/discordkit-status.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Inspect current status

Input: task or repository. Follow [the contract](../contract.md) and [tracker lifecycle](../state-transitions.md).

Follow [the worktree lifecycle](../worktree-lifecycle.md) for observational
resource closure. Create no branch or checkout merely to enter this stage;
release only resources created by this invocation and preserve the author's
checkout and candidate.

Read current Git/worktree state, durable records, active ownership, candidate/review/test evidence and available YouTrack, TeamCity and delivery receipts. Use tracker reads only when configured and not explicitly skipped. Check current observations instead of relying on historical SHAs or prior inventory.

Report actual stage/phase, branch/worktree, candidate and tested revision, completed evidence, blockers, pending synchronization, ownership/resource conflicts and next exact action. Distinguish unverified claims from authoritative results and local readiness from delivered acceptance.

Remain read-only. Do not repair files, write tracker state, refresh ownership, alter schema, commit, fetch/push, start services or clean preexisting resources as part of status. Stop and join any owned read-only workers and release only temporary resources created by this invocation. Report observed branch/worktree leftovers and their known owners or uncertainty without removing them. Missing access produces a precise limitation, not fabricated success.
