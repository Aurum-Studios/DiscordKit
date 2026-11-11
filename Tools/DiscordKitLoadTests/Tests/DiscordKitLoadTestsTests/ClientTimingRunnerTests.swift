// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/ClientTimingRunnerTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

@testable import DiscordKitLoadTests
import DiscordBenchmarkSupport
import Foundation
import Testing

/// Real local client owners retain finite outcome populations and independent post-cleanup receipts.
@Suite("Phase seven client timing", .timeLimit(.minutes(1)))
struct ClientTimingRunnerTests {
    /// Every finite script has its declared exact outcome and metric population; successful local start
    /// never substitutes for socket/lease/task/body cleanup evidence or claims live Discord qualification.
    @Test(arguments: ClientTimingScenario.allCases)
    func finiteClientPopulation(scenario: ClientTimingScenario) async throws {
        let report = try await Phase7ClientTimingRunner().run(scenario: scenario, requests: 4,
            concurrency: 2, delay: .microseconds(10))
        try report.counts.validate()
        #expect(report.counts.offered == 4 && report.counts.admitted == 4 && report.counts.completed == 4)
        #expect(report.cleanup.remainingOwners == 0 && report.cleanup.isEmpty)
        #expect(report.metrics.allSatisfy { $0.clockDomain == report.clockDomain })
        #expect(report.metrics.first { $0.id == "client.construct" && $0.outcome == .success }?.distribution.observedCount == 4)
        #expect(report.metrics.first { $0.id == "client.shutdown" && $0.outcome == .success }?.distribution.observedCount == 4)
        let expected: BenchmarkOutcome
        switch scenario {
        case .construction, .lifecycle, .slowSubscriber: expected = .success
        case .cancelledDiscovery: expected = .cancelled
        case .discoveryFailure, .projectionFailure: expected = .failure
        }
        #expect(report.counts.outcomes[expected] == 4)
        #expect(report.counts.outcomes.filter { $0.key != expected }.allSatisfy { $0.value == 0 })
        #expect(report.discoveryExecutions == (scenario == .construction ? 0 : 4))
        if scenario == .construction {
            #expect(!report.metrics.contains { ["client.discovery", "client.start", "client.lifecycleJoined", "client.ingestion"].contains($0.id) })
        } else {
            let discovery: BenchmarkOutcome = scenario == .cancelledDiscovery ? .cancelled : scenario == .discoveryFailure ? .failure : .success
            #expect(report.metrics.first { $0.id == "client.discovery" && $0.outcome == discovery }?.distribution.observedCount == 4)
            #expect(report.metrics.first { $0.id == "client.lifecycleJoined" && $0.outcome == expected }?.distribution.observedCount == 4)
            #expect(report.metrics.first { $0.id == "client.start" && $0.outcome == expected }?.distribution.observedCount == 4)
        }
        let ready = scenario == .lifecycle || scenario == .slowSubscriber
        #expect(report.localReadyClients == (ready ? 4 : 0))
        #expect(report.slowSubscriberRetainedEvents == (scenario == .slowSubscriber ? 4 : 0))
        if ready {
            #expect(report.metrics.first { $0.id == "client.ingestion" && $0.outcome == .success }?.distribution.observedCount == 8)
        } else if scenario == .projectionFailure {
            #expect(report.metrics.first { $0.id == "client.ingestion" && $0.outcome == .failure }?.distribution.observedCount == 4)
            #expect(!report.metrics.contains { $0.id == "client.start" && $0.outcome == .success })
        }
        let bytes = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(ClientTimingReport.self, from: bytes)
        #expect(decoded.counts == report.counts && decoded.metrics == report.metrics)
        #expect(decoded.cleanup == report.cleanup)
        #expect(bytes.count < 1_048_576)
    }

    /// Cancellation before the first wave creates no client, starts no interval and returns a complete
    /// empty receipt instead of reporting the configured population as offered or completed.
    @Test func preCancelledDriverHasNoOwners() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Phase7ClientTimingRunner().run(scenario: .lifecycle, requests: 8, concurrency: 2)
        }
        let report = try await task.value
        #expect(report.counts.offered == 0 && report.counts.completed == 0)
        #expect(report.metrics.isEmpty)
        #expect(report.cleanup.isEmpty && report.discoveryExecutions == 0 && report.localReadyClients == 0)
        try report.counts.validate()
    }

    /// Invalid dimensions fail before allocating any client, discovery body, lease or run task.
    @Test func rejectsUnboundedDimensions() async {
        await #expect(throws: LoadFailure.invalidArguments) {
            try await Phase7ClientTimingRunner().run(scenario: .lifecycle, requests: 0)
        }
        await #expect(throws: LoadFailure.invalidArguments) {
            try await Phase7ClientTimingRunner().run(scenario: .lifecycle, requests: 4, concurrency: 5)
        }
        await #expect(throws: LoadFailure.invalidArguments) {
            try await Phase7ClientTimingRunner().run(scenario: .lifecycle, requests: 65, concurrency: 65)
        }
        await #expect(throws: LoadFailure.invalidArguments) {
            try await Phase7ClientTimingRunner().run(scenario: .lifecycle, delay: .nanoseconds(-1))
        }
        await #expect(throws: LoadFailure.invalidArguments) {
            try await Phase7ClientTimingRunner().run(scenario: .lifecycle, delay: .seconds(2))
        }
    }
}
