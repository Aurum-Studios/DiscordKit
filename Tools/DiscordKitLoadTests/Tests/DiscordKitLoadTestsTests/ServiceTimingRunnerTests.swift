// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/ServiceTimingRunnerTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

@testable import DiscordKitLoadTests
import DiscordBenchmarkSupport
import Foundation
import Testing

/// Every implemented service composition has complete outcomes and independently empty joined ownership.
@Suite("Phase eight service timing", .timeLimit(.minutes(1)))
struct ServiceTimingRunnerTests {
    /// A partial final wave retains every result, error and child observation without timing-dependent waits.
    /// - Parameter scenario: Closed service product/script class.
    /// - Throws: Unexpected fixture failure, population mismatch or report serialization error.
    @Test(arguments: ServiceTimingScenario.allCases)
    func completePopulation(scenario: ServiceTimingScenario) async throws {
        let report = try await ServiceTimingRunner().run(scenario: scenario, requests: 5, concurrency: 2)
        try report.counts.validate()
        #expect(report.scenario == scenario.rawValue)
        #expect(report.counts.offered == 5 && report.counts.admitted == 5 && report.counts.completed == 5)
        #expect(report.cleanup.completed == true && report.cleanup.remainingOwners == 0)
        let outcome: BenchmarkOutcome
        switch scenario {
        case .socialCancelled, .commerceCancelled, .devicesCancelled: outcome = .cancelled
        case .socialRejected, .commerceRejected, .devicesRejected: outcome = .rejected
        case .gameFailure: outcome = .failure
        default: outcome = .success
        }
        #expect(report.counts.outcomes[outcome] == 5)
        #expect(report.counts.outcomes.filter { $0.key != outcome }.allSatisfy { $0.value == 0 })
        let primary = report.metrics.filter { $0.id == "service.operation" }
        #expect(primary.count == 1 && primary.first?.outcome == outcome)
        #expect(primary.first?.distribution.observedCount == 5)
        #expect(report.metrics.first { $0.id == "service.cleanup" && $0.outcome == .success }?.distribution.observedCount == 5)
        #expect(report.metrics.allSatisfy { $0.clockDomain == report.clockDomain && $0.distribution.droppedCount == 0 })

        let backendCalls: Int
        switch scenario {
        case .socialSnapshot, .gameSnapshot, .devicesRejected: backendCalls = 0
        case .gameMembers, .gameFailure: backendCalls = 2
        default: backendCalls = 1
        }
        #expect(report.backendExecutions == backendCalls * 5)
        let backend = report.metrics.filter { $0.id == "service.backend" }
        #expect(backend.reduce(UInt64(0)) { $0 + $1.distribution.observedCount } == UInt64(backendCalls * 5))
        if scenario == .gameFailure {
            #expect(backend.first { $0.outcome == .success }?.distribution.observedCount == 5)
            #expect(backend.first { $0.outcome == .failure }?.distribution.observedCount == 5)
        } else if backendCalls > 0 {
            let backendOutcome: BenchmarkOutcome = outcome == .cancelled ? .cancelled : .success
            #expect(backend.count == 1 && backend.first?.outcome == backendOutcome)
        }
        let snapshot = scenario == .socialSnapshot || scenario == .gameSnapshot
        #expect(report.snapshotApplications == (snapshot ? 5 : 0))
        #expect(report.metrics.first { $0.id == "service.validation" }?.distribution.observedCount == (snapshot ? 5 : nil))
        let validated = [ServiceTimingScenario.socialProfile, .gameMembers, .gameSnapshot, .commerceVerify, .devicesPublish].contains(scenario)
        #expect(report.validatedResults == (validated ? 5 : 0))
        #expect(report.droppedMembers == (scenario == .gameMembers || scenario == .gameFailure ? 5 : 0))
        #expect(report.observedBodies == (scenario == .devicesPublish || scenario == .devicesCancelled ? 5 : 0))
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(ServiceTimingReport.self, from: data)
        #expect(decoded.counts == report.counts && decoded.metrics == report.metrics && decoded.cleanup == report.cleanup)
        #expect(data.count < 1_048_576)
    }

    /// Parent cancellation before admission has no invented offered population or resource ownership.
    /// - Throws: Unexpected runner or counts validation errors.
    @Test func preCancelledDriver() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ServiceTimingRunner().run(scenario: .devicesPublish, requests: 8, concurrency: 2)
        }
        let report = try await task.value
        try report.counts.validate()
        #expect(report.counts.offered == 0 && report.counts.admitted == 0 && report.counts.completed == 0)
        #expect(report.metrics.isEmpty && report.backendExecutions == 0 && report.observedBodies == 0)
        #expect(report.cleanup.completed == true && report.cleanup.remainingOwners == 0)
    }

    /// Resource and delay bounds fail before constructing or admitting any product fixture.
    @Test func rejectsInvalidLimits() async {
        await #expect(throws: LoadFailure.invalidArguments) {
            try await ServiceTimingRunner().run(scenario: .commerceVerify, requests: 0)
        }
        await #expect(throws: LoadFailure.invalidArguments) {
            try await ServiceTimingRunner().run(scenario: .commerceVerify, requests: 100_001)
        }
        await #expect(throws: LoadFailure.invalidArguments) {
            try await ServiceTimingRunner().run(scenario: .commerceVerify, requests: 4, concurrency: 0)
        }
        await #expect(throws: LoadFailure.invalidArguments) {
            try await ServiceTimingRunner().run(scenario: .commerceVerify, requests: 4, concurrency: 5)
        }
        await #expect(throws: LoadFailure.invalidArguments) {
            try await ServiceTimingRunner().run(scenario: .commerceVerify, requests: 65, concurrency: 65)
        }
        await #expect(throws: LoadFailure.invalidArguments) {
            try await ServiceTimingRunner().run(scenario: .commerceVerify, delay: .nanoseconds(-1))
        }
        await #expect(throws: LoadFailure.invalidArguments) {
            try await ServiceTimingRunner().run(scenario: .commerceVerify, delay: .seconds(2))
        }
    }
}
