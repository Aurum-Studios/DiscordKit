// File: Tools/DiscordFoundationBenchmarks/Tests/DiscordFoundationBenchmarksTests/HarnessTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation
import Testing
@testable import DiscordFoundationBenchmarks

@Suite struct HarnessTests {
    /// Creates an inert arithmetic oracle to test harness boundaries without public product or performance assumptions.
    /// - Parameters:
    ///   - rejected: Makes each call one expected rejection instead of success; defaults to success.
    ///   - corrupt: Replaces expected checksums with zero to prove integrity failure; defaults to the correct independent formula.
    /// - Returns: A synchronous test-only workload with no I/O, tasks or retained output.
    private func fixture(rejected: Bool = false, corrupt: Bool = false) -> FoundationWorkload {
        FoundationWorkload(id: "test", dimensions: [:], fixture: Data("fixture".utf8),
            operation: { .init(checksum: $0 &* 3, rejections: rejected ? 1 : 0) },
            expected: { .init(checksum: corrupt ? 0 : $0 &* 3, rejections: rejected ? 1 : 0) }, verify: {})
    }

    /// Proves exact injected batch endpoints, call counts and separate warmup with no numerical performance assertion.
    /// - Throws: Unexpected statistics/configuration/report errors from a finite arithmetic fixture.
    @Test func exactBatchBoundaryAndWarmupSeparation() throws {
        var configuration = FoundationConfiguration()
        configuration.workload = "test"; configuration.batches = 3
        configuration.batchSize = 4; configuration.warmupBatches = 2
        var timestamp: UInt64 = 0
        let population = try FoundationHarness.population(configuration, workload: fixture(), warmup: false, now: {
            defer { timestamp += 10 }; return timestamp
        })
        #expect(population.batches == 3)
        #expect(population.calls == 12)
        #expect(population.timedNanoseconds == 30)
        #expect(population.elapsedNanoseconds == 100)
        #expect(population.histogram.snapshot().observedCount == 3)
        #expect(try FoundationHarness.verify(population, configuration: configuration, workload: fixture()) == 234)
        let result = try FoundationHarness.run(configuration, workload: fixture())
        #expect(result.warmupBatches == 2 && result.warmupCalls == 8)
        #expect(result.completedBatches == 3 && result.completedCalls == 12)
        #expect(result.common.metrics[0].distribution.observedCount == 3)
        #expect(result.common.metrics[0].p99 == .unavailable(.insufficientTailData))
        #expect(result.common.identity.inputSizes["batchSize"] == 4)
        #expect(result.common.identity.catalogVersion == 4)
    }

