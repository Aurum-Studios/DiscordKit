<!-- copyright:begin
File: Docs/Air-Workflow/prompts/discordkit-split.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Decompose substantial work

Input: issue, existing plan or large approved phase. Follow [the contract](../contract.md) and [tracker lifecycle](../state-transitions.md).

Follow [the worktree lifecycle](../worktree-lifecycle.md) for observational
resource closure. Create no branch or checkout merely to enter this stage;
release only resources created by this invocation and preserve the author's
checkout and candidate.

Read scope, ACs, dependencies, current source, plan/approval, active ownership and available resources. Propose a dependency graph with bounded slices, shared contracts, owned paths, required checks, integration order and stop conditions. Prefer useful independent questions or non-overlapping work over a worker quota.

Keep existing phase gates and approval boundaries. Identify whether the decomposition is a routine scheduling choice within approved scope or a material plan change. Routine scheduling can proceed under existing authorization; a material change needs its concrete decision recorded before dependent implementation.

Return the proposal and any meaningful trade-offs. Do not create child tracker issues, change issue state, alter schema, spawn new Air tasks or commit a revised plan merely from this proposal stage. Apply an expressly authorized plan amendment only within its stated scope, preserving unrelated work and the task's current lifecycle.

Stop and join owned research workers and release their disposable resources
before handoff. Preserve the existing issue branch/checkout and other tasks;
report retained resources without creating branches or worktrees for the proposal.
