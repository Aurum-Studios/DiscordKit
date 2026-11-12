<!--
File: Docs/Tasks/ci-reliability/baseline/CAPTURE.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 0 retained remote evidence

Read-only capture on November 12, 2026 UTC for source
`85eac6f3c1d3b17e53596c49e7438efee366c1b3`. No workflow dispatch, retry,
push, billing change, build, publication or deployment was performed.

[Offline run 43146954720](https://github.com/Aurum-Studios/DiscordKit/actions/runs/43146954720)
has all 152 jobs retained in two pages (100 + 52): 142 success, five failure,
two cancelled and three skipped.
[Documentation run 43146954594](https://github.com/Aurum-Studios/DiscordKit/actions/runs/43146954594)
has all seven jobs retained, all successful. Run metadata and original API payload
shapes are preserved under each run directory.

All 157 offline artifacts (100 + 57) and ten documentation artifacts have retained
IDs, names, sizes, GitHub-reported digests and expiry. None were marked expired at
capture. Offline metadata reports 10,743,621,569 retained bytes and documentation
775,922,078 bytes; these are archive storage sizes, not total network traffic or
invoiced storage. Earliest expiries are November 14 at 03:18:57 UTC and 03:19:17 UTC,
respectively. Artifact archive download allowance was zero bytes: no compiled
archive or other binary artifact was downloaded.

## Failure and cancellation classification

| Job ID | Job | Evidence and classification |
| --- | --- | --- |
| 130951994094 | macOS ARM64 / Tests / load | Complete 3,736-line log. Assertion failure: `wallCapHasJoinedPartialPopulation`; 146 tests/27 suites end with one issue. |
| 130951994277 | macOS ARM64 / Tests / DSLEvents | Complete 542-line log. Three tests and smoke pass; required evidence upload fails `CreateArtifact` with `ENOTFOUND`. Transport failure, not a test assertion. |
| 130952646908 | Linux x64 / Tests / load | Complete 3,374-line log. Test operation cancelled after prolonged silence; last test-case output names `.dslCancelled`. No stack proves its blocked owner and no supervisor timeout is established. |
| 130955307556 | macOS ARM64 / Platform validation passed | Complete 121-line log. Aggregate gate fails because test-suites result is failure; not an independent product test. |
| 130962475454 | Linux x64 / Platform validation passed | Complete 122-line log. Aggregate gate fails because test-suites result is cancelled. |
| 130962476496 | Linux x64 / Export validated platform source | Cancelled with no runner/step fields. Logs API returns HTTP 404. Queued/unassigned classification is inferred from missing runner/step evidence; no execution log is available. Metadata end time precedes start by one second. |
| 130962519712 | Offline certification passed | Complete 66-line log. Final aggregate fails; it does not satisfy complete certification. |

No failed provisioning job is present in this snapshot. The Linux incident is a
cancelled test operation; treating it as a diagnosed timeout or deadlock would
exceed the retained evidence.

The macOS load diagnostic explicitly reports one discarded copy:
`2026-11-12T03:32:59.4524040Z ↳   report.measurement.discardedAdmittedCopies → 1`.
This is line 1507 of the uncompressed log for job 130951994094. The assertion is
established; its exact interleaving is not. Linux's last case output is
`2026-11-12T03:34:07.8890962Z ◇ Test case passing 1 argument scenario → .dslCancelled to completeEquivalentPopulations(scenario:) started.`
at line 3307; cancellation follows at 03:59:20.9589494 UTC.

The DSLEvents log retains the exact 2,536,784,274-byte consumer archive ID
13913026031 and its expected/downloaded digest. Its large restore and repeated
toolchain download can therefore be compared with its tiny test duration without
downloading that compiled archive.

## Files and coverage

- [capture-coverage.json](capture-coverage.json): API methods, page coverage, byte
  limits and explicit access/coverage gaps.
- [log-index.json](log-index.json): all 17 requested jobs; 16 gzip log files,
  reported/retained line counts, complete/excerpt flags and compressed/raw hashes.
- [native-facts.json](native-facts.json): hosted runner images/architecture,
  installed Swift 6.4.1, pre-setup Swift and native dependency observations with
  original uncompressed log line references.
- [source-facts.json](source-facts.json): exact source hashes, committed dependency
  pins and setup policy. No dependency resolution was performed.
- [SHA256SUMS](SHA256SUMS): SHA-256 of the capture-owned files only. The separate
  source preflight, local environment and cost-summary files have other owners
  and are deliberately outside this manifest.

All six available failure/cancellation logs are complete by the connector's
reported original line count. Five successful-job logs are 5,000-line tail
excerpts because the connector caps output despite a 20,000-line request. Their
original sizes and excerpt status are explicit in the index. Remaining successful
job logs were not requested. The original full workflow ZIP, HTTP response
headers, full installed-package/SDK inventory and invoice reconciliation are
unavailable here. Metadata digests do not independently verify undownloaded
artifact contents. No signed artifact URL or credential was persisted.
