// File: Tools/DiscordMediaBenchmarks/Tests/DiscordMediaBenchmarksTests/ContinuousWorkloadTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordDAVE
import Foundation
import Testing
@testable import DiscordMediaBenchmarks

@Suite struct ContinuousWorkloadTests {
    /// All version-two cases retain state through successive batches, safely discard unused preparation and close twice.
    /// - Throws: Fixture, authentication, codec, resampling or full-stream oracle errors; no time threshold is asserted.
    /// Replay windows start full and all successful opens use monotonically increasing unique nonces; the final
    /// verifier requires exact replay rejection. FIR verifies final stream duration and retained history bounds.
    @Test func successiveBatchesPreserveContinuousStateAndOracles() async throws {
        let ids = MediaCatalog.ids.filter { $0.contains(".v2.") }
        #expect(ids.count == 18)
        for id in ids {
            let workload = try MediaCatalog.selected(id)
            let factory = try #require(workload.preparePopulation)
            #expect(workload.dimensions["fixtureVersion"] == 2 && workload.dimensions["continuousState"] == 1)
            let session = try await factory(65_535)
            do {
                let unused = try await session.prepare(2, 65_535)
                await unused.close()
                for count in [1, 4] {
                    let batch = try await session.prepare(count, UInt64(count))
                    do {
                        #expect(try await batch.run() == UInt64(count), "\(id)")
                        try await batch.verify()
                        await batch.close()
                    } catch { await batch.close(); throw error }
                }
                try await session.verify()
                await session.close(); await session.close()
            } catch { await session.close(); throw error }
        }
    }

    /// Waveform offsets concatenate exactly at both source rates; stereo channels remain distinct and finite.
    /// This catches source-rate and per-block phase resets before any codec or FIR implementation is involved.
    @Test func continuousSignalUsesSourceClockAndContiguousOffsets() {
        for rate in [16_000, 44_100, 48_000] {
            for channels in [1, 2] {
                let frames = rate / 50
                let full = MediaCatalog.continuousSamples(frames: 2 * frames, channels: channels, rate: rate, firstFrame: 17)
                let first = MediaCatalog.continuousSamples(frames: frames, channels: channels, rate: rate, firstFrame: 17)
                let second = MediaCatalog.continuousSamples(frames: frames, channels: channels, rate: rate,
                    firstFrame: 17 + UInt64(frames))
                #expect(full == first + second && full.allSatisfy(\.isFinite))
                let time = 17.0 / Double(rate)
                #expect(full[0] == Float(sin(time * 2 * .pi * 440) * 0.18 + sin(time * 2 * .pi * 206.8) * 0.04))
                if channels == 2 { #expect(full[0] != full[1]) }
            }
        }
    }

    /// New DAVE owners use the production/default or supported maximum full replay window and become permanently closed.
    /// - Throws: Fixture setup/preparation errors; opening after explicit owner closure must fail with `closed`.
    @Test func prefilledReplayPolicyAndClosedOwnerAreObservable() async throws {
        for window in [1_024, 8_192] {
            let workload = try MediaCatalog.selected("dave.v2.frame.open.replay\(window)")
            #expect(workload.dimensions["replayWindow"] == UInt64(window))
            #expect(workload.dimensions["prefillFrames"] == UInt64(window))
        }
        let workload = try MediaCatalog.selected("dave.v2.frame.open.replay1024")
        let factory = try #require(workload.preparePopulation)
        let session = try await factory(1)
        let batch = try await session.prepare(1, 1)
        await session.close()
        await #expect(throws: DAVEError.closed) { try await batch.run() }
        await batch.close(); await session.close()
    }
}

/// Exclusively mutated by one serial test population; the fake clock has no connection to host performance.
private final class PopulationCounts: @unchecked Sendable {
    var clock: UInt64 = 0
    var factories = 0, preparations = 0, calls = 0, batchCloses = 0, verifications = 0, closes = 0
    var seeds: [UInt64] = []
    /// Advances exactly ten nanoseconds per harness read, keeping timer assertions deterministic.
    func now() -> UInt64 { defer { clock += 10 }; return clock }
}

@Suite struct PopulationLifecycleTests {
    /// Two batches share one stream, final verification and closure; warmup receives an independent seed and owner.
    /// - Throws: Unexpected harness accounting errors; fake setup/oracle/close costs must stay outside batch timers.
    @Test func oneOwnerPerPopulationWithUntimedFinalization() async throws {
        let counts = PopulationCounts()
        let workload = MediaCase.continuous(id: "test.v2.continuous", dimensions: [:]) { seed in
            counts.factories += 1; counts.seeds.append(seed); counts.clock += 1_000
            return MediaSession(prepare: { count, _ in
                counts.preparations += 1; counts.clock += 100
                return MediaBatch(run: { counts.calls += count; counts.clock += 50; return UInt64(count) },
                    verify: { counts.clock += 200 }, close: { counts.batchCloses += 1; counts.clock += 300 })
            }, verify: { counts.verifications += 1; counts.clock += 400 },
                close: { counts.closes += 1; counts.clock += 500 })
        }
        var config = MediaConfiguration(); config.batches = 2; config.batchSize = 3; config.warmupBatches = 1
        let measured = try await MediaHarness.population(config, workload: workload, warmup: false, now: counts.now)
        #expect(measured.calls == 6 && measured.batches == 2 && measured.timedNanoseconds == 120)
        #expect(counts.factories == 1 && counts.preparations == 2 && counts.batchCloses == 2)
        #expect(counts.verifications == 1 && counts.closes == 1)
        _ = try await MediaHarness.population(config, workload: workload, warmup: true, now: counts.now)
        #expect(counts.factories == 2 && counts.closes == 2 && counts.verifications == 2)
        #expect(counts.seeds == [config.seed, config.seed &+ (1 << 63)])
    }

