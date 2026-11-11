// File: Tools/DiscordMediaBenchmarks/Tests/DiscordMediaBenchmarksTests/MediaBenchmarkTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation
import Testing
@testable import DiscordMediaBenchmarks

private final class Counts: @unchecked Sendable {
    var prepared = 0, ran = 0, verified = 0, closed = 0
    var clock: UInt64 = 0
    /// Advances an injected monotonic clock by ten nanoseconds without consulting host performance.
    func now() -> UInt64 { defer { clock += 10 }; return clock }
}

@Suite struct MediaBenchmarkTests {
    /// Confirms every supported ID is finite/unique and configuration parsing rejects malformed or aliased inputs.
    @Test func finiteCatalogAndConfiguration() throws {
        #expect(MediaCatalog.ids.count == 143)
        #expect(MediaCatalog.ids.filter { !$0.contains(".v2.") && !$0.contains(".v3.") }.count == 80)
        #expect(Set(MediaCatalog.ids).count == MediaCatalog.ids.count)
        #expect(throws: MediaBenchmarkError.self) { try MediaCatalog.selected("opus.encode.unknown") }
        for arguments in [["--batch-size", "65"], ["--batch-size", "0"], ["--batches", "0"],
            ["--duration-seconds", "11"], ["--concurrency", "2"], ["--case", "a", "--case", "b"],
            ["--unknown", "1"], ["--seed", "-1"], ["--warmup-seconds", "61"], ["--output", "same", "--common-report", "./same"]] {
            #expect(throws: MediaBenchmarkError.self) { try MediaConfiguration.parse(arguments, environment: [:]) }
        }
        let config = try MediaConfiguration.parse(["--seed", "9"], environment: ["DK_BENCHMARK_SEED": "2",
            "DK_BENCHMARK_PROFILE": "stress", "DK_BENCHMARK_DURATION_SECONDS": "12", "DK_BENCHMARK_ENVELOPE": "common.json"])
        #expect(config.seed == 9 && config.profile == "stress" && config.durationSeconds == 12 && config.commonReport == "common.json")
    }

    /// Every legacy finite case executes real public wrappers and complete untimed oracles, including all codec layouts.
    @Test func everyCatalogCaseRoundtripsAndCloses() async throws {
        for id in MediaCatalog.ids.filter({ !$0.contains(".v2.") && !$0.contains(".v3.") }) {
            let workload = try MediaCatalog.selected(id)
            let batch: MediaBatch
            do { batch = try await workload.prepare(2, 65_535) }
            catch { throw MediaBenchmarkError.integrityFailure("Fixture \(id): \(error)") }
            do {
                #expect(try await batch.run() == 2, "\(id)")
                try await batch.verify()
                await batch.close(); await batch.close()
            } catch {
                await batch.close()
                throw error
            }
        }
    }

    /// Separates injected setup, operation, oracle and closure costs and checks exact observed batch totals.
    @Test func preparedVerificationAndClosureAreOutsideBatchTimer() async throws {
        let counts = Counts()
        let workload = MediaCase(id: "test.fixture", transition: false, dimensions: [:]) { count, _ in
            counts.prepared += 1
            counts.clock += 100
            return MediaBatch(run: { counts.ran += 1; counts.clock += 50; return UInt64(count) },
                verify: { counts.verified += 1; counts.clock += 200 }, close: { counts.closed += 1; counts.clock += 300 })
        }
        var config = MediaConfiguration(); config.batches = 2; config.batchSize = 3
        let result = try await MediaHarness.population(config, workload: workload, warmup: false, now: counts.now)
        #expect(result.batches == 2 && result.calls == 6 && result.timedNanoseconds == 120)
        #expect(result.histogram.snapshot().observedCount == 2)
        #expect(result.elapsedNanoseconds > result.timedNanoseconds)
        #expect(counts.prepared == 2 && counts.ran == 2 && counts.verified == 2 && counts.closed == 2)
    }

