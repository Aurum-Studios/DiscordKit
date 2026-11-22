<!-- copyright:begin
File: Docs/YouTrack/Issue-Description.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Issue description template

Use this template when capturing actionable work in a project configured with
[the YouTrack kit](README.md). It is intended for the issue coordinator after
duplicate search and project discovery. Copying this text performs no tracker
operation and adds no required custom fields.

Replace every `REPLACE_WITH_...` placeholder before treating the description as
complete. Keep unknown facts explicitly `pending`, `unconfigured` or `not
applicable` with a reason. A newly captured issue can have pending repository
records; create them during planning using [the task templates](../Tasks/README.md).
Use actual repository web links when available, without credentials or private
customer data. The project short name is not proof that its schema or access has
been verified.

## Copyable issue body

```markdown
## Problem and intended behavior

Trigger: REPLACE_WITH_REPRODUCTION_OR_CONCRETE_REQUEST
Current result: REPLACE_WITH_OBSERVED_RESULT_AND_EVIDENCE
Expected result: REPLACE_WITH_OBSERVABLE_OUTCOME
Impact: REPLACE_WITH_WHO_OR_WHAT_IS_AFFECTED

## Scope

- Included: REPLACE_WITH_BOUNDED_CHANGES
- Excluded: REPLACE_WITH_CONSEQUENTIAL_EXCLUSIONS
- Dependencies and compatibility: REPLACE_WITH_KNOWN_CONSTRAINTS_OR_NONE_IDENTIFIED

## Acceptance criteria

- AC-1: REPLACE_WITH_OBSERVABLE_BEHAVIOR_AND_HOW_IT_WILL_BE_CHECKED
- AC-2: REPLACE_WITH_ANOTHER_REQUIRED_OUTCOME_AND_ITS_CHECK
- AC-3: REPLACE_WITH_DOCUMENTATION_OR_DELIVERY_ACCEPTANCE_WHEN_APPLICABLE

## Identity and canonical records

- Canonical issue: pending returned issue identity and URL
- Repository: REPLACE_WITH_REPOSITORY_URL
- Task/run: pending planning identity
- Coordinator: pending designated coordinator; no distributed lock claimed
- PLAN: pending concrete plan under Docs/Tasks/TASK-KEY/RUN-ID/PLAN.md
- STATE: pending record under Docs/Tasks/TASK-KEY/RUN-ID/STATE.md
- EVIDENCE: pending record under Docs/Tasks/TASK-KEY/RUN-ID/EVIDENCE.md
- Plan commit and approval: pending; capture does not approve implementation

## Verification and delivery policy

- Required checks: REPLACE_WITH_KNOWN_CHECKS_OR_UNCONFIGURED_WITH_REASON
- Documentation scope: REPLACE_WITH_AFFECTED_GUIDES_SYMBOLS_EXAMPLES_OR_CONFIGURATION
- Local evidence: pending; no checks claimed from this description
- Hosted or platform qualification: pending, or not applicable with reason
- Delivery policy: REPLACE_WITH_SOURCE_ONLY_OR_RUNTIME_DELIVERY_REQUIREMENTS
- Acceptance procedure: REPLACE_WITH_EXACT_SOURCE_OR_ARTIFACT_ACCEPTANCE
- External action scope: REPLACE_WITH_EXISTING_AUTHORIZATION_AND_PENDING_BOUNDARIES

## Current evidence and next action

- Observations and reproduction quality: REPLACE_WITH_LINKS_AND_LIMITS
- Known uncertainties or blockers: REPLACE_WITH_OPEN_FACTS_OR_NONE_IDENTIFIED
- Tracker synchronization: pending discovery of actual field/value IDs and read-back
- Next action: REPLACE_WITH_CONCRETE_PLANNING_OR_DISCOVERY_STEP
```

## Maintain the description through the task

Keep acceptance identifiers stable as evidence accumulates. Add new IDs for new
criteria and record approved scope changes rather than renumbering covered work.
Replace record placeholders with the canonical links once the actual issue and
run exist. Detailed commands, candidate SHAs and transition receipts belong in
PLAN/STATE/EVIDENCE; link them from a concise [stage handoff](Stage-Handoff.md).
Never fill an evidence gap with a successful-looking placeholder.

For source-only work, state why runtime deployment does not apply, identify the
exact merged commit/tree as the delivery artifact when the established policy
allows it, and define source acceptance. A local commit alone does not establish
merge or delivery. Runtime work needs its actual artifact, environment and
acceptance evidence. Follow [the lifecycle](../Air-Workflow/state-transitions.md)
for either path; template text does not authorize integration, publication,
deployment or service startup.
