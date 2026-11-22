<!-- copyright:begin
File: Docs/Air-Workflow/worktree-lifecycle.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Branches, worktrees and stage handoffs

Apply this lifecycle whenever an Air stage opens, finishes, fails, is cancelled
or hands off. Release temporary stage resources at every boundary. Final issue
cleanup follows verified integration separately from delivery and acceptance.
Follow [the operating contract](contract.md) and existing user authorization;
cleanup supplies no permission to merge, push, delete remote refs or deploy.

## One issue lineage and a separate standard checkout

The standard worktree is the user's usual checkout. Record its branch/HEAD,
tracked and untracked status, and staged changes before creating an issue
workspace. Preserve that baseline, including existing dirty work and staging;
do not switch, reset, clean, stash or write task records into it to close a stage.
Concurrent unrelated edits may change the baseline: identify them without
reverting them or claiming the checkout remained byte-identical. Explicit target
integration is the only stage here that advances the named standard branch.

Use one canonical issue/run and branch for planning, implementation, review and
documentation before integration. A separately authorized post-delivery repair
may establish its own run/branch under the repair scope; do not resurrect retired
history merely because triage or resume was invoked. Before creating anything, inspect Air tasks, existing records,
`git worktree list --porcelain`, local refs and actual ownership. Reuse the
recorded issue workspace and verify its tip. A new chat or stage name is no
reason to create another branch, task, run or worktree. Do not rename a branch
at every stage. If the issue has an active writer, coordinate with that owner
instead of creating a competing successor workspace.

Read-only research and review normally need no new branch or checkout. If a
check really requires a writable isolated checkout, prefer a temporary detached
worktree pinned to the exact candidate and record its owner and removal trigger.
Use Air's supported isolation for Air-managed tasks. Create a child branch only
for an independently writable slice that needs commits; name its receiving
issue branch and owner in advance, integrate returned work serially, then retire
that child checkout/ref after verifying preservation. A detached checkout alone
does not preserve new commits: checkpoint any needed history first.

## Close each stage

The stage coordinator owns closure of the resources it created, including
delegated resources. Observers release only their own disposable resources and
return findings to the coordinator; they never clean the author's workspace.

1. Reconcile current work and uncertain operations before retrying. Stop and join
   owned workers, commands, services and file watchers, checking exact process
   identity. Release child reservations before parent reservations under the
   actual coordinator protocol. Expiry or old timestamps alone do not establish
   inactivity or transfer ownership.
2. Checkpoint the stage's authorized owned changes and compact evidence on the
   same issue branch. Respect no-write/no-commit scope; do not commit, stash or
   discard unrelated work to make removal possible. Preserve uncommitted work
   when checkpointing is not authorized and report why its checkout remains.
   Verify plan/candidate SHAs, actual tracker read-back and the next stage gate.
