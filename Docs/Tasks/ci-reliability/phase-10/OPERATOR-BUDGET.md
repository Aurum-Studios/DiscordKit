<!--
File: Docs/Tasks/ci-reliability/phase-10/OPERATOR-BUDGET.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Repository budget and read-back

Current: the operator selected USD 50 remaining November compute on November 12,
2026, confirmed included non-compute usage and kept timing scheduled. The
repository stop-usage budget is configured and verified; see the
[November allocation and complete read-back](../november-2026/BUDGET.md).
Source preflight is enabled within a dated window. The proposal below is retained
as the historical preparation checklist, not the current authorization state.

Status: prepared operator checklist only. No settings were read as configured or
changed. The concrete proposal below is not an operator-selected allowance and
does not authorize a hosted job. Source admission retains USD 0.00.

| Setting | Proposed value requiring operator selection |
| --- | --- |
| Billing owner | Aurum-Studios |
| Scope | Repository `Aurum-Studios/DiscordKit` only |
| Budget type / product | Product-level / GitHub Actions |
| Amount | USD 50.00 per monthly billing cycle |
| Stop usage when budget limit is reached | Enabled |
| Threshold alerts | 75%, 90%, 100% |
| Recipients | Billing owner and explicitly selected operator; identities pending |
| Covered known runner SKUs | `actions_linux`, `linux_8_core`, `linux_64_core`, `macos_xl`; verify actual mappings and additional Actions storage/image SKUs |
| Existing overlapping budgets | Inventory before creation; their more restrictive stop rules may apply |

The USD 50 proposal is a monthly backstop, not a per-run allowance. It may be
insufficient for a conservatively bounded full certification. Review the actual
plan before choosing any per-experiment/workflow allowance. Included credits,
repository visibility and discounts must not be assumed to eliminate charges.

1. Obtain explicit authorization for the selected amount/scope/recipients before
   creating or changing a budget. Record the actual billing-cycle start/end and
   operator identity. Confirm each custom runner group's real billing SKU.
2. Open organization Billing & Licensing, then Budgets and alerts. Inspect existing
   repository, organization and account budgets before adding a repository-scoped
   Actions product budget. Select the proposed amount or a newly authorized amount,
   stop-usage behavior and the three alert thresholds.
3. After saving, completely read back the budget ID, owner, product/type, repository,
   selected amount/currency, current cycle, usage/remaining amount, stop-usage flag,
   thresholds and recipients. Retain a dated receipt with every value; mutation
   success alone is insufficient. Record separately any unavailable fields.
4. Verify the admission file's dated mappings/rates, non-runner charge envelope,
   safety allowance, run identity and maximum attempts before allowing execution.
   Retain proof that configured storage/transfer units cover all retained artifact/
   cache bytes and transport attempts; the configured envelope is not a byte quota.
   A monthly budget does not replace per-job admission or qualify native checks.
5. At the next cycle, verify the cycle rollover and current usage; changes to an
   amount or stop-usage rule require new explicit authorization and read-back.

GitHub documents repository budget scope, optional stop usage and 75/90/100 alerts
in [setting up budgets](https://docs.github.com/en/billing/how-tos/set-up-budgets).
Its [budget limitations](https://docs.github.com/en/billing/concepts/budgets-and-alerts)
explain that first-cycle usage before creation is excluded; the cycle can therefore
exceed the nominal amount. Usage and billing observation are not an instantaneous
local cutoff. Check current provider behavior when performing the authorized setup.
The [runner pricing reference](https://docs.github.com/en/billing/reference/actions-runner-pricing)
was checked on November 12, 2026: published rates match the retained Linux 8/64-core
and macOS 5-core list rates. This does not verify account pricing or group mappings.
