// File: Tools/DiscordMediaBenchmarks/Tests/DiscordMediaBenchmarksTests/PhaseEightWorkloadTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Testing
@testable import DiscordMediaBenchmarks

@Suite struct PhaseEightWorkloadTests {
    /// New dimensions identify construction, continuous processing and flush without altering old identities.
    @Test func endpointAndChunkPoliciesAreExplicit() throws {
        #expect(MediaCatalog.phaseEightIDs.count == 45)
        #expect(Set(MediaCatalog.phaseEightIDs).count == 45)
        for (source, destination) in MediaCatalog.phaseEightRates {
            for layout in ["mono", "stereo"] {
                let prefix = "resample.v3."
                let suffix = "\(source).\(destination).\(layout)"
                let startup = try MediaCatalog.selected(prefix + "startup." + suffix)
                let finish = try MediaCatalog.selected(prefix + "finish." + suffix)
                #expect(startup.preparePopulation == nil && finish.preparePopulation == nil)
                #expect(startup.dimensions["startupInsideTimer"] == 1 && startup.dimensions["finishInsideTimer"] == 0)
                #expect(finish.dimensions["startupInsideTimer"] == 0 && finish.dimensions["finishInsideTimer"] == 1)
                let regular = try MediaCatalog.selected(prefix + "continuous." + suffix + ".regular")
                let irregular = try MediaCatalog.selected(prefix + "continuous." + suffix + ".irregular")
                #expect(regular.dimensions["chunkPatternLength"] == 1)
                #expect(irregular.dimensions["chunkPatternLength"] == 3)
                #expect(irregular.dimensions["minimumChunkFrames"] == 1 && irregular.dimensions["maximumChunkFrames"] == 509)
            }
        }
    }

    /// Every new endpoint/owner runs with complete PCM/FIFO oracles, discarded preparation and repeated closure.
    /// Irregular batches span all three chunk sizes, and final verification checks exact carry and queue drain.
    @Test func newCasesKeepIndependentOwnersAndCompleteOracles() async throws {
        for id in MediaCatalog.phaseEightIDs {
            let workload = try MediaCatalog.selected(id)
            #expect(workload.dimensions["fixtureVersion"] == 3)
            if let factory = workload.preparePopulation {
                let session = try await factory(65_535)
                do {
                    let unused = try await session.prepare(2, 1)
                    await unused.close()
                    for count in [1, 2, 4] {
                        let batch = try await session.prepare(count, UInt64(count))
                        do {
                            #expect(try await batch.run() == UInt64(count), "\(id)")
                            try await batch.verify()
                            await batch.close(); await batch.close()
                        } catch { await batch.close(); throw error }
                    }
                    try await session.verify()
                    await session.close(); await session.close()
                } catch { await session.close(); throw error }
            } else {
                let batch = try await workload.prepare(2, 65_535)
                do {
                    #expect(try await batch.run() == 2, "\(id)")
                    try await batch.verify()
                    await batch.close(); await batch.close()
                } catch { await batch.close(); throw error }
            }
        }
    }

    /// Queue identities cover the default, shallow, deep and maximum capacities with a bounded stereo PCM budget.
    @Test func queueOccupancyAndBytesAreIndependentOfBatchFanout() throws {
        for depth in [1, 8, 64, 1_024, 4_096] {
            let workload = try MediaCatalog.selected("pcm.v3.queue.occupancy\(depth)")
            #expect(workload.dimensions["queueOccupancy"] == UInt64(depth))
            #expect(workload.dimensions["maximumBlocks"] == UInt64(depth))
            #expect(workload.dimensions["retainedPCMBytes"] == UInt64(depth * 960 * 2 * 4))
            #expect(workload.dimensions["readsPerCall"] == 1 && workload.dimensions["writesPerCall"] == 1)
        }
    }

    /// Fresh whole-population reports keep batch histograms, wrapper totals, v3 scheduling and joined cleanup exact.
    @Test func phaseEightReportsRetainWholePopulationAndFixtureIdentity() async throws {
        for id in ["resample.v3.startup.44100.48000.stereo",
            "resample.v3.continuous.48000.47999.stereo.irregular", "pcm.v3.queue.occupancy8"] {
            let workload = try MediaCatalog.selected(id)
            var configuration = MediaConfiguration(); configuration.workload = id
            configuration.batches = 2; configuration.batchSize = 3; configuration.warmupBatches = 1
            let clock = PhaseEightClock()
            let result = try await MediaHarness.run(configuration, workload: workload, now: clock.now)
            #expect(result.completedCalls == 6 && result.completedBatches == 2)
            #expect(result.warmupCalls == 3 && result.warmupBatches == 1)
            #expect(result.common.metrics[0].distribution.observedCount == 2)
            #expect(result.common.identity.concurrency == 1)
            #expect(result.common.identity.scheduler == (workload.preparePopulation == nil
                ? "serial-wrapper-batches" : "serial-population-stream-v3"))
            #expect(result.common.identity.inputSizes["fixtureVersion"] == 3)
            #expect(result.common.cleanup.completed == true && result.common.cleanup.remainingOwners == 0)
            #expect(try DiscordBenchmarkReport.decode(result.common.validatedData()).identity.scenario == id)
        }
    }
}

private final class PhaseEightClock: @unchecked Sendable {
    var value: UInt64 = 0
    /// Deterministic monotonic reads separate harness accounting from host performance.
    func now() -> UInt64 { defer { value += 10 }; return value }
}
