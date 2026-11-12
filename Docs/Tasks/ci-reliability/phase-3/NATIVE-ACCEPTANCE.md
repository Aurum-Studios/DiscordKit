<!--
File: Docs/Tasks/ci-reliability/phase-3/NATIVE-ACCEPTANCE.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Remaining native acceptance

The repair is locally tested under x64 emulation. Phase 3 still requires a
verified **native x64 Ubuntu 24.04** host and **Swift 6.4.1**. No paid host, GitHub
run, push or dispatch is authorized by the local zero-paid execution sheet.

Before execution, record the host/owner, exact source commit and content hashes,
compiler/target, OS, CPU/memory/disk, virtualization and absence of x64 translation.
Use an isolated checkout and private scratch/output directories. Retain the existing
local evidence; copy this phase's replay driver into a fresh evidence directory and
adjust its output location, or invoke the same `linux_ci.Command` argument vectors
directly. Do not overwrite the committed Rosetta receipts with native results.

Use six compiler jobs and committed pins. Each compilation is limited to 1,200
seconds; discovery to 60 seconds; focused tests to 90 seconds with 30/60-second
stacks; the whole load package to 600 seconds; each existing REST/loopback smoke to
120 seconds. Record an aggregate deadline before admission. Limit a diagnostic
experiment to two native test-process attempts, then inspect and revise. A hosted
sheet additionally needs the explicit job/minute/attempt/spend allowance, runner
pool/rate, owner and remaining balance before dispatch.

Required replay:

1. Cold-build the load package with tests separately, using native SwiftPM,
   `--force-resolved-versions`, `--disable-experimental-prebuilts`, strict imports
   and `SWIFTNIO_STRICT=1` as retained in `validate.py`.
2. Require nonempty exact discovery. Run the synthetic and transport suites with
   `--skip-build --no-parallel` under their focused deadlines. Keep all parameterized
   cases. If either stalls, capture meaningful native stacks and the complete
   admitted-session tree before cleanup; do not increase the limit or exclude it.
3. Run all eight synthetic CLI scenarios in separate processes and verify their
   exact seven-request parity, failure/cancellation populations and zero owners.
4. Run the whole load package in one process with the same settings. An isolated
   pass is insufficient. Retain the final Swift Testing summary and verified session
   cleanup; the baseline XCTest zero-test banner is not the acceptance count.
5. Run both existing REST and loopback smokes, validate native/common reports and
   zero owners. The local evidence used the debug executable. To qualify the
   workflow's release path, separately build its release product within a recorded
   compilation allowance before using the unchanged smoke argument vectors.
6. Run changed peer and CI helper regressions; retain exits, diagnostics and complete
   cleanup receipts. Bind all tested inputs and artifacts to the actual commit.

Only after the required native result passes may the Phase 3 ledger advance.
An identical cause for the older hosted stall remains an inference unless its
own stacks or an equivalent native reproduction support that attribution.
