<!-- copyright:begin
File: Docs/Air-Workflow/prompts/discordkit-triage.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Diagnose failed checks or delivery

Input: exact failure/run, candidate and diagnosis-only or repair scope. Follow [the contract](../contract.md) and [tracker lifecycle](../state-transitions.md).

Follow [the worktree lifecycle](../worktree-lifecycle.md) for reuse and stage
closure. Keep one canonical issue branch across stages; create no branch or
worktree merely for a stage transition.

1. Read actual logs/status, candidate/base, environment, recent changes, CI triggers and task/delivery receipts. Separate source defects, baseline failures, tooling/transport failures, unavailable capabilities and stale evidence. Do not assume a queued or interrupted operation failed.
2. Reproduce safely using focused offline checks where possible. Delegate bounded independent hypotheses. Revisit the hypothesis after repeated failed approaches; a green unrelated check or repeated retry does not explain the failure.
3. Diagnosis-only remains read-only for source, Git, tracker state and external mutations. Return the confirmed cause/evidence or remaining uncertainty and a concrete scoped remedy.
4. When repair is authorized, use the existing owned pre-integration candidate and approved scope, implement the fix, run affected meaningful checks and independent review, update documentation/evidence and commit coherent owned changes. Follow the normal mapped implementation/testing/review/readiness lifecycle; do not skip gates because this is triage.
5. Preserve actual merge/delivery facts. A post-delivery repair needs the appropriate authorized repair scope/run; do not rewrite shared history, reopen done work, restart production or replay uncertain effects automatically. Report cause, exact fix/candidate, checks and remaining delivery/acceptance boundary.
6. Stop and join owned investigation workers and release owned temporary resources. Diagnosis-only preserves all preexisting branches/checkouts; report leftovers without cleaning them. Authorized repair uses implementation closure on the current pre-integration issue branch or the separately authorized post-delivery repair run's branch; do not recreate retired history merely to triage. Preserve its candidate and records while retiring disposable resources and safely releasing an idle checkout through Air. Record any retained checkout's owner, reason, exact tip, next action and cleanup trigger.
