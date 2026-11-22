<!-- copyright:begin
File: Docs/Plans/Repository-Initialization.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Repository initialization

Project: DiscordKit (`discordkit`).

Purpose: A modular, Swift-native library for Discord applications and bots.

Company allocation: `com.aurum-studios.libraries.discordkit` (`library`, key
`discordkit`). Identity UUID: `b467fa11-3125-59c2-86af-f22bd630eaf4`.
Read [the identity contract](../Identity.md) and `.air/project.json` under
`identity` before creating product/package/tooling names. Local generation leaves
company allocation unverified; repository and display names do not rename it.

Default branch: `main`. Tracker mode: `youtrack`. YouTrack project: `pending verification (YouTrack)`.

DiscordKit adopts the current Aurum Studios Blank template in its existing
SwiftPM repository. The new foundation adds the Air skills and tracker
configuration, engineering and documentation conventions, and a library
namespace. Swift products, dependency pins and attributed licenses retain
their existing identifiers and terms.

The [TeamCity settings](../../.teamcity/settings.kts) port Linux and macOS
qualification, parallel compilation, distributed suites and the certification
gate. They also provide a manual GitHub Release job and retain the DocC site as a
build artifact. Finish project provisioning, import and hosted verification
using the [setup runbook](../TeamCitySetup.md).

Review [selected language guidance](../Languages/README.md) against the actual
stack. Configuration records the resolved profiles under `guidance.languages`;
selection supplies no application code, installed toolchain or validation result.
Read **Preferred tools and dependencies** before making new choices and record
project-specific tool/package identifiers, source links, purpose and constraints
in those copied profiles. Preserve existing project choices and resolve material
conflicts before dependency changes.

Review the selected root .gitignore rules and copied `<profile>/gitignore`
fragments against actual component paths. Follow [dependency and build guidance](../Dependencies.md)
to commit exact tool/dependency pins and variants, initialize source submodules
at recorded revisions and configure compatible cache reuse. Keep lockfiles,
wrappers, authored assets and submodule metadata visible. Verify a clean restore
and unchanged rebuild when the real stack is configured.

Apply [the documentation standards](../Documentation.md) throughout Markdown,
source symbols, examples and tooling. Plan concrete setup, architecture,
reference, tutorial and operational material as product concerns are implemented.
Configure actual documentation checks alongside the other project checks.

For future product work, use `discordkit-plan` to define acceptance criteria and ordered phases under the Air contract. The existing local validation commands are recorded in `.air/project.json`.

When YouTrack is enabled, verify authenticated access, the actual project and existing state field/value mapping before tracker-dependent stage writes. Do not create fields, states or boards as part of routine issue work. An explicit request to skip all tracker operations retains the supplied local task identity.

For separately authorized creation of a new YouTrack project, follow the
[project template kit](../YouTrack/README.md) and [launch checklist](../YouTrack/Launch-Checklist.md).
Generation includes setup references and issue text. Explicit
[automatic setup](../YouTrack/Automatic-Setup.md) can configure the supported schema
of a supplied empty project and record real mapping IDs after read-back. Ordinary
generation leaves mapping pending. Neither path creates the project, converts a
native template or seeds issues/articles. Review inherited workflows separately.

The [Knowledge Base updater](../YouTrack/Knowledge-Base.md) separately publishes
all rendered repository Markdown through the article MCP connector after Git
initialization. Complete this initial sync within requested YouTrack documentation
setup, then use `$discordkit-kb-sync` for later updates. Record the actual
library link and verified result; ordinary generation and missing access remain
unpublished/pending.

Confirm the approved GitHub repository or other Git remote, access, licensing
and branch protections with the project owner. Inspect TeamCity agent
capabilities before importing settings or enabling product builds. Record verified
YouTrack schema and commit-to-issue links when configured. For publication, record
the source revision, Knowledge Base article URLs, verified audience and any
conflicts or pending articles.
