<!-- copyright:begin
File: Docs/YouTrack/Automatic-Setup.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Configure an empty YouTrack project automatically

Use this guide when you already created an empty standard issue-tracking project
and want `$new-repo` to apply [Air Development settings](project-template.json).
The initializer can configure fields, defaults and a board, then save the real
state mapping. It does not create the project itself. Existing projects with work
should retain their schema and use read-only mapping instead.

## Prerequisites

- An exact existing project key and an empty, active standard project. The helper
  refuses projects containing visible issues or articles, archived/template
  projects and incompatible fields. Use an administrator account with visibility
  into **all** project content; the API cannot prove absence of content hidden
  from the token. Private drafts held by other users are not qualified.
- A YouTrack REST token able to manage custom fields/bundles, project field
  settings and boards. The current MCP has no project-administration tools;
  authentication for its read-only discovery does not supply REST credentials.
- `YOUTRACK_URL` set to `https://issues.aurum-studios.com` for Aurum Studios
  projects or the verified instance base URL for another organization, with
  `YOUTRACK_TOKEN` supplied
  through your trusted environment or secret manager. Tokens are never command
  arguments, repository configuration or setup receipt content. Do not paste a
  token into a task prompt. Normal TLS verification is required; plain HTTP is
  accepted only for local loopback test servers. Redirects are refused.
