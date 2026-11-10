<!--
File: Docs/Tasks/latency-timing/PHASE-4.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
-->

# Phase 4 — Foundation, model and permission microbenchmarks

Implemented 2026-11-10 from Phase 3 revision `7912304d`. This implements
[Stage 4](PLAN.md#stage-4--foundation-model-and-permission-microbenchmarks)
under the frozen [contracts](CONTRACTS.md). Actual completed evidence and remaining
qualifications belong in the [validation record](VALIDATION.md#phase-4-validation).

## Implementation plan

1. Add a development executable selecting existing Bits, Core, Models, authoring,
   Cache and RPC products and shared support. Preserve pure runtime dependencies.
2. Prepare representative size/width/depth/Unicode/role/overwrite/fragment fixtures,
   four variants per case, and independent semantic oracles outside timers.
3. Time finite synchronous batches through minimal observable checksums and exact
   rejections. Separate warmup, batch distributions, normalized mean and throughput;
   never present normalized batch p99 as call p99.
4. Add catalog-revision-4 `pure.batch`, retaining revisions 2/3. Reuse shared
   histograms, release receipts and fresh-process supervision.
5. Prove semantic results, seed wrapping, bad checksums, warmup separation, time
   caps, clock regression, between-batch cancellation, output aliasing and cleanup.
6. Run optimized whole-matrix CPU smoke and inspect size-scaling evidence; complete
   root/tooling/dependency/documentation checks before the requested local commit.

## Implemented slice

[DiscordFoundationBenchmarks](../../../Tools/DiscordFoundationBenchmarks/README.md)
provides 77 cases: JSON 17, identifiers/bitsets 14, models 9, builders 10,
permissions 10 and RPC 17. Its matrix lists exact representative dimensions,
timed APIs, rejection boundaries and independent oracles. Only the selected
fixture family is constructed; only the selected case remains during measurement.
No instrumentation hook, task or log is added per access.

The common report uses catalog revision 4, metric version 1 and external-batch
identity. Histograms use 1 microsecond precision over 0...100 ms; censoring, loss
and insufficient tails stay explicit. Common counts are batch outcomes. Native
reports separately record calls/rejections and gross normalized mean. Warmup
never enters measured histograms or checksums. Full verification occurs before
warmup and after measurement.

Shared supervision binds source, pins, executable, compiler and available host
identity. The wrapper selects serial fresh processes, forwards cancellation and
awaits supervisor teardown. Its compact scaling index links full reports and
retains dimensions, quantile evidence and population/censor/loss counts. No
numerical threshold, baseline promotion or optimization is introduced.

No runtime source or root-manifest dependency changes. The development package
explicitly selects already-pinned swift-crypto for fixture SHA-256; shared support
stays dependency-free. Local checks do not qualify hosted CI, Linux/native
performance, controlled-host stability, individual-call tails, real IPC/Discord
behavior or later roadmap stages.
