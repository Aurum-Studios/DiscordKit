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
