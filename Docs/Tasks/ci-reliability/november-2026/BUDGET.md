<!--
File: Docs/Tasks/ci-reliability/november-2026/BUDGET.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# November remaining CI allocation

On November 12, 2026 the operator allocated **USD 50 of additional compute** to
DiscordKit for the rest of November, from an operator-reported USD 100 enterprise
budget. The operator confirmed that remaining included enterprise usage covers
non-compute costs and selected keeping scheduled timing within the cap. There is
no additional paid storage/transfer allowance or separate safety reserve.

## Configured provider backstop

[The complete read-back](budget-readback.json) records repository Actions budget
`581114fb-5d5a-4a71-95e0-16773b646082`, amount USD 50, **stop usage enabled**, alerts
enabled for `CarsonAurum`, and USD 0 consumed / USD 50 remaining at read-back.
Both the complete budget listing and the individual budget endpoint confirmed it.
Offline plan fields do not attest provider configuration; their
`providerBudgetConfigured: false` remains an explicit limit on planner evidence,
while the separate API read-back records the actual configured budget.
A first individual read returned 404 during propagation; the subsequent read passed.
The existing organization USD 250 Actions budget was left unchanged. Enterprise
read access is unavailable, so the enterprise USD 100 budget is operator-reported.

This is a new remaining allocation from creation, not a rewrite of earlier
November charges. GitHub excludes pre-creation usage from a new budget's first
cycle. The product budget covers all Actions charges; included non-compute usage
is expected to keep those charges at zero. If it becomes billable it consumes the
same USD 50 rather than increasing this limit. Budget/usage reporting and provider
cutoffs can lag; this is not an exact instantaneous invoice cap.

GitHub repository budgets recur monthly and have no repository expiry field.
The source admission authorization is explicitly valid November 12 through
November 30, 2026 UTC. Review the next cycle before renewing source authorization.
The existing timing/upstream schedules remain enabled under the provider budget;
they do not use the source CI admission window or per-run reservations.

## Source admission and next run

[Admission policy](../../../../Tools/ci/admission.v1.json) now records verified
runner groups/SKUs, published list-rate ceilings and an affirmative operator
assurance for included non-compute capacity. [The usage baseline](usage-baseline.json)
shows the corresponding runner unit rates and zero net storage charges; the
repository cache usage endpoint reported zero active bytes. Included capacity is
not an unlimited storage quota and must be rechecked if that assurance changes.

The automatic push scope remains **preflight**, eight jobs and 135 maximum runner
minutes on standard Ubuntu. The repository API confirms public visibility, so
these standard runners cost USD 0 under GitHub's public-repository exemption.
The operator additionally authorized **one full certification attempt**, monitored
manually, with a USD 723 source reservation covering the USD 722.99 timeout
ceiling. Manual native expansion is enabled; automatic push/PR scope remains
preflight. Diagnostic experiment allowance stays USD 50. No automatic test/build
reruns are authorized. The non-publishing full run and duplicate push preflight
were cancelled at the operator request. One replacement full run now includes
GitHub Pages publication after successful certification. Its additional free
standard-Ubuntu publication job raises the envelope to 82 jobs / 7,805 minutes
without changing the USD 722.99 cost ceiling. The monthly provider budget stays USD 50
and can block the full run before completion. Fresh planning and every CI job guard reject an
expired source authorization; per-run reservations do not form a monthly ledger.

| Scope | Maximum runner cost before included non-compute usage |
| --- | ---: |
| Push preflight | USD 0.00 |
| Linux qualification diagnostic, one attempt | USD 55.86 |
| macOS load diagnostic, one attempt | USD 35.70 |
| Full certification, one attempt | USD 722.99 |
| Existing Sunday timing workload, each execution | USD 22.44 |

These are outer-timeout ceilings, not forecasts or actual spend. The remaining
three Sunday timing runs could exceed USD 50 together, so later jobs may be
blocked by the provider budget. The Linux diagnostic exceeds its USD 50 experiment allowance. The authorized full
run fits its separate USD 723 source reservation, but can be stopped by the
USD 50 monthly provider budget. Launching it does not establish native
qualification or complete Phase 11; inspect terminal results and artifacts. GitHub release publication remains a
separate action. Keep the default branch at this revision until the Pages
publication guard has finished.

Sources checked November 12, 2026: [runner pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing),
[Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions),
[budget behavior](https://docs.github.com/en/billing/concepts/budgets-and-alerts),
and [budget API](https://docs.github.com/en/rest/billing/budgets).

[Local validation](validation.json) records 1,018 passing helper/browser tests,
six existing Linux-only skips, source/workflow checks and all 81 full-plan guards.
These checks do not establish hosted native qualification.

[Publication authorization](publication-authorization.json) records the replacement
scope and successful admission of all 82 job guards. The replacement commit skips
the automatic push workflow; its explicit full dispatch still runs all required
checks and publication.
