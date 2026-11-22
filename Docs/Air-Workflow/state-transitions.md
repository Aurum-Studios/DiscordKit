<!-- copyright:begin
File: Docs/Air-Workflow/state-transitions.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# Tracker lifecycle and synchronization

Read `.air/project.json` for tracker intent. `tracker.mode` is `youtrack` or `local`; `tracker.project_key` identifies the chosen YouTrack project when enabled, and `tracker.state_mapping` starts empty until the actual schema is discovered. Local mode performs no tracker operations. Explicit instructions to skip all tracker operations also override configuration: use the supplied local task identity and perform no tracker reads or writes. Preserve normal plan, validation and integration boundaries; never invent an issue to satisfy a workflow. Configuration contains no credentials.

## Discover the project's actual model

For separately authorized fresh-project administration, the
[YouTrack project template kit](../YouTrack/README.md) provides recommended defaults,
native-template instructions and copyable issue/handoff text.
[Explicit automatic setup](../YouTrack/Automatic-Setup.md) applies supported schema
to an existing empty project and stores verified IDs. It does not enforce issue
evidence gates or qualify inherited workflows; populated projects retain their
actual model. Routine stage work never invokes administrative setup.

For YouTrack work, discover an available authenticated connector/API, canonical issue/project and actual field/value IDs. Read the complete issue, relevant comments and existing run records. Verify access and the configured state mapping before tracker-dependent stage writes. If unavailable, continue independent read-only research, report the exact missing capability and preserve pending synchronization. Never invent endpoints, credentials, IDs, successful writes or manual board updates.

This preferred development model guides mapping to the project's existing schema. It does not require a new board or twelve exact state names:

| Logical stage | Evidence required |
| --- | --- |
| Backlog | Actionable captured issue |
| Planning | Coordinator begins owned investigation |
| Awaiting Approval | Concrete plan committed and handed off |
| Implementation | Concrete plan approved or authorized in-scope repair |
| Testing | Completed slice enters required checks |
| Review | Complete candidate has required checks and AC coverage |
| Documentation | Independent exact-candidate review accepted |
| Ready to Integrate | Documentation and candidate readiness verified |
| Integration | Requested integration begins with readiness and protection checks |
| Deployment | Merge/source inclusion verified; required delivery pending |
| Verification | Exact delivery artifact established; acceptance underway |
| Done | Actual acceptance policy satisfied |

Map these logical stages to existing project values and record the mapping with actual IDs. Multiple logical stages may share one actual value; record their precise distinction in durable task state rather than manufacturing tracker churn. If a required mapping is ambiguous, ask a consequential setup question. Routine issue work never creates or changes project fields, state values, boards, workflows or permissions. Such setup needs separate explicit authorization.

## One coordinator and verified writes

An expressly invoked capture/plan/implement/review/docs/integrate/resume stage may perform the necessary lifecycle writes for the named task. Only its designated coordinator writes; delegated workers, native reviews, unsolicited reviews, status, capacity and split proposals do not. Acquire existing exclusive issue ownership when a real coordinator is configured; otherwise ensure there is one named coordinator and do not claim a distributed lock.

For every necessary transition:

1. Resolve the canonical issue and real target field/value IDs. Establish the authorized stage, run, branch, current candidate and gate evidence.
2. Immediately before writing, reread actual issue state/revision and current Git candidate. Reconcile unexpected human/other-task moves, changed scope or a newer candidate; do not overwrite them. Use versioned writes only if the real connector supports them.
3. If already at the mapped target with a matching current receipt, record a verified no-op. Preserve the issue's truthful lifecycle; do not replay completed intermediate states or reopen completed work merely because a skill was invoked again.
4. Write only necessary existing issue fields and a concise gate handoff identifying task/run, source/target, candidate and evidence. Preserve assignees, hierarchy, unrelated fields and notification settings. Do not send separate messages or repetitive per-test comments.
5. Read back the exact state and receipt. If the call times out or its result is uncertain, inspect authoritative current state before retrying. A matching target/receipt means success without repeating the write; an unexplained revision change requires reconciliation.
6. Record actual source/target IDs, issue revision when available, candidate, UTC time, evidence and read-back outcome. A pending/failed write remains pending. Do not claim tracker synchronization or cross its required next stage gate until reconciled; retain already completed local work safely.

Capture searches for duplicates before creating and uses actual returned identity. Planning moves toward approval only after the concrete plan commit exists. Implementation alternates logical Implementation/Testing by completed slice and enters Review only for the complete validated candidate. Accepted independent review permits Documentation; confirmed defects return to authorized repair and affected testing/review. Documentation readiness permits Ready to Integrate. Integration, exact delivery and acceptance each require their separate actual evidence and requested authorization.

Review keeps source and Git history read-only and records an independent review receipt. A specifically invoked tracker-coordinating review may update the named issue only with exclusive coordination and current evidence; if a writer is active, give that owner the findings. Status/capacity/split remain read-only for tracker state. Recovery resumes the truthful authorized stage and reconciles uncertain effects before retrying.

For source-only delivery, the established policy may use the exact merged commit/tree as artifact; record why runtime deployment is not applicable and perform source acceptance. Preserve actual merge/delivery facts when later operations fail. Cleanup is a separate receipt, not another board state.
