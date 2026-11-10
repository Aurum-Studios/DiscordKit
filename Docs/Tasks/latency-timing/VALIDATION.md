<!--
File: Docs/Tasks/latency-timing/VALIDATION.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Latency timing validation and reference-host procedure

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

The Stage 0 checkpoint advertised no new capture command. Stage 1 now supplies
the [shared harness commands](../../../Tools/DiscordBenchmarkSupport/README.md)
and [implementation record](PHASE-1.md). Existing executable recipes remain
runnable under their documented legacy semantics. New whole-population sidecars
have distinct identities and do not relabel historical baselines.

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

## Phase 1 validation

Executed 2026-11-10 on the local macOS ARM64 candidate described above with Apple
Swift 6.4. The [implementation record](PHASE-1.md) and
[shared harness guide](../../../Tools/DiscordBenchmarkSupport/README.md) describe
the adopted boundaries and reproduction commands. Stage 0 evidence above remains
historical; this checkpoint adds development code and three local package edges.

Each check below completed successfully:

| Check | Result |
| --- | --- |
| Root `swift build -j 4` and `swift test -j 4` | Build passed; 2,530 tests passed across 34 executable summaries |
| `swift test --package-path Tools/DiscordBenchmarkSupport -j 4` | 35 tests in five suites passed: histogram merging, precision, censoring, loss/overflow, sparse tails, reservoir selection, checked conversions, strict reports, compatibility, partial outcomes and concurrent collection |
| `python3 -m unittest discover -s Tools/DiscordBenchmarkSupport/scripts -p 'test_*.py'` | 29 tests passed: real process ownership, timeout/escalation, cancellation, output/RSS limits, incomplete reports, strict integer schema/receipt versions, release identity, fixtures, fresh processes and counterbalanced ordering |
| `swift test --package-path Tools/DiscordKitLoadTests -j 4` | 28 tests in four suites passed, including all-completion histograms beyond the legacy successful prefix |
| `swift test --package-path Tools/DiscordDSLBenchmarks -j 4` | 10 tests passed, including same-plan warmup exclusion, exact measured counters, failure/cancellation observations and joined cleanup |
| Offline `DiscordKitTools inventory validate --repository .` | Passed: 1,081 implemented, 15,475 pending semantic, 951 reviewed and 255 mapped records |
| `swift test --package-path Tools/DiscordKitTools -j 4` and its Python validator suite | 106 Swift tests in eight suites and 230 Python tests passed |
| Existing load and DSL Python readers | 12 load and 19 DSL tests passed; legacy reader scripts unchanged |
| Optimized participant preparation | All three participants built with `-c release --force-resolved-versions -j 4`; release receipts include executable, compiler/target/SDK, dependency pins and exact source identity |
| Common report CLI | Every release-capture sidecar passed `DiscordBenchmarkReports validate`; legacy adapters remain explicitly unqualified |
| Dependency, documentation and whitespace review | Runtime manifest/import graph and dependency pins unchanged; local Markdown targets and phase anchors resolve; `git diff --check` passed |

The subprocess tests exposed a Darwin race while an exited parent's orphaned group
was transitioning to zombies: `killpg(group, 0)` can return `EPERM`. Cleanup now
uses bounded process-state evidence to accept only an absent or entirely zombie
group; live or unknown groups retain failure status. The real early-exit/orphan
case then passed 500 consecutive repetitions. Injected permission states also
cover live and unavailable groups, and cleanup preserves an earlier timeout or
cancellation cause. Final review additionally closed boolean/float version
acceptance in Python and comparison of mismatched resource gauge scopes, units,
methods or availability.

### Local release captures

Captures ran sequentially, without competing task builds/tests. Direct optimized
smokes covered transport, HTTP policy, handwritten routing, DSL routing and local
duplex voice. A final driver run prepared fresh release receipts and performed
five paired direct/DSL observations plus one smoke each for transport, HTTP and
voice: 13 distinct subprocess identities, each reaped with no live process-group
members after cleanup. The standard order alternated A/B then B/A across all five
pairs. Source, executable and fixture receipts were checked before and after each
observation; no output bytes were dropped.

| Participant / native settings | Checked result |
| --- | --- |
| Transport `--scenario transport --profile accounts-100` | 10,000 whole-population successes; legacy prefix remains capped at 4,096; zero active/idle pool owners after shutdown |
| HTTP `--scenario http --profile accounts-100` | 2,000 whole-population successes; zero failure/refusal counts and zero queued/active/flight/cache owners after shutdown |
| Direct/DSL `--mode direct` or `dsl --handlers 10 --invocations 10000 --concurrency 1` | Every fresh process retained 10,000 observations and exact handler/callback totals with joined zero-owner cleanup; direct smokes also exercised 100 unmeasured warmup invocations |
| Voice `--seconds 0.1` | Five measured duplex ticks after 100 warmup frames per direction; two closed media, DAVE and datagram owners; native success and empty final media buffers |

The driver used `standard` for routing pairs, `smoke` otherwise, a one-second
requested measurement budget and declared native cohorts of 1, 8, 8 and 2 for
routing, transport, HTTP and voice. Voice declared two seconds of participant
warmup; other driver captures declared cold-process execution. Native commands
retain their actual operation counts/duration. Generic process supervision does
not prove that a participant obeyed a requested interval, cohort or retained-state
cap. The guide records this distinction and finite timeout/RSS/output limits.

