# MC-29-D1 local evidence

Approved scope: explicit Air answer Authorize DiscordKit work, associated with
MiniCarson MC-29. Starting clean sibling main: f469253d6dcdc654afb6756e915579b942548038.
Local implementation branch: implement/MC-29-D1. Shared sibling main is preserved.

## Executed checks

- Original store at f469253d with identical corrected new regressions: two
  parameterized methods/six cases execute; all three positive-headroom alias
  orders and exact/after-reset cases fail (ten issues). Expected failure.
- Repaired rate/store/coordinator slice at a61dcbf: 31 methods/three suites pass.
- Combined clean 1f2bc0a0: Transport 23/4, HTTP 541/65, Gateway 119/11,
  Interactions 72/8, BotDSL 66/6, Commands 29/7, Client 14/3, CommandDSL 131/14
  test methods/suites pass, totaling 995/118. All timing regression cases execute.
- Exact eaa3474: fresh private-inclusive symbol graphs and warnings-as-errors
  DocC conversion pass for five affected modules, with zero diagnostics.
- All-visibility SwiftSyntax audit: 825 files/9,002 explicit callables/zero missing.
  The read-only existing pinned auditor binary has SHA-256
  e42819eca3a8d3450d0b06aca4afd085557198658fc53098643c9b6ae5185137; its
  source matches the candidate. Positive/negative private/inactive fixtures
  validate the actual audit invocation first.
- Authored REST tutorial: Swift 6/ApproachableConcurrency/warnings-as-errors
  compile and actual offline execution pass, observing four expected phases.
- Rendered DocC: eight pages/two clicked curated links; no page, console, local
  HTTP or request errors; browser/server join verified. Tutorial image inspected.
- git diff --check: base to exact reviewed candidate passes.

Commands use pinned dependencies, two compiler jobs, serial test execution and
one owned shared build. Swift 6.4 (swiftlang-6.4.0.34.1), arm64 macOS 27 local
test infrastructure; no retired application is built or run. Raw finite commands,
logs, source hashes, resource admission/releases and receipts are retained in the
MiniCarson Git-common MC-29 coordinator artifacts, not committed generated output.

## Operational failures retained

A preliminary rate run could not compile suite-level availability; per-test
availability follows existing practice without changing assertions. An initial
resource-wrapper cleanup called a nonexistent API; exact released ownership was
verified, the helper repaired, and all subsequent runs release normally.
Standalone compilation of the auditor against host SwiftSyntax was unsupported
(the tools package pins 604.0.0); the pinned existing auditor and sanity fixtures
provide the successful source audit. Initial private graph extraction encountered
Swift's duplicate Foundation PCM paths because the same owned build was reached
through a symlink; resolving the build path fixes extraction without source edits.
Initial rendered inspection expected the wrong overview heading; correcting the
expectation to the actual authored generated title yields the complete pass.
These failed attempts are not counted as passing checks.

## Independent acceptance

A separate reviewer authored none of D1 and examined all 33 changed files at
eaa3474a34c140e99c67eeefc1c075a6f2041a87 against f469253d, surrounding
rate/provenance/lifecycle code and raw validation receipts. No material finding;
local source gate accepted for phase-five pairing. Earlier isolated rate and
timing reviews also reported no material findings. Reviews are source/evidence
reviews; reviewers did not independently execute tests/browser checks.

MiniCarson consumer qualification, native Linux, real Discord/client observation
and production attribution remain separate. No network provider/live effects,
push, PR, merge, deployment or bot Start occurred.
