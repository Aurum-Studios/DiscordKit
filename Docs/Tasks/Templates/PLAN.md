<!-- copyright:begin
File: Docs/Tasks/Templates/PLAN.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Implementation plan

## Identity and approval

Record task key, run ID, repository, base SHA, branch/worktree and the current source issue revision when applicable. Record the concrete plan commit and actual user approval in the later handoff; do not infer approval from a completed planning session.

## Problem and intended behavior

Describe the concrete trigger, current behavior, desired result, scope and consequential exclusions. Link relevant source, reproduction and upstream evidence.

## Acceptance criteria

Assign stable AC identifiers to observable outcomes and state how each will be verified.

## Ordered phases

For each phase, record prerequisites, deliverables, owned paths, dependencies, meaningful checks, documentation updates and exit conditions. Keep phase gates sequential; identify useful independent work inside a ready phase. Plan coherent commits within the authorized implementation.

## Disk and cache budget

Before heavy work, follow the cache budgets and cleanup section in
repository-root `Docs/Dependencies.md`.
Record the shared host/filesystem budget, current measured usage and free space,
required reserve and estimated additional peak demand across active agents,
including downloads, extraction and copies. Assign cache/build/scratch owners,
compatible reuse, retention and cleanup points. Reduce or serialize planned work
when the aggregate cannot fit; keep personal absolute paths in local records.

## Compatibility and operations

Record data/migration and API impact, deployment assumptions, rollout/rollback needs, external effects and separate qualification boundaries where relevant.

## Documentation scope and checks

Follow the repository's documentation standards. Identify affected Markdown,
symbols at every visibility, guides/tutorials, examples,
configuration, architecture and operations. Assign updates and proportionate
source, link/fragment, rendered-reference and example checks to their phases;
record unavailable tools or environments without claiming a pass.

## Decisions and uncertainties

Record consequential decisions already resolved, remaining questions and their effect on scope or behavior. Routine engineering choices do not require new user approval.