3. Inventory named branch/worktree targets: tip and unique commits, index,
   tracked changes, untracked and ignored files, active sessions/processes,
   reservations and recovery evidence. Clean Git status alone is insufficient.
   Preserve irreplaceable files outside the removal target and verify their
   contents/readability; exclude secrets and personal paths from committed logs.
   Apply [cache cleanup](../Dependencies.md#cache-budgets-and-cleanup) to disposable
   output without purging shared, active or unknown caches.
4. Remove safely disposable stage/worker checkouts and eligible child refs. Keep
   the canonical unmerged issue branch and its committed records. Default to
   releasing a clean idle canonical checkout too when Air can preserve that
   branch, records and recovery material; the next stage can reattach the same
   branch. Retain at most one needed canonical checkout per issue by default,
   with a reason and removal trigger. Do not remove the standard worktree.
5. Verify actual refs, worktree registrations, filesystem targets, processes and
   reservations after cleanup. Check that preserved commits/records remain
   readable and unrelated work is intact. Record removed, retained or pending
   resources and the exact next reuse/reattach action. A successful removal call
   alone does not establish closure; blocked cleanup does not erase completed
   work, verified integration or delivery.

Use Air to close/remove Air-managed worktrees/tasks. Inspect whether that action
also deletes the branch or task records; preserve required history first. Do not
delete an active parent task or a directory beneath a running worker. When the
current session cannot safely close itself, the Air capability is unavailable,
or its removal would discard required refs/records, retain that one checkout and
record the exact Air close action for the owner. Do not bypass Air with shell
deletion. An unsupported cleanup action is a pending handoff, not a reason to
create another workspace at the next stage.

For a verified ordinary Git worktree outside Air ownership, use Git's supported
worktree removal after the same checks, without force. Move command execution to
a surviving checkout before removing its working directory. Delete a named local
branch only after no worktree uses it and its required history is verified in
the intended surviving ref/target. Prefer normal non-forced deletion. A refusal,
squash/rebase ancestry mismatch or uncertain inclusion requires reconciliation
and retention, not force deletion. Never run blanket branch sweeps, filesystem
deletion, `git clean`, forced removal or broad pruning as a stage exit action.
Remote refs and protected/release/base branches remain outside routine cleanup.

## Outcomes by stage

| Stage | Exit outcome |
| --- | --- |
| Capture | No new issue branch/worktree or Air task. Preserve the authorized capture and release investigation resources. |
| Plan | Verify the plan-only commit and approval handoff on the canonical issue branch. Release idle checkouts safely; retain the branch while approval is pending. |
| Implement | Preserve coherent phase commits, exact candidate and validation/review state on that branch. Retire included child work; close disposable and idle checkouts without integrating to the standard branch. |
| Review | Return the exact candidate/base receipt. Stop owned checks and remove only review-created disposable resources. Leave the author's branch/checkout and source unchanged. |
| Docs | Checkpoint authorized documentation on the same issue branch. Reconcile the resulting head with review/test receipts, release disposable/idle checkouts and give the exact integration handoff. |
| Integrate | At an unmet gate, preserve the issue branch and pending delivery records, releasing disposable/idle checkouts. After verified source inclusion, retire eligible owned issue checkouts/refs; keep any refs needed for pending delivery/recovery. Record delivery, acceptance and cleanup independently. |
| Resume | Reconcile the original issue/run and retained refs/resources; finish the recovered stage's closure. Reuse a retained checkout or reattach the same branch at its verified tip. |
| Status, capacity, split | Create no issue branch/worktree. Remain observational about existing resources; stop pilots and release only resources this invocation created. Report cleanup candidates without removing them. |
| Triage | Diagnosis follows observational closure. An authorized repair reuses the canonical issue lineage and follows implementation closure. |
| KB sync | Release owned disposable synchronization scratch and locks after workers stop. Preserve stable/pending receipts in Git-common state; create no issue branch/worktree and leave source/staging unchanged. |

## A durable, resumable handoff

Use [STATE and EVIDENCE](../Tasks/README.md) for portable summaries. Record the
canonical issue branch, verified plan/candidate and current tip, intended base,
completed stage, authorization/gate, next owner/action, removed resources and
retained resources with reason and cleanup trigger. Distinguish an absent checkout
from a deleted branch. Every extra retained checkout/ref needs a concrete purpose
such as unfinished owned work, an active session or unique recovery evidence.

Before removing a checkout, verify that its committed task documents can be read
from the surviving issue ref, for example with `git show <issue-ref>:<record>`.
Keep post-removal observations in surviving coordinator/local receipt storage
outside the removed checkout, with a discoverable pointer in the handoff; do not
dirty the standard worktree or invent a tracker comment merely for cleanup.
After final branch retirement, required records must remain readable from the
verified integration target or verified recovery storage. Keep private recovery
material outside Git and bound its retention under the cache policy.

On resume, reread refs and ownership before attaching the same issue branch in
an isolated checkout. Reconcile a moved tip or branch already checked out
elsewhere instead of resetting it or creating a replacement branch. Verify a
clean removal and branch preservation independently: neither implies the other.

These instructions establish a lifecycle policy. Copying them does not remove
existing branches/worktrees, install cleanup hooks or prove real Air removal.
