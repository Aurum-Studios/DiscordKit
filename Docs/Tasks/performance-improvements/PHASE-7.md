<!--
File: Docs/Tasks/performance-improvements/PHASE-7.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 7 — Authoring and build performance

Authorized 2026-11-11 from `d766cf83db7a9baffeb46bcadbc1153336f4ba9b` under the
[stage contract](PLAN.md#stage-7--refine-authoring-and-build-performance).

## Implementation plan

1. Preserve the original runtime in a detached checkout. Inspect DefinitionPlan
   shape, preflight, exact payload accounting, typed routing, macros and the
   independent consumer build driver. Keep public and import contracts intact.
2. Evaluate exact bounded payload byte counting in place of constructing a
   complete serialized document solely for its length. Preserve shape validation,
   raw lower-bound admission, diagnostic order and the original escaping rules.
3. Add deterministic differential coverage against the existing writer, including
   escaped ASCII, Unicode, nested values, exact limits and invalid payloads.
4. Separate prepared-plan compilation, full schema/lowering authoring, steady
   invocation, compiler bootstrap, clean/incremental consumers, no-change planning
   and inert consumer startup. Preserve historical workload identities; use fresh
   processes and whole-population common reports for new runtime comparisons.
5. Retain identical development harnesses for original and candidate runtimes,
   five independent no-change pairs and five alternating comparison pairs per
   selected runtime workload. Record exact outcomes, source/build identities,
   resources, cleanup and independent diagnostic CPU samples.
6. Run focused and strict root tests, benchmark and macro/extension tests,
   external compiler fixtures, offline consumers, graph/import and API audits,
   inventory/generation/parity and callable/authored documentation checks.
   Run host builds and captures serially with fixed pins and job counts.
7. Review the completed changes and local evidence, commit locally, then verify
   the commit and working tree. Reserved-host numerical, allocation-event and
   other-platform qualification remain separate gates.

## Implementation decisions

DefinitionPlan retains its shape pass and aggregate raw lower-bound preflight.
The final admission pass counts exact compact JSON bytes without constructing a
complete output buffer or sorting object keys. Safe ASCII contributes its raw
UTF-8 length plus quotes; other strings use one lazily created, compilation-local
Foundation encoder per declaration, matching the shared writer's escaping policy.
Only one escaped string buffer is temporary. This preserves the public payload,
numeric spelling, source coordinates, sticky failure and diagnostic priority.
The additional private counter has no global cache or cross-compilation owner.

Typed routing, macro expansion, package boundaries and compiler parallelism retain
their existing runtime behavior. The current router already uses dictionary
lookup; no evidence supports replacing it. Compiler/bootstrap/consumer costs need
separate attribution before changing module boundaries or job counts. Narrow
runtime products retain their independent adoption and never select compiler
plugins or benchmark dependencies.

The development harness separates prepared raw-plan compilation from complete
schema/lowering authoring and steady invocation. A direct JSON serialization
control has a distinct identity because it does not perform DefinitionPlan
admission. New populations retain every observation in bounded histograms and
exact duration totals. Existing prefix-sampled reports and combined authoring
workloads keep their original identities and semantics.

Compiler receipts retain separate dependency/plugin bootstrap, clean consumer,
one-file incremental, no-change SwiftPM invocation and fresh inert consumer startup.
No-change includes SwiftPM planning and cache validation; it does not isolate pure
package planning. Startup includes process loading, inert catalog construction,
qualification output and supervised teardown; the OS file cache is not flushed.
CPU and largest-process peak RSS accompany wall time, with fixed jobs and pins.

## Correctness and local validation

The complete strict macOS root run passed **2,683 tests in 337 suites** across
34 test products. Definition tests cover every ASCII byte in keys and values,
controls/slashes/quotes, composed/decomposed Unicode, non-BMP scalars, empty and
nested containers, huge/exponent number spellings, 64 generated nested cases,
exact/one-byte-short byte budgets, maximum depth/nodes, sticky diagnostics and
shape-before-byte failure priority. Original payloads and serialized bytes stay
unchanged. No new registration, handler, task, listener or transport starts during
inert compilation.

| Check | Result |
| --- | --- |
| Root build and strict root tests | Passed; 2,683 tests / 337 suites |
| DSL benchmark Swift / Python tests | 24 / 33 passed |
| Shared measurement Swift / Python tests | 68 / 47 passed |
| Macro / extension package tests | 34 / 6 passed |
| External macro compiler fixtures | 26/26 positive and negative semantic cases passed |
| External extension fixtures | Passed |
| Tooling Swift / Python and CI Python tests | 106 / 234 / 183 passed |
| Independent consumers | DSLCommands, DSLBot and RESTOnly built with committed pins |
| Inventory, deterministic generation and parity | Passed; no generated source changes |
| Product/import graph and release record | Passed; 33 products, unchanged dependency policy |
| Callable documentation | 10,488 explicit callables in 978 Swift files; zero missing comments |
| Public API | 33-module snapshot identical to phase 6 except version metadata; reviewed baseline check passed |
| Authored documentation | Curation, example synchronization and strict DiscordDSL DocC conversion passed |
| Independent source reviews | No blocking correctness or dependency findings |

The first macro fixture run failed its import check in a reused scratch directory,
claiming the explicitly declared SwiftSyntaxBuilder dependency was absent. A fresh
scratch build and the complete 26-case matrix passed with the exact same native
engine, pins, disabled prebuilts and strict import checker. The failed log and fresh
successes are retained separately; no manifest, source or checker relaxation was
needed. An initial misnamed focused test filter ran zero cases; the corrected
DefinitionTests filter passed before the complete root run. Neither initial
attempt is counted as successful qualification.

## Runtime measurements and decision

Original runtime `d766cf83` and candidate release binaries use byte-identical DSL
and shared measurement harnesses. The detached original checkout contains only
those development harness updates. Native/common reports, source/build receipts,
fixture hashes, driver cleanup and exact duration sums are retained in the
[local capture directory](../../../.build/performance-phase7), indexed by
[the observation record](phase-7-observations.json). Executable/test/build source
hashes and release dependency hashes are checked after documentation-only edits;
the root manifest and pin independently match the original revision and compiler
identities. These checks separate the final documentation from captured binaries.
This is local evidence, not an uploaded or reserved-host baseline.

The primary matrix contains 22 selected workloads, each with five candidate/candidate
no-change pairs and five alternating original/candidate pairs: **440 fresh
processes**. Definition fixtures vary 10/100/1,000 declarations, 1/100 modules,
ASCII/escaped/Unicode strings and 64/1,024 token repetitions. String shape changes
UTF-8/escaped bytes; token repetition is not a fixed-byte comparison. Each fixture
has an explicit exact admitted byte limit. At 1,000 declarations, ASCII64 admits
357,802 bytes; escaped64, Unicode64 and ASCII1024 admit 3,429,802, 2,085,802 and
3,237,802 bytes respectively, exceeding the production default 1 MiB in those
explicit stress cases. The standard 1,000-declaration ASCII target remains below
that default. Module count and payload content are independent controls.

Full authoring selects direct/DSL at 10/1,000 declarations. It includes schema and
lowering work inside the existing definition boundary; fixed interaction/sink
construction follows that boundary. Invocation constructs once and measures 2,048
completed calls at one/eight workers, excluding schema, catalog and router setup.
Both paths decode equivalent inputs, execute the same handler and validate the
same response. The direct writer control only serializes prepared payloads; it
has its own metric and is not an admission-equivalent baseline. Warmup is three
separate unmeasured operations. Caps are 30 s measured / 3 s warmup per process.

Every primary process has exactly its requested successful population, no rejected,
cancelled, failed, timed-out or uncertain outcomes, zero remaining ownership,
reaped process groups and no histogram underflow, overflow, loss or counter overflow.
All observations enter bounded 10 µs cells; exact target sums determine means.
No p99 or numerical regression budget is qualified. Gross throughput includes
validation and collection; concurrent invocation duration sums overlap and cannot
be used as elapsed loop time.

The table reports medians of five process means, in microseconds. Ranges show the
five paired relative changes, not confidence intervals. These are separate
populations; means and percentiles are never pooled across them. The host was
unreserved, with unknown contention/frequency/thermal effects, so results do not
establish portable speedups or a passed numerical acceptance gate.

| Workload | Original mean (µs) | Candidate mean (µs) | Paired change range | No-change range |
| --- | ---: | ---: | ---: | ---: |
| definition-ascii-h10 | 20.914 | 11.104 | -70.2% to -43.8% | -27.9% to +7.2% |
| definition-ascii-h100 | 201.450 | 112.693 | -44.6% to -43.2% | -2.4% to +3.6% |
| definition-ascii-h1000 | 1911.544 | 1066.255 | -46.1% to -43.1% | -2.1% to +1.4% |
| definition-escaped-h1000 | 7839.219 | 6832.012 | -13.9% to -12.4% | -1.1% to +2.5% |
| definition-unicode-h1000 | 5199.010 | 4177.512 | -22.0% to -15.7% | -1.0% to +0.1% |
| definition-long-ascii-h1000 | 4502.873 | 3626.441 | -20.4% to -19.3% | -0.2% to +4.1% |
| definition-modules100-h1000 | 1946.014 | 1101.501 | -43.6% to -42.9% | -1.8% to +0.6% |
| writer-ascii-h10 | 14.116 | 14.066 | -0.4% to +3.1% | -3.2% to +0.2% |
| writer-ascii-h1000 | 1316.139 | 1342.493 | +1.4% to +2.6% | -1.9% to +4.3% |
| writer-escaped-h1000 | 7152.961 | 7157.807 | -1.1% to +2.6% | -1.6% to +1.9% |
| authoring-direct-h10 | 363.953 | 370.446 | -0.1% to +2.7% | -3.0% to +3.1% |
| invocation-direct-h10-c1 | 71.907 | 72.627 | +0.3% to +2.4% | -3.7% to +0.9% |
| invocation-direct-h10-c8 | 539.679 | 547.877 | -0.1% to +3.3% | -5.4% to +0.9% |
| authoring-direct-h1000 | 38084.317 | 37043.823 | -4.8% to -1.1% | -0.6% to +1.2% |
| invocation-direct-h1000-c1 | 72.745 | 73.270 | -1.1% to +2.0% | -1.7% to +1.9% |
| invocation-direct-h1000-c8 | 543.788 | 552.637 | -1.0% to +2.1% | -0.8% to +0.9% |
| authoring-dsl-h10 | 470.597 | 465.357 | -3.3% to +0.1% | -1.3% to +2.1% |
| invocation-dsl-h10-c1 | 71.773 | 73.119 | -0.1% to +3.8% | -0.6% to +1.2% |
| invocation-dsl-h10-c8 | 532.732 | 552.842 | +2.3% to +5.9% | -1.8% to +2.0% |
| authoring-dsl-h1000 | 49218.538 | 46453.181 | -8.3% to -4.6% | -1.5% to +1.2% |
| invocation-dsl-h1000-c1 | 73.264 | 73.598 | -2.4% to +1.8% | -1.7% to -0.0% |
| invocation-dsl-h1000-c8 | 547.855 | 544.396 | -2.6% to +2.3% | -3.1% to +9.1% |

Prepared ASCII plan compilation improves substantially across declaration/module
counts; Unicode/escaped/long-string gains are smaller because string encoding
and traversal remain. Large complete authoring improves: direct 1,000-declaration
means decrease 1.1%–4.8% per pair, DSL 4.6%–8.3%. Small complete authoring remains
mixed. The 10-declaration prepared target and its no-change control have large
outliers; all individual process receipts remain in the index.

Steady invocation has no source algorithm change and is not uniformly faster.
The 10-declaration/eight-worker DSL target is 2.3%–5.9% slower in the primary set,
beyond its observed -1.8%–+2.0% no-change range. A separate **60-process** follow-up
repeats no-change and original/candidate pairs for direct/DSL 10-declaration and
DSL 1,000-declaration eight-worker controls, using the same requested dimensions.
The 10-declaration DSL/direct changes repeat at +3.2%–+5.0% and +2.4%–+4.5%,
respectively; their fresh no-change ranges are -2.0%–+2.0% and -0.8%–+1.6%.
The 1,000-declaration DSL follow-up improves 1.1%–3.3%, whereas its first set was
mixed. All follow-up integrity/cleanup checks pass. Follow-ups remain separate
from primary summaries; none replaces or hides the first set.

Code generation/layout, allocator history and host effects remain possible causes;
the invocation interval does not isolate them. The repeated small-catalog slowdown
is retained as an unresolved qualification issue. The implementation removes the
measured serialization mechanism and improves its selected construction target;
it does not claim uniform runtime improvement or nonregression at every policy.
Reserved-host acceptance and application-specific tradeoff review remain open.

Across primary captures, measurement-loop CPU ranges from 2.557 to 1,453.448 ms;
process peak RSS through cleanup ranges from 8.61 to 40.53 MiB. CPU includes
validation/collection outside the target timestamp; RSS includes setup/warmup and
fixed fixture storage, but precedes report construction. For ASCII1,000, gross
successful construction throughput ranges from 477.7–497.0/s originally to
830.0–852.7/s in the candidate, and loop CPU from 80.6–83.8 ms to 47.0–48.3 ms.
For the slower small-catalog DSL/eight-worker control, gross successful invocation
throughput ranges from 14,695.9–15,192.9/s to 14,117.5–14,525.7/s, with CPU from
238.0–245.1 ms to 246.1–255.3 ms. Other per-arm resource and successful-throughput
ranges are retained in the index. Live allocator gauges are observations of live
state, not cumulative allocation events or a leak test.

Two separate one-second CPU stack samples at 1 ms intervals cover original and
candidate 1,000-declaration ASCII compilation over 3,000 operations. Both complete
all requested work, exit zero and leave no owned process group or runtime owner.
The original append stack contains JSONValue.serialized / JSONWriter; the
candidate append stack contains countPayloadBytes / countPayloadString. These
profiles support stack attribution, not allocation-event counts, executor/lock
wait accounting or reserved-host timing. They are outside the paired captures.

## Compiler and startup measurements

The selected debug consumer matrix uses 10/1,000 handlers, one module and manual/
macro paths, with native SwiftPM, fixed dependency pins and four jobs. It is a
reduced matrix with its own configuration; it cannot qualify the legacy full
10/100/1,000 matrix's regression identity. Generated Swift source hashes are
identical across arms. Generated manifests contain absolute library checkout
paths, so original/candidate manifest hashes legitimately differ. Root/macro
source, manifest and pin hashes bind each selected library independently.

Each matrix arm records a separate dependency/plugin bootstrap, then clean
consumer, no-change build, clean-binary startup and one-response-literal
incremental build. The edit occurs before the timer and original bytes are
restored afterward. Consumer clean removes the consumer outputs while retaining
prepared dependencies/plugin work. Bootstrap workspaces have different cache
ages; their measurements are retained separately and do not establish a cold-setup
optimization. No dependency-download improvement is claimed.

The no-change SwiftPM invocation includes planning and cache validation, with
manifest caching disabled consistently; it is not an isolated planning interval.
Startup runs a fresh inert clean consumer, verifies its catalog count and includes
process loading, construction, qualification output and supervised teardown. OS
file caches are retained. Startup executable hashes are checked before and after
execution; incremental output hashes are separate. Workspace binaries are later
overwritten rather than archived, so hashes identify earlier binaries without
retaining copies. Unique process receipts and raw stdout/stderr survive workspace
reuse; flat compatibility logs are overwritten and are not the authoritative
per-process evidence.

Native reports supply exact monotonic gross wall duration, native `time` user plus
system CPU for the command and waited descendants, and largest-process peak RSS.
Wall duration includes bounded collection, RSS probes, group teardown and reap;
receipt serialization follows the timer. Average active cores is observed CPU/wall,
not reserved CPU allocation. Peak RSS does not sum simultaneous compiler-family
memory. The existing common converter projects only clean/incremental wall and
RSS into separate catalog7 populations; bootstrap, no-change, startup, CPU and the
new complete build-input identities remain authoritative in the native reports.

Five candidate/candidate no-change pairs and five alternating original/candidate
pairs produce 20 native matrices: **340 timed processes**, comprising 20 bootstrap,
80 clean, 80 no-change, 80 incremental and 80 startup processes. All timed processes
exit zero, preserve complete stdout/stderr and reap their groups. Every selected
consumer sample passes its catalog gates. Input/runner/toolchain/fixture/pin checks pass across the complete
set. Eighty validated common envelopes cover the 160 clean/incremental observations;
they do not represent all 340 processes.

The table uses median wall seconds across five processes per arm and the five
paired relative changes. Each phase is a separate population; rows are not
subtracted or combined into a causal timeline.

| Path / handlers / phase | Original median (s) | Candidate median (s) | Paired change range | No-change range |
| --- | ---: | ---: | ---: | ---: |
| manual / 10 / clean | 3.810 | 3.763 | -1.7% to +0.6% | -1.9% to +3.4% |
| manual / 10 / incremental | 3.787 | 3.764 | -1.8% to +2.2% | -1.2% to +0.3% |
| manual / 10 / no-change | 3.077 | 3.045 | -2.6% to +3.5% | -3.6% to +1.9% |
| manual / 10 / startup | 0.245 | 0.250 | -5.9% to +1.9% | -7.5% to +12.3% |
| manual / 1,000 / clean | 5.973 | 5.988 | -1.7% to +8.3% | -1.6% to +0.6% |
| manual / 1,000 / incremental | 4.211 | 4.206 | -1.7% to +10.9% | -1.5% to +0.9% |
| manual / 1,000 / no-change | 3.105 | 3.088 | -4.0% to +7.1% | -4.7% to +2.5% |
| manual / 1,000 / startup | 0.455 | 0.395 | -19.0% to -3.9% | -14.7% to +10.4% |
| macro / 10 / clean | 3.867 | 3.830 | -3.1% to +6.4% | -2.0% to +3.3% |
| macro / 10 / incremental | 3.823 | 3.804 | -1.7% to +6.3% | -2.4% to +4.0% |
| macro / 10 / no-change | 3.099 | 3.042 | -2.5% to +4.4% | -1.5% to +1.4% |
| macro / 10 / startup | 0.270 | 0.271 | -6.5% to +4.5% | -3.4% to +7.7% |
| macro / 1,000 / clean | 7.116 | 7.219 | +0.1% to +10.9% | -3.0% to +1.2% |
| macro / 1,000 / incremental | 5.416 | 5.531 | -0.9% to +6.7% | -2.2% to +1.1% |
| macro / 1,000 / no-change | 3.045 | 3.078 | -0.9% to +5.9% | -4.0% to +1.4% |
| macro / 1,000 / startup | 0.459 | 0.419 | -12.6% to +12.6% | -10.3% to +3.1% |

The compiler observations do not establish an improvement. Large macro clean
builds are slower in every comparison pair, with a 7.116→7.219 s median; other
build populations include larger positive outliers and mixed signs. These remain
qualification concerns rather than evidence of a harmless cost. Large manual
startup is faster locally, consistent with reduced construction work, but gross
startup includes other work and its no-change variation is substantial. No
compiler stack attribution, package/module change, macro optimization, job-count
increase or numerical nonregression decision follows from these observations.

Across both no-change and comparison sets, native resource ranges are:

| Phase | Processes | CPU seconds | Largest-process peak RSS (MiB) |
| --- | ---: | ---: | ---: |
| Bootstrap | 20 | 2.99–50.41 | 119.41–359.78 |
| Clean consumer | 80 | 4.08–14.93 | 214.30–290.17 |
| Incremental consumer | 80 | 3.81–6.00 | 214.00–291.05 |
| No-change build | 80 | 2.75–2.97 | 119.34–126.14 |
| Fresh inert startup | 80 | 0.00–0.16 | 8.44–17.58 |

Reported zero CPU is valid at native `time` precision. These ranges cover distinct
sizes/paths and are not equal-workload resource deltas. Per-arm and per-workload
wall/CPU/RSS observations remain in the index. Bootstrap wall spans 3.161–17.766 s
across different cache ages and remains outside clean/incremental comparisons.

## Local completion and remaining gates

The selected source change, independent harness boundaries, differential tests,
local correctness checks, paired observations and source reviews are complete.
The exact counter removes full-document materialization for admission while
preserving definitions, routes, diagnostics, limits and inert construction.
Public APIs and delivered product/import dependencies remain unchanged.

Reserved-host numerical acceptance remains open, including the repeated
small-catalog concurrent invocation slowdown and variable/slower large compiler
results. Allocation-event counts, executor/lock waits, compiler stack attribution,
other target platforms and integrated application tradeoff review are unqualified.
No p99 budget, hosted CI, publication, deployment or live Discord result is claimed.
Later stages must retain these qualifications instead of treating the local
construction improvement as a universal runtime/build nonregression gate.
