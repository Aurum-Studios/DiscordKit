<!--
File: Docs/Tasks/latency-timing/VALIDATION.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Stage 0 validation and reference-host procedure

Prepared 2026-11-10 against `c8d842f7ce51e9adc69ff9997e2c0f374dc2ee68`.
This records the contract checkpoint for [PLAN.md](PLAN.md),
[INVENTORY.md](INVENTORY.md), [METRICS.md](METRICS.md) and
[CONTRACTS.md](CONTRACTS.md). The implementation changes documentation only.

## Initial reference host

The available **candidate** is the local macOS ARM64 host. It is not yet a
qualified numerical baseline host. Read-only observations in this task:

| Property | Observed value / limitation |
| --- | --- |
| Hardware model | Mac15,10 |
| CPU allocation | 14 physical / 14 logical CPUs reported by sysctl; exclusive allocation and thermal state not established |
| Physical memory | 38,654,705,664 bytes |
| OS | macOS 27.0.1, build 26A434; Darwin arm64 |
| Compiler | Apple Swift 6.4, swiftlang-6.4.0.34.1, clang-2100.3.34.1 |
| Compiler target | arm64-apple-macosx27.0.0; this does not qualify deployment minima |
| Xcode / macOS SDK | Xcode 27.1, build 27A9275; SDK 27.0 |
| Configuration | Existing semantic tests use debug; future runtime performance captures require release |
| Other support | No Linux, Windows, mobile, browser, physical audio or live Discord timing run in Stage 0 |

These observations describe the session, not a permanent machine identity.
Stage 1 must obtain a stable platform-appropriate runner identity, effective CPU
allocation and unavailable-gauge reasons. A missing non-Darwin hardware identity
cannot be accepted as a comparison key.

## Reproducible capture procedure for later stages

1. Select a versioned workload from the inventory and catalog, its fixture seed,
   adapter, instrumentation mode and profile. Record exact source revision,
   dirty tracked/untracked content fingerprint, root/tool dependency-pin hashes,
   compiler/build flags, SDK/target, executable hash and host allocation. Reject
   unknown required provenance. Keep baseline/candidate outputs in separate paths.
2. Quiesce competing builds, tests, soaks and user workloads. Record power/thermal
   conditions where available, host contention and process scheduling policy.
   Use the same controlled allocation for both candidates. Shared CI smoke is
   informational regardless of its numerical result.
3. Build each runtime runner with `swift build -c release --force-resolved-versions`
   in its package. Build outside timed work; record build identity. Compiler
   workloads separately retain their declared configuration, currently debug
   consumer builds with prepared dependencies. Any C# work on macOS uses `msbuild`.
4. Pilot to choose explicit warmup and measured duration within the initial
   collection/process ceilings. Separate cold fresh-process cases from warmed
   steady state. Prepare fixtures, peers and expected results before the timer;
   validate results/checksums without including report serialization or diagnostic
   snapshots. Existing v1 runner boundaries remain historical until corrected.
5. Start five fresh-process paired standard observations, alternating A/B and
   B/A order with the order recorded. Do not run independent captures concurrently.
   Record every run, outcome and histogram/loss count, including unsuccessful and
   partial runs. Give subprocesses finite timeouts; terminate, escalate and reap
   owned groups, then await peers/tasks/sockets and check resource baselines.
6. Review whole-run distributions, counts, throughput, missed arrivals/deadlines,
   uncertainty, admitted/refused work, observer overhead and cleanup together.
   At least 10,000 observations in each gated population are required for p99;
   sparse populations retain insufficient-tail-data status. Do not combine marginal
   percentiles, average them into a population percentile or treat operations
   within one run as independent replications.
7. Run a no-change comparison to establish a measured noise floor before proposing
   numerical budgets. Check compatible catalog/metric/profile/fixture/toolchain/
   host/adapter/mode identity, including censor/loss constraints. Record paired
   deltas and variation. A >10% regression reproduced in three matching runs
   requires investigation; budgets/floors and promotion remain reviewed Stage 10
   work. Preserve failed baselines and never replace one automatically.

No new timing capture command is advertised here: the shared harness and report
adapters do not exist until Stage 1. The existing executable recipes in the
inventory remain runnable under their documented legacy semantics. A future guide
must supply actual new CLI flags only after implementing and testing them.

## Stage 0 checks

The required evidence is source/contract/link consistency, the existing timing
semantics, report-reader compatibility and a clean scoped diff. Full product
build/test and performance captures are not required for documentation-only edits
by [CONTRIBUTING.md](../../../CONTRIBUTING.md#validation-and-review).

Executed on the local host described above; each process exited successfully:

| Check | Result |
| --- | --- |
| `SWIFTNIO_STRICT=1 swift test --jobs 6 --force-resolved-versions --filter 'MC29.*TimingTests\|DiscordLogTests'` | 23 test methods in five suites passed (8 logging, 5 responder, 4 HTTP, 3 dispatcher, 3 trusted Gateway); parameterized cases also passed; debug test build completed |
| `python3 -m unittest discover -s Tools/DiscordKitLoadTests/scripts -p 'test_*.py'` | 12 tests passed; legacy load report/peer readers retained |
| `python3 -m unittest discover -s Tools/DiscordDSLBenchmarks/scripts -p 'test_*.py'` | 19 tests passed; compiler/runtime v1, baseline compatibility, invalid/missing data and regression cases |
| Local document/catalog audit | All five task documents; local links/anchors resolve; 79 unique version-1 metric IDs; exact coverage of 14 source phase cases and four unchanged outcomes; 11 workload families and all 12 stage inventory rows |
| Scope and whitespace audit | Only the five task Markdown files; no runtime/manifests/pins/artifact changes; `git diff --check` and staged whitespace check passed |
| Independent source/contract reviews | Two reviews completed; corrected dispatcher symbol, separate coalescer ownership, first-confirmed-response semantics, pool snapshot placement, batch checksum boundary and throughput drain accounting |

The document/catalog audit resolved relative Markdown links and heading anchors,
compared legacy metric IDs directly with the source enum cases, rejected duplicate
catalog IDs and checked stage coverage. Source review separately checked owner
symbols, JSON/profile defaults, report versions and boundaries; link existence
alone does not prove those semantics. No new implementation tests or targets were
added for this documentation checkpoint.

No runtime behavior, manifest, dependency pin, historical measurement artifact,
baseline, budget, CI workflow or tracker state is changed. The Stage 0 exit gate
does not establish numerical performance, native adapter qualification, device
behavior, publication or deployment.
