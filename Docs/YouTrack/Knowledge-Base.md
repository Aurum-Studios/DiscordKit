<!-- copyright:begin
File: Docs/YouTrack/Knowledge-Base.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Synchronize the DiscordKit Knowledge Base

The [guide inventory](../../.air/youtrack/project-guides.json) defines the exact
Markdown sources and their position in the library. Each entry has a repository
path, a YouTrack section, and an article title. Publish source updates from a
committed revision that passed **Validate YouTrack documentation**.

## Verify the project and preview

Confirm the DiscordKit project key, the DiscordKit Team group and its membership
in YouTrack. Confirm that `tracker.project_key` and
`knowledge_base.permitted_groups` in [the repository configuration](../../.air/project.json)
match those verified values. The publication runner applies the group at article
creation and verifies project, parent and visibility before sending guide
content.

From the repository root, render the files and inspect the resulting JSON
receipt. Supplying the full candidate SHA checks that the input is committed and
that all local links resolve.

```sh
python3 Scripts/youtrack_knowledge_base.py verify --root . --revision "$(git rev-parse HEAD)"
```

## Publish and verify

Use the authenticated YouTrack article connector with the
[companion runner](../../Scripts/youtrack_knowledge_base_runner.js). In the
connected runner environment, set `YOUTRACK_KB_SYNC_OPTIONS` with the absolute
Git root and `dryRun: true` for a preview. For a published update, supply
`candidateRevision` as the accepted full commit SHA. Supply `bootstrap: true`
for a confirmed empty library. Resume existing libraries with their verified
local receipts so article IDs and manually owned content are preserved.

The runner preserves its receipts in the Git common directory. For interrupted
article creation, verify the exact article on the server and pass its ID in
`reconcileRoot` or `reconcile[articleKey]` when prompted. The receipt identifies
the pending article key. Check the resulting section links, page counts,
revision and effective access in YouTrack to complete publication.

The [publication guide](../Publishing-Documentation.md) explains how the
separately generated DocC archive is delivered.
