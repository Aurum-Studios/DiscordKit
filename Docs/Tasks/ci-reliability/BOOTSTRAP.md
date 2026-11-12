<!--
File: Docs/Tasks/ci-reliability/BOOTSTRAP.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 0 execution sheet

Reviewed locally on November 12, 2026 UTC by Codex, the integration owner.
This sheet records the limits of the user's instruction to plan, implement, test
and commit Phase 0. It supplies no paid execution authorization.

## Ownership and source

- Base: `85eac6f3c1d3b17e53596c49e7438efee366c1b3`, matching the read-only
  `origin/main` lookup at preparation time.
- Implementation branch: `ci/phase-0-baseline` in the sibling
  `DiscordKit-ci-phase0` checkout. The original `DiscordKit` checkout and its four
  uncommitted planning files remain intact. The input hashes, initial status,
  worktrees, author, remote and process observations are retained in
  [source-preflight.json](baseline/source-preflight.json).
- One integration owner controls native planner/workflow changes in later phases.
  Phase 0 delegates separate evidence, policy and usage files; no delegate edits
  `native_jobs.py` or a workflow. Existing baseline and paired validation
  worktrees are retained. No validation process was observed during preflight.
- Authoritative phase boundaries remain [PLAN.md](PLAN.md); completion receipts
  belong in [STATE.md](STATE.md) and [EVIDENCE.md](EVIDENCE.md).

## Authorized experiment P0-local

| Property | Fixed limit |
| --- | --- |
| Scope | Read existing run metadata/logs; local policy/usage helper tests, source planning, JSON/hash/link/diff checks; scoped local commits |
| Platform | Existing macOS ARM64 host; Python standard library |
| Paid jobs / paid minutes / paid workflow attempts | **0 / 0 / 0** |
| Experiment and workflow spend allowance | **USD 0.00** |
| Native test-process attempts / cold compilations | **0 / 0** during Phase 0 |
| Automatic build/assertion/test retries | **0** |
| Local helper test invocation deadline | 300 seconds; bounded cleanup and retained output |
| Remote writes | None; no push, PR, workflow dispatch, rerun, billing or runner-setting change |
| Publication/deployment/runtime | None |

The versioned [scheduling policy](../../../Tools/ci/scheduling-policy.v1.json)
is the common planning and future cost-admission input. Its bootstrap authorization
is zero. Proposed operation limits and concurrency values are preparation for
later phases; they do not change the current workflow or process supervisor.
The existing full matrix still runs on pushes and PRs. Keep all intermediate
commits local. Remote review first requires a reviewed containment-only patch for
both CI and documentation, followed by explicit publication authorization.

Reproduce the source inventory, zero allowance and retained usage estimate
without compiling or contacting GitHub:

```sh
python3 Tools/ci/scheduling_policy.py validate
python3 Tools/ci/scheduling_policy.py bootstrap
python3 Tools/ci/scheduling_policy.py scope --mode diagnostic \
  --platform linux-x64 --component load --suite load
python3 Tools/ci/baseline_usage.py --output .build/phase-0-cost-recheck.json
```

The last command requires an existing `.build` directory; alternatively omit
`--output` to write JSON to stdout. Compare it byte-for-byte with
[cost-summary.json](baseline/cost-summary.json). Full native scope describes
24 producers and 101 suite jobs from the existing planner, across Linux/macOS
only. It does not include the workflow's auxiliary gates or separate
documentation run, nor discover test leaves. The baseline usage report includes
both retained historical runs independently of that source-scope description.

## Next diagnostic boundary

After Phase 1 supervision is implemented and tested, first inspect a matching
local Ubuntu environment. The host is ARM64 macOS 27.0.1. The already-running
Colima profile is Ubuntu 24.04.4 **aarch64** with six CPUs; it belongs to
MiniCarson and was only inspected. No container, VM, image or host setting was
changed. See [local-environment.json](baseline/local-environment.json).

Native Ubuntu x64 with pinned Swift 6.4.1 has not been established locally.
Running an x64 image under emulation on this ARM64 machine would provide
exploratory evidence, not native Linux acceptance. The system Swift is 6.4,
which also cannot qualify the pinned native toolchain.

Any future native experiment needs its own reviewed sheet specifying exact
revision, platform/component/suite, commands, runner SKU, verified rate and
rounding, paid job/minute/attempt limits, total allowance including reserves and
transfer/storage, and remaining authorization. Until that exists, its paid
allowance is zero. No proposed limit below grants execution:

- At most **two native test-process attempts per diagnostic experiment**, each
  limited to 90 seconds. Inspect retained evidence and revise the experiment
  before another attempt. Do not spend again on an unchanged reproduction.
- Bound cold compilation separately at 20 minutes per command and require a
  component aggregate budget. Compilation does not reset the test-attempt limit.
- Reserve finite provisioning, diagnosis, cleanup and upload time inside each
  paid job's enclosing deadline. A timeout fails; a transport retry cannot rerun
  a test or compiler. At most three transport attempts fit inside 420 seconds.
- The initial native build concurrency proposal is two per platform. Independent
  platform reservations must share a single workflow allowance before admission
  is enabled in Phase 10.

## Stop conditions and evidence gaps

Stop paid preparation at missing authorization, unknown/stale rate or runner
mapping, missing allowance, mismatched source/toolchain, unbounded operations,
empty scope/discovery, exhausted attempts, or an evidence contradiction. Retain
the failed result before revising the plan. No partial diagnostic may emit the
`Offline certification passed` result or qualify source exports/releases.

Runner list rates and workflow-declared pool mappings support a baseline estimate;
they are not invoice verification. The reported additional USD 40 remains a
user observation. Missing/expired artifacts, unavailable queued-job logs and
unseparated mixed-step timings are recorded explicitly in the baseline rather
than filled with estimates. Phase 0's completion does not close any runtime
defect, hosted qualification, billing reconciliation or later phase.
