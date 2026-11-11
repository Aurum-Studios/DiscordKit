// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/RESTTimingRunnerTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordHTTP
import Foundation
import Testing
@testable import DiscordKitLoadTests

/// Functional accounting for finite offline REST timing cases; no throughput thresholds are asserted.
@Suite("REST timing suite", .timeLimit(.minutes(1)))
struct RESTTimingRunnerTests {
    /// Every case records every terminal caller, keeps all owners bounded and serializes complete evidence.
    /// - Parameter scenario: Closed offline fixture identity.
    /// - Throws: Fixture setup, JSON serialization or unexpectedly malformed count evidence.
    @Test(arguments: RESTTimingScenario.allCases)
    func completePopulationsAndCleanup(scenario: RESTTimingScenario) async throws {
        let report = try await RESTTimingRunner().run(scenario: scenario, requests: 6, concurrency: 3, delay: .zero)
        try report.counts.validate()
        #expect(report.counts.offered == 6 && report.counts.completed == 6)
        #expect(report.cleanup.isEmpty)
        #expect(report.peakActive <= 3)
        #expect(count(report, "rest.request") == 6)
        #expect(count(report, "rest.executionJoined") == 6)
        #expect(report.metrics.allSatisfy { $0.distribution.droppedCount == 0 })
        #expect(Set(report.metrics.map(\.clockDomain)).count == 1)
        #expect(try JSONEncoder().encode(report).count > 0)
        switch scenario {
        case .cacheFresh:
            #expect(report.wireExchanges == 0 && report.setupWireExchanges == 1)
            #expect(count(report, "rest.cacheLookup") == 6)
            #expect(count(report, "rest.admission") == 0)
            #expect(count(report, "rest.decode") == 6)
        case .cacheExpiry:
            #expect(report.wireExchanges == 6 && report.setupWireExchanges == 6)
            #expect(count(report, "rest.cacheLookup") == 6)
            // The second wave's intentional four-millisecond expiry wait remains in throughput.
            #expect(report.durationNanoseconds >= 4_000_000)
        case .cacheMiss:
            #expect(report.wireExchanges == 6 && report.setupWireExchanges == 0)
            #expect(count(report, "rest.cacheLookup") == 6)
        case .coalesced:
            #expect(report.wireExchanges == 2)
            #expect(report.subscribers == 6)
            #expect(count(report, "rest.admission") == 2)
            #expect(count(report, "rest.headers") == 2)
            #expect(count(report, "rest.body") == 2)
            #expect(count(report, "rest.decode") == 8)
        case .rateLimitRetry, .serverRetry, .retryExhausted:
            #expect(report.wireExchanges == 12)
            #expect(count(report, "rest.construct") == 12)
            #expect(count(report, "rest.retryWait") == (scenario == .rateLimitRetry ? 0 : 6))
        case .malformed:
            #expect(report.counts.outcomes[.failure] == 6)
            #expect(report.wireExchanges == 6)
            #expect(count(report, "rest.decode", outcome: .failure) == 6)
        case .cancelled:
            #expect(report.counts.outcomes[.cancelled] == 6)
            #expect(count(report, "rest.body", outcome: .cancelled) == 6)
        case .uncertainMutation:
            #expect(report.counts.outcomes[.uncertain] == 6)
            #expect(report.wireExchanges == 6)
            #expect(count(report, "rest.headers", outcome: .uncertain) == 6)
            #expect(count(report, "rest.orderWait") == 6)
        case .orderedMutation, .orderedMutationDefaultV1:
            #expect(count(report, "rest.orderWait") == 6)
            #expect(report.wireExchanges == 6)
        default:
            #expect(report.wireExchanges == 6)
            #expect(count(report, "rest.cacheLookup") == 0)
            #expect(count(report, "rest.decode") == 12)
        }
        if scenario != .malformed && scenario != .cancelled && scenario != .uncertainMutation && scenario != .retryExhausted {
            #expect(report.counts.outcomes[.success] == 6)
        }
        if scenario == .retryExhausted { #expect(report.counts.outcomes[.failure] == 6) }
    }

    /// A partial final cohort still owns one exchange and exactly its actual number of subscribers.
    /// - Throws: Unexpected fixture setup or execution failure.
    @Test func partialCoalescedCohort() async throws {
        let report = try await RESTTimingRunner().run(scenario: .coalesced, requests: 7, concurrency: 3, delay: .zero)
        #expect(report.wireExchanges == 3 && report.subscribers == 7)
        #expect(report.counts.outcomes[.success] == 7)
        #expect(report.cleanup.isEmpty)
    }

    /// Invalid driver dimensions fail before any work; reusable arrival owners execute real REST and join.
    /// - Throws: Unexpected fixture execution or bounds behavior.
    @Test func boundsAndArrivalFixture() async throws {
        for (requests, concurrency, delay) in [(0, 1, Duration.zero), (1, 2, .zero), (100_001, 1, .zero),
                                               (1, 1, .seconds(-1)), (1, 1, .seconds(2))] {
            await #expect(throws: LoadFailure.invalidArguments) {
                try await RESTTimingRunner().run(scenario: .noCache, requests: requests, concurrency: concurrency, delay: delay)
            }
        }
        let fixture = try RESTArrivalFixture(concurrency: 2, delay: .zero)
        await withTaskGroup(of: BenchmarkOutcome.self) { group in
            for ordinal in 0..<4 { group.addTask { await fixture.execute(ordinal: ordinal) } }
            for await result in group { #expect(result == .success) }
        }
        #expect(await fixture.shutdown().isEmpty)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await RESTTimingRunner().run(scenario: .cacheExpiry, requests: 10, concurrency: 2)
        }
        let partial = try await task.value
        #expect(partial.counts.offered == 0 && partial.counts.completed == 0)
        #expect(partial.cleanup.isEmpty)
    }

