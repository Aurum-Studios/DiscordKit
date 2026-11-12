<!--
File: Docs/Tasks/ci-reliability/november-2026/FULL-AUDIT.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# November 12 comprehensive CI check before another push

The operator requested diagnosis and local verification before committing,
pushing or launching another hosted run. Source HEAD and remote main remain
`d54e0e8b33184bc08e1a9a23d73a7f4835b7027d`; the following repairs are local changes.
No new hosted run or publication was launched during this audit.

## Failure and repairs

[Full publishing run 43281310149](https://github.com/Aurum-Studios/DiscordKit/actions/runs/43281310149)
compiled the Linux load component successfully, then rejected its archive at the
canary's exact compatibility check, before executing tests. Producer and consumer
again had different weekly Ubuntu image versions. The downstream coverage/barrier
failures reflected that missing work. The doomed run was cancelled to stop further
spend; the macOS compiler was interrupted, not diagnosed as a separate compiler
failure. Cancellation is confirmed terminal. The earlier
[root archive reservation repair](ROOT-RECOVERY.md) remains necessary and intact.

Linux compatibility policy v2 compares actual compiler/runtime inputs instead of
using the weekly image build number as a proxy. A bounded helper scans the active
dedicated Swift installation's native ELF files, observes executable dependencies
under the actual environment and shared-library dependencies under recorded Swift
runtime search paths, then fingerprints the complete resolved library/loader bytes,
owning package versions and native compiler/linker tools. The common CRT/header set
includes libc6-dev, libgcc-13-dev, libstdc++-13-dev and linux-libc-dev. Both shared
prerequisite profiles explicitly install all four, so older already-installed
Linux headers are upgraded consistently after apt update. Missing
dependencies, partial facts, ownership gaps, changing files, excessive output or
elapsed limits fail closed. Child groups remain in the enclosing supervisor's
session and are reclaimed even when a parent exits with descendants alive.

The kernel, Ubuntu release, ImageOS, compiler target and paths, source/pin/build
identity and authenticated distribution/signing identity remain exact. Both hosted
image facts are still mandatory; the Linux weekly ImageVersion is diagnostic.
Each provisioning receipt and compiler cache key still bind its own full image
version. macOS and Windows image compatibility rules are unchanged. Legacy Linux
artifacts require fresh producers. Archive, immutable selection, coverage, resource,
overwrite, timeout and spend checks were not relaxed.

Rejected artifacts now retain bounded differing-field paths and expected/observed
previews before extraction. The Apple selected-module job forces resolved versions,
verifies Package.resolved bytes after resolution and compilation, and records its
original digest. A timeout test now gives its two real subprocesses enough time
to exercise aggregate cancellation deterministically on Linux; production deadlines
are unchanged. Existing identity-test fixtures now supply the complete new ABI
facts. CI documentation distinguishes current November authorization from historical
Phase 10 preparation and explains the one-attempt rerun restriction.

## Completed local verification

| Check | Result and limits |
| --- | --- |
| CI Python helpers | 650 on each OS: 644 passed and six existing Linux-only skips on macOS; all 650 passed on Ubuntu/Python 3.12/Node 24 |
| Other Python/browser helpers | 375 Python and 38 browser tests passed on each OS |
| Source/workflows | Policy/source inventory, 32 tutorial snapshots, all seven workflow files with actionlint and ShellCheck passed |
| Linux native handoff | Swift 6.4.1 compiled a real offline resource/parameterized-test fixture; production helpers archived it, restored it with a fresh consumer reservation, discovered and executed exact leaves, reconciled 6.4 events and checked final identity |
| Linux ABI observation | 109 native ELF inputs, 101 libraries, 50 installed packages and four tools; supervised observation fits the existing 30-second metadata allowance |
| Image drift regression | Actual local ABI facts replayed under both observed weekly labels compare equal; changed compiler/library/header facts reject. This is not an executed hosted image pair |
| Current root native tests | 2,710 discovered leaves: 2,709 passed, one existing MLS opt-in policy exclusion; exact event reconciliation passed |
| Current component native tests | Load 161, macros 34, extensions six, tooling 106; all 307 passed with discovery/event reconciliation |
| Supplementary retained tests | 149 benchmark/timing leaves and four LoggingApp leaves passed; these retained SwiftBuild binaries do not qualify current native build production |
| Compiler fixtures | All 26 macro fixtures and three extension fixtures passed with unchanged production strict flags |
| Apple compilation | All 72 selected module emissions across nine installed SDK/device/simulator targets passed through the new pin guard; pins unchanged |
| Audits/API/DocC | 11 audit commands, all eight API baseline comparisons, strict conversion of 36 public-module archives and three merged archives passed |
| Release products/smokes | Five current benchmark/load release products compiled; seven production timing smokes plus 1,000 DSL invocations passed |
| Local admission simulation | All 82 full-publication guards passed; 7,805 maximum minutes and USD 722.990 fit the unchanged USD 723 reservation. Wrong group/job, stale source, expired authorization and attempt 2 rejected |

The first combined helper run found one identity-query mock that had not yet
provided the new ABI response; both complete final suites pass after its repair.
Initial local extension API graphs and macro scratch metadata were stale. Fresh
extension graphs passed the baseline, and an existing source-built SwiftSyntax
cache passed all strict macro fixtures. Original failures and their superseding
evidence are retained; no baseline or production compiler strictness was changed.

macOS uses local Apple Swift 6.4 and installed SDKs. Linux execution uses a cached
official Swift 6.4.1 Ubuntu 24.04 x64 Docker image under local emulation. Neither
environment qualifies GitHub's actual fresh runner images. Root/macro/extension
optimized native release producers and fresh native consumer package graphs were
not cold rebuilt locally. Six retained consumer smokes passed; DSLEvents has no
retained executable. Full clean Linux/macOS certification, coverage aggregation,
sealed documentation export and actual publication therefore remain hosted checks.
No successful hosted certification or publication is claimed.

## Shared runner configuration before the next hosted run

Live inspection found all nine larger Linux runner pools use GitHub image 2306,
"Ubuntu Latest (24.04)". GitHub is
[migrating that alias to Ubuntu 26.04 during October 19–November 19](https://github.blog/changelog/2026-09-17-ubuntu-26-generally-available-and-latest-migration/),
while this toolchain explicitly requires Ubuntu 24.04. The prepared
[exact configuration plan](runner-image-update-plan.json) changes only image source
and image ID to GitHub's explicit Ubuntu 24.04 image 2295; sizing, capacity, group
access and workflow routing remain unchanged. It includes all nine current
configurations, PATCH bodies and GET read-back targets.

These groups also serve MiniCarson. Their cross-project configuration change has
not been applied and needs the operator's approval. No dedicated runner, custom
image or additional budget was created. The next push should retain normal free
preflight. A separately authorized full publishing dispatch needs fresh producers
at the final committed revision after resolving this shared pool choice.

[Structured validation](full-audit-validation.json) records input and evidence
hashes. Full local logs remain under the ignored
`.build/ci-complete-audit-2026-11-12` directory. The monthly USD 50 provider stop
usage budget and existing source reservations remain unchanged.
