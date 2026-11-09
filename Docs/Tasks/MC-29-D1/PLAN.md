# MC-29-D1: bounded rate accounting and interaction timing

This is the separately authorized local DiscordKit dependency task for MiniCarson
MC-29, not a fabricated YouTrack issue. Carson explicitly selected Authorize
DiscordKit work through the Air scope question on 2026-11-09. The MiniCarson plan
is 902595977cb5caddf7f201a769452a557e225d3d. Starting DiscordKit revision is
f469253d6dcdc654afb6756e915579b942548038, originally clean main. This isolated
branch and its child writer branches own all changes; shared main is preserved.

## Scope and sequence

1. Repair provisional-route/learned-bucket accounting and completion crossing an
   elapsed reset. Distinguish startup depletion, real 429 restrictions and learned
   exhaustion; preserve exact outstanding debits across alias/window changes.
   Keep identity/major-resource/egress isolation, bounded metadata, no refunds,
   conservative late/out-of-order observations and public store contracts.
2. Add optional content-free timing seams for adapter receive, queue/admission,
   HTTP headers/body completion, acknowledged response/final edit and joined
   cancellation. Default nil performs no clock read/task/registry work. Only
   trusted adapter delivery can supply Gateway receive provenance; public replay
   does not invent it. Keep original deadlines/FIFO/concurrency/whole-body/retry/
   single-send/uncertainty and shutdown ownership unchanged.
3. Run direct ManualClock boundary/alias/overlap/migration/429/malformed/expiry/
   metadata tests and existing coordinator/REST/dispatcher/responder regressions.
   Update all-visibility symbol contracts, rate-limit/timing guides, examples and
   affected DocC. Independently review the exact sibling candidate before pairing.
4. Qualify the exact sibling and MiniCarson revisions together with the supported
   relative sibling relationship. Preserve pinned external dependencies. Local
   offline checks do not qualify native Linux, provider/client/Discord production
   latency, deployment, runtime Start or READY.

No FIFO/concurrency increase, generic GET coalescing change, retry relaxation,
production operation, shared checkout mutation, push or merge is authorized.
Compiler/browser/shared disk capacity uses the MiniCarson coordinator limits and
fresh ownership admission; no duplicated dependency/build trees without budget.

## Integration authorization (2026-11-09)

Carson subsequently requested combining and merging all new timing API
implementations and pushing to origin. This authorizes integration into main and
the origin push after local validation. The original local-only stage above is
retained as history; no release or live runtime operation is part of integration.
