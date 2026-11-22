<!-- copyright:begin
File: Docs/Air-Workflow/prompts/discordkit-integrate.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Integrate the verified candidate

Input: task, exact ready candidate and requested integration/delivery scope. Follow [the contract](../contract.md) and [tracker lifecycle](../state-transitions.md).

Follow [the worktree lifecycle](../worktree-lifecycle.md) for reuse and stage
closure. Keep one canonical issue branch across stages; create no branch or
worktree merely for a stage transition.

For remote integration, reconcile required gates and artifact reuse using
[the TeamCity build chain guide](../../Continuous-Integration.md). Require complete
evidence for the actual head/combined candidate or an explicitly verified exact
tree adoption; preserve producer provenance. Draft deferral, queued jobs and
incomplete receipts cannot qualify merge or delivery.

For explicitly requested local-only source integration, use a clean checkout of
the named local target after the same candidate, review, documentation and
ownership checks. Pin its expected base and the verified candidate. Prefer a
fast-forward guarded against that expected base. If a merge is needed, prepare
and validate the combined candidate in an isolated coordinator checkout before
advancing the target; reconcile any target movement. Preserve applicable
protections and shared history. Verify final ancestry/source inclusion and the
exact resulting commit/tree. Record local inclusion, local validation and any
pending TeamCity qualification, remote delivery or live acceptance. Keep cleanup
within the requested scope and apply the preservation checks below.

1. Reconcile current candidate, AC coverage, independent review and documentation readiness. Inspect Git operations, worktrees, owners, current base and applicable remote state, branch protections, YouTrack review, TeamCity gates and publication triggers. Preserve the user's dirty checkout and other tasks. Use one integration coordinator.
2. Establish the actual requested boundary before irreversible external actions. Existing explicit authorization persists; a stage name does not add deployment, service startup or production writes beyond the requested scope. Prepare a concrete verified candidate and identify exact delivery effects before asking any necessary missing permission.
3. For remote integration, use the existing protected merge path, merge queue or equivalent verified base guard. Revalidate affected combined behavior if the base advances. Never bypass protection, force-push shared history, invent review approval or merge a different head. If a required capability/authorization is absent, return a concrete local handoff at that boundary.
4. Verify actual source inclusion/merge, exact delivery artifact and required acceptance independently. Update mapped tracker lifecycle with current receipts and read-back. Refresh the [task article](../../YouTrack/Knowledge-Base.md#publish-an-approved-task) from committed integration and delivery checkpoints within the authorized scope before retiring the task checkout. Use results tied to the accepted candidate and delivered artifact. For source-only policy, identify the merged tree as artifact and perform source acceptance without inventing runtime deployment.
5. Apply lifecycle closure even when integration or delivery remains blocked: preserve the canonical unmerged issue branch and shared records, stop and join workers and release only owned resources. Reconcile uncertain external results by authoritative ID/current state before retrying; preserve already verified facts if a later step fails. Inventory named cleanup targets, unique commits, tracked changes and untracked/ignored content; preserve irreplaceable work and recovery evidence outside the target and verify archive contents/readability. Retire disposable integration checkouts. After verified source inclusion, remove eligible owned local issue branches/checkouts only under the lifecycle guide's ownership, inclusion and preservation checks; preserve any refs still needed for pending delivery or recovery. Use Air for Air-managed cleanup and retain the canonical branch whenever removing an idle worktree before integration. Remote branch deletion requires its existing explicit authorization. Verify actual resource removal/release, readable recovery material and preservation of unrelated work; retain anything uncertain and record owner, reason, exact tip, next action and cleanup trigger.
6. Report exact merge/source artifact, actual delivery, acceptance, tracker synchronization, task article outcome and cleanup, with pending boundaries. Do not label the task done until its real acceptance policy is satisfied.
