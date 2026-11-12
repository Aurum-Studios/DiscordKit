<!--
File: Docs/Tasks/ci-reliability/phase-9/IMPLEMENTATION.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 9 shared documentation inputs

Owner: Codex `/root`; branch `ci/phase-9-documentation`, sibling checkout
`DiscordKit-ci-phase9`. Base: `e37ad2bc` (Phase 8 completion receipt).
The [source preflight](source-preflight.json) records ownership and preserves the
original checkout's four planning-file hashes. Earlier phase worktrees remain intact.

## Plan and execution sheet

1. Preserve the existing three macOS native producers and every public API
   comparison. Convert each component once after restoring its exact compiled graphs.
2. Seal strict conversion outputs with source/content/pin and execution provenance,
   component/module scope, per-file size/hash and complete conversion status.
3. Publish a nonmatrix immutable artifact identity to a same-run read-only site
   consumer. Authenticate its original job and latest replacement before restoring;
   merge/transform validated archives without compilation, graph emission or conversion.
4. Require site preparation in the full barrier. Replace overlapping automatic
   documentation builds with a manual request for ordinary full CI.
5. Keep Pages upload/deploy after full qualification and an explicit publication
   request; verify current trusted default-branch source and immutable site bytes.
6. Run focused and complete helper suites, actual local DocC fixture rendering,
   workflow/source checks and independent review, then make scoped local commits.

| Limit | Phase 9 local preparation |
| --- | --- |
| Paid jobs / minutes / workflow attempts | 0 / 0 / 0 |
| Spend allowance | USD 0.00 |
| Native package compilations / native tests | 0 / 0 |
| Local checks | Python/Node helper groups, source/workflow checks; tiny installed-DocC fixture conversion and static rendering |
| Process bounds | 300-second helper groups; 300-second local rendering check; supervised TERM/grace/KILL cleanup |
| Remote writes | No push, dispatch, rerun, billing/runner setting change or publication |

The existing rollout setting remains unchanged. Phase 10 admission, Phase 3 native
x64 acceptance and Phase 11 hosted qualification remain open. No hosted savings,
native compatibility or live service claim follows from local helper tests.

## Implemented contracts

The macOS public API job calls `documentation_inputs.py prepare` once for each
of root/macros/extensions. Preparation validates restored graphs, supervises
curation and root tutorial checks, performs the existing strict conversion and
seals its module archives. Each component uses a finite shared preparation budget;
no command/test/compile retry is introduced. Every existing API baseline remains.
A source or execution change prevents export. Unsafe paths, links, duplicates,
missing/changed files, incomplete reports and unknown required fields fail closed.
Tar transport preserves colon-containing DocC filenames.

The nonmatrix conversion producer exposes its verified immutable upload ID/digest.
The consumer freshly validates same repository/workflow/event/source/run and the
original successful producer attempt, rejects newer unsuccessful replacements,
and validates every source/pin/file before staging. It consumes exactly the three
required components without duplicate public modules. Its only DocC operations
are one combined merge and one static transformation. Failed preparation leaves
no reusable marked output site. The site preserves root navigation, static routes,
hosting base path, `.nojekyll` and generated-site marker.

`documentation_workflow.py` supervises selection/download/site preparation with
480/480/1200-second command limits and a 2160-second shared aggregate. The site's
65-minute outer job includes ten-minute provisioning and bounded upload/diagnostic
reserves. Site export accepts only generated regular files. Full coverage names
the site job and its preparation step explicitly; missing, failed or skipped work
cannot qualify release. Release helper eligibility and historical records remain
unchanged.

Documentation has only a manual dispatch trigger. Its five-minute request job
uses job-scoped `actions: write` to request `ci.yml` full mode at the selected ref;
it neither compiles nor publishes. Its default publication choice is false. This
path still obtains ordinary producers through the contained full CI admission.

The optional CI publication job follows the exact successful full gate and site.
It alone has Pages/OIDC write permissions and the existing `github-pages`
environment/concurrency. The guard checks upstream repository identity and fork
status, the live default-branch tip, exact original workflow/ref/event/run/source,
current attempt, full and site jobs/required steps, and immutable artifact ID/name/
digest. It rechecks live run/tip stability, then safely stages only complete regular
site files. No `workflow_run` or cross-run privileged consumer is introduced.
A deploy-only rerun with an earlier site attempt fails closed and requires fresh
site preparation plus full barrier; native compiled producers can still be reused.

## Acceptance and remaining evidence

Local results and input hashes are recorded in [validation.json](validation.json);
independent review is recorded in [review.json](review.json). The real DocC fixture
uses tiny authored documentation and the installed Xcode DocC, with no Swift
compilation. It checks actual merged/static routes and base-path asset links;
structural and helper invocation fixtures prove the once-only producer graph.
This fixture does not claim all production catalogs were reconverted locally.

Real hosted producer/consumer transport, native Swift 6.4.1 conversions of all
production catalogs, full rendered-site acceptance, partial-rerun behavior and
measured build/transfer/runner savings remain Phase 11. Publication remains a
separately requested operation. Phase 10 still owns spend/trigger admission.
