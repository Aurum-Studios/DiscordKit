<!-- copyright:begin
File: Docs/Air-Workflow/prompts/discordkit-implement.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Complete the approved implementation

Input: task and approved plan/plan commit. Follow [the contract](../contract.md) and [tracker lifecycle](../state-transitions.md).

Follow [the worktree lifecycle](../worktree-lifecycle.md) for reuse and stage
closure. Keep one canonical issue branch across stages; create no branch or
worktree merely for a stage transition.

Use applicable **Preferred tools and dependencies** in the affected
[language profiles](../../Languages/README.md) for new choices within the approved
scope. Preserve established project choices and reconcile material conflicts
before dependency changes; record adopted choices in project guidance.

Apply [the documentation standards](../../Documentation.md) within every affected
phase. Keep Markdown, all-visibility symbol contracts, guides, examples and
configuration/operations reference current with the implementation.

For CI or parallel-test changes, apply [the TeamCity build chain guide](../../Continuous-Integration.md).
Complete platform jobs first, fan out independent build sections next, then fan
out independent test jobs after every required build passes. Preserve complete
platform/test coverage, resource admission and artifact identity;
exercise failure, cancellation and missing/duplicate receipt paths. Record local
validation separately from actual hosted overlap and current-candidate gates.

Follow [cache budgets and cleanup](../../Dependencies.md#cache-budgets-and-cleanup)
before heavy work and worker fan-out. Record aggregate usage, available disk,
additional peak demand and owned cache/build/scratch roots. On phase success,
failure, cancellation and handoff, stop and join owned processes, remove owned
temporary output that is no longer needed, and retain only bounded compatible
reuse with an owner and retention recorded. Preserve source and evidence, leave
other agents' resources intact and record verified cleanup or pending targets.

1. Read current issue/input and durable records. Verify the actual plan commit, approved scope and current Air checkout. A request to implement that concrete plan supplies approval; do not ask again for authorized work. Reconcile existing phase commits and uncertain operations before changing anything. Establish exclusive writing/coordination.
2. Work through all unfinished phases in dependency order. Use independent workers inside a ready phase with explicit ownership and stop conditions. Keep one writer per shared checkout; integrate independent child changes serially after review. Actual runtime admission governs capacity.
3. For each phase, establish baseline, implement the complete slice, add meaningful regression evidence and affected documentation, then run real configured/appropriate checks. Record outcomes and AC coverage, inspect the diff, commit coherent owned changes and update the exact next action. Continue automatically through every approved phase. Reconsider repeated failed approaches; ask only for newly material scope or behavior decisions.
4. Keep tracker lifecycle truthful around implementation/testing. Missing or failed required checks do not produce a successful complete-candidate handoff. Separate local, hosted, native and live qualification. After all phases pass their required checks, obtain independent review of the exact candidate; repair confirmed defects and rerun affected testing/review.
5. Prepare a review handoff with every acceptance criterion, tested SHA and current head. Record it in task evidence and synchronize it to the configured YouTrack issue when authorized. Push to the approved Git remote only within scope after inspecting TeamCity triggers. Accepted independent review leads to documentation.
6. Stop and join workers, release owned resources and retire disposable stage/worker checkouts under the lifecycle guide. Preserve the canonical issue branch, candidate and shared records for review/documentation. Release a clean idle issue worktree through Air when safe while preserving that branch; otherwise retain at most the required canonical checkout and record owner, reason, exact tip, next reuse action and cleanup trigger. Report completed phases/commits, evidence, worktree disposition, remaining qualifications and `discordkit-review` or `discordkit-docs` next action. Integration, deployment and live production actions need their corresponding scope authorization.

In step 1, when the configured project and article audience are authorized,
commit the single-line approval receipt in the
[task publication guide](../../YouTrack/Knowledge-Base.md#publish-an-approved-task).
Attempt publication of the approved plan before the first implementation phase
and verify its issue backlink. At steps 3 and 5, refresh the same article from
the committed phase or candidate handoff. Record the verified article link or
the pending result and its next recovery action. Continue independent authorized
work while a publication result is pending.
