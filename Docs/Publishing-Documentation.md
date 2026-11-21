<!-- copyright:begin
File: Docs/Publishing-Documentation.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Build and publish DiscordKit documentation

Public project guides are available in the GitHub repository. YouTrack hosts
the curated guides for the DiscordKit Team, and TeamCity builds and retains the
DocC archive. Offline certification runs both documentation checks.

| Output | Source | Delivery |
| --- | --- | --- |
| [DiscordKit Knowledge Base](https://issues.aurum-studios.com/articles/DISCORDKIT-A-1/DiscordKit-Overview) | [Curated Markdown inventory](../.air/youtrack/project-guides.json) | DiscordKit project articles for the DiscordKit Team |
| Public project guides | [GitHub documentation directory](../Docs/) | Browse the Markdown for the selected branch or release tag |
| GitHub releases | [Release tooling](ReleaseTooling.md) | Find versioned source archives, checksums, and provenance on the [Releases page](https://github.com/Aurum-Studios/DiscordKit/releases) |
| DocC documentation | Package symbol graphs and the [DocC catalog](../Sources/DiscordKit/DiscordKit.docc) | [Download and reconstruct](CI.md#documentation) the archive from the macOS documentation job |

The YouTrack library contains Overview, Guides, Engineering Reference, and
Project History. Review the intended DiscordKit Team audience when changing
the curated inventory. Keep release evidence and revision-specific engineering
records in Git and link to them when a guide needs that context.

1. Commit the reviewed guide changes.
2. Run **Offline certification** for the candidate revision. It includes
   **Validate YouTrack documentation**, which can also run independently. Its validation
   artifact records the candidate SHA, source and manifest digests, and the
   source and page counts.
3. Preview and publish the candidate with the authenticated YouTrack
   session. Follow the [Knowledge Base operations guide](YouTrack/Knowledge-Base.md)
   to verify scope, article access and publication receipts.
