# MC-33 Gateway recovery prerequisite

The MiniCarson coordinator owns [MC-33](https://issues.aurum-studios.com/issue/MC-33). Carson explicitly authorized DiscordKit implementation and integration into local `main` on November 11, 2026: “Integrate the discordkit changes and commit them to main.” This scope includes source, tests, affected documentation, validation and local integration. No push, publication, release, live Discord or production operation is inferred.

## Inputs and behavior

- Current clean DiscordKit main/base: `9493598b56b68f463f6f51dcaa4b7d93830ec5ca`, including completed unrelated performance work. The prior planning snapshot and MiniCarson's historical pin are not this candidate's inputs. No existing recovery implementation was present.
- One isolated receiving branch owns production changes; test and documentation writers have disjoint claimed files in their own branches. Coordinator integrates their work serially. Existing performance checkouts/caches stay outside ownership.
- `GatewayReconnectBudgetPolicy.totalRun` remains the default. Maximum replacements remain zero through thirty, default five. Explicit `afterHealthySession(minimumDuration:minimumScheduledHeartbeatACKs:)` validates both thresholds as positive.
- Health belongs to one READY/RESUMED socket generation, requiring uninterrupted monotonic uptime and enough post-readiness scheduled ACK observations. A sole adapter-confirmed scheduled heartbeat can qualify at most once; requested, pre-ready, unsolicited, early and overlapping ACK observations cannot. More than two outstanding ambiguous beats conservatively disable new credit for that generation. ACKs have no nonce, so this is observational evidence rather than exact protocol pairing.
- Health time freezes at the first terminal child boundary before joined cleanup. A qualifying certificate can reset retries/backoff only after the existing recoverable-failure classification. Fatal/protocol/ownership/coordinator/overflow/continuity behavior, shared Identify/session budgets, Resume semantics, jitter, cancellation and joined cleanup remain independently enforced. No timer, history, runtime restart or effect replay is added.
- MiniCarson's proposed 300-second/two-ACK threshold is a consumer policy example, not a DiscordKit default or Discord requirement. MiniCarson must separately adopt and validate the final commit.

## Evidence status

Source is implemented but uncompiled/unexecuted at this checkpoint. Documentation presence audit using the hash-frozen existing offline validator passed: 992 files, 10,581 callables, zero missing comments. The validator binary's source-build binding is unavailable; its unchanged source and before/after binary hash are recorded locally. This syntactic check establishes neither behavior nor strict DocC resolution. Diff hygiene passed.

The official Gateway/status-code guidance was checked on November 11 by the documentation writer. Historical source provenance remains unchanged. No additional upstream endpoint/opcode is invented for this local configuration policy. Original overnight incident correlation, prior reconnect distribution and trigger remain unknown; synthetic tests cannot establish them.

## Resource admission

Known existing build roots exceed MiniCarson's default aggregate budget. Fresh admission saw about 29.67 GiB free and about 59 GiB in existing DiscordKit output. Existing compiled paths are mutable and embed main's paths, so they are not reused as changed-source validation. A fresh single serialized lane is provisionally estimated at 3–4 GiB, retaining the earlier proposed cap of 8 GiB additional output and 10 GiB free reserve. Carson explicitly accepted this measured exception through the Air budget question on November 11: up to 8 GiB additional temporary output, one serialized validation lane, stopping before the 10 GiB free reserve. One heavy-build reservation was admitted afterward. Task-owned output is monitored and will be removed after retaining compact receipts. No unrelated cache is deleted or duplicated.

The final validation, independent exact-candidate review and local-main receipt must be appended before claiming integration complete. The issue remains Implementation until the mandatory coordinator-owned validation transition; no MC-33 closure or production qualification is supplied by this prerequisite.
