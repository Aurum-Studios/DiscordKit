<!--
File: Docs/Parity/changes/2026-11-13-upstream-review.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Upstream maintenance review

Reviewed on **2026-11-13 UTC**. The previous review was valid through November 12;
the hosted maintenance gate correctly rejected the November 13 run. REST and
Gateway remain **v10**, and Voice Gateway remains **v8**.

## Sources and classification

The [dated review snapshot](../../Release/sources/2026-11-13-upstream-review.json)
records exact revisions, byte counts, SHA-256 hashes, JSON pointers and affected
support records for all reviewed changes. The original discovery catalog and
previous source snapshots retain their historical revisions and dates.

- Written docs: compared
  [`da52492`](https://github.com/discord/discord-api-docs/tree/da52492ced82d375981c46618cc3e182daada9a2)
  with [`36adecb`](https://github.com/discord/discord-api-docs/tree/36adecb2e0bbbf500c430147ef4acbe9aa1a389e).
  The complete diff changes only the voice connection guide and close-code table.
  All 22 sources from the November 5 review are byte-identical at the new revision,
  including the change log and channel-obfuscation announcement.
- Stable and preview specifications: compared discovery revision
  [`ed01408`](https://github.com/discord/discord-api-spec/tree/ed014089afa986f2b532ae081c456a85de074d0c)
  with [`3a21a01`](https://github.com/discord/discord-api-spec/tree/3a21a01249a763cd47f1dfec3da91c5ba71bb974).
  The four permission routes, permission response, content-scan metadata and audit
  actions 16/33 already have November 5 implementation and test evidence.
  Parameter descriptions and equivalent invite-parameter placement require no
  runtime change; removal of the preview search `contents` parameter matches the
  existing single `content` query.
- Specification-only overlays remain explicit gaps: typed/outgoing embed audio,
  writable lobby names and nullable media placeholders are unsupported. Letterboxd
  remains an unknown provider string. Exact unknown response audio and provider
  values remain preserved. Existing partial written models and unsupported
  duplicate spec rows retain their classifications; this review adds no claim of
  complete stable or preview specification parity. The
  [ambiguity register](../ambiguities.json) records the adopted precedence.

## Voice correction and migration

The written guide now explicitly permits Select Protocol only once per voice
session. A successful resume preserves that selection; sending it again can close
the socket with code **4006**, requiring the
[Connecting to Voice flow](https://docs.discord.com/developers/topics/voice-connections#connecting-to-voice).

Established sessions already retained their protocol selection on resume, and
4006 already required a fresh join. The pure reducer had an incomplete-handshake
edge: socket loss after selection but before Session Description could clear the
selection and allow another Identify/Select Protocol using the same credentials.
It now closes at that boundary. The supervised session returns `rejoinRequired`
before consuming a retry or opening another socket, and closes owned resources.
Acquire fresh main-Gateway voice credentials before constructing the replacement.
Loss before protocol selection and established-session resume retain their existing
policies. This conservative local recovery rule does not claim that Discord
documents every interrupted-handshake outcome.

Regressions cover repeated selection, selected-protocol retention after resume,
interrupted negotiation, no replacement socket, unchanged retry count and cleanup.
The [voice capability inventory](../voice-media-capabilities.json) records this
component behavior without broadening full voice qualification.

## Review deadline and qualification

The [maintenance ledger](../../Release/maintenance.json) is reviewed on November 13
and due again **November 15**, ahead of the **November 16** HTTP channel-obfuscation
transition. That transition remains `future_effective` on this review date. Its
existing before/on-boundary fixtures and status checks remain enforced; review
freshness does not activate future behavior early.

Upstream announcement and activation dates for the voice clarification remain
unknown. This record establishes source review and local deterministic behavior;
hosted certification, live Discord, native SDKs and other platforms require their
own evidence.

## Local validation

On macOS ARM64 with Swift 6.4, the root build and all 34 test targets passed
(2,713 test functions, including parameterized cases). The independent offline
tool suite passed 106 tests, and its Python scripts passed 236 tests. Inventory,
generation, parity, source preflight, declaration documentation and changed local
documentation links passed. Generated output remained byte-identical; the
documentation presence audit found no missing comments in 10,688 declarations.
The maintenance gate accepted November 13 and its inclusive November 15 deadline,
and rejected dates outside that review window. An independent source/code review
found no blocking problems. These are local results; hosted results are recorded
by their own workflow runs.
