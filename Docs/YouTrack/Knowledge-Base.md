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

The [publication guide](../Publishing-Documentation.md) explains article
ownership, versioned plans and approval evidence.

## Verify the project and preview

Confirm the DiscordKit project key and the DiscordKit Team group's membership in
YouTrack. The [repository configuration](../../.air/project.json) uses
`tracker.project_key` for the project, `identity.uuid` for the repository
identity and `knowledge_base.layout` for the article layout. Live synchronization
requires `knowledge_base.permitted_groups` to contain `DiscordKit Team` and
`knowledge_base.permitted_users` to be empty. The runner verifies project,
parent and article visibility before sending guide content.

From the repository root, render the inventory and inspect the JSON receipt.
Supplying the full candidate SHA verifies that all published inputs match the
committed revision and that the render has no link warnings.

```sh
python3 Scripts/youtrack_knowledge_base.py verify --root . --revision "$(git rev-parse HEAD)"
```

The TeamCity job runs the same check for its selected revision and records the
source and guide manifest digests, source document count and planned page count.

## Publish and verify

Use the DiscordKit `kb-sync` workflow or the authenticated YouTrack article
connector with the [companion runner](../../Scripts/youtrack_knowledge_base_runner.js).
The runner requires a POSIX host, Git and Python 3.9 or newer. It uses a local
coordinator lock, validates the sources, creates missing pages, updates eligible
content and reads the pages back.

In the connected runner environment, set `YOUTRACK_KB_SYNC_OPTIONS` with the
absolute Git root and `dryRun: true` for a preview. For a published update,
supply `candidateRevision` as the accepted full commit SHA. The runner checks
that the actual revision matches, the sources and configuration are committed,
and the render has zero link warnings.

Supply `bootstrap: true` for an explicitly authorized first sync of a verified
fresh library. Resume an existing library with its Git common directory receipts
so existing article IDs and independently owned articles are preserved. For an
interrupted create, use the receipt and verify the exact article on the server
before passing its ID in `reconcileRoot` or `reconcile[articleKey]`.

Check the resulting section links, page counts, revision and effective access in
YouTrack. Review any pending pages, reconciliation conflicts or input changes
before recording the publication as complete.

## Included Markdown and presentation

The configured project layout uses the curated guide manifest. It organizes
sources under four top-level articles.

| Top-level article | Content |
| --- | --- |
| Overview | Project purpose and links to the other sections |
| Guides | Getting started, development setup and product workflows |
| Engineering Reference | Architecture, platform coverage, CI and operations |
| Project History | Changelog, parity history and separately published task articles |

The manifest excludes hidden skills and prompts and individual task records.
Task updates use their own runner operation and issue-specific audience checks.
Add independently owned articles with an authorized editor.

Relative links between synced guides point to their corresponding articles.
Other repository links can point to the exact Git revision specified by the
publication. Larger documents are split into ordered parts. Review anchor links,
navigation and effective access on the target instance.

## Publish an approved task

The Air coordinator publishes one task article per YouTrack issue under the
verified Project History section. Before the first write, confirm all of the
following:

- The project layout is enabled, the library setup was authorized, and the
  bootstrap receipt identifies the actual Project History article.
- The user approved the exact committed plan and the current stage may
  coordinate the task's YouTrack writes. Use one coordinator across linked
  worktrees. Honor narrower scope, explicit tracker skips and local-only mode.
- The canonical issue belongs to the configured project and the approved
  article audience is available. When the issue has named visibility
  restrictions, the article and its issue backlink use those restrictions.
  When the connector explicitly reports an empty issue audience, they use the
  configured named Knowledge Base audience. Unverified audience data leaves
  the publication pending.

In the existing run's `Docs/Tasks/<ISSUE>/<RUN>/STATE.md`, record
`Knowledge Base plan approval: <full plan commit SHA>` as a standalone line
using the actual SHA. Commit this approval receipt before the first task
publication. The runner reads `PLAN.md` from the approved commit and checks the
approval line from the candidate commit. Use the full SHA of the current
worktree HEAD for the candidate. It must descend from the approved plan and
from the last accepted checkpoint when one exists. The runner accepts committed
UTF-8 plans up to 32 KiB and state records up to 64 KiB. The full article,
including the plan, progress and any existing owner notes, must fit in 30,000
UTF-8 bytes.

