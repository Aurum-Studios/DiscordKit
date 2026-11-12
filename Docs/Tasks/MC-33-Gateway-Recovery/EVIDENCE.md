# MC-33 Gateway recovery prerequisite

The MiniCarson coordinator owns [MC-33](https://issues.aurum-studios.com/issue/MC-33). Carson explicitly authorized DiscordKit implementation and integration into local `main` on November 11, 2026: “Integrate the discordkit changes and commit them to main.” This scope includes source, tests, affected documentation, validation and local integration. No push, publication, release, live Discord or production operation is inferred.

## Inputs and behavior

- Current clean DiscordKit main/base: `9493598b56b68f463f6f51dcaa4b7d93830ec5ca`, including completed unrelated performance work. The prior planning snapshot and MiniCarson's historical pin are not this candidate's inputs. No existing recovery implementation was present.
- One isolated receiving branch owns production changes; test and documentation writers have disjoint claimed files in their own branches. Coordinator integrates their work serially. Existing performance checkouts/caches stay outside ownership.
- `GatewayReconnectBudgetPolicy.totalRun` remains the default. Maximum replacements remain zero through thirty, default five. Explicit `afterHealthySession(minimumDuration:minimumScheduledHeartbeatACKs:)` validates both thresholds as positive.
- Health belongs to one READY/RESUMED socket generation, requiring uninterrupted monotonic uptime and enough post-readiness scheduled ACK observations. A sole adapter-confirmed scheduled heartbeat can qualify at most once; requested, pre-ready, unsolicited, early and overlapping ACK observations cannot. More than two outstanding ambiguous beats conservatively disable new credit for that generation. ACKs have no nonce, so this is observational evidence rather than exact protocol pairing.
- Health time freezes at the first terminal child boundary before joined cleanup. A qualifying certificate can reset retries/backoff only after the existing recoverable-failure classification. Fatal/protocol/ownership/coordinator/overflow/continuity behavior, shared Identify/session budgets, Resume semantics, jitter, cancellation and joined cleanup remain independently enforced. No timer, history, runtime restart or effect replay is added.
- MiniCarson's proposed 300-second/two-ACK threshold is a consumer policy example, not a DiscordKit default or Discord requirement. MiniCarson must separately adopt and validate the final commit.

## Initial source checkpoint (superseded below)

Source is implemented but uncompiled/unexecuted at this checkpoint. Documentation presence audit using the hash-frozen existing offline validator passed: 992 files, 10,581 callables, zero missing comments. The validator binary's source-build binding is unavailable; its unchanged source and before/after binary hash are recorded locally. This syntactic check establishes neither behavior nor strict DocC resolution. Diff hygiene passed.

The official Gateway/status-code guidance was checked on November 11 by the documentation writer. Historical source provenance remains unchanged. No additional upstream endpoint/opcode is invented for this local configuration policy. Original overnight incident correlation, prior reconnect distribution and trigger remain unknown; synthetic tests cannot establish them.

## Resource admission

Known existing build roots exceed MiniCarson's default aggregate budget. Fresh admission saw about 29.67 GiB free and about 59 GiB in existing DiscordKit output. Existing compiled paths are mutable and embed main's paths, so they are not reused as changed-source validation. A fresh single serialized lane is provisionally estimated at 3–4 GiB, retaining the earlier proposed cap of 8 GiB additional output and 10 GiB free reserve. Carson explicitly accepted this measured exception through the Air budget question on November 11: up to 8 GiB additional temporary output, one serialized validation lane, stopping before the 10 GiB free reserve. One heavy-build reservation was admitted afterward. Task-owned output is monitored and will be removed after retaining compact receipts. No unrelated cache is deleted or duplicated.

The initial checkpoint above preceded executable validation. Final local results follow; no MC-33 closure or production qualification is supplied by this dependency prerequisite.


## Local validation — November 11 local / November 12 UTC, 2026

Validated code/documentation candidate: `f51e64c2c9ef40fae0c3b89fa2e64b095809ff57`, based on clean main `9493598b56b68f463f6f51dcaa4b7d93830ec5ca`. Apple Swift 6.4, target `arm64-apple-macosx27.0.0`; pinned native SwiftPM backend, experimental prebuilts disabled, resolved versions forced and two build jobs. The backend and skip-update flags emit tooling deprecation warnings; no dependency pins changed. Executable/test/build inputs are retained as a 1,285-file SHA-256 manifest in compact local receipts.

| Check | Result |
| --- | --- |
| Root native `swift build` | Passed. |
| New recovery suite | 15 test functions / 30 parameterized scenarios passed. Initial compilation rejected suite-level availability; moving availability to individual tests matches existing fixtures and passed compilation. |
| Complete root regression inventory | All 2,707 discovered tests passed across 34 sequential module processes, each using default internal scheduling and anchored module filters. Discovery was identical before/after; every partition was nonempty and each final test count matched its discovered leaves. All 154 Gateway tests passed. |
| Development tooling | 106 Swift tests / 8 suites and 234 Python tests passed. Freshly built validator passed inventory validation, generation byte identity, parity and documentation audits on November 12 UTC. Existing global freshness dates/source pins were preserved. |
| Source documentation | 993 Swift files / 10,636 explicit callable declarations; zero missing comments. This is an all-visibility syntactic presence audit, supplemented by source review. |
| Gateway DocC and examples | 37 graph files emitted; affected Gateway curation check passed, then strict warnings-as-errors/analyze conversion and static transformation passed. Generated reference pages retain informational summary notes. The guide's exact Swift example typechecked; 32 existing tutorial code listings matched. |
| Rendered navigation | Pinned Playwright 1.64.1 inspected landing → guide → policy → associated-value case, configuration and its policy property. No failed HTTP resources or page errors. Air preview transport was unavailable; a task-owned pinned headless browser supplied this check. Browser and preview server were closed afterward. |
| REST-only adoption | Offline consumer build passed with explicit dependency-import checking; executable was not run. |
| Local Gateway load smoke | Debug `accounts-100` profile passed its existing report validator: 10,000 delivered dispatches, two Resumes, zero owned sockets and zero leases after shutdown, with other admission/cleanup assertions retained. This exercises default compatibility and supplies no optimized performance qualification. |
| Diff hygiene | `git diff --check` passed. |

An unrestricted default-scheduling root run finished with 53 issues, mostly deadline failures while CPU-heavy suites were active. A prior serial run stopped making progress in an unchanged HTTP virtual-clock fixture and was cancelled after 170 seconds; its process group was confirmed gone. Neither attempt is a passing receipt. Read-only triage identified a feasible pre-existing timer-registration interleaving, but did not prove the observed stall cause; resource contention as the source of the unrestricted failures also remains an inference. Complete module-isolated validation subsequently passed without changing those product/test inputs or omitting tests. This local scheduling variant is not exact hosted-CI parity: the repository CI also partitions modules but explicitly disables internal parallel scheduling.

Independent review found one P2 curation defect in the first authored reference pages. Regenerating the three affected navigation pages from current graphs closed the source issue; final independent read-back is recorded below. The policy guide retains authored explanation and the configuration example. No additional runtime finding was reported in the initial review.

Measured task output peaked at approximately 3.97 GiB, including the fallback browser, under the accepted 8-GiB cap; at least approximately 26.46 GiB remained free. No unrelated cache/performance worktree was modified. Task-owned generated output is disposable after retaining compact receipts.

Local macOS/offline results do not qualify Linux, hosted CI, live Discord, deployment or recovery of the historical incident. MiniCarson still must select/adopt this exact accepted dependency and complete its own sequential phases and validation. Local-main integration and final review are pending at this documentation checkpoint.


## Accepted review and local-main integration

An independent reviewer accepted exact candidate `686d1a8f6eb1042c128bd889145e1d98fa5114ca` with no open findings. The reviewer independently reconciled all 34 module receipts and 2,707 discovered test results, including 154 Gateway tests, and verified all 1,285 executable/test/build input hashes against the validated candidate. The regenerated reference-page curation finding is closed. Only this evidence record changed after the executable/documentation validation checkpoint; its unsuccessful attempts and qualification limits remain applicable.

On November 11 local / November 12 UTC, 2026, the coordinator fast-forwarded clean local `main` from `9493598b56b68f463f6f51dcaa4b7d93830ec5ca` to the accepted candidate. Fresh branch, ancestry, clean status and index-content checks preceded integration; exact main HEAD and clean status were verified afterward. This final documentation-only receipt records the completed operation. No push, hosted CI, release, deployment or live Discord operation occurred. MiniCarson's dependency adoption and remaining MC-33 phases are separate pending work.
