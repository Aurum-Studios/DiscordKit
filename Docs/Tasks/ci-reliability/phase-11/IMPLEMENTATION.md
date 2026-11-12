<!--
File: Docs/Tasks/ci-reliability/phase-11/IMPLEMENTATION.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 11 qualification preparation and execution gates

Owner: Codex `/root`; branch `ci/phase-11-qualification`, sibling checkout
`DiscordKit-ci-phase11`. Base: `d19bb530fcde7f6a4f269d4b90aa308825be5c31`
(Phase 10 local acceptance). [Source preflight](source-preflight.json) retains
the original planning hashes and existing worktrees.

Status: local implementation and validation only. **Phase 11 is not complete.**
No hosted run, native qualification, rollout activation, push, publication,
deployment or billing change is established by this document. The
[phase completion contract](../PLAN.md#phase-11--qualify-the-final-revision-and-roll-out)
still requires both native platforms, real partial-rerun proof and an exact-final-
revision full certification within an authorized allowance.

## Plan and authorized local execution

1. Preserve the shared checkout and earlier phase branches. Review the cumulative
   workflow, artifact, coverage, admission and release contracts.
2. Prepare one deliberate consumer fault after successful native suite execution.
   Seal its scope into admission; preserve evidence and earlier producer identity.
3. Verify retained full/partial snapshots with existing receipt and release gates.
   Exercise corrupt, missing, failed and stale evidence with offline fixtures.
4. Run all helper groups, source/documentation checks, actionlint and independent
   review. Retain commands, results, input hashes and the scoped local commit.
5. Regenerate pure scope/coverage/cost plans without native execution. Prepare the
   hosted sequence below; leave unverified account facts and authorization open.

| Local boundary | Limit |
| --- | --- |
| Paid jobs / minutes / attempts | 0 / 0 / 0 |
| Spend allowance | USD 0.00 |
| Native compilations / native test processes | 0 / 0 |
| Helper group execution | 300 seconds, existing supervised cleanup |
| Checks | Python/browser helpers, localhost transport fixtures, workflow/source/docs checks, pure planning |
| Remote changes | None |

## Implemented qualification path

The manual CI input `qualification-fault` defaults to false. It is legal only for
`diagnostic`, `linux-x64`, `root`, `DiscordBitsTests`, with publication disabled.
Admission validates this before querying source identity or expanding any work.
The flag changes the sealed plan identity, never the job or attempt reservations.
All current-attempt guards receive it, including the reusable workflow. Its
concurrency identity differs from an ordinary diagnostic at the same source.

The selected root consumer first restores the immutable producer, checks exact
nonempty discovery and runs the ordinary complete suite. The next step validates
its actual `consumer.json`, `restored.json` and complete executed-leaf receipt.
Only then does it emit `qualification-fault.json` and intentionally exit 1 on
attempt one. On a later attempt the ordinary tests must run and pass again before
the marker passes. No build, test, assertion or workflow retry is automatic.
Rejected receipts cannot become an intentional-failure proof. Always-run evidence
upload retains the consumer directory, spend guard and full resolver index.

The rollout parser now accepts a separately reviewed boolean manual native switch
while retaining automatic preflight. Checked-in native expansion stays false;
the independent admission policy still has disabled authorization, zero allowances,
unknown additional charges and unverified account mappings. A switch, input or
repository variable cannot supply paid authorization.

[qualification_evidence.py](../../../../Tools/ci/qualification_evidence.py) verifies
retained snapshots locally. Full verification requires the exact repository,
workflow ID/path, revision, current attempt, successful terminal run and unique
`Offline certification passed` job with its successful full-coverage step. It uses
the same gate as release tooling. Partial verification requires one diagnostic
run's failed attempt one and successful attempt two, real tests before the marker,
unchanged load/root producer selections, no repeated producer build, fresh root
consumer evidence and complete diagnostic coverage. Missing leaves, corrupt v2
receipts, changed bytes, stale/future attempts and diagnostic promotion fail.
Snapshots are retained observations, not authenticated live API reads; successful
offline verification explicitly leaves `certificationEstablished` false.

## Hosted execution sheet — pending authorization

Do not dispatch this sequence using the current policy. Before any hosted work,
verify current account-specific runner mappings, dated rates, bounded storage/
transfer liability, explicit per-workflow/experiment allowances, job/minute/attempt
limits and safety reserve. A partial-rerun experiment needs two reserved attempts;
current policy allows one and zero paid work. The proposed repository budget in
[the operator checklist](../phase-10/OPERATOR-BUDGET.md) remains separate and unset.
Do not substitute the proposed monthly amount for a per-run allowance.

The prepared graph reserves 17 jobs / 765 maximum runner minutes per attempt
for the Linux fault scope, 14 / 485 for the macOS load scope, and 81 / 7,780
for full certification without publication. Two permitted attempts reserve twice
the complete scope, even when a failed-jobs rerun will reuse producers. These are
outer-timeout ceilings, not predicted duration or actual spend. Unknown account
pricing and additional charges prevent a complete dollar maximum.

1. Commit the authorized policy and reviewed manual rollout setting, then freeze
   the final revision. Re-read clean state and regenerate all plans from that SHA.
   Recheck admission at every job entry. Do not publish intermediate branches or
   dispatch during preparation.
2. Authorize one Linux diagnostic with `component=root`, `suite=DiscordBitsTests`,
   `qualification-fault=true`. Its required load canary establishes the Linux
   producer/archive/fresh-consumer/full-load/smoke path before the cheap consumer.
   Require the exact deliberate failure after passing root tests. Retain attempt
   one's terminal API jobs and immutable evidence before requesting a rerun.
3. Explicitly rerun **failed jobs only once**. Require unchanged successful load
   and root producers, a new root consumer resolving the attempt-one archive, fresh
   executed-leaf receipts and successful diagnostic barriers. Stop and diagnose any
   different failure; never use an automatic full rerun.
4. Authorize one macOS `diagnostic` load scope, proving its real native round trip,
   cancellation regressions, whole load package and required smokes. Retain native
   probe results; local Apple Swift 6.4 or emulated Linux is insufficient.
5. Only after both diagnostics and local fault checks pass, authorize **one full
   certification** at the final SHA with the fault input false and publication
   false. Admission's maximum reserves every configured attempt even when only one
   execution is authorized; account for that conservative bound before approval.
   Watch every required gate, upload and both platform barriers to terminal status.
   A new failure returns to a revised smallest affected scope.
6. Read back final API jobs, full producer indices, coverage/usage artifacts and
   the exact check context. Inspect branch protection/required checks read-only.
   Compare measured Phase 0 versus final runner minutes, setup/transfer time and
   wall time. Do not invent savings, account billing or provider budget settings.
   Do not enable automatic full rollout or alter protection as an incidental step.

Retain raw API responses separately from normalized snapshots. Read
`actions/runs/{run}/attempts/{attempt}/jobs` through all pages; annotate a missing
job `run_attempt` only from that endpoint's attempt. Capture the matching workflow
metadata and run response. Full snapshots contain `schemaVersion: 1`,
`workflow: {id, path}`, `scope`, `run` and `jobs`. Their full scope is exactly
`{mode: full, platform: null, component: null, suite: null, qualificationFault: false}`.
Partial snapshots use the fixed diagnostic scope and additionally contain
`selections: {load, root}` with retained full artifact indices and
`groups: {load, root}`, each containing `receipt` (group coverage) and `artifact`
(the immutable artifact's API metadata). The unchanged load consumer remains from
attempt one; the second root selection and receipt must belong to attempt two.
Download and verify artifact digests using existing transfer helpers before
assembling these observations; the snapshot verifier does not authenticate downloads.

Run the verifier from the selected source checkout with the captured workflow ID
and exact SHA; its diagnostic coverage plan comes from that checkout:

```sh
python3 Tools/ci/qualification_evidence.py partial \
  --before /retained/attempt-1.json --after /retained/attempt-2.json \
  --repository Aurum-Studios/DiscordKit --revision "$FINAL_SHA" \
  --workflow-id "$CI_WORKFLOW_ID" --output .build/partial-proof.json
python3 Tools/ci/qualification_evidence.py full \
  --snapshot /retained/full.json --repository Aurum-Studios/DiscordKit \
  --revision "$FINAL_SHA" --workflow-id "$CI_WORKFLOW_ID" \
  --output .build/full-proof.json
```

The `/retained` names above are operator-supplied inputs, not existing evidence.
No partial/scoped result, successful archive upload or offline snapshot fixture
can satisfy the exact full barrier, source-export gate or release eligibility.

## Evidence and remaining gates

[Validation](validation.json) records actual local commands and tested input hashes.
[Independent review](review.json) records findings and resolutions. Pure plans are
retained under [checks/planning](checks/planning/results.json); their refused
admission is an expected local result, not successful hosted qualification.

Open: native Linux x64 acceptance from Phase 3; actual hosted producer/consumer
round trips, partial-rerun proof, provisioning cold/cache measurements, shared
documentation invocation counts, final full certification, observed cost comparison,
branch-protection read-back and an operator-selected authorized spend policy.
Provider-budget configuration remains a separate pending operator subtask.