Set the following options in the connected runner environment. Use the actual
checkout root and the verified task values.

```javascript
globalThis.YOUTRACK_KB_SYNC_OPTIONS = {
  root,
  task: {
    issueId: "DEMO-123",
    runId: "initial",
    approvedPlanCommit: "<full approved plan SHA>",
    candidateCommit: "<full checkout HEAD SHA>",
    stage: "Approved plan",
    progress: "Plan approved. Implementation is ready to begin."
  }
};
```

Use the existing task run. Start the stage label with a letter and use up to
48 letters, numbers, spaces or dashes. Summarize verified progress and remaining
work from the committed handoff in reviewed Markdown of at most 2048 UTF-8
bytes. Include relevant test or delivery evidence and links that the approved
audience can open. Use `dryRun:true` at the top level to validate the Git source
and scope without publication.

Refresh at approved-plan, committed implementation, reviewed candidate,
documentation readiness and verified integration or delivery checkpoints.
Retain the exact plan SHA and report the candidate that supports each update.
New progress requires a new committed checkpoint. A reviewer hands findings
to the coordinator when the review evidence still needs its checkpoint commit.
Reuse the same article through every checkpoint. The article includes the
committed plan, shows the approved and current checkpoint SHAs, and links to
the issue. The runner adds one issue comment linking back to the article.
Record `complete`, the article ID and URL, the verified backlink ID and the
candidate revision. Check navigation and effective access with an intended
reader before claiming that verification.

Task receipts live under the Git common directory in
`air-workflow/youtrack-kb-v1/tasks/<ISSUE>/receipt.json`. Retain them across Air
handoffs and restore them before continuing from a different clone. Use one
coordinator when working across machines because the lock is local. When the
first create is uncertain, set `task.reconcileArticleId` to the exact article
ID with the matching create marker. On uncertain content or backlink writes,
resume using read-back of the intended effect. An unresolved write remains
pending. An existing independently maintained issue article requires deliberate
reconciliation. Keep the existing article and its URL when no verified receipt
establishes that it belongs to the runner.

## Receipts and recovery

Mutable state lives under the Git common directory in
`air-workflow/youtrack-kb-v1`, shared by linked worktrees. It contains snapshots,
managed article IDs, baselines, operation intents and outcomes. It contains no
connector credentials and is not a substitute for backing up the repository.
Do not run concurrent writers against one library from separate clones/machines;
the local lock cannot coordinate them.

Every create records a unique placeholder intent before the connector call.
Confirmed article IDs are retained across updates. If a create response is lost,
retain the receipt and reconcile the exact article, project, marker, parent and
access. Search absence is not proof that creation failed. In particular, an
uncertain initial-root create requires `reconcileRoot` with the exact discovered
article ID. This restores Overview in the project layout or the root in the
repository layout. For any other article, set `reconcile` with the exact source
key reported by the runner and the actual matching ID. Example entries include
`{"group:project-history": "DEMO-A-123"}` for Project History or
`{"file:Docs/Example.md": "DEMO-A-124"}` for a source article. The runner checks
the saved placeholder and scope before accepting that identity. Retain the
existing receipts throughout recovery.

Before updating an article, the updater compares content, summary, parent,
project and access with its last verified baseline. Manual edits remain intact
and pending for deliberate reconciliation. It rechecks immediately before a
replacement and verifies afterward; the connector has no conditional revision
argument, so this is optimistic protection, not an atomic remote lock. Partial
success is retained. Removed sources keep their original article URLs and last
verified narrative with archival context. Unowned children remain untouched.

Sources changed during synchronization make the result incomplete; rerun to
capture them. Missing/conflicted pages, access failures or interrupted operations
must be reported explicitly. A successful connector update alone is insufficient
without complete read-back. Library sync writes only approved library articles.
Task publication additionally writes the verified issue backlink.

See the official [article API](https://www.jetbrains.com/help/youtrack/devportal/resource-api-articles.html),
[article access rules](https://www.jetbrains.com/help/youtrack/cloud/manage-access-to-articles.html)
and [Markdown reference](https://www.jetbrains.com/help/youtrack/cloud/youtrack-markdown-syntax-issues.html)
for instance behavior. Local fixture tests do not qualify a live server's rendered
navigation, hidden-content visibility or access configuration.
