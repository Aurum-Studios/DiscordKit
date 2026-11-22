<!-- copyright:begin
File: Docs/Tasks/Templates/STATE.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Task state

## Current identity

Record task/run, repository, branch, worktree, base, plan commit, approved scope, current stage/phase, candidate SHA and current head. Identify the next exact action and any blocker.

## Tracker synchronization

Record configured mode and canonical issue/project when enabled; otherwise record the explicit local identity/skip instruction. Preserve actual state field/value IDs, state mapping, last observed issue revision, verified transition receipt and pending transition. Never label a pending or uncertain write successful.

## Knowledge Base publication

When task publication is authorized, the coordinator adds a standalone line
`Knowledge Base plan approval: <full plan commit SHA>` after actual approval of
the exact plan and commits this receipt. Record the project, issue and article
IDs and URLs, read-back of the issue backlink, the plan and candidate SHAs and
the exact stage/checkpoint. Record pending writes with the verified partial
outcome and next recovery action. Keep article publication results distinct
from issue lifecycle receipts.

## Ownership and resources

Identify coordinator and active workers, exact path ownership, permitted resources and stop conditions. Record reservation references only when a real coordinator exists; keep live tokens out of committed records. Distinguish configured limits from actual admitted workers.

Follow the cache budgets and cleanup section in repository-root
`Docs/Dependencies.md`.
Record each cache/build/scratch root, owner, shared or private use, compatible
variant, measured usage with observation time, expected additional peak demand,
retention and cleanup state. Include the shared host/filesystem budget, observed
free space, reserve and other active agents' demand or uncertainty. Keep exact
personal absolute paths in local records; commit portable path references and
bounded summaries. Identify retained resources and pending cleanup explicitly.

## Handoff and delivery

Link current evidence and the independent review receipt. Record Git integration, TeamCity qualification, delivery artifact, acceptance and cleanup with exact identities and authorization boundaries. Preserve already verified facts if a later operation fails.

Follow repository-root `Docs/Air-Workflow/worktree-lifecycle.md`. Record the
canonical issue branch and verified tip across stages, standard-checkout baseline
and any concurrent changes, removed disposable checkouts/refs and each retained
resource's owner, reason and cleanup trigger. State whether the issue checkout
is retained or absent with its branch preserved. Give the exact reuse/reattach
action and the surviving location of records and post-removal receipts.
