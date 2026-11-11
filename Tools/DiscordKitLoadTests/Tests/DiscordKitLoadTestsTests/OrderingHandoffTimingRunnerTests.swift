// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/OrderingHandoffTimingRunnerTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation
import Testing
@testable import DiscordKitLoadTests

@Suite(.serialized) struct OrderingHandoffTimingRunnerTests {
    /// The one-caller control still has a held predecessor; larger cohorts retain every acquire.
    @Test(arguments: [1, 4, 16, 64]) func heldOwnerCohorts(callers: Int) async throws {
        let result = try await OrderingHandoffTimingRunner().run(requests: callers, concurrency: callers,
            partitions: 1, identities: 1, releaseOffsetMicroseconds: 0)
        #expect(result.counts.completed == UInt64(callers))
        #expect(result.counts.outcomes[.success] == UInt64(callers))
        #expect(result.releaseToSuccessor.observedCount == UInt64(callers))
        #expect(result.releaseToSuccessor.droppedCount == 0)
        #expect(result.metrics.count == 1)
        #expect(result.metrics.first?.id == "rest.orderWait")
        #expect(result.metrics.first?.distribution.observedCount == UInt64(callers))
        #expect(result.samples.count == 1)
        #expect(result.samples.first?.queuedCallers == callers)
        #expect(result.samples.first?.heldPartitions == 1)
        #expect(result.maximumCallerTasks == callers && result.maximumHolderTasks == 1)
        #expect(result.clock.activeSleeps == 0 && result.remainingOwners == 0)
        #expect(result.clock.sleepInvocations == result.clock.completedSleeps + result.clock.cancelledSleeps)
        #expect(result.clock.peakActiveSleeps <= callers + 1)
        #expect(result.scheduling.profile == "SchedulingPolicy-default-v1")
        #expect(result.successfulThroughputPerSecond > 0)
        try result.releaseToSuccessor.validate()
    }

    /// Every independent partition is held before its successor is queued and released.
    @Test(arguments: [0, 2_500, 7_500]) func independentPartitionsAndReleaseOffsets(offset: Int) async throws {
        let result = try await OrderingHandoffTimingRunner().run(requests: 8, concurrency: 4,
            partitions: 2, identities: 2, releaseOffsetMicroseconds: offset)
        #expect(result.completedWaves == 2)
        #expect(result.samples.count == 8 && result.omittedSamples == 0)
        #expect(result.samples.allSatisfy { $0.heldPartitions == 4 && $0.queuedCallers == 4 })
        #expect(result.releaseToSuccessor.observedCount == 8)
        #expect(result.counts.outcomes[.success] == 8)
        #expect(result.clock.activeSleeps == 0 && result.remainingOwners == 0)
    }

    /// Full-population histograms continue after the bounded causal sample fills.
    @Test func boundedSamplesAndCommonEnvelope() async throws {
        let configuration = try Phase5TimingConfiguration.parse(["--case", "ordering.heldOwnerDefaultV1",
            "--requests", "68", "--concurrency", "4", "--ordering-partitions", "2", "--ordering-identities", "2",
            "--release-offset-microseconds", "0", "--warmup-requests", "0", "--warmup-seconds", "0"], environment: [:])
        let result = try await Phase5TimingCommand.measure(configuration)
        guard case .orderingHandoff(let value) = result.measurement else {
            Issue.record("Expected the versioned held-owner measurement"); return
        }
        #expect(value.samples.count == 64 && value.omittedSamples == 4)
        #expect(value.releaseToSuccessor.observedCount == 68)
        #expect(result.common.counts?.completed == 68)
        #expect(result.common.cleanup.remainingOwners == 0)
        #expect(result.common.identity.inputSizes["orderingPartitionsPerIdentity"] == 2)
        #expect(result.common.identity.inputSizes["orderingIdentities"] == 2)
        #expect(result.common.identity.scenario == "ordering.heldOwnerDefaultV1")
        #expect(result.common.gauges["clockRemainingSleeps"]?.value == 0)
        #expect(try DiscordBenchmarkReport.decode(result.common.validatedData()) == result.common)
        let encoded = try JSONEncoder().encode(result)
        #expect(encoded.count <= DiscordBenchmarkReport.maximumSerializedBytes)
        _ = try JSONDecoder().decode(Phase5TimingReport.self, from: encoded)
    }

    /// Cancellation before admission creates no synthetic caller or handoff samples.
    @Test func alreadyCancelledRunHasNoOwners() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await OrderingHandoffTimingRunner().run(requests: 4, concurrency: 4,
                partitions: 1, identities: 1, releaseOffsetMicroseconds: 0)
        }
        let result = try await task.value
        #expect(result.counts.completed == 0 && result.releaseToSuccessor.observedCount == 0)
        #expect(result.samples.isEmpty && result.remainingOwners == 0 && result.clock.activeSleeps == 0)
    }
}
