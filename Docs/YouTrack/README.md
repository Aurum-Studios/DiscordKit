<!-- copyright:begin
File: Docs/YouTrack/README.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# YouTrack project template

Use this kit to configure a reusable **Air Development** project template in
[Aurum Studios YouTrack](https://issues.aurum-studios.com) and connect each new
project to this repository's Air workflow. Use this kit to set up a fresh
issue-tracking project as a project administrator. Existing
projects should map their current schema using the [lifecycle contract](../Air-Workflow/state-transitions.md).
For an existing empty project, [automatic setup](Automatic-Setup.md) can apply the
supported fields/defaults and optional board, then record the actual state mapping.

The kit supplies configuration and copyable text. Ordinary generation stays
offline; explicit automatic setup uses public REST. Neither creates the project
or changes workflow attachments. Native
setup requires an authenticated administrator with permission to create projects
and edit the intended fields, workflows, board and access settings. Converting
a project to a template requires **Update Project**. Instructions were checked
against YouTrack Cloud 2026.2 documentation on 2026-11-08; verify equivalent
controls and permissions for the installed edition.

## Kit contents

| File | Use |
| --- | --- |
| [project-template.json](project-template.json) | Configuration specification consumed by automatic setup; not a native YouTrack import |
| [Automatic setup](Automatic-Setup.md) | Preview/apply an existing empty project's schema and recover interrupted setup |
| [state-mapping.example.json](state-mapping.example.json) | Illustrative discovery record for the twelve logical stages, with unknown instance IDs |
| [Issue description](Issue-Description.md) | Copyable issue body with acceptance criteria and task-record references |
| [Knowledge Base sync](Knowledge-Base.md) | Default project sections or an optional repository Markdown mirror with recovery receipts |
| [Stage handoff](Stage-Handoff.md) | Copyable evidence and synchronization receipt |
| [Launch checklist](Launch-Checklist.md) | Repeatable setup for each real product project |

The JSON specification is authoritative for this kit's recommended defaults.
The lifecycle contract defines the gates. These documents require no additional
generator flags, credentials or installed packages.

## Configure the source project once

1. In **Projects → Create Project**, create a dedicated standard issue-tracking
   project named **Air Development**. Choose an unused project ID; the ID is
   instance-specific and does not belong in reusable files. Keep this source
   separate from active product work. If starting from a built-in preset,
   inspect and adapt every inherited field and workflow before conversion.
2. In its **Fields** settings, configure the single-valued `State` field and
   values in the specification. Use a project-specific value bundle when editing
   shared values would change unrelated projects. Set `Backlog` as the default;
   make only `Done` resolved. Remove unused inherited state values from this
   project's bundle after checking workflow dependencies.
3. Optionally add the recommended standard fields below. Keep defaults usable
   without assigning anyone. No extra approval, SHA, run, deployment or evidence
   fields are required: [task records](../Tasks/README.md) own those facts.
4. Review attached workflows and project access as described below. Optionally
   configure the board. Keep integrations absent and time tracking disabled
   until a real project needs them.
5. Verify the configuration in a disposable project made from the template
   before using it for real product work. Only create test issues or perform
   transitions when that live validation is explicitly authorized.

The built-in Kanban preset currently uses `Stage` and a pull/blocking workflow,
so it does not supply this kit's `State` model without adaptation.
See [JetBrains' Kanban defaults](https://www.jetbrains.com/help/youtrack/cloud/kanban-project-template.html).

### Fields and defaults

| Field | Kind | Empty/default | Requirement |
| --- | --- | --- | --- |
| State | Single state | Nonempty; Backlog | Required for this fresh-template design |
| Type | Single enum | Nonempty; Task | Optional recommendation: Epic, Feature, Task, Bug, Improvement |
| Priority | Single enum | Nonempty; Normal | Optional recommendation: Show-stopper, Critical, Major, Normal, Minor |
| Assignee | Single user | Empty allowed; unassigned | Optional; real project team only |

The Air contract needs an existing lifecycle field and a verified mapping, not
these exact optional fields or twelve exact values. Existing projects may use
another field name or collapse stages; preserve their real configuration.
Use ordinary issue links for subtasks, dependencies and duplicates. Add versions,
subsystems, estimates or work-item types only when the product needs them.

### State values and gates

Create these values in order. All are unresolved except `Done`.
The [lifecycle contract](../Air-Workflow/state-transitions.md) defines the evidence
needed for each transition; state labels alone do not satisfy those gates.

| Value | Meaning |
| --- | --- |
| Backlog | Captured actionable issue; initial value |
| Planning | Owned investigation |
| Awaiting Approval | Concrete plan committed and handed off |
| Implementation | Authorized implementation or repair |
| Testing | Completed slice undergoing required checks |
| Review | Complete validated candidate awaiting independent review |
| Documentation | Independent candidate review accepted; documentation readiness underway |
| Ready to Integrate | Documentation and candidate readiness verified |
| Integration | Authorized integration underway |
| Deployment | Source inclusion verified; required delivery pending |
| Verification | Exact delivered artifact established; acceptance underway |
| Done | Actual acceptance policy satisfied; resolved |

Implementation and Testing may alternate by phase. Repair returns to appropriate
testing and review. An interrupted run preserves the last truthful stage.
Do not add a second state field for delivery or mark Review, Ready to Integrate
or a merged issue resolved. For source-only work, identify the merged tree as
the artifact, explain why runtime deployment is inapplicable, and record source
acceptance. Cleanup has its own receipt rather than a board column.

### Board

The optional **Air Development** board manages only the source project, uses
project-based viewing/editing access and identifies columns by `State` in the
order above. Disable sprints; use no swimlanes, estimates or WIP limits by default.
Twelve columns favor visibility of delivery gates; a team may group columns for
readability while retaining the real states and mapping. Dragging a card changes
its state, so it needs the same authorization and evidence as any issue update.

### Access, workflows and notifications

Keep the source's team and explicit role assignments limited to people or groups
intended for every future project. Avoid product-specific members and public
access defaults. Scope the real project's coordinator to necessary issue access;
routine stage work does not require project administration. Store authentication
in the actual connector, never in repository configuration.

Inspect every attached rule, including built-in rules. Detach or adapt rules that
resolve parents when subtasks finish, resolve issues from commits/builds, force
Kanban pull states, assign people automatically, depend on another project, or
require fields this kit does not provide. Preserve a shared workflow used by
other projects; change attachment or make a reviewed project-specific copy.
This kit installs no custom workflow code and does not enforce evidence gates
on the server. The coordinating Air stages apply those gates and read back
necessary issue writes. A future server guard needs its own reviewed design.

Keep standard instance notifications unless the team deliberately chooses
otherwise. The kit configures no notification addresses, reminders, webhooks or
outbound messages. Adding workflow guidance does not execute those actions.

## Save the native template

Open the source project's **More → Convert to template**, then confirm.
Select **Air Development** on **Create Project** for each new project.
Conversion hides the source from ordinary issue creation/search; keep active
product work elsewhere. Later template edits affect future projects only.
See [JetBrains' custom project template instructions](https://www.jetbrains.com/help/youtrack/cloud/custom-project-templates.html).

Fields/value sets, attached workflows, access/team, notification settings and
time tracking carry into new projects. VCS/build/mailbox configurations copy
disabled. Boards copy only when limited to the source project, shared with
project/group access, and accessible to the creator. Issues, articles, reports
and dashboards do not copy. Audit the resulting project using the
[launch checklist](Launch-Checklist.md).
See [the documented copy rules](https://www.jetbrains.com/help/youtrack/cloud/custom-project-templates.html).

Use the issue body after creating a real project. The bundled
[Knowledge Base updater](Knowledge-Base.md) seeds the selected library after
article publication is authorized for that project's audience. The default
project layout uses four top-level sections with starter guidance. Choose the
repository layout for the full Markdown mirror. The repository-prefixed
`kb-sync` command preserves article IDs on later syncs.
The bundled JSON is a versioned setup specification; the documented
[project REST resource](https://www.jetbrains.com/help/youtrack/devportal/resource-api-admin-projects.html)
does not define importing this file as a custom project template.

## Connect a generated repository

Run `$new-repo` with the actual project purpose and selected language profiles.
Use `--youtrack-pending` until the exact project and connector access are verified.
After read-only discovery, `--youtrack-project PROJECT` records the real key;
that flag by itself verifies neither connectivity nor a state mapping. Ordinary
generation starts mapping empty even with a key; successful explicit automatic
setup records the actual field/value IDs after complete read-back.

Read the actual project, issue-field schema and current state values through an
available authenticated connector. Record the real project key and project-field
and value IDs in `.air/project.json`, using the illustrative
[mapping](state-mapping.example.json) as a discovery worksheet. Its object shape
is the shape recorded by automatic setup. The setup helper verifies schema IDs;
it does not execute issue transitions. Confirm how the actual connector accepts fields
(names or IDs), and retain resolved IDs in task evidence. Never submit null
example IDs as an update.

Replace all unknown identities before using a mapping for tracker writes;
preserve other project settings and real validation commands. Many logical stages
may map to the same value. Record their precise distinction in task state and
avoid redundant updates. If discovery is unavailable, leave mapping empty and
tracker synchronization pending while independent local setup continues.
Explicit local-only mode or instructions to skip tracker operations mean no
tracker calls, even though this reference kit is present.

Configure actual build/test/lint/documentation commands for the product stack;
empty commands are unconfigured. Complete the [launch checklist](Launch-Checklist.md),
then use the repository-prefixed stages. Only one named coordinator writes issue
state; reread before writes, read back results, and reconcile uncertain outcomes
before retrying. Record local checks, TeamCity validation, Git integration and
production acceptance using their respective receipts.

## Check, maintain and recover

Compare a new project's fields, defaults, resolved flags, board project/access,
workflow attachments, permissions and disabled integrations against the spec.
Record observed IDs and discrepancies before enabling issue synchronization.
Document independently whether configuration discovery, an authorized transition
and its read-back have actually succeeded. Creation of a project alone proves
none of those later steps.

If a board is missing, check that it references only the source project and that
the creator has the board's viewing access. If stages reject updates or finish
unexpectedly, inspect workflow attachments and required fields; preserve the
current issue rather than replaying transitions. If access was copied too widely,
correct the real project's roles through an authorized administrator and review
the source template before the next project is created.

Version changes to this kit and the native source configuration deliberately.
Existing product projects retain their copied setup; adopt updates through a
scoped migration and fresh discovery. Never rerun generation to overwrite a
customized existing project or change shared value bundles merely to force a match.
