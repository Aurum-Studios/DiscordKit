// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/CacheTimingRunnerTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation
import Testing
@testable import DiscordKitLoadTests

/// Functional population, fencing and ownership tests; elapsed values are not performance gates.
@Suite("Cache timing suite", .timeLimit(.minutes(1)))
struct CacheTimingRunnerTests {
    /// Every selected operation records the complete run, including a partial last cohort.
    /// - Parameter scenario: Closed local fixture class; no real service is accessed.
    /// - Throws: Unexpected fixture setup, cache invariant or report serialization errors.
    @available(macOS 15, *)
    @Test(arguments: CacheTimingScenario.allCases)
    func populationsAndCleanup(scenario: CacheTimingScenario) async throws {
        let report = try await CacheTimingRunner().run(scenario: scenario, requests: 7, concurrency: 3,
            workingSet: 4, identities: 2, hitPercent: 50, fanOut: 2, slowSubscriber: true, delay: .zero)
        try report.counts.validate()
        #expect(report.counts.offered == 7 && report.counts.completed == 7)
        #expect(report.counts.outcomes[.success] == 7)
        #expect(report.cleanup.isEmpty)
        #expect(count(report, "cache.call") == 7)
        #expect(count(report, "cache.owner") == (scenario.ownerStage == nil ? 0 : 7))
        #expect(report.metrics.allSatisfy { $0.distribution.droppedCount == 0 })
        #expect(Set(report.metrics.map(\.clockDomain)).count == 1)
        #expect(try JSONEncoder().encode(report).count > 0)
        switch scenario {
        case .singleFlight, .staleFence:
            #expect(report.loaderCalls == 3 && report.coalescedReads == 4)
            #expect(count(report, "cache.loader") == 3)
            #expect(report.staleCompletions == (scenario == .staleFence ? 3 : 0))
        case .refresh:
            #expect(report.loaderCalls == 7)
            #expect(count(report, "cache.loader") == 7)
        case .eviction: #expect(report.evictions == 7)
        case .expiry: #expect(report.expirations == 24)
        case .broadcast:
            #expect(report.healthyDeliveries == 21 && report.slowResynchronizations == 7)
            #expect(count(report, "cache.broadcast") == 21)
        default: #expect(report.loaderCalls == 0)
        }
    }

    /// Healthy fan-out delivers every publication; hit-ratio endpoints preserve exact caller counts.
    /// - Throws: Unexpected offline fixture or cache failures.
    @available(macOS 15, *)
    @Test func healthyFanoutAndLookupEndpoints() async throws {
        let broadcast = try await CacheTimingRunner().run(scenario: .broadcast, requests: 4, concurrency: 2,
            fanOut: 3, slowSubscriber: false, delay: .zero)
        #expect(broadcast.healthyDeliveries == 12 && broadcast.slowResynchronizations == 0)
        #expect(count(broadcast, "cache.broadcast") == 4)
        #expect(broadcast.cleanup.isEmpty)
        for ratio in [0, 100] {
            let report = try await CacheTimingRunner().run(scenario: .lookup, requests: 5, concurrency: 2,
                workingSet: 2, identities: 3, hitPercent: ratio, delay: .zero)
            #expect(report.counts.outcomes[.success] == 5 && report.cleanup.isEmpty)
            #expect(count(report, "cache.call") == 5 && count(report, "cache.owner") == 5)
        }
    }

    /// Invalid limits and cancellation fail before owners are created; pre-cancelled work acquires no owners.
    /// - Throws: Unexpected dimension validation or task ownership errors.
    @available(macOS 15, *)
    @Test func invalidBoundsAndCancellation() async throws {
        for (requests, concurrency, workingSet, identities, hitPercent, fanOut, delay) in [
            (0, 1, 16, 1, 100, 2, Duration.zero), (1, 2, 16, 1, 100, 2, .zero),
            (1, 1, 0, 1, 100, 2, .zero), (1, 1, 16, 33, 100, 2, .zero),
            (1, 1, 16, 1, 49, 2, .zero), (1, 1, 16, 1, 100, 33, .zero),
            (1, 1, 16, 1, 100, 2, .seconds(-1))] {
            await #expect(throws: LoadFailure.invalidArguments) {
                try await CacheTimingRunner().run(scenario: .lookup, requests: requests, concurrency: concurrency,
                    workingSet: workingSet, identities: identities, hitPercent: hitPercent, fanOut: fanOut, delay: delay)
            }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CacheTimingRunner().run(scenario: .singleFlight, requests: 3, concurrency: 3)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// Adds all histogram mass, including censored tails, for one registered identity.
    /// - Parameters:
    ///   - report: Fully joined report under test.
    ///   - id: Exact finite catalog identity.
    /// - Returns: Complete recorded population size across outcomes.
    private func count(_ report: CacheTimingReport, _ id: String) -> UInt64 {
        report.metrics.filter { $0.id == id }.reduce(0) { $0 + $1.distribution.observedCount }
    }
}
