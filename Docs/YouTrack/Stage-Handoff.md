<!-- copyright:begin
File: Docs/YouTrack/Stage-Handoff.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Stage handoff template

Use this concise update when an authorized coordinator hands a named issue to its
next evidenced stage. Read [the lifecycle](../Air-Workflow/state-transitions.md)
and current [task records](../Tasks/README.md) first. This is copyable text, not an
automatic comment, state transition or approval. It introduces no custom fields.

Resolve the actual issue and field/value IDs, reread its current state/revision
and candidate, then perform only the necessary authorized write. Verify its
read-back before reporting synchronization. If the result is uncertain, inspect
authoritative current state before retrying; keep the transition pending until
reconciled. A matching current receipt can establish a verified no-op.

## Copyable handoff

```markdown
Task/run: REPLACE_WITH_CANONICAL_ISSUE_AND_RUN
Coordinator: REPLACE_WITH_DESIGNATED_WRITER
Repository: REPLACE_WITH_REPOSITORY_URL
Logical stage: REPLACE_WITH_SOURCE_AND_TARGET_OR_CURRENT_STAGE
Candidate: REPLACE_WITH_EXACT_SHA_OR_PENDING_WITH_REASON
Issue branch/checkout: REPLACE_WITH_CANONICAL_REF_TIP_AND_RETAINED_OR_RELEASED_CHECKOUT
Plan: REPLACE_WITH_PLAN_URL_AND_VERIFIED_PLAN_COMMIT
Approval: REPLACE_WITH_ACTUAL_APPROVAL_OR_PENDING_WITH_REASON

Gate evidence: REPLACE_WITH_REQUIRED_GATE_AND_EVIDENCE_URL
Acceptance coverage: REPLACE_WITH_AC_IDS_AND_RESULTS_OR_REMAINING_GAPS
Checks: REPLACE_WITH_TESTED_REVISION_ENVIRONMENT_AND_OUTCOME_SUMMARY
Independent review: REPLACE_WITH_EXACT_CANDIDATE_RECEIPT_OR_PENDING_OR_NOT_APPLICABLE
Documentation: REPLACE_WITH_UPDATED_SCOPE_AND_CHECKS_OR_PENDING

Tracker: REPLACE_WITH_VERIFIED_WRITE_OR_VERIFIED_NO_OP_OR_PENDING
Observed state: REPLACE_WITH_ACTUAL_FIELD_AND_VALUE_IDS_AND_REVISION_IF_AVAILABLE
Read-back: REPLACE_WITH_RECEIPT_AND_UTC_TIME_OR_UNCERTAINTY
STATE: REPLACE_WITH_CANONICAL_STATE_URL
EVIDENCE: REPLACE_WITH_CANONICAL_EVIDENCE_URL

Merge/source inclusion: pending, or REPLACE_WITH_VERIFIED_EXACT_RECEIPT
Delivery artifact: pending, or REPLACE_WITH_VERIFIED_ARTIFACT_IDENTITY
Acceptance: pending, or REPLACE_WITH_ACTUAL_POLICY_AND_CHECK_RESULTS
Cleanup: pending, or REPLACE_WITH_OWNED_RESOURCES_RELEASED_AND_PRESERVED_WORK
Retained resources: none, or REPLACE_WITH_OWNER_REASON_AND_CLEANUP_TRIGGER
Next action: REPLACE_WITH_EXACT_ACTION_OWNER_AND_ANY_AUTHORIZATION_BOUNDARY
```

## Record the current truth

Replace every placeholder. Use `not applicable` only with the actual policy or
reason; retain `pending`, `blocked`, `failed`, `skipped`, `baseline failure` and
`unconfigured` where they describe the outcome. Keep the comment short by linking
detailed evidence. Do not post a new comment for each test or replay intermediate
states when recovery finds the task farther along.

Several logical stages may share one real state. Preserve that distinction in
STATE even when no tracker state change is necessary. If another coordinator is
active or issue/candidate state has changed, reconcile ownership and evidence
before writing. Preserve assignees, hierarchy and unrelated fields.

Local checks, hosted CI, independent review, merge, delivery and acceptance are
separate receipts. For source-only policy, the delivery artifact may be the exact
verified merged commit/tree; record why runtime deployment is not applicable and
what source acceptance established. For runtime policy, identify the actual
delivered artifact and acceptance environment. Do not mark Done until the real
policy is satisfied. Keep already verified merge/delivery facts if a later step
or cleanup fails.

An approval-waiting handoff requires the concrete plan commit. An implementation
handoff requires actual approval or authorized repair scope. Integration and
delivery still require their requested authorization; a state update or this
template supplies none of those permissions.

Apply [stage closure](../Air-Workflow/worktree-lifecycle.md) before the handoff:
preserve required issue refs, release disposable/idle checkouts safely and link
surviving records. Cleanup is due at each boundary and is separate from final
integration/delivery. Do not post an extra tracker comment solely for cleanup.