    /// The new workload constructs the complete production scheduler and retains legacy tuning separately.
    @Test func defaultSchedulingHasDistinctReceipt() async throws {
        let defaults = SchedulingPolicy()
        let tuned = try RESTArrivalFixture(concurrency: 4, delay: .zero)
        let shared = try RESTArrivalFixture(concurrency: 4, delay: .zero, orderedDefault: true,
            observeAdmission: true)
        let legacy = await tuned.schedulingReceipt()
        let production = await shared.schedulingReceipt()
        #expect(legacy.profile == "legacy-tuned-v1")
        #expect(legacy.fairnessIntervalNanoseconds == 100_000)
        #expect(legacy.provisionalWindowNanoseconds == 1_000)
        #expect(legacy.initialGlobalRequestsPerSecond == 1_000_000)
        #expect(production == RESTSchedulingReceipt(policy: defaults, usesDefaults: true))
        #expect(production.profile == "SchedulingPolicy-default-v1")
        #expect(production.fairnessIntervalNanoseconds == 10_000_000)
        #expect(production.provisionalWindowNanoseconds == 1_000_000_000)
        #expect(production.initialGlobalRequestsPerSecond == 50)
        let before = DispatchTime.now().uptimeNanoseconds
        let result = await shared.executeMeasured(ordinal: 0)
        let after = DispatchTime.now().uptimeNanoseconds
        #expect(result.outcome == .success)
        let admitted = try #require(result.admittedNanoseconds)
        #expect(admitted >= before && admitted <= after)
        let unobserved = await tuned.executeMeasured(ordinal: 0)
        #expect(unobserved.admittedNanoseconds == nil)
        #expect(await tuned.shutdown().isEmpty)
        #expect(await shared.shutdown().isEmpty)
    }

    /// Adds observed histogram mass for a finite identity and optional outcome without reading percentiles.
    /// - Parameters:
    ///   - report: Joined complete report.
    ///   - id: Registered identity under test.
    ///   - outcome: Optional one-outcome partition.
    /// - Returns: Total observed population, including censored observations.
    private func count(_ report: RESTTimingReport, _ id: String, outcome: BenchmarkOutcome? = nil) -> UInt64 {
        report.metrics.filter { $0.id == id && (outcome == nil || $0.outcome == outcome) }
            .reduce(0) { $0 + $1.distribution.observedCount }
    }
}
