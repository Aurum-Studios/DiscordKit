// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/RPCActivitiesTimingRunnerTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

@testable import DiscordKitLoadTests
import DiscordBenchmarkSupport
import Foundation
import Testing

/// Protocol workloads prove real client correlation, bounded ownership and independent adapter cleanup.
@Suite("Phase eight RPC and Activities timing", .timeLimit(.minutes(1)))
struct RPCActivitiesTimingRunnerTests {
    /// Every script retains its exact primary population and post-close receipts without live host access.
    @Test(arguments: RPCActivitiesTimingScenario.allCases.filter { $0 != .activitiesSubscriptionGroupsV1 && $0 != .rpcQueuedRepliesV1 })
    func finiteProtocolPopulation(scenario: RPCActivitiesTimingScenario) async throws {
        let report = try await RPCActivitiesTimingRunner().run(scenario: scenario, requests: 4, concurrency: 2,
            fanOut: 3, delay: .microseconds(1))
        try report.counts.validate()
        let expected: BenchmarkOutcome = scenario.isPressure ? .rejected : scenario.isCancelled ? .cancelled : scenario.isMismatch ? .failure : .success
        #expect(report.counts.offered == 4 && report.counts.completed == 4)
        #expect(report.counts.admitted == (scenario.isPressure ? 0 : 4))
        #expect(report.counts.outcomes[expected] == 4)
        #expect(report.counts.outcomes.filter { $0.key != expected }.allSatisfy { $0.value == 0 })
        #expect(report.cleanup.completed == true && report.cleanup.remainingOwners == 0)
        #expect(report.closedPeers == 4)
        let prefix = scenario.isRPC ? "rpc" : "activities"
        #expect(report.metrics.first { $0.id == "\(prefix).request" && $0.outcome == expected }?.distribution.observedCount == 4)
        #expect(report.metrics.first { $0.id == "\(prefix).handshake" && $0.outcome == .success }?.distribution.observedCount == 4)
        #expect(report.metrics.first { $0.id == "\(prefix).close" && $0.outcome == .success }?.distribution.observedCount == 4)
        #expect(report.metrics.allSatisfy { $0.clockDomain == report.clockDomain && $0.distribution.droppedCount == 0 })
        #expect(report.protocolWrites >= 8 && report.inputFragments > 0)
        #expect(report.peakPendingRequests == (scenario.isConcurrent ? 3 : 1))
        #expect(report.retainedEvents == (scenario.isEvents ? 12 : 0))
        #expect(report.acquiredSubscriptions == (scenario == .activitiesSubscriptions ? 12 : 0))
        #expect(report.upstreamSubscriptions == (scenario == .activitiesSubscriptions ? 4 : 0))
        #expect(report.upstreamUnsubscriptions == (scenario == .activitiesSubscriptions ? 4 : 0))
        if scenario == .activitiesSubscriptions {
            #expect(report.metrics.first { $0.id == "activities.subscription" && $0.outcome == .success }?.distribution.observedCount == 12)
            #expect(report.metrics.first { $0.id == "activities.subscription" && $0.outcome == .rejected }?.distribution.observedCount == 4)
        }
        let bytes = try JSONEncoder().encode(report)
        let restored = try JSONDecoder().decode(RPCActivitiesTimingReport.self, from: bytes)
        #expect(restored.counts == report.counts && restored.metrics == report.metrics && restored.cleanup == report.cleanup)
        #expect(bytes.count < 1_048_576)
    }

    /// Production framing processes more actual read fragments when splitting each byte independently.
    @Test func framingFragmentationIsActuallyExercised() async throws {
        let runner = RPCActivitiesTimingRunner()
        let split = try await runner.run(scenario: .rpcFragmented, requests: 1, fanOut: 1)
        let normal = try await runner.run(scenario: .rpcHandshake, requests: 1, fanOut: 1)
        #expect(split.inputFragments > normal.inputFragments * 4)
        #expect(split.protocolWrites == normal.protocolWrites && split.counts == normal.counts)
        #expect(!split.metrics.contains { $0.id == "rpc.peerWait" })
    }

