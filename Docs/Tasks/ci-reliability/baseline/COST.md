<!--
File: Docs/Tasks/ci-reliability/baseline/COST.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Retained runner usage baseline

The two runs have a **$35.962 USD known list-price subtotal** from 451 rounded
runner minutes. This is an estimate, not an invoice reconciliation. The user's
reported additional $40 remains an observation. One cancelled job has unknown
runner identity and invalid timestamps, so the subtotal excludes it.

Evidence: [offline run](https://github.com/Aurum-Studios/DiscordKit/actions/runs/43146954720)
(152 jobs) and [documentation run](https://github.com/Aurum-Studios/DiscordKit/actions/runs/43146954594)
(7 jobs), both at source `85eac6f3c1d3b17e53596c49e7438efee366c1b3`.
[cost-summary.json](cost-summary.json) retains every job's duration, category,
rounding and unknown fields. Raw pages and logs remain under [runs](runs/).

## Rates and rounding

The summarizer consumes the shared versioned
[scheduling policy](../../../../Tools/ci/scheduling-policy.v1.json), including
its rate dates, rather than maintaining another rate table. Prices were checked
against [GitHub's official runner pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing)
on November 12, 2026. Runner-group identity comes from the retained job API;
case normalization matches the policy's workflow groups. Mapping those groups to
billing SKUs is **not billing-verified**. Public-repository larger runners remain
paid usage; no free-minute allowance, credit or discount is assumed here.

Each started job rounds separately with `ceil(runner_seconds / 60)`, including
failed and cancelled work. Skipped jobs contribute zero. Missing/inverted
timestamps, unknown groups and stale/unavailable rates leave cost unknown.

| Run | Runner group / proposed billing SKU | Jobs | Runner seconds | Rounded minutes | USD/minute | Known subtotal USD |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Offline | Linux-x64-8 / linux_8_core | 63 | 7,453 | 161 | 0.022 | 3.542 |
| Offline | Linux-x64-64 / linux_64_core | 14 | 2,565 | 50 | 0.162 | 8.100 |
| Offline | MacOS-26-5 / macos_xl | 71 | 11,423 | 219 | 0.102 | 22.338 |
| Documentation | Linux-x64-8 / linux_8_core | 2 | 35 | 2 | 0.022 | 0.044 |
| Documentation | MacOS-26-5 / macos_xl | 5 | 947 | 19 | 0.102 | 1.938 |

Offline adds three skipped jobs and one cancelled export with no assigned runner,
giving 152 jobs total. Export `130962476496` reports completion at 03:59:25Z
before its 03:59:26Z start/creation, no steps, and no available log. It is retained
as unknown, not silently given negative or zero charged time. Offline's known
subtotal is $33.980; documentation adds $1.982.

## Time attribution

These are sums across jobs, not workflow wall time. `created_at → started_at`
is only an upper bound for queue time: it can include dependency waiting and
does not isolate runner capacity delays. The known upper bounds are 13,504 seconds
offline and 14 seconds for documentation. Per-runner-group values are in the JSON.

| Whole named API step category | Offline seconds | Documentation seconds |
| --- | ---: | ---: |
| Setup, host checks and action cleanup | 8,444 | 344 |
| Compile, including compound helper work | 5,057 | 460 |
| Discovery/planning outside compound helpers | 9 | 0 |
| Separate verification/restore | 17 | 16 |
| Tests/audits, including compound helper work | 5,800 | 9 |
| API/DocC checks, conversion and site export | 46 | 94 |
| Artifact upload steps | 257 | 21 |
| Artifact download steps | 1,320 | 3 |
| Other gates, packaging and deployment | 128 | 21 |

Compilation helpers also discover tests, emit applicable symbol graphs and create
archives; suite helpers restore, rediscover and execute suites/smokes. Their whole
step duration stays in one category, with mixed components identified per step.
This capture does not isolate those stages. API timestamps have second precision,
so category sums need not equal job durations. A zero discovery-only value does
not mean no discovery occurred. No missing step durations were observed.

## Artifact bytes and remaining gaps

All 167 retained artifact records had digests and were unexpired at capture.
Offline retained 157 artifacts totaling **10,743,621,569 stored archive bytes**;
documentation retained 10 totaling **775,922,078 bytes**. These sizes measure
stored outputs, not uploaded wire traffic or total consumer downloads.

Three complete failure/cancellation logs show successful downloads with explicit
archive sizes: macOS load 329,642,190 bytes; macOS DSLEvents 2,536,784,274 bytes;
Linux load 324,631,002 bytes. Their **3,191,057,466-byte observed subset** is a
lower bound on downloaded artifact archive bytes. Most successful consumer logs
were not retained in full, and documentation conversion is a tail excerpt. Total
download bytes, uploaded/downloaded wire bytes, storage/network charges and the
invoice remain unavailable; no transfer volume is inferred from repeated fan-out.

Regenerate offline from the repository root:

```sh
python3 Tools/ci/baseline_usage.py --output Docs/Tasks/ci-reliability/baseline/cost-summary.json
python3 -m unittest discover -s Tools/ci -p 'test_baseline_usage.py'
```

This baseline authorizes no hosted jobs and does not satisfy certification.
