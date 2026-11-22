<!-- copyright:begin
File: Docs/Tasks/Templates/EVIDENCE.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Evidence

## Acceptance coverage

Map every AC identifier to current implementation and verification evidence. Identify gaps explicitly.

## Checks

Record exact command/procedure, UTC date, environment/toolchain, checkout and tested revision, outcome, relevant output location and limitations. Use passed, failed, skipped, blocked, baseline failure and unconfigured accurately. Do not commit credentials or private data from logs.

## Documentation checks

Record affected guides/examples and source-symbol coverage, including helpers,
private members and tests. Identify file-link versus fragment checks, documentation
build diagnostics, rendered navigation and runnable-example results separately.
State the exact tested revision, exclusions and blocked/skipped/unconfigured work.

## Independent review

Record reviewer, exact candidate/base, reviewed scope, findings, disposition and accepted receipt. New behavior/build-input changes invalidate affected review and test evidence.

## External receipts

Record the authoritative YouTrack read-back, TeamCity build ID and candidate revision, Git integration result, exact delivered artifact and acceptance checks for the work performed. Reconcile uncertain durable effects before retrying.

## Preservation and cleanup

Record owned resources released, work preserved and any cleanup still pending. A cleanup failure does not erase a verified merge or delivery.

Follow repository-root `Docs/Air-Workflow/worktree-lifecycle.md`. Bind each stage
closure receipt to its canonical issue branch, exact tip and next action. Record
ownership/inclusion checks, pre-removal tracked/staged/untracked/ignored inventory,
preserved commits/records and verified postconditions for refs, checkouts and
processes. Identify retained resources with owner, reason and removal trigger;
record the standard checkout's preservation and explain concurrent differences.
Keep the receipt readable outside removed checkouts without staging unrelated
work or writing into the standard checkout.

Follow the cache budgets and cleanup section in repository-root
`Docs/Dependencies.md`.
Record named targets and ownership, stopped/joined owned processes, verified
removal or release, retained compatible caches and their retention, and preserved
work. Measure usage and free space before and after; report observed reclaimed
space separately from logical bytes removed, including uncertainty from concurrent
activity. List pending targets and reasons. Keep personal absolute paths local.
