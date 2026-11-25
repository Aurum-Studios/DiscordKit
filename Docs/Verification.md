<!-- copyright:begin
File: Docs/Verification.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Verification record

## Mixed-load cache expiration

On November 24, 2026, the macOS package job for certification 3962 ran
`completeMixedCycle()` on `5e0a6ae5` and recorded zero cache expirations.
Overflow can reject the scheduled arrivals that advance the fixture clock.
Each band now advances the clock on its first arrival, which has a waiting
worker, and retains the periodic advances during the band.
[macOS package job 3959](https://ci.aurum-studios.com/buildConfiguration/DiscordKit_MacTestTooling/3959?buildTab=buildLog) ·
[Mixed-load procedure](../Tools/DiscordKitLoadTests/README.md#performance-phase-10-integration-and-recovery)

Local validation on macOS 27.0.1 ARM64 used Swift 6.4.2 and the resolved
dependency versions. The four `Phase10TimingTests` passed, followed by all
161 load-tool package tests. Three additional filtered `completeMixedCycle()`
runs passed. Hosted certification of the repair is pending.

## Offline certification DocC retry repair

On November 24, 2026, the certification chain reached the macOS DocC export
with 21 successful prerequisites. The export stopped when the archive join
encountered `documentation-inputs/root.tar.gz` left by an earlier run. The
pipeline preserves incoming artifacts in incremental checkouts. The repair
allows this job to replace its reconstructed archives after verifying the
current same-chain parts. [Certification 3933](https://ci.aurum-studios.com/buildConfiguration/DiscordKit_Certification/3933) ·
[DocC export 3936](https://ci.aurum-studios.com/pipeline/DiscordKit_CandidateExports/3932?job=3936&tab=log)

Local validation on macOS used base `738eb697315921ad31e785485f04fd2285f0974f`.
The repair passed independent review.

| Check | Result |
| --- | --- |
| Maven 3.9.11, Java 21 and TeamCity DSL 2026.2 | `mvn -o -f .teamcity/pom.xml teamcity-configs:generate` passed for the base and the repair. Generated settings differed only in the three DocC joins, and both generated scripts passed Bash syntax validation. |
| Incremental checkout | The generated base commands reproduced the hosted failure on a second run. The repair joined fresh fixtures for all three inputs on two retries. Corrupt parts withheld the export receipt and preserved the previous complete archive. |
| Certification receipt fixture | The generated classic gate accepted 19 matching fixture receipts and recorded the verified archive SHA-256. |
| CI helpers | `python3 -m unittest discover -s Tools/ci` ran 698 tests, with 692 passed and six skipped. |

Hosted qualification of the repair remains pending a new Offline certification
run on the published revision.

## TeamCity and YouTrack migration

The migration uses Aurum Studios Blank at `deded696cb08f13a64c56c13076cbc4ec2778cf4`
and starts from DiscordKit `8bfc38b5d6956340442cb7e92e66678f25176846`. This record
covers the uncommitted migration candidate checked on November 21, 2026.

| Area | Evidence | Hosted acceptance |
| --- | --- | --- |
| GitHub Actions | GitHub accepted the repository-level disable request. Policy read-back returned `enabled=false`. Follow-up run queries found zero active or queued runs. | Repository shutdown verified. The working-copy workflow removal still awaits source integration. |
| TeamCity configuration | `mvn -f .teamcity/pom.xml teamcity-configs:generate` passed with Maven 3.9.11, Java 21.0.11 and the Aurum server plugin API. Generated 69 default configurations and 71 with release and integration settings. Both variants had 59 required same-chain receipts. Generated shell syntax passed, and the DocC artifact was present in both variants. | Import authenticated project settings, qualify the three agents and run both lanes. |
| CI helpers | `python3 -m unittest discover -s Tools/ci` ran 671 tests. 663 passed, 6 skipped, and 2 unchanged process-group tests failed where the macOS sandbox limits process visibility. All 40 focused release tests passed. Source preflight and upstream maintenance checks passed. The next upstream review is due November 28. | Check same-chain artifacts and exact-SHA certification on TeamCity. |
| Browser and docs | All 38 Node browser tests and 32 DocC example snapshots validated locally. The DocC site remains a certification artifact. | Render and retain the full site in the macOS chain. Its publishing destination is pending. |
| YouTrack | Air configuration records YouTrack as the tracker. GitHub reported zero open issues. Project key, State mapping and Knowledge Base publication are pending. | Authenticate, discover the project, verify schema and issue links, and confirm the library audience. |
| Release | The TeamCity workflow prepares exact-SHA assets and uses a named approver and the build-scoped GitHub App credential for publication. | Connect the approved App, verify hosted certification read-back and qualify the deployment. |

TeamCity project discovery and YouTrack administration returned HTTP 401 without
authenticated access. Native platform execution, release qualification and
Knowledge Base publication remain pending. [Service setup](TeamCitySetup.md) ·
[CI coverage](CI.md)