    /// Preparation, execution, batch verification and final verification failures all close the population exactly once.
    /// - Throws: Unexpected setup errors; each injected failure must propagate rather than produce a report.
    @Test func failuresCloseTheLongLivedOwner() async throws {
        for failure in 0..<4 {
            let counts = PopulationCounts()
            let workload = MediaCase.continuous(id: "test.v2.failure", dimensions: [:]) { _ in
                MediaSession(prepare: { count, _ in
                    if failure == 0 { throw MediaBenchmarkError.integrityFailure("prepare") }
                    return MediaBatch(run: {
                        if failure == 1 { throw MediaBenchmarkError.integrityFailure("run") }
                        return UInt64(count)
                    }, verify: {
                        if failure == 2 { throw MediaBenchmarkError.integrityFailure("batch verify") }
                    }, close: { counts.batchCloses += 1 })
                }, verify: {
                    if failure == 3 { throw MediaBenchmarkError.integrityFailure("population verify") }
                }, close: { counts.closes += 1 })
            }
            var config = MediaConfiguration(); config.batches = 1
            await #expect(throws: MediaBenchmarkError.self) {
                try await MediaHarness.population(config, workload: workload, warmup: false, now: counts.now)
            }
            #expect(counts.closes == 1 && counts.batchCloses == (failure == 0 ? 0 : 1))
        }
    }

    /// Zero warmup and preexisting cancellation allocate no stream; expired prefill closes without running a batch.
    /// - Throws: Unexpected harness errors; cancellation is injected in the task itself without racing another task.
    @Test func zeroWarmupCancellationAndExpiredPrefillReleaseOwners() async throws {
        let counts = PopulationCounts()
        let workload = MediaCase.continuous(id: "test.v2.expired", dimensions: [:]) { _ in
            counts.factories += 1; counts.clock += 2_000_000_000
            return MediaSession(prepare: { count, _ in
                counts.preparations += 1
                return MediaBatch(run: { counts.calls += count; return UInt64(count) }, verify: {}, close: {})
            }, verify: {}, close: { counts.closes += 1 })
        }
        var config = MediaConfiguration(); config.durationSeconds = 1; config.warmupSeconds = 0
        _ = try await MediaHarness.population(config, workload: workload, warmup: true, now: counts.now)
        #expect(counts.factories == 0)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MediaHarness.population(MediaConfiguration(), workload: workload, warmup: false, now: counts.now)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(counts.factories == 0)
        let expired = try await MediaHarness.population(config, workload: workload, warmup: false, now: counts.now)
        #expect(expired.calls == 0 && counts.factories == 1 && counts.preparations == 0 && counts.closes == 1)
    }

    /// Cancellation in the final timed batch joins batch closure and population closure before it propagates.
    /// - Throws: Only unexpected setup errors; cancellation must not emit a successfully completed population.
    @Test func cancellationAfterLastRunJoinsPopulationCleanup() async throws {
        let counts = PopulationCounts()
        let workload = MediaCase.continuous(id: "test.v2.cancel", dimensions: [:]) { _ in
            MediaSession(prepare: { count, _ in
                MediaBatch(run: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return UInt64(count)
                }, verify: { counts.verifications += 1 }, close: { counts.batchCloses += 1 })
            }, verify: { counts.verifications += 100 }, close: { counts.closes += 1 })
        }
        var config = MediaConfiguration(); config.batches = 1
        let cancelled = Task {
            try await MediaHarness.population(config, workload: workload, warmup: false, now: counts.now)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(counts.verifications == 1 && counts.batchCloses == 1 && counts.closes == 1)
    }
}
