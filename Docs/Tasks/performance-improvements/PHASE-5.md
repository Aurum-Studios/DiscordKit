<!--
File: Docs/Tasks/performance-improvements/PHASE-5.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 5 — Shared values and RPC framing

Authorized 2026-11-11 from `ca5c4cb9`. Implements the
[stage contract](PLAN.md#stage-5--reduce-shared-value-and-framing-cpuallocation-costs).
Reserved-host numerical and profiler qualification from earlier phases remains open.

## Implementation plan

1. Preserve an original-runtime checkout and release receipt. Profile JSON parse
   and serialization separately, including strings, escaping and Unicode; inspect
   RPC fragmentation at fixed 256 KiB. Keep profiler captures separate from paired
   timings. Inspect bitset conversion/algebra and model/builder controls before
   deciding whether those owners justify a change.
2. Evaluate a narrow ASCII string path and operation-local Foundation coder reuse.
   Preserve Unicode validation, numeric lexemes, duplicate-key equality, sorted
   output, exact error offsets and byte/node/depth caps. Defer buffer ownership,
   sorting and reservation changes without supporting evidence.
3. Retain a validated RPC header while its payload is incomplete. Preserve value
   semantics, frame ordering, opaque control bytes, truncation/resume, error/reset
   behavior and inclusive resource caps.
4. Add independent Foundation differential and generated malformed JSON coverage,
   fragmented/coalesced RPC wire oracles, and versioned coalesced small-frame
   workloads. Preserve all historical benchmark identities and fixtures.
5. Run focused tests, full strict runtime tests, affected benchmark/tooling tests,
   independent REST/Gateway/DSL/RPC consumers, API/inventory/generation and authored
   documentation checks. Keep host builds and captures serial.
6. Capture five fresh-process no-change pairs and five alternating original and
   candidate pairs per selected workload with identical development harnesses.
   Retain raw reports, failed attempts, source/build receipts and cleanup evidence.
   Report local observations and resource tradeoffs without claiming a reserved
   host baseline, application speedup or qualified tails.
7. Review the final owned diff, record validation and decisions, commit locally,
   and verify the resulting commit and clean working tree.


## Implementation and decisions

The parser scans every quoted token as before. It constructs a string directly
only after proving the entire token is unescaped ASCII; escaped and non-ASCII
tokens retain Foundation validation and the same error mapping. The writer quotes
safe ASCII directly, retaining Foundation for Unicode, controls, quotes,
backslashes and forward slashes so Foundation's exact escaping remains unchanged.
Each parse/write lazily owns at most one fallback coder. There is no global coder,
new asynchronous work, public API or dependency change. Numeric parsing, sorted
keys, input/output buffers and recursive limit/error ordering remain unchanged.
No allocation profile justifies changing reservation, buffer ownership or sorting.

RPC retains one validated opcode/required-byte pair while its payload is
incomplete. Completion, explicit reset and every append error clear both input
and parsed state. EOF inspection remains non-consuming: a truncated decoder can
resume if the caller supplies the missing suffix. Buffer caps, value-copy
independence, all opcodes and opaque control bytes remain unchanged. The cost is
constant per-decoder metadata, with no whole-payload reservation or new tasks.

Dedicated bitset, model-projection and builder algorithms remain unchanged. The
4096-bit decimal profile confirms material long-division and uniqueness-check
cost in its isolated workload; retaining that owner is a scope decision, not a
finding that conversion is free. Conversion/algebra at all three widths remain
measured controls and an explicit follow-up. Model and builder profiles identify
shared JSON work alongside projection/lowering/validation. This phase changes
the common owner first; independent workload dimensions and a validated candidate
are needed before changing those separate algorithms or their diagnostic order.

## Correctness and measurement controls

Seven new JSON test methods independently compare Foundation-encoded scalar
strings and mixed documents, every ASCII scalar, Unicode scalar bytes, exact
escaped output, generated truncation/control/escape/UTF-8 failures, exact error
offsets, all sixteen canonical-equivalent duplicate-key combinations, arbitrary
numeric spellings and byte/node/depth boundaries through depth 128. Foundation's
bounded numeric conversion is deliberately excluded from the arbitrary-number
oracle. Existing model and protocol suites protect presence and unknown fields.

RPC generated streams cover five opcodes, twelve payload sizes through 4096 and
seven fragment sizes, including empty appends and nonzero Data indices. Every
truncation position exercises EOF failure, resume, independent copies and reset.
Split invalid headers, malformed-opcode precedence, excessive announced/appended
sizes and valid-prefix/failing-next-frame recovery protect all reset paths.

The foundation catalog grows from 115 to 129 cases without changing historical
identities or fixtures. Ten `json.v3` cases independently vary numeric-array leaves
1/16/128 and variable key lengths 1/8/64 at exactly 16 KiB, root width four, depth
two and seventeen string leaves. Padding changes to hold total bytes fixed.
Four `rpc.v2` coalesced cases hold sixteen-byte payload size while varying frame
count 1/16/128, plus 128 empty frames. Every frame fits the explicit 4096-byte cap.
Independent authored headers, ordered full-byte equality and weighted checksums
protect control bytes, output count and order. Existing 256 KiB fragmentation
cases retain their 7/256/4096-byte dimensions.

## Validation

Local checks completed on 2026-11-11 with Apple Swift 6.4, arm64 macOS 27.0.1,
SDK 27.0, pinned dependencies and four build jobs. Builds, tests and benchmark
processes ran serially. The [capture index](phase-5-observations.json) records
commands, source/build receipts, reports, resource gauges, cleanup and hashes.
Raw artifacts and retained paired binaries remain in the ignored local capture
directory; the index is not a published artifact store. Documentation added after
captures does not change the 816 recorded runtime/test/benchmark input files.

- Root build and strict tests passed: **2,676 methods in 335 suites across 34
  test-target runs**, zero issues. Focused JSON, RPC, bits and raw-value validation
  passed 38 methods in five suites.
- Foundation benchmarks passed **23 methods in five suites**, load harness
  **130 methods in 24 suites**, and development tooling **106 methods in eight
  suites**. Python checks passed 234 tooling, 47 benchmark-support, three
  foundation-runner and 183 CI-helper tests.
- Independent RESTOnly, GatewayBot, DSLCommands and RPCApp consumer builds passed.
  Inventory, deterministic generation, parity, symbol graphs, DocC curation and
  documentation-example synchronization passed. The callable audit found 970
  Swift files, 10,402 declarations and zero missing comments. Strict Core/RPC
  DocC conversion passed with analysis and warnings as errors.
- Public API policy checks passed; the complete API snapshot is byte-identical
  to phase 4. Independent production, wire-semantic and cross-owner reviews
  found no blocking correctness defect.
- All **129** catalog cases completed supervised smoke with exact checksums and
  expected rejection counts, no histogram loss/censoring and joined cleanup.
  These include every bitset parse/serialize/algebra width, malformed JSON and
  RPC rejection paths, all independent JSON dimensions and all coalesced cases.

## Paired local observations

Sixteen workloads each ran five independent candidate/candidate no-change pairs
and five alternating original/candidate pairs: **320 fresh processes, 163,840
measured calls and 10,240 separate warmup calls**. Each process completed 64
batches of eight calls after four warmup batches. Offered work, serial concurrency,
seed policy, fixtures, caps and harness were identical between arms. The original
runtime is `ca5c4cb9`; only the identical new development harness was installed in
its detached checkout before rebuilding. Every accepted child exited zero, its
producer joined, ownership returned to zero and its process group was reaped.
No batch was lost, censored or overflowed.

The table gives **medians of five process normalized means**, in microseconds per
call. Each normalized mean divides gross summed batch time by its calls; these
are not call percentiles or pooled distributions. The 64 observations per process
cannot qualify p99. All results are informational on an unreserved host; visible
peer activity, available thermal observations and process gauges are retained.

| Workload | Original µs/call | Candidate µs/call |
| --- | ---: | ---: |
| JSON parse, 16 KiB / 128 ASCII strings | 90.91 | 23.80 |
| JSON write, 16 KiB / 128 ASCII strings | 92.66 | 29.41 |
| JSON parse, Unicode control | 43.29 | 42.31 |
| JSON write, Unicode control | 42.81 | 41.49 |
| JSON parse, fully escaped control | 275.42 | 276.25 |
| JSON write, fully escaped control | 33.47 | 32.03 |
| RPC 256 KiB / 7-byte fragments | 3502.24 | 1064.71 |
| RPC 256 KiB / 256-byte fragments | 110.97 | 45.36 |
| RPC 256 KiB / 4096-byte fragments | 21.01 | 17.01 |
| RPC 128 coalesced 16-byte frames | 33.48 | 33.58 |
| Large model unknown-field roundtrip | 2017.45 | 877.89 |
| Large V2 component builder | 784.86 | 589.26 |
| JSON parse, 256 KiB / 16 ASCII strings | 347.64 | 197.64 |
| JSON write, 256 KiB / 16 ASCII strings | 530.01 | 371.59 |
| JSON parse, 16 KiB / one ASCII string | 24.26 | 13.39 |
| JSON write, 16 KiB / one ASCII string | 34.73 | 23.96 |

The strongest changes exceed their local no-change variation: the string-heavy
ASCII parse/write pairs decrease about 74%/68%, and 7/256-byte fragmented RPC
pairs decrease about 70%/59%. Model and builder cases also improve in these
fixtures. These are scoped batch-cost observations, not application response-time
claims. Long ASCII controls improve as well. Unicode, fully escaped parsing and
coalesced RPC do not establish a resolved change. In particular, the 4096-byte RPC
comparison decreases about 17–26%, while its no-change pairs span approximately
−22% to +9%; that case cannot support a confident numerical improvement claim.
No regression policy or performance budget is promoted.

### Resources and profiler limits

The process CPU gauges support the large targeted reductions, while RSS ranges
overlap or increase in some controls. RPC 128-frame coalescing has original peak
RSS 18.14 MiB and candidate 18.20–19.80 MiB; the 4096-byte-fragment case has
18.61 MiB versus 18.67–20.03 MiB. These are fresh-process lifetime peaks, including
fixture construction, allocator/library state and warmup. They do not measure the
exact heap retained by one decoder. Logical buffering remains capped and parsed
header state is constant-sized; no exact allocation-count or memory reduction is
claimed. A write containing a late escape/Unicode scalar still scans its ASCII
prefix before falling back to Foundation; that pattern has no dedicated paired
qualification here.

Separate CPU stack samples were captured before source changes and repeated
against the final identical-harness original and candidate release binaries.
They locate Foundation string decoding/encoding and repeated RPC header-array
materialization in the original. Supplemental original-runtime profiles cover
bitset parse, decimal formatting and algebra at 64/256/4096 bits. Model/builder
profiles retain the distinction between common JSON and projection/validation
work; nested stack counts are not summed into a synthetic waterfall. Profiling
runs are separate from ordinary paired measurements and are not used as timings.
One supplemental bitset run exceeded the post-measurement verification wait and
was killed/reaped; its failure log is retained. Four remaining bitset captures
explicitly terminate and reap their child after successful sampling, without
claiming a completed native report or benchmark cleanup from that termination.
All nineteen final stack samples succeeded; completed profiling reports and
sample-only terminations are distinguished in the index.

An attempted Instruments Allocations capture failed to attach and reported an
incomplete log archive. The failed trace/log remains recorded. Allocation-event,
lock/executor and controlled-host profiler qualification remains open. Initial
exploratory profile receipts retain their historical executable hash; that build
output was subsequently replaced by the identical-harness rebuild. The final
paired binaries are retained separately with verified hashes.

Two orchestration failures remain in the index. The first comparison spec used
an unsupported positive-warmup label and started no benchmark children. The
second completed ten children but its scenario carried a driver-only prefix that
did not match the participant identity; it was rejected and excluded. Corrected
specifications use `participant-declared` warmup and the native case identity.
The original failed spec bytes were retained and verified against their recorded
hashes. Neither attempt is presented as an accepted comparison or test failure.

## Decision and remaining gates

Retain the narrow ASCII/coder and RPC-header changes: their direct mechanisms,
wire correctness and large local target reductions are supported. Preserve the
existing algorithms for bitset conversion, model projection, builder validation,
JSON buffer ownership/reservation and sorting pending separate discriminating
candidates. Reserved-host noise/paired numerical acceptance, allocation and
executor/lock profiles, target-platform results, production critical paths and
live Discord/desktop qualification remain open. Local implementation and
validation complete this authorized phase without closing those separate gates.
