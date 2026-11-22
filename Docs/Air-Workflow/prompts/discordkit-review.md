<!-- copyright:begin
File: Docs/Air-Workflow/prompts/discordkit-review.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Independently review a candidate

Input: task, exact candidate/base and review scope. Follow [the contract](../contract.md) and [tracker lifecycle](../state-transitions.md).

Follow [the worktree lifecycle](../worktree-lifecycle.md) for observational
resource closure. Create no branch or checkout merely to enter this stage;
release only resources created by this invocation and preserve the author's
checkout and candidate.

Compare new tool/dependency choices with applicable **Preferred tools and
dependencies** in the affected [language profiles](../../Languages/README.md), the
approved plan and established project constraints. Check documented reasons for
deviations; do not request unrelated migrations just to match a preference.

Review affected documentation against [the documentation standards](../../Documentation.md):
behavioral contracts at every visibility, Markdown/navigation, examples,
configuration and compatibility/operations notes. Check completeness against
source and evidence; generated reference success alone is insufficient.

For CI or parallel-test changes, check [the TeamCity build chain guide](../../Continuous-Integration.md):
all-platform and all-build barriers, independent sibling builds/tests,
distinct-contract qualification, complete unique assignments, bounded nested
workers, compatible artifacts, required receipt reconciliation and current
candidate/reuse provenance. Treat hosted capacity and speedup as unverified
unless actual admitted execution and representative measurements establish them.

1. Read the original issue/ACs, repository instructions and actual candidate diff before relying on the author's rationale. Verify candidate/base identity and examine affected callers, invariants, test evidence and compatibility.
2. Keep source and Git history read-only. Delegate bounded independent questions when useful; isolate any test caches/output. Focus on reproducible defects, missing meaningful evidence and violations of the approved behavior. Resolve conflicting claims using source or reproduction rather than reviewer votes.
3. Report concrete findings with severity, trigger, consequence, source location and suggested remedy. Separate confirmed blockers, uncertain concerns and external qualification gaps. Self-review does not replace this independent receipt.
4. Native/delegated reviews remain observational. An express `discordkit-review` invocation may coordinate the named issue's necessary tracker transition only when it owns exclusive coordination; if a writer is active, send findings back to that owner. Accepted current-candidate review maps toward Documentation; confirmed blocking defects map toward authorized repair; missing evidence leaves review pending. Verify all writes by read-back.
5. Pass verified findings to the exclusive task coordinator for the [task article checkpoint](../../YouTrack/Knowledge-Base.md#publish-an-approved-task). An explicitly authorized coordinating reviewer who owns that handoff can publish when an authorized writer has committed the review evidence. Otherwise, pass the exact reviewed SHA and evidence to the writer with the publication checkpoint pending. Native and delegated reviewers remain observational.
6. Stop and join review workers and release only resources created for this review under the lifecycle guide, including isolated disposable test output. Preserve the author's issue branch/worktree and all preexisting resources; report observed leftovers without cleaning them. Return exact reviewed SHA/base, checks and limitations, finding dispositions, accepted/pending receipt and retained-resource disposition. Keep source and candidate refs read-only. A later source/build-input change requires affected review/evidence reconciliation.
