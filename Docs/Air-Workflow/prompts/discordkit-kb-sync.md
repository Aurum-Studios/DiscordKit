<!-- copyright:begin
File: Docs/Air-Workflow/prompts/discordkit-kb-sync.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Synchronize the Knowledge Base

Use `$discordkit-kb-sync` to refresh this repository's configured YouTrack
documentation library. Follow [the operator guide](../../YouTrack/Knowledge-Base.md)
and [operating contract](../contract.md). This is a documentation sync command,
separate from the eleven issue workflow stages.

Follow [the worktree lifecycle](../worktree-lifecycle.md) for resource closure.
Reuse the source checkout without creating an issue branch or worktree; release
only resources created by this invocation and preserve durable sync receipts.

An explicit invocation authorizes creation/update only of the managed library
for the configured exact project and access scope. A requested preview performs
reads and local preparation only. Local-only mode or a tracker skip prohibits
connector calls. Do not change issues, schema, permissions, Git staging, source
files, builds or deployment as part of sync.

Preview the curated guide inventory and verify the DiscordKit Team audience.
Validate the exact committed candidate and pass its full SHA as `candidateRevision`
for an authorized publish. Preserve stable article IDs, manual edits and unrelated
children. Verify complete read-back.
Keep failed or uncertain operations pending and retain their receipts. Missing
project access or connector capability leaves setup pending.

After the runner and owned workers complete, release only disposable resources
created for this invocation. Preserve durable sync manifests, receipts, pending
create intents and all source branches/checkouts; keep retained resources and
uncertain operations explicit in the handoff. A sync creates no issue checkout.
