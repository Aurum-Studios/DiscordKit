<!-- copyright:begin
File: Docs/Air-Workflow/prompts/discordkit-capacity.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Inspect usable concurrency

Input: current session/repository. Follow [the contract](../contract.md).

Follow [the worktree lifecycle](../worktree-lifecycle.md) for observational
resource closure. Create no branch or checkout merely to enter this stage;
release only resources created by this invocation and preserve the author's
checkout and candidate.

Inspect model-visible collaboration capabilities, runtime admission and any actual repository resource policy/active reservations. Distinguish configured worker limits, available slots, genuinely observed overlapping workers and independent compiler/browser/integration constraints. A prompt cannot increase a runtime cap.

Apply [cache budgets and cleanup](../../Dependencies.md#cache-budgets-and-cleanup)
to the proposed allocation. Inspect available usage observations and inexpensive
checks of free space and named cache/build roots. Account for shared
host/filesystem usage, reserve and estimated additional peak demand across agents;
report unknown demand and reduce or serialize heavy work when headroom is unclear.
Keep this inspection observational: do not run broad recursive disk scans,
allocate trial caches or purge files to establish capacity.

If useful, run a few small independent read-only investigations to observe admission. Do not start expensive builds, services or a quota-filling stress test. Give each worker a bounded output and stop/release all pilot workers afterward. Admission rejection means reduce/queue work, not bypass or repeatedly retry.

Return practical allocation for the current task, planned versus admitted workers, disk budget/headroom and what remains unmeasured. Do not edit configuration, acquire writer ownership, change tracker state or claim coordination across separate clones/machines without a real mechanism.

Before handoff, stop and join pilot workers and release only disposable resources
created by this invocation. Preserve preexisting branches, checkouts and caches;
report observed leftovers and any retained owned resources without repairing them.
