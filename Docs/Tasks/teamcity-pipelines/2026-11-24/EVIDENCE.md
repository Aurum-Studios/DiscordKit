<!-- copyright:begin
File: Docs/Tasks/teamcity-pipelines/2026-11-24/EVIDENCE.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# TeamCity pipeline consolidation evidence

Local validation ran on macOS on November 24, 2026. The implementation
candidate was `6368f3c7801b8395dd3c26f1d57115196e43ee9c`.

| Acceptance | Check and result |
| --- | --- |
| AC-1 | `mvn -o -f .teamcity/pom.xml teamcity-configs:generate` passed with Maven 3.9.11, Java 21.0.11 and TeamCity DSL 2026.2. The base generated 26 classic configurations, or 28 with publishing. The candidate generated four pipelines with nine jobs and 15 classic configurations, or 17 with publishing. The publishing variant used placeholder context references and disabled native WSL to exercise both routing settings. |
| AC-2 | Generated XML and YAML assertions verified both platform qualifications, the global compile barrier, disjoint classic work, corresponding WSL affinity edges, repository verification, the export barrier and unchanged native driver command inventories. Generated Unix scripts passed `/bin/bash -n`. A scripted Linux dispatch check verified status propagation without running the Windows command. |
| AC-3 | Generated settings retain `DiscordKit_Certification`, strict same-chain DocC transfers, 19 distinct job receipt references, the GitHub pull request and status features, release approval and scoped publication. Separate review reproduced namespaced artifact transfer with TeamCity's artifact parser. `python3 -m unittest discover -s Tools/ci` ran 693 tests with 685 passed and eight skipped, including five new supervisor tests for artifact staging, retry, timeout and rejection. |
| AC-4 | The 38 Node browser tests passed. Source preflight verified 32 DocC examples, the upstream maintenance check passed and the YouTrack plan verifier found zero link warnings across 28 guides and 34 pages. `bash -n Tools/ci/teamcity_wsl.sh`, copyright and `git diff --check` passed. The setup guide records license read-back and rollback. |

The TeamCity version endpoint reported 2026.2.2. Authenticated license read-back,
the hosted settings import, Windows CMD and WSL execution, native build
qualification, failed-chain behavior and GitHub status remain pending. Local
generation establishes the configuration counts and graph, while the live
license counters depend on import and retirement of the superseded entities.
