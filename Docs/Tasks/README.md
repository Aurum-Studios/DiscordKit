<!-- copyright:begin
File: Docs/Tasks/README.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Durable task records

Use `Docs/Tasks/<TASK-KEY>/<RUN-ID>/` for a run's canonical PLAN.md, STATE.md and EVIDENCE.md. A real YouTrack task uses its canonical issue key. Explicitly issue-free work keeps the user's supplied local key; do not invent a tracker issue or replace an existing branch/worktree merely to match this layout.

Copy the [plan](Templates/PLAN.md), [state](Templates/STATE.md) and [evidence](Templates/EVIDENCE.md) templates when a named stage needs durable records. Replace instructional text with actual observations. Link the canonical plan from a short `.air/plans/<TASK-KEY>-<RUN-ID>.plan.md` entry for Air's plan viewer.

Keep secrets, reservation tokens and private customer data out of records. Record exact revision identities and authoritative receipts. A plan cannot contain its own resulting commit hash; record that SHA in the subsequent handoff or state update after verifying the commit.

Use the committed [approval receipt](Templates/STATE.md#knowledge-base-publication)
and exact candidate when
[publishing an approved task](../YouTrack/Knowledge-Base.md#publish-an-approved-task).
Record the same article URL and issue backlink across progress checkpoints.

Follow [the worktree lifecycle](../Air-Workflow/worktree-lifecycle.md) at every
stage handoff. Preserve one issue branch/run even when its idle checkout is
released. Verify committed records remain readable from the surviving ref;
keep post-removal receipts outside the deletion target without dirtying the
standard checkout. Record each retained checkout/ref's owner, exact tip, reason,
cleanup trigger and exact next reuse action.
