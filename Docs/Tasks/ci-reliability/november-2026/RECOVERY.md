<!--
File: Docs/Tasks/ci-reliability/november-2026/RECOVERY.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# November 12 hosted bootstrap recovery

[Full publishing run 43266996709](https://github.com/Aurum-Studios/DiscordKit/actions/runs/43266996709)
at source `426fbd57c3e93a94f69509489ce0f6b74a193ea1` passed spend admission,
then its scope job failed while verifying the initial evidence artifact.
The Linux and macOS jobs were skipped; this failure supplies no native
qualification or publication evidence.

The upload finalized artifact `13967056973` at `2026-11-12T17:19:19Z`.
At `17:19:20Z` the immediate REST metadata read returned HTTP 404 and was treated
as permanent. A subsequent API read confirms the same artifact, source/run,
name and digest `sha256:bd0cb952420f15f6605589ae143338bd265ea584820b73c74f3df43750494cf0`.
This supports delayed metadata visibility after a successful upload as the cause.

The transport now retains the successful finalization ID and retries verification
of that exact ID after a post-finalization 404. It does not upload again or repeat
the artifact listing. The existing three attempts, 120 seconds per attempt and
420-second aggregate deadline still apply. Retry delays of two and four seconds
consume those same bounds. Authentication errors and mismatched ID, name, digest,
expiry or run still fail; a missing artifact outside this specific finalization
case remains permanent.

The scope log also forwarded about 384,000 characters of encoded Git filenames.
The source query and final plan took almost four minutes on the hosted runner,
although the same source query completed locally in under a second. Admission
now captures metadata output and prints a compact result. Every guard still
recomputes the exact source identity, and the complete plan remains in its JSON
output artifact. Failed source queries retain a bounded diagnostic excerpt.
Reduced hosted duration remains to be verified.

The operator requested the repaired push and one new full certification attempt
with publication enabled. Automatic push preflight remains enabled. The USD 50
repository stop-usage budget, USD 723 per-workflow reservation, 82-job / 7,805-minute
envelope, one-attempt restriction and November 30 source expiry are unchanged.
The failed run is superseded; no paid native job had started in its failed graph.

The checked-in upstream review is valid through November 12 UTC. That gate still
requires a genuine maintainer review once overdue. Pages still requires successful
full certification and a same-run artifact at the current default-branch revision.

Local validation and code input hashes are recorded in [recovery-validation.json](recovery-validation.json).
Hosted native tests, the complete toolchain and publication remain unqualified
until the new run finishes successfully.

## Follow-up gates before native execution

The repair at `9166fcf4cde8766f341474efe487c69849e9ccda` passed hosted bootstrap
and artifact retention in 21 seconds, followed by successful maintenance, browser,
tooling and benchmark helper checks. Full run `43269359753` and push preflight
`43269343066` then failed before native scheduling on two independent checks:

- Hosted actionlint invokes ShellCheck, which was absent locally. SC2016 flagged
  literal Markdown backticks inside the release-summary format. The format now
  escapes those backticks in double quotes and produces identical Markdown.
  Official ShellCheck 0.11.0 was downloaded to ignored local tooling and verified
  against its release asset SHA256. All seven workflows pass with it enabled.
- The usage-report integration test loaded active authorization and inherited
  GitHub identity, but asserted that admission must be rejected. Local execution
  had no hosted identity and therefore hid the assumption. The test now supplies
  explicit dated policies and local/hosted identities, tests rejected and admitted
  plans, and verifies identical results with unrelated ambient GitHub variables.
  No admission or usage-report product logic was relaxed.

The next repaired push retains automatic preflight, followed by an explicitly
dispatched full publishing run under the same recovery request and unchanged
budget bounds. These preceding attempts started no paid native jobs.

## macOS provisioning receipt normalization

At source `3a462d7c7a3cebf5138e589274d3d83500cb5d71`, push preflight
`43270058777` completed successfully and full run `43270087675` passed every
shared helper gate. The Linux platform/compiler/runtime probe and its artifact
retention passed. The macOS toolchain installation passed, but the subsequent
platform check rejected its provisioning receipt as belonging to another image
or SDK. The failed full run was cancelled before native compilation.

Both observations described the same SDK. Provisioning's command wrapper strips
stdout, while the probe's wrapper returns newline-terminated stdout. The common
SDK collector validated but retained those trailing newlines in five Xcode/SDK
fields, producing a different exact receipt and cache key. The collector now
strips the command-output boundaries consistently. It preserves multiline Xcode
text and all meaningful image, SDK, compiler, policy, signer and path checks.
New macOS receipt integration regressions reproduce the old failure using LF
and CRLF output; changes to each of the five SDK/Xcode facts still reject.

The encoded Git filename inventory is now quiet in native metadata collection
as well as admission. Exact captured bytes, logs, receipts and source hashes
remain available to their owners; failed metadata queries retain bounded console
diagnostics. Ordinary text metadata is still visible. This avoids repeating the
large console record in native planning and consumers.

The next push runs normal preflight and a new explicit full publishing dispatch
under the same recovery request. The signed compiler download and all native
compatibility checks remain enforced. Successful preflight and a Linux probe
still do not certify the entire native toolchain or publish documentation.
