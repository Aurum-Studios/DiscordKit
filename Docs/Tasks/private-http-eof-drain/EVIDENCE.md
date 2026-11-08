# Evidence

- Initial checkout clean; HEAD `08606545afd39b0d3a3785c02490307074c8fbb6`.
- Read CONTRIBUTING.md and relevant architecture, concurrency, dependencies, platform and NIO API documentation.
- Current source: HTTPWireHandler checks cumulative maximumResponseBytes before a separate 65,536 + chunkBytes queued-byte guard. SwiftNIO BaseSocketChannel.readEOF0 loops readable0 synchronously to EOF. NIOHTTPIngress writes Connection: close and closes its responder after flushing the response.
- Initial reconciliation completed before the red/green work recorded below. Original sibling remains outside writer scope. Parent owns resource leases.

## Red baseline

- Receipt: `.build/private-http-eof-drain/red-20261108T101702Z/` (`command.json`, `swift.log`, `exit-code.txt`).
- Command: `SWIFTNIO_STRICT=1 swift test --disable-sandbox --disable-automatic-resolution --jobs 6 --filter HTTPAdapterTests.closedResponseRetainsExactAggregateLimit`.
- Exit 1. Both Content-Length and EOF-framed exact-limit cases failed with `.responseTooLarge` after the server-close barrier, at 262,144 response bytes with an unchanged 8,192-byte read chunk. Test duration 0.008 seconds; build 102.45 seconds. No sleeps, live endpoint, credentials or response data logging.

## Repair

- Removed only the incompatible secondary queue-byte ceiling and obsolete queue-byte counter; cumulative `maximumResponseBytes` guard still runs before retention or delivery. Normal demand reads, emitted chunk limits, no-retry behavior and cleanup ownership are unchanged.
- Declaration/API guide now state whole-response retained-payload bounds on peer EOF. Parent owns corresponding repository Docs/Transport.md update outside this writer scope.
- Green validation follows below.

## Green validation

- Full target receipt: `.build/private-http-eof-drain/green-20261108T101958Z/`.
- Command: `SWIFTNIO_STRICT=1 swift test --disable-sandbox --disable-automatic-resolution --jobs 6 --filter DiscordNIOTransportTests`.
- Exit 0; 58 tests in 8 suites passed, test duration 5.024 seconds (build 30.83 seconds). Includes exact-limit Content-Length/EOF response retention, one-byte aggregate overflow, unread response close, pending cancellation/deadline, pool shutdown, ingress, datagrams and WebSocket ownership checks.
- Final framing receipt: `.build/private-http-eof-drain/framing-20261108T102150Z/`.
- Command: `SWIFTNIO_STRICT=1 swift test --disable-sandbox --disable-automatic-resolution --jobs 6 --filter 'HTTPAdapterTests.closedResponse|HTTPAdapterTests.closeUnreadClosedResponse'`.
- Exit 0; 3 tests with 5 cases passed, test duration 0.010 seconds (build 4.15 seconds). This test-only follow-up explicitly asserts Content-Length 262144 for the known-length case, absent Content-Length and Transfer-Encoding for EOF framing, and Connection: close. The existing fixture disables automatic framing headers. No production source changed after the full-target pass.
- Independent final read-only review found no blocking findings in the production/test/documentation diff, aggregate response-budget enforcement, connection reuse or joined cleanup.
- Paired MiniCarson consumer validation passed 316 tests across 54 suites in 323.763 seconds; receipt in its checkout: `.build/harness/runs/20261108T102204Z-g0vq4df5/`. This includes the real near-limit nested binary/symbol request/response round trip. The parent task records exact tested source hashes and the separate application evidence.
- Original sibling checkout git status remains clean. No source staging or commits. `git diff --check` passes.
- Exact owned-source patch and hashes: `.build/private-http-eof-drain/source.patch` and `source-sha256.json`; task records and parent-owned Docs/Transport.md edits are outside that patch.

## Source identity

- `Sources/DiscordNIOTransport/NIOHTTPTransport.swift`: `7b4e065fbb7e39d5600ac9a4e8146279344edfe4c90663b34a9a97ec8a4d193f`
- `Sources/DiscordNIOTransport/DiscordNIOTransport.docc/Guides/NetworkAdapters.md`: `3692b0904c594540579fa4123309ac633e0b918960517c48a4ef5f0233046875`
- `Tests/DiscordNIOTransportTests/HTTPAdapterTests.swift`: `cbc7505b280bbb0fa00c140157ce3aa6b5b41ec7d76049123d15bae07210fb8c`
- Owned-source patch SHA256: `2b70a50539e06f72dccc42e7d65c120cbb40fae144d1de30dd11dd545182d9f8`

## Documentation

- Receipt: `.build/private-http-eof-drain/docc-20261108T102257Z/` retains exact commands, fresh public symbol graphs, extraction/conversion logs and DiscordNIOTransport.doccarchive.
- `SWIFTNIO_STRICT=1 swift package --disable-sandbox --disable-automatic-resolution --jobs 6 dump-symbol-graph --minimum-access-level public` passed.
- `xcrun docc convert` for the NIO catalog passed with `--warnings-as-errors --analyze`, public documentation coverage and external-link metadata enabled; exact arguments in commands.json. Conversion emitted existing summary notes but no warnings/errors. Changed rendered NetworkAdapters article JSON contains the EOF whole-response retention contract and response-cap reference.
- Public coverage output is not all-access documentation qualification: generated existing reference pages still lack some summaries. Every newly declared fixture/test callable has purpose, parameters/behavior and cleanup documentation.
- Native Linux, full-package test execution, REST-only example and whole application load scenarios remain unrun by this worker. Paired MiniCarson validation and any broader checks belong to the parent task.
- Toolchain: Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS arm64. Local loopback only; no production or Discord calls.

## Current consolidation qualification

Fresh receipt: `.build/consolidation-sibling-20261108T135721Z/summary.json`.
All source, manifest and dependency pin hashes stayed unchanged; SwiftNIO SSL
remained 2.37.5. Existing source/DocC validation above remains provenance, with
fresh paired three-catalog conversion recorded by the MiniCarson consolidation.

- Strict transport target: 58 tests / eight suites passed.
- Required root `swift build` passed.
- Required serial full `swift test`: 2,469 tests / 304 suites / 30 bundles passed.
- Required RESTOnly example build and release load-tool build passed.
- Concrete NIO HTTP loopback `accounts-100` normal and burst: 10,000 offered
  exchanges each, all applicable gates passed, zero request failures and zero
  retained pool/peer connections after joined shutdown. This is local-only
  transport load evidence, not live Discord or native Linux qualification.
- Commands used Swift 6.4 on macOS arm64, `SWIFTNIO_STRICT=1`, four compiler
  jobs and forced existing dependency versions. Existing RESTOnly deprecation
  warnings were nonblocking. Exact commands, timings and hashes are in receipt.
- Independent current review found no blocking source defect.
- `git diff --check` passed. Original official sibling checkout stayed clean.

The November 8 user request now authorizes these source/documentation/task
commits and local source consolidation. No push, remote PR/merge, deployment,
provider request or bot operation has occurred. MiniCarson CI must pin the
resulting sibling commit, and this branch must be pushed before that CI can
fetch its new revision.