- YouTrack 2026.1 or newer when a missing Assignee field needs a new project-team
  bundle. The [project team API](https://www.jetbrains.com/help/youtrack/devportal/resource-api-admin-projects-projectID-team.html)
  provides the authoritative group; the helper does not guess user membership.

If the project key, access or credentials are unavailable, complete independent
local scaffolding with `--youtrack-pending`. Do not claim the project was configured.
Explicit local-only setup skips all tracker operations.

## Preview and apply

During `$new-repo`, supply the empty project's key and request its initialization.
The skill uses this flow after inspecting the destination and project identity.
For direct CLI use, run from the installed new-repo skill directory with literal,
properly quoted arguments. Example placeholders below must match the real project;
the environment must already contain the token.

```sh
export YOUTRACK_URL='https://issues.aurum-studios.com'
python3 scripts/new_repo.py '/absolute/project-folder' \
  --name 'Project Name' --description 'Purpose of this project.' \
  --youtrack-project PROJECT --configure-youtrack
```

Preview checks local conflicts first, performs authenticated GET discovery and
prints the proposed resource changes. It creates no local files and sends no
remote writes. Review the exact target and actions. Apply that configuration:

```sh
python3 scripts/new_repo.py '/absolute/project-folder' \
  --name 'Project Name' --description 'Purpose of this project.' \
  --youtrack-project PROJECT --configure-youtrack --apply
```

Add selected `--language` options and other project arguments consistently on
both invocations. Add `--youtrack-no-board` to configure fields without the
optional board. It requires `--configure-youtrack`; setup cannot combine with
pending or local-only mode. Without `--configure-youtrack`, generation stays
offline even when the authentication variables are present.

An initialization request for this supplied empty project authorizes the packaged
setup within that scope. It does not authorize creating issues/articles, assigning
people, changing access or workflows, or publishing a Git repository. An uncertain
target or migration of an existing populated project needs a separate decision.

## Configure an adopted repository

Use this procedure when the repository already has customized Air files and the
verified YouTrack destination is an empty standard project. The New Repo
generator checks every template file against the checkout. Use the installed
New Repo 0.0.1 schema helper directly so setup can operate on the existing
configuration. For a populated YouTrack project, inspect its existing State
field and values and record a read-only mapping.

Run from the adopted checkout. Verify the instance, project identity and empty
status, then record its exact short name in `tracker.project_key` in
`.air/project.json`. Leave `tracker.state_mapping` empty for a newly linked
project. Set `YOUTRACK_URL` and supply `YOUTRACK_TOKEN` through the trusted
environment as described above. Set `new_repo_scripts` to the installed
New Repo 0.0.1 skill's scripts directory containing `youtrack_setup.py` and
`new_repo.py`.

```sh
new_repo_scripts='/absolute/path/to/new-repo/0.0.1/skills/new-repo/scripts'

youtrack_setup_existing() {
    youtrack_setup_root=$(git rev-parse --show-toplevel) || return 1
    python3 -B - "$youtrack_setup_root" "$new_repo_scripts" "$@" <<'PY'
import json
from pathlib import Path
import runpy
import sys

root, scripts = map(Path, sys.argv[1:3])
action = sys.argv[3:]
if action not in (["--preview"], ["--apply"]):
    raise SystemExit("Choose --preview or --apply.")

config_path = root / ".air/project.json"
try:
    if config_path.is_symlink() or config_path.parent.is_symlink():
        raise ValueError("Use a regular .air/project.json in the checkout.")
    expected = config_path.read_bytes()
    tracker = json.loads(expected)["tracker"]
    if tracker["mode"] != "youtrack" or not tracker.get("project_key"):
        raise ValueError("Record the verified YouTrack project key first.")
    setup_type = runpy.run_path(str(scripts / "youtrack_setup.py"))["Setup"]
    setup = setup_type(root, tracker["project_key"])
    print(json.dumps(setup.inspect(), indent=2), flush=True)
    if action == ["--apply"]:
        store_mapping = runpy.run_path(str(scripts / "new_repo.py"))[
            "store_discovered_mapping"
        ]
        if config_path.read_bytes() != expected:
            raise ValueError("Project configuration changed during setup.")
        store_mapping(root, expected, setup.apply())
        print("Verified State mapping saved to .air/project.json.")
except (OSError, ValueError, KeyError) as error:
    raise SystemExit(f"YouTrack setup: {error}") from None
PY
}

youtrack_setup_existing --preview
```

Review the project and proposed schema and board changes. With explicit
authorization for those changes, run `youtrack_setup_existing --apply` in the
same shell. Apply repeats discovery, retains its operation and read-back receipt
in `.air/youtrack-setup.json`, and updates only `tracker.state_mapping` in the
existing project configuration after verified read-back. If the configuration
changes during setup, preserve the edits and reconcile against that receipt.
Review the resulting mapping and keep the receipt with the setup evidence.

## Applied configuration and boundaries

The helper consumes the bundled [specification](project-template.json):

- State receives twelve ordered values, Backlog as default and Done as the sole
  resolved state. Type and Priority receive the recommended enum values/defaults.
  New project-specific bundles avoid editing shared defaults. Existing global
  field definitions must have compatible types; their types are never changed.
- Assignee remains empty by default. An existing valid user bundle is preserved;
  a missing field receives a bundle containing the authoritative project team.
  No users, team memberships or assignments are changed.
- By default, a project-only board named `PROJECT Air Development` uses State
  columns, project-based access, disabled sprints and no swimlanes or estimation.
  Other boards are preserved. A conflicting board with that name is refused
  rather than taken over. `--youtrack-no-board` leaves board setup out of scope.

The REST API supports [project-field default values](https://www.jetbrains.com/help/youtrack/devportal/api-usecase-set-default-value-for-project-field.html)
and [board settings](https://www.jetbrains.com/help/youtrack/devportal/operations-api-agiles.html).
The helper verifies the actual read-back before saving IDs, including board
column values; unsupported server behavior leaves setup pending.

Permissions, workflow code/attachments, integrations, notifications and time
tracking remain unchanged. Inspect inherited workflows using the
[manual setup guide](README.md): they can still force fields or advance states.
Public REST does not offer supported workflow administration, so the helper does
not use private endpoints. Schema read-back does not prove workflow compatibility,
an actual issue transition, team permissions or runtime acceptance.

## Receipts, retries and failure recovery

After local preflight and preview discovery, apply creates the local foundation
first. Before remote mutations it writes secret-free operation intent and
read-back receipts to `.air/youtrack-setup.json`. This file records the actual
instance/project and resources; it is durable setup evidence, not authentication.
Do not run simultaneous setup writers for the same project or repository.

Only complete verified schema read-back permits filling
`.air/project.json` → `tracker.state_mapping`. It uses actual project-field and
bundle-value IDs, matching [the example](state-mapping.example.json). Configuration
replacement checks the original bytes to preserve unexpected local edits. Setup
does not configure product build/test/lint/documentation commands.

If a request fails or times out, keep the receipt and pending local foundation.
Rerun the same command to discover authoritative resources and reconcile completed
effects. An exactly matching configured project needs no remote writes. Each apply
invocation performs fresh discovery; a separate earlier preview does not lock
that snapshot. If the initial apply discovery differs from that invocation's
inspected snapshot, setup stops before schema writes. An uncertain effect that
cannot be reconciled remains pending; inspect the receipt and actual
project with an administrator before a deliberate recovery. Do not remove receipts
or delete shared bundles to force a retry. No automatic remote rollback occurs.

If local configuration changes concurrently, preserve those edits and use the
receipt to reconcile schema completion before updating the mapping deliberately.
A partial remote failure does not erase independently completed local work.
If authentication fails, correct the environment/permissions and retry discovery;
diagnostics do not echo tokens or raw server bodies.

The [Knowledge Base updater](Knowledge-Base.md) is a separate MCP-backed step
after local Git initialization. Requested documentation setup publishes the
rendered repository Markdown; this REST helper still writes no articles. Once
that library exists, use its updater for documentation refreshes rather than
rerunning empty-project schema setup against a populated project.

Once the schema is configured, review workflow compatibility and the
[launch checklist](Launch-Checklist.md). Capture the first issue only within its
authorization and verify a real transition/read-back separately. You may convert
the configured empty project into a native reusable template using the
[manual conversion steps](README.md#save-the-native-template).