    /// Requires visible rejected batches/calls and verifies that an intentionally false checksum prevents a report.
    /// - Throws: Unexpected setup/report errors; the deliberately corrupt run is asserted to throw.
    @Test func expectedRejectionsAreVisibleAndBadChecksumsFail() throws {
        var configuration = FoundationConfiguration()
        configuration.workload = "test"; configuration.batches = 2; configuration.batchSize = 4
        configuration.warmupSeconds = 0
        let result = try FoundationHarness.run(configuration, workload: fixture(rejected: true))
        #expect(result.rejectedCalls == 8)
        #expect(result.common.counts?.outcomes[.rejected] == 2)
        #expect(result.common.metrics[0].outcome == .rejected)
        #expect(result.warmupCalls == 0)
        #expect(throws: FoundationBenchmarkError.self) {
            try FoundationHarness.run(configuration, workload: fixture(corrupt: true))
        }
    }

    /// Uses exact virtual nanoseconds to prove a reached cap admits no batch and a regressing endpoint fails.
    /// - Throws: Unexpected fixture/configuration errors; no real waiting or performance threshold is used.
    @Test func capAndRegressingClockDoNotInventSamples() throws {
        var configuration = FoundationConfiguration()
        configuration.batches = 1
        var reads: [UInt64] = [0, 1_000_000_000, 1_000_000_000]
        configuration.durationSeconds = 1
        let empty = try FoundationHarness.population(configuration, workload: fixture(), warmup: false,
            now: { reads.removeFirst() })
        #expect(empty.batches == 0 && empty.histogram.snapshot().observedCount == 0)
        reads = [0, 0, 20, 10]
        #expect(throws: FoundationBenchmarkError.self) {
            try FoundationHarness.population(configuration, workload: fixture(), warmup: false, now: { reads.removeFirst() })
        }
    }

    /// Rejects invalid budgets, duplicate options, nonserial execution and aliased report destinations before writes.
    /// - Throws: Unexpected parsing failure for the valid UInt64 maximum seed/environment-precedence fixture.
    @Test func configurationRejectsUnboundedAndAmbiguousRuns() throws {
        for arguments in [["--batch-size", "0"], ["--batches", "100001"], ["--concurrency", "2"],
            ["--seed", "-1"], ["--case"], ["--seed", "1", "--seed", "2"], ["--unknown", "x"],
            ["--output", "same", "--common-report", "same"]] {
            #expect(throws: FoundationBenchmarkError.self) { try FoundationConfiguration.parse(arguments, environment: [:]) }
        }
        #expect(throws: FoundationBenchmarkError.self) {
            try FoundationConfiguration.parse(["--output", "same", "--common-report", "./same"], environment: [:])
        }
        let parsed = try FoundationConfiguration.parse(["--seed", "18446744073709551615"],
            environment: ["DK_BENCHMARK_SEED": "1", "DK_BENCHMARK_ENVELOPE": "common.json"])
        #expect(parsed.seed == UInt64.max && parsed.commonReport == "common.json")
    }

    /// Cancels structured test tasks before admission and during a call, proving zero first-case calls and one complete second-case batch.
    /// - Throws: Unexpected task setup errors; cancellation failures are asserted inside each task and both tasks are joined.
    @Test func cancellationStopsAtBatchBoundaries() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var calls: UInt64 = 0
            let workload = FoundationWorkload(id: "cancel", dimensions: [:], fixture: Data(),
                operation: { _ in calls += 1; return .init(checksum: 0) }, expected: { _ in .init(checksum: 0) }, verify: {})
            #expect(throws: CancellationError.self) {
                try FoundationHarness.population(FoundationConfiguration(), workload: workload, warmup: false)
            }
            #expect(calls == 0)
        }
        await task.value
        let during = Task {
            var calls: UInt64 = 0
            let workload = FoundationWorkload(id: "cancel", dimensions: [:], fixture: Data(),
                operation: { _ in
                    calls += 1; withUnsafeCurrentTask { $0?.cancel() }; return .init(checksum: calls)
                }, expected: { _ in .init(checksum: 0) }, verify: {})
            var configuration = FoundationConfiguration()
            configuration.batches = 2; configuration.batchSize = 4
            #expect(throws: CancellationError.self) {
                try FoundationHarness.population(configuration, workload: workload, warmup: false)
            }
            #expect(calls == 4)
        }
        await during.value
    }

    /// Executes every prepared case through all four variants and validates native checksums/common report round trips.
    /// - Throws: Any case, integrity or report failure. Small batches establish semantics without comparing elapsed values.
    @Test func finiteCatalogRunsAllVariantsAndChecksReports() throws {
        let workloads = try FoundationWorkloads.make()
        #expect(Set(workloads.map(\.id)).count == workloads.count)
        for workload in workloads {
            var configuration = FoundationConfiguration()
            configuration.workload = workload.id; configuration.batches = 1
            configuration.batchSize = 4; configuration.warmupSeconds = 0
            let result = try FoundationHarness.run(configuration, workload: workload)
            #expect(result.completedCalls == 4)
            #expect(result.checksum == result.expectedChecksum)
            #expect(try DiscordBenchmarkReport.decode(result.common.validatedData()) == result.common)
        }
    }
}
