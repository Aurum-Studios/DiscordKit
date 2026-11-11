// File: Tools/DiscordMediaBenchmarks/Tests/DiscordMediaBenchmarksTests/PhaseNineWorkloadTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordDAVE
import Testing
@testable import DiscordMediaBenchmarks

@Suite struct PhaseNineWorkloadTests {
    /// Version-four catalog identities expose distinct endpoints and input populations without replacing old fixtures.
    @Test func finitePoliciesDescribeTheirMeasuredEndpoints() throws {
        #expect(MediaCatalog.phaseNineIDs.count == 31)
        #expect(Set(MediaCatalog.phaseNineIDs).count == 31)
        for window in [64, 1_024, 8_192] {
            let steady = try MediaCatalog.selected("dave.v4.open.steady.replay\(window)")
            let reordered = try MediaCatalog.selected("dave.v4.open.reorderDuplicate.replay\(window)")
            let failure = try MediaCatalog.selected("dave.v4.open.authenticationFailure.replay\(window)")
            let expiry = try MediaCatalog.selected("dave.v4.expiry.replay\(window)")
            #expect(steady.dimensions["authenticatedFramesPerCall"] == 1)
            #expect(reordered.dimensions["authenticatedFramesPerCall"] == 2)
            #expect(reordered.dimensions["duplicateRejectionsPerCall"] == 1)
            #expect(failure.dimensions["authenticationFailuresPerCall"] == 1)
            #expect(expiry.preparePopulation == nil && expiry.dimensions["generationExpiriesPerCall"] == 1)
        }
        for members in [4, 8, 16] {
            let sparse = try MediaCatalog.selected("mls.v4.remove1.sparse.members\(members)")
            #expect(sparse.dimensions["startingMembers"] == UInt64(members - 1))
            #expect(sparse.dimensions["initialTreeLeaves"] == UInt64(members))
            #expect(sparse.dimensions["startingBlankLeaves"] == 1)
            let removals = try MediaCatalog.selected("mls.v4.remove3.dense.members\(members)")
            #expect(removals.dimensions["cachedRemovalProposals"] == 3)
            #expect(removals.dimensions["endingMembers"] == UInt64(members - 3))
        }
    }

    /// All three full-window policies retain one receiver through discarded and successive bounded batches.
    @Test func prefilledReceiversAuthenticateReorderRejectDuplicatesAndFailedTags() async throws {
        for id in MediaCatalog.phaseNineIDs.filter({ $0.hasPrefix("dave.v4.open.") }) {
            let workload = try MediaCatalog.selected(id)
            #expect(workload.dimensions["fixtureVersion"] == 4)
            #expect(workload.dimensions["prefillFrames"] == workload.dimensions["replayWindow"])
            let factory = try #require(workload.preparePopulation)
            let session = try await factory(91)
            do {
                let discarded = try await session.prepare(2, 1); await discarded.close()
                for count in [1, 4] {
                    let batch = try await session.prepare(count, 1)
                    do {
                        #expect(try await batch.run() == UInt64(count), "\(id)")
                        try await batch.verify(); await batch.close(); await batch.close()
                    } catch { await batch.close(); throw error }
                }
                try await session.verify(); await session.close(); await session.close()
            } catch { await session.close(); throw error }
        }
    }

    /// Explicit closure invalidates retained work without resetting any key domain for reuse.
    @Test func retainedBatchCannotOpenAfterPopulationClosure() async throws {
        let workload = try MediaCatalog.selected("dave.v4.open.steady.replay64")
        let factory = try #require(workload.preparePopulation)
        let session = try await factory(1)
        let batch = try await session.prepare(1, 1)
        await session.close()
        await #expect(throws: DAVEError.closed) { try await batch.run() }
        await batch.close(); await session.close()
    }

    /// Every expiry receiver crosses a real generation boundary with old-key liveness before its immutable deadline.
    @Test func expiryEndpointsPruneOncePerCallAndRejectWithheldOldFrames() async throws {
        for window in [64, 1_024, 8_192] {
            let workload = try MediaCatalog.selected("dave.v4.expiry.replay\(window)")
            let batch = try await workload.prepare(1, 17)
            do {
                #expect(try await batch.run() == 1)
                try await batch.verify(); await batch.close(); await batch.close()
            } catch { await batch.close(); throw error }
        }
    }

    /// All bounded dense/sparse/removal cases authenticate complete membership changes and revoke removed owners.
    @Test func boundedGroupsSparseTreesRemovalCountsAndMixedMediaAgree() async throws {
        for id in MediaCatalog.phaseNineMLSIDs {
            let workload = try MediaCatalog.selected(id)
            let batch = try await workload.prepare(1, 29)
            do {
                #expect(try await batch.run() == 1, "\(id)")
                try await batch.verify(); await batch.close(); await batch.close()
            } catch { await batch.close(); throw error }
        }
    }

    /// Exact accounting preserves padded/extended packet geometry and complete playout across UInt16 sequence wrap.
    @Test func matchedRTPSerializationAndJitterControlsPreservePacketsAndLengths() async throws {
        for id in MediaCatalog.phaseNineAccountingIDs {
            let workload = try MediaCatalog.selected(id)
            #expect(workload.dimensions["serializedBytesPerPacket"] == workload.dimensions["payloadBytes"]! + 36)
            let batch = try await workload.prepare(2, 65_533)
            do {
                #expect(try await batch.run() == 2)
                try await batch.verify(); await batch.close(); await batch.close()
            } catch { await batch.close(); throw error }
        }
    }

    /// Native/common reports retain full batch counts, independent warmup and explicit mixed-job scheduler identity.
    @Test func versionFourReportsKeepWholePopulationAndConcurrencyIdentity() async throws {
        for id in ["dave.v4.open.reorderDuplicate.replay64", "dave.v4.expiry.replay64", "mls.v4.mixed.dense.members8"] {
            let workload = try MediaCatalog.selected(id)
            var configuration = MediaConfiguration(); configuration.workload = id
            configuration.batches = 2; configuration.batchSize = 1; configuration.warmupBatches = 1
            let clock = PhaseNineClock()
            let report = try await MediaHarness.run(configuration, workload: workload, now: clock.now)
            #expect(report.completedCalls == 2 && report.completedBatches == 2)
            #expect(report.warmupCalls == 1 && report.warmupBatches == 1)
            #expect(report.common.metrics[0].distribution.observedCount == 2)
            #expect(report.common.identity.inputSizes["fixtureVersion"] == 4)
            #expect(report.common.identity.concurrency == (id.hasPrefix("mls") ? 2 : 1))
            #expect(report.common.identity.scheduler == (id.hasPrefix("mls")
                ? "joined-concurrent-transition-media-batches-v4" : workload.preparePopulation == nil
                ? "serial-wrapper-batches" : "serial-population-stream-v4"))
            #expect(report.common.cleanup.completed == true && report.common.cleanup.remainingOwners == 0)
        }
    }
}

private final class PhaseNineClock: @unchecked Sendable {
    var value: UInt64 = 0
    /// Deterministic monotonic reads validate timer accounting without host performance thresholds.
    /// - Returns: The current synthetic nanosecond tick, then advances by ten; finite harness reads cannot overflow.
    /// One serial test population owns this unchecked storage. Reads perform no I/O, suspension, cancellation or
    /// host-clock access, and concurrent callers would violate the clock's deterministic accounting contract.
    func now() -> UInt64 { defer { value += 10 }; return value }
}