    /// Reversed replies retain every supporting caller's distinct response with the maximum finite fan-out.
    @Test(arguments: [RPCActivitiesTimingScenario.rpcRequests, .activitiesRequests])
    func maximumCorrelationPopulation(scenario: RPCActivitiesTimingScenario) async throws {
        let report = try await RPCActivitiesTimingRunner().run(scenario: scenario, requests: 1, fanOut: 64)
        #expect(report.peakPendingRequests == 64)
        #expect(report.counts.outcomes[.success] == 1 && report.cleanup.remainingOwners == 0)
        #expect(scenario.isRPC ? report.protocolWrites == 65 : (65...66).contains(report.protocolWrites))
    }

    /// Cancels after replies are released while the actual first adapter delivery is explicitly held.
    /// - Parameter scenario: Public RPC or Activity correlation workflow with supporting callers.
    /// - Throws: Unexpected operation errors; CancellationError requires every caller/read to join first.
    @Test(arguments: [RPCActivitiesTimingScenario.rpcRequests, .activitiesRequests])
    func parentCancellationJoinsReleasedReplyCallers(scenario: RPCActivitiesTimingScenario) async throws {
        let gate = ProtocolTimingCancellationGate()
        let task = Task {
            try await RPCActivitiesTimingRunner(onReplyDelivery: { await gate.arriveAndWait() })
                .run(scenario: scenario, requests: 4, concurrency: 1, fanOut: 4)
        }
        await gate.waitForArrival()
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    /// Cancellation before a wave creates no client, protocol work, histogram observation or peer-close invocation.
    @Test func preCancelledDriverOwnsNothing() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await RPCActivitiesTimingRunner().run(scenario: .rpcRequests, requests: 4, concurrency: 2)
        }
        let report = try await task.value
        try report.counts.validate()
        #expect(report.counts.completed == 0 && report.metrics.isEmpty)
        #expect(report.closedPeers == 0 && report.protocolWrites == 0 && report.cleanup.remainingOwners == 0)
    }

    /// Limits fail before clients or protocol resources are allocated.
    @Test func rejectsUnboundedDimensions() async {
        for dimensions in [(0, 1, 1), (4, 5, 1), (65, 65, 1), (1, 1, 0), (1, 1, 65)] {
            await #expect(throws: LoadFailure.invalidArguments) {
                try await RPCActivitiesTimingRunner().run(scenario: .rpcRequests, requests: dimensions.0,
                    concurrency: dimensions.1, fanOut: dimensions.2)
            }
        }
        await #expect(throws: LoadFailure.invalidArguments) {
            try await RPCActivitiesTimingRunner().run(scenario: .activitiesRequests, delay: .nanoseconds(-1))
        }
        await #expect(throws: LoadFailure.invalidArguments) {
            try await RPCActivitiesTimingRunner().run(scenario: .activitiesRequests, delay: .seconds(2))
        }
    }
}

/// Explicit read-side barrier proves cancellation occurs after release with every reply still undelivered.
private actor ProtocolTimingCancellationGate {
    private var arrived = false
    private var released = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var delivery: CheckedContinuation<Void, Never>?

    /// Signals the first released reply's actual read and parks delivery until the test cancels its owner.
    func arriveAndWait() async {
        arrived = true
        arrival?.resume(); arrival = nil
        if !released { await withCheckedContinuation { delivery = $0 } }
    }

    /// Awaits actual reply delivery admission without a wall-clock scheduling assumption.
    func waitForArrival() async {
        if !arrived { await withCheckedContinuation { arrival = $0 } }
    }

    /// Releases the reader so existing awaited close can join it after public caller cancellation.
    func release() {
        released = true
        delivery?.resume(); delivery = nil
    }
}
