---
name: discordkit-kb-sync
description: "For discordkit: Synchronize its configured YouTrack Knowledge Base while preserving article IDs, access and manual edits."
---
<!-- copyright:begin
File: .agents/skills/discordkit-kb-sync/SKILL.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->


# discordkit Knowledge Base sync

Refresh the DiscordKit YouTrack library from its curated guide inventory.
Review the manifest and confirm the DiscordKit Team article audience before
publishing. Preserve separately owned articles.
An explicit invocation authorizes writes only to this configured article tree.
Honor preview-only or narrower instructions. Implicit discovery grants no
publication permission. Read [the sync prompt](../../../Docs/Air-Workflow/prompts/discordkit-kb-sync.md)
and [operator guide](../../../Docs/YouTrack/Knowledge-Base.md).

1. Resolve the actual Git root and inspect its AGENTS.md, status, worktrees and
   `.air/project.json`. Confirm slug `discordkit`, exact YouTrack project,
   identity and Knowledge Base access settings. Local-only or an explicit tracker
   skip means no connector calls. Pending project/access stays pending.
2. Discover currently available MCP article get/create/update capabilities. Use
   the authenticated connector; do not request tokens or run another product's
   updater. Preserve source files, staging, issues, schema, permissions and
   unrelated articles. Initialize Git only within existing setup authorization.
3. Set `globalThis.YOUTRACK_KB_SYNC_OPTIONS = {root: repositoryRoot}` in
   functions.exec, where repositoryRoot is the verified absolute Git root. Add
   `dryRun:true` for preview. For publication, verify the exact committed
   candidate with `Scripts/youtrack_knowledge_base.py verify --root . --revision <full SHA>`
   and set `candidateRevision` to that SHA. A first requested setup of a verified fresh library
   sets `bootstrap:true`; ordinary updates reuse receipts. A clone missing receipts
   must restore them or deliberately establish fresh-library scope, not silently
   create a duplicate root. Read `Scripts/youtrack_knowledge_base_runner.js`
   through exec_command using correct shell quoting and await its evaluated
   expression. The runner acquires the local coordinator lock and performs
   snapshot, rendering, synchronization and complete read-back. If execution
   yields, resume using functions.wait; never discard its promise.
4. Finish only when the report has no pending pages, conflicts or sources changed
   during sync. Rerun to capture source changes. Preserve manual-edit conflicts
   and report the affected article links. Keep uncertain create intents; follow
   the exact-ID recovery in the operator guide rather than creating duplicates.
5. Report the library link, source-document count, created/updated/unchanged and
   conflicted/pending results. Distinguish verified publication from preview and
   incomplete work. A successful local render is not a publication receipt.

Follow [the worktree lifecycle](../../../Docs/Air-Workflow/worktree-lifecycle.md)
for canonical-branch reuse and this stage's closure. Do not create a branch or
checkout merely because the stage changes. Preserve the standard checkout and
report resources retained for the next action.

Record Knowledge Base receipts separately from issue status and any product
reference delivery.
The updater requires a POSIX host (macOS or Linux), Python 3.9+, Git and the article MCP
connector, with no extra Python packages or dependency on the initializer checkout.
