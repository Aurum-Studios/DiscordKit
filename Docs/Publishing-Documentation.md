<!-- copyright:begin
File: Docs/Publishing-Documentation.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Build and publish DiscordKit documentation

DiscordKit uses YouTrack for project guides and TeamCity build artifacts for
DocC. The two outputs use their own validation jobs.

| Output | Source | Delivery |
| --- | --- | --- |
| [DiscordKit Knowledge Base](https://issues.aurum-studios.com/articles/DISCORDKIT-A-1/DiscordKit-Overview) | [Curated Markdown inventory](../.air/youtrack/project-guides.json) | DiscordKit project articles for the DiscordKit Team |
| DocC documentation | Package symbol graphs and the [DocC catalog](../Sources/DiscordKit/DiscordKit.docc) | Download the archive from the macOS documentation job in the [certification chain](CI.md#documentation) |

The YouTrack library contains Overview, Guides, Engineering Reference, and
Project History. Review the intended DiscordKit Team audience when changing
the curated inventory. Keep release evidence and revision-specific engineering
records in Git and link to them when a guide needs that context.

1. Commit the reviewed guide changes.
2. Run **Validate YouTrack documentation** for that revision. Its validation
   artifact records the candidate SHA, source and manifest digests, and the
   source and page counts.
3. Preview and publish the candidate with the authenticated YouTrack
   session. Follow the [Knowledge Base operations guide](YouTrack/Knowledge-Base.md)
   to verify scope, article access and publication receipts.
