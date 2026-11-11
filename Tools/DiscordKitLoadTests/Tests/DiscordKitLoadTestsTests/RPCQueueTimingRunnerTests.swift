// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/RPCQueueTimingRunnerTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

@testable import DiscordKitLoadTests
import DiscordBenchmarkSupport
import Foundation
import Testing

/// Queue depth changes only unsent support ownership; the timed public reply cohort remains exactly 64.
@Suite("RPC reply cohorts with a controlled writer backlog", .timeLimit(.minutes(1)))
struct RPCQueueTimingRunnerTests {
    /// Whole cohorts and original public calls retain separate populations and exact joined write receipts.
    /// - Parameter depth: Empty queue control and two independent nonempty backlog sizes.
    @Test(arguments: [0, 4, 64])
    func completeCohortsPreserveQueueAndCleanup(depth: Int) async throws {
        let report = try await RPCQueueTimingRunner().run(requests: 2, concurrency: 2, queueDepth: depth, delay: .zero)
        try report.counts.validate()
        #expect(report.scenario == "rpc.queuedRepliesV1")
        #expect(report.counts.offered == 2 && report.counts.admitted == 2 && report.counts.completed == 2)
        #expect(report.counts.outcomes[.success] == 2)
        #expect(report.metrics.first { $0.id == "rpc.queuedReplyCohortV1" }?.distribution.observedCount == 2)
        #expect(report.metrics.first { $0.id == "rpc.request" }?.distribution.observedCount == 128)
        #expect(report.metrics.allSatisfy { $0.outcome == .success && $0.distribution.droppedCount == 0 })
        #expect(report.queuedReplyCohorts == 2 && (report.queuedReplyCohortNanoseconds ?? 0) > 0)
        #expect(report.peakPendingRequests == depth + 65)
        #expect(report.protocolWrites == 132 && report.inputFragments == 130 && report.closedPeers == 2)
        #expect(report.cleanup.completed == true && report.cleanup.remainingOwners == 0)
        let decoded = try JSONDecoder().decode(RPCActivitiesTimingReport.self, from: JSONEncoder().encode(report))
        #expect(decoded.queuedReplyCohorts == report.queuedReplyCohorts)
        #expect(decoded.queuedReplyCohortNanoseconds == report.queuedReplyCohortNanoseconds)
    }

    /// Explicit injected reply delay changes no ownership counts, write population or cohort cardinality.
    @Test func delayedRepliesKeepTheSamePopulation() async throws {
        let report = try await RPCQueueTimingRunner().run(requests: 1, concurrency: 1, queueDepth: 2, delay: .microseconds(1))
        #expect(report.counts.completed == 1 && report.counts.outcomes[.success] == 1)
        #expect(report.queuedReplyCohorts == 1 && report.protocolWrites == 66 && report.inputFragments == 65)
        #expect(report.peakPendingRequests == 67 && report.cleanup.remainingOwners == 0)
    }

    /// Cancellation before fixture admission produces an empty truthful report with no transport ownership.
    @Test func preCancelledDriverOwnsNoFixture() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await RPCQueueTimingRunner().run(requests: 1, concurrency: 1, queueDepth: 64, delay: .zero)
        }
        let report = try await task.value
        #expect(report.counts.completed == 0 && report.metrics.isEmpty)
        #expect(report.queuedReplyCohorts == 0 && report.queuedReplyCohortNanoseconds == 0)
        #expect(report.protocolWrites == 0 && report.closedPeers == 0 && report.cleanup.remainingOwners == 0)
    }

    /// Cancellation after actual reply submission releases the sleeping reader, held writer and every caller.
    /// The explicit submission notification establishes the target boundary without an elapsed-time sleep.
    @Test func cancellationDuringReplyCohortJoinsAllOwners() async throws {
        let submitted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let runner = RPCQueueTimingRunner(onCohortSubmitted: { _ = submitted.continuation.yield(()) })
        let task = Task { try await runner.run(requests: 1, concurrency: 1, queueDepth: 4, delay: .seconds(1)) }
        var iterator = submitted.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        submitted.continuation.finish()
    }

    /// Finite request, parallelism, backlog and delay bounds reject scripts before any peer is constructed.
    @Test func invalidDimensionsFailBeforeOwnership() async {
        for dimensions in [(0, 1, 0), (1, 2, 0), (65, 65, 0), (1, 1, -1), (1, 1, 4_097)] {
            await #expect(throws: LoadFailure.invalidArguments) {
                try await RPCQueueTimingRunner().run(requests: dimensions.0, concurrency: dimensions.1,
                                                     queueDepth: dimensions.2, delay: .zero)
            }
        }
        await #expect(throws: LoadFailure.invalidArguments) {
            try await RPCQueueTimingRunner().run(requests: 1, concurrency: 1, queueDepth: 0, delay: .nanoseconds(-1))
        }
        await #expect(throws: LoadFailure.invalidArguments) {
            try await RPCQueueTimingRunner().run(requests: 1, concurrency: 1, queueDepth: 0, delay: .seconds(2))
        }
    }
}
