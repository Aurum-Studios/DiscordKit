// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/GatewayTimingRunnerTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

@testable import DiscordKitLoadTests
import DiscordBenchmarkSupport
import Foundation
import Testing

/// Finite real-owner protocol populations and independently read post-shutdown ownership receipts.
@Suite("Gateway timing runner", .timeLimit(.minutes(1)))
struct GatewayTimingRunnerTests {
    /// Every registered script drives production parsing and leaves no socket, lease, queue or handler owner.
    @Test(arguments: GatewayTimingScenario.allCases) func finiteProtocolPopulation(scenario: GatewayTimingScenario) async throws {
        let report = try await GatewayTimingRunner().run(scenario: scenario, requests: 8,
            concurrency: 2, delay: .microseconds(100), rate: 100_000)
        try report.counts.validate()
        #expect(report.counts.offered == 8 && report.counts.completed == 8)
        #expect(report.cleanup.remainingOwners == 0)
        let trusted = scenario == .trustedInteraction || scenario == .trustedDeferred || scenario == .trustedUncertain
        if trusted {
            #expect(report.initialResponseSends == 8)
            #expect(report.continuationSends == (scenario == .trustedDeferred ? 8 : 0))
            #expect(report.metrics.first { $0.id == "gateway.receiveToAdmission" }?.distribution.observedCount == 8)
            if scenario == .trustedUncertain {
                #expect(report.metrics.first { $0.id == "gateway.initialResponse" && $0.outcome == .uncertain }?.distribution.observedCount == 8)
                #expect(!report.metrics.contains { $0.id == "gateway.receiveToAcknowledgement" && $0.outcome == .success })
            } else {
                #expect(report.metrics.first { $0.id == "gateway.receiveToAcknowledgement" && $0.outcome == .success }?.distribution.observedCount == 8)
                #expect(report.metrics.first { $0.id == "gateway.admissionToAcknowledgement" && $0.outcome == .success }?.distribution.observedCount == 8)
            }
            if scenario == .trustedDeferred {
                #expect(report.metrics.first { $0.id == "gateway.originalEdit" && $0.outcome == .success }?.distribution.observedCount == 8)
            }
        } else {
            #expect(report.metrics.contains { $0.id == "gateway.decode" })
            #expect(report.metrics.contains { $0.id == "gateway.socketReceipt" })
            #expect(report.metrics.contains { $0.id == "gateway.ingestionQueue" })
            #expect(report.metrics.contains { $0.id == "gateway.shutdown" })
        }
        #expect(report.metrics.allSatisfy { $0.clockDomain == report.clockDomain })
        switch scenario {
        case .burst, .slowSubscriber, .slowHandler, .reconnect, .trustedInteraction, .trustedDeferred:
            #expect(report.counts.outcomes[.success] == 8)
        case .trustedUncertain:
            #expect(report.counts.outcomes[.uncertain] == 8)
        case .callbackError:
            #expect(report.counts.outcomes[.failure, default: 0] > 0)
        case .cancelled:
            #expect(report.counts.outcomes[.cancelled, default: 0] > 0)
        case .overloadRecovery:
            #expect(report.recoverySucceeded)
            #expect(report.controlWhileHandlerBlocked)
        }
        if scenario == .reconnect { #expect(report.reconnects == 1) }
        if scenario == .slowSubscriber { #expect(report.slowSubscriberDrops == 7) }
        #expect(report.duplicateFrames == 1)
        let bytes = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(GatewayTimingReport.self, from: bytes)
        #expect(decoded.counts == report.counts)
        #expect(decoded.metrics == report.metrics)
        #expect(bytes.count < 4_194_304)
    }

    /// A cancelled driver joins callbacks sleeping for sixty seconds and drops every retained copy.
    @Test func externalCancellationJoinsOwnedTasks() async throws {
        let task = Task { try await GatewayTimingRunner().run(scenario: .slowHandler,
            requests: 100_000, concurrency: 2, delay: .seconds(1), rate: 1_000) }
        try await ContinuousClock().sleep(for: .milliseconds(10))
        task.cancel()
        let report = try await task.value
        #expect(report.cleanup.remainingOwners == 0)
        #expect(report.counts.offered < 100_000)
        #expect(report.counts.completed == report.counts.offered)
        try report.counts.validate()
    }

    /// Invalid dimensions fail before creating a socket or reserving an ownership lease.
    @Test func rejectsUnboundedDimensions() async {
        await #expect(throws: LoadFailure.invalidArguments) {
            try await GatewayTimingRunner().run(scenario: .burst, requests: 0)
        }
        await #expect(throws: LoadFailure.invalidArguments) {
            try await GatewayTimingRunner().run(scenario: .burst, requests: 4, concurrency: 5)
        }
        await #expect(throws: LoadFailure.invalidArguments) {
            try await GatewayTimingRunner().run(scenario: .slowHandler, rate: 0)
        }
    }
}
