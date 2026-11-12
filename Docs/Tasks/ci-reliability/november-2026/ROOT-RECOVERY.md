<!--
File: Docs/Tasks/ci-reliability/november-2026/ROOT-RECOVERY.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# November 12 Linux root consumer recovery

This records the recovery implemented in `d54e0e8b`. Its subsequent full run
again rejected a mixed weekly image pair. The
[comprehensive follow-up](FULL-AUDIT.md) replaces Linux's weekly-version
compatibility rule with exact observed compiler/runtime inputs and records the
checks completed before another push. The evidence below remains historical.

[Full publishing run 43275033751](https://github.com/Aurum-Studios/DiscordKit/actions/runs/43275033751)
at `7d226ce42382ad136559f8139f4483c371d49555` passed both load canaries and
advanced through core compilation into the root consumers. All four Linux root
groups failed during restore, before running any test. The run was cancelled
once these failures made certification/publication impossible.

Root groups 01, 03 and 04 rejected archive extraction because the producer's
repository-level `.build/spend/guard.json` collided with the consumer's fresh
spend reservation. The root producer archives `.build`; it previously excluded
its compilation diagnostics but unintentionally included the separate spend
reservation. Archive creation now omits only repository-level `.build/spend`.
Each job retains its own spend evidence separately. Compiled resources with a
nested directory named `spend` remain included. The consumer still rejects every
unexpected overwrite; that diagnostic now identifies the conflicting member.
A real-tar regression reproduces the failure before the fix and proves that the
consumer reservation, compiled executable and nested resources survive restore.

Root group 02 encountered a separate exact-image compatibility rejection. The
producer used `20261101.360.1`; this consumer used `20261111.370.1`. The complete
recorded runtime subtree differs only at `image.version`: compiler version and
target metadata, authenticated distribution, kernel and GLIBC match. GitHub's
new Ubuntu image release is still marked as deploying (`prerelease: true` at
observation). This is not evidence of a test or ABI defect. Exact image equality
remains enforced; no image values are overwritten or removed from compatibility.
A fresh full dispatch creates fresh producers, rather than retrying consumers
against the old compiled archives. Mixed images during GitHub's rollout can
still reject until that deployment converges.

The tooling audit was an independent failure after successful binary restore:
four callables lacked documentation. Added comments describe the timing command
initializer and three test-only actor helpers. The same existing compiled audit
now scans 995 Swift files and 10,685 explicit callable declarations with zero
missing comments. No callable implementation or audit rule changed.

Validation: all 634 CI helper tests completed in a simulated GitHub Actions
context on local macOS, with 628 passed and six existing Linux-only skips.
Independent review ran all 50 native-job tests successfully. Strict source,
compiler/SDK/image identity, immutable artifact selection, payload seals, safe
paths/links, overwrite rejection, deadlines and spend bounds remain enforced.
[Structured evidence](root-recovery-validation.json) records the failed jobs and
input hashes. The repaired push retains normal preflight and launches one full
publishing run. Hosted root tests and publication remain pending; USD 50 monthly
stop usage and the existing USD 723 workflow reservation are unchanged.