    /// Both native-operation errors and untimed semantic errors await the same batch owner cleanup.
    @Test func failedOperationAndFailedOracleCloseJoinedOwners() async throws {
        for failingRun in [true, false] {
            let counts = Counts()
            let workload = MediaCase(id: "test.failure", transition: false, dimensions: [:]) { _, _ in
                MediaBatch(run: {
                    if failingRun { throw MediaBenchmarkError.integrityFailure("run") }
                    return 4
                }, verify: { throw MediaBenchmarkError.integrityFailure("oracle") }, close: { counts.closed += 1 })
            }
            await #expect(throws: MediaBenchmarkError.self) {
                try await MediaHarness.population(MediaConfiguration(), workload: workload, warmup: false, now: counts.now)
            }
            #expect(counts.closed == 1)
        }
    }

    /// Zero warmup creates no fixture; a fixture whose preparation consumes the wall budget is closed unused.
    @Test func zeroWarmupAndExpiredPreparationDoNotRun() async throws {
        let counts = Counts()
        let workload = MediaCase(id: "test.expired", transition: false, dimensions: [:]) { _, _ in
            counts.prepared += 1; counts.clock += 2_000_000_000
            return MediaBatch(run: { counts.ran += 1; return 1 }, verify: {}, close: { counts.closed += 1 })
        }
        var config = MediaConfiguration(); config.warmupSeconds = 0; config.durationSeconds = 1
        let warmup = try await MediaHarness.population(config, workload: workload, warmup: true, now: counts.now)
        #expect(warmup.calls == 0 && counts.prepared == 0)
        let result = try await MediaHarness.population(config, workload: workload, warmup: false, now: counts.now)
        #expect(result.calls == 0 && counts.prepared == 1 && counts.ran == 0 && counts.closed == 1)
    }

    /// Cancellation during the last bounded batch still verifies/closes owners and cannot emit completed evidence.
    @Test func cancellationInFinalBatchJoinsBeforeReturning() async throws {
        let counts = Counts()
        let workload = MediaCase(id: "test.cancelled", transition: false, dimensions: [:]) { count, _ in
            MediaBatch(run: {
                withUnsafeCurrentTask { $0?.cancel() }
                return UInt64(count)
            }, verify: { counts.verified += 1 }, close: { counts.closed += 1 })
        }
        var config = MediaConfiguration(); config.batches = 1
        let task = Task { try await MediaHarness.population(config, workload: workload, warmup: false, now: counts.now) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(counts.verified == 1 && counts.closed == 1)
    }

    /// Validates complete catalog-nine report roundtrips, disjoint warmup counts and queue caller concurrency.
    @Test func catalogNineEnvelopeSeparatesWarmupAndMeasuredCalls() async throws {
        var config = MediaConfiguration(); config.workload = "rtp.packetize.roundtrip"
        config.batches = 3; config.warmupBatches = 2; config.batchSize = 2
        let clock = Counts()
        let result = try await MediaHarness.run(config, workload: MediaCatalog.selected(config.workload), now: clock.now)
        #expect(result.completedBatches == 3 && result.completedCalls == 6)
        #expect(result.warmupBatches == 2 && result.warmupCalls == 4)
        #expect(result.common.identity.catalogVersion == 9)
        #expect(result.common.metrics.map(\.id) == ["media.batch"])
        #expect(result.common.counts?.completed == 3 && result.common.cleanup.remainingOwners == 0)
        #expect(try DiscordBenchmarkReport.decode(result.common.validatedData()).identity.scenario == config.workload)
        let transitionClock = Counts()
        config.workload = "dave.transition.queue"; config.batches = 1; config.warmupBatches = 0
        let transition = try await MediaHarness.run(config, workload: MediaCatalog.selected(config.workload), now: transitionClock.now)
        #expect(transition.common.metrics.map(\.id) == ["mls.transition"])
        #expect(transition.common.identity.concurrency == 2)
    }
}