Local logs, receipts and JSON remain in ignored build directories. Receipts bind
the pre-commit revision plus the exact dirty/untracked source fingerprint, rather
than claiming a committed executable identity. The final review checked hashes
of executable/test/build inputs before commit and reviewed documentation changes
separately. This evidence establishes local integrity and cleanup. It does not
establish a stable noise floor, numerical baseline, full stress/soak recovery,
observer overhead, hosted CI, Linux, physical audio, live Discord or deployment.

## Phase 2 validation

Executed 2026-11-10 from Phase 1 revision `2cbe0e10` on the local macOS ARM64
candidate with Apple Swift 6.4. The [implementation record](PHASE-2.md) and
[runtime interval guide](../../../Sources/DiscordLogging/DiscordLogging.docc/Guides/RuntimeIntervals.md)
describe the actual owner boundaries, propagation, clock validity and callback costs.
Historical Stage 0/1 results above remain unchanged.

| Check | Result |
| --- | --- |
| Root `swift build` | Passed |
| `SWIFTNIO_STRICT=1 swift test --jobs 6 --force-resolved-versions` | Passed: 2,556 tests across 34 executable summaries, including 26 new interval test methods and existing scalar/trusted-receipt suites |
| `swift build --package-path Examples/RESTOnly --jobs 4` | Passed: independently adopted REST consumer |
| `swift test --package-path Tools/DiscordKitLoadTests --jobs 4` | Passed: 28 tests in four suites |
| Load participant `swift build -c release --package-path Tools/DiscordKitLoadTests --jobs 4` | Passed; prepares local integrity smoke, not a performance baseline |
| Release load `--scenario http --profile accounts-100` | Existing validator passed: 2,000 successes, zero failures/cancellations/refusals, 1,045 wire exchanges, 1,155 avoided exchanges and 200 retry responses; active/queued/flight/cache ownership zero after shutdown |
| Release load `--scenario gateway --profile accounts-100` | Existing validator passed: 10,000 dispatches, one identify, two resumes/reconnects and six heartbeat/ACK pairs; connections, leases, pending requests and application writes zero after shutdown |
| Offline `DiscordKitTools inventory validate --repository .` | Passed: 18,245 entries from 290 sources, 1,081 implemented records, 15,475 pending semantic review, 951 reviewed definitions and 255 mapped endpoints |
| Offline `DiscordKitTools generate --check --repository .` / `parity check --repository .` | Passed: five generated artifacts byte-identical; parity evidence structurally valid |
| `swift test --package-path Tools/DiscordKitTools --jobs 4 --force-resolved-versions` | Passed: 106 Swift tests in eight suites |
| `python3 -m unittest discover -s Tools/DiscordKitTools/scripts -p 'test_*.py'` | Passed: 230 Python tests |
| Offline `DiscordKitTools documentation audit --repository .` | Passed: 841 Swift files, 9,169 explicit callable declarations, zero missing comments; semantic review performed separately |
| `python3 Tools/ci/emit_symbol_graphs.py --jobs 6` | Final export passed: 37 normalized graph files; 33 public library modules selected for documentation |
| `python3 Tools/ci/curate_docc.py --check` with the five affected `--module` selections | Passed after regenerating those modules' navigation: zero changed files; new detailed types and owner initializer signatures resolve |
| `python3 Tools/ci/build_docc.py` | Passed: all 33 public-module archives converted with strict diagnostics |
| Local Markdown link/anchor audit and whitespace review | Passed: 26 Markdown files, 247 local links/anchors; `git diff --check` clean |
| Independent review | No blocking arithmetic, lock/callback, terminal, ownership or result-propagation defect found; exact callback-cost and enabled auto-defer tests added following review |

The initial focused retry fixture stalled because its virtual clock did not advance
through the coordinator's existing one-second unknown-route debit. The fixture now
waits for the second admission boundary and advances that clock explicitly. A response
fixture also incorrectly created its interaction-clock origin after advancing time;
it now captures the origin first. These were test corrections; rate/deadline policy
was preserved. The final full root run includes both corrected fixtures.

The first symbol-graph export emitted the current libraries but exited unsuccessfully
while loading an unbuilt generated `DiscordKitPackageTests` module in the native
build directory. `swift build --build-tests --build-system native
--disable-experimental-prebuilts --jobs 6 --force-resolved-versions` completed that
local build graph. The standard export retry then passed, followed by fresh
navigation generation/checking and strict DocC conversion. Failed/old normalized
graphs were not accepted as final documentation evidence.

Manifests, dependency pins, runtime product graph and `OperationTiming.swift` are
unchanged. Ordinary constructor calls retain defaults; new observer parameters are
public signature additions, so code storing an initializer as a function value may
need to include the new parameter. No release API baseline or published version was
rewritten. Logs and local smoke reports remain under ignored build directories.
The new hook model does not write files, retain an unbounded history or start tasks.

This evidence establishes local semantics, integrity and cleanup. It does not
establish detailed trusted socket-receipt begins, per-event Gateway waterfalls,
broader Stage 5/6 catalog attribution, observer overhead, a numerical baseline,
hosted CI, Linux/device runtime, live Discord behavior, publication or deployment.
