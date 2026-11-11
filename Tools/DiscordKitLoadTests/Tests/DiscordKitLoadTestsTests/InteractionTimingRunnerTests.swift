// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/InteractionTimingRunnerTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Testing
@testable import DiscordKitLoadTests

/// Bounded offline scenarios retain every terminal result and exact body/admission cleanup.
@Suite(.timeLimit(.minutes(1))) struct InteractionTimingRunnerTests {
    /// Checks every declared outcome, population, admission receipt and resource close.
    @Test(arguments: InteractionTimingScenario.allCases) func allOutcomes(scenario: InteractionTimingScenario) async throws {
        let report = try await InteractionTimingRunner().run(scenario: scenario, requests: 3, concurrency: 2,
            delay: .milliseconds(2))
        #expect(report.counts.offered == 3 && report.counts.completed == 3)
        let expectedAdmissions: UInt64 = [.duplicate, .invalidSignature, .malformed, .cancelled, .deadlineRace, .durableDuplicate].contains(scenario) ? 0 : 3
        #expect(report.counts.admitted == expectedAdmissions)
        #expect(report.cleanup.isEmpty)
        #expect(report.cleanup.remainingOwners == 0)
        #expect(report.durationNanoseconds > 0)
        let outcome: BenchmarkOutcome
        switch scenario {
        case .duplicate, .invalidSignature, .admissionRefusal: outcome = .rejected
        case .malformed, .callbackError, .handlerFailureAfterAcknowledgement, .durableFailure: outcome = .failure
        case .deadlineRace: outcome = .timedOut
        case .uncertain: outcome = .uncertain
        case .cancelled: outcome = .cancelled
        default: outcome = .success
        }
        #expect(report.counts.outcomes[outcome] == 3)
        let workflow = report.metrics.filter { $0.id == "interaction.workflow" }
        #expect(workflow.reduce(UInt64(0)) { $0 + $1.distribution.observedCount } == 3)
        for outcome in BenchmarkOutcome.allCases {
            #expect(workflow.filter { $0.outcome == outcome }.reduce(UInt64(0)) { $0 + $1.distribution.observedCount }
                == report.counts.outcomes[outcome])
        }
        #expect(!report.metrics.contains { $0.id == "ingress.trustedResponse" })
        let signature = report.metrics.filter { $0.id == "ingress.signature" }
        if scenario != .cancelled && scenario != .deadlineRace {
            #expect(signature.reduce(UInt64(0)) { $0 + $1.distribution.observedCount } == 3)
            #expect(report.metrics.contains { $0.id == "ingress.bodyRead" })
        }
        if scenario == .manualDefer || scenario == .automaticDefer {
            #expect(report.metrics.filter { $0.id == "interaction.originalEdit" }.reduce(UInt64(0)) { $0 + $1.distribution.observedCount } == 3)
            #expect(report.metrics.filter { $0.id == "interaction.initialResponse" }.reduce(UInt64(0)) { $0 + $1.distribution.observedCount } == 3)
        }
        if scenario == .durableDuplicate {
            #expect(report.durableTransactions == 0 && report.setupDurableTransactions == 1)
            #expect(!report.metrics.contains { $0.id == "ingress.admission" })
        } else if scenario.isDurable {
            #expect(report.durableTransactions == 3 && report.setupDurableTransactions == 0)
            let admission = report.metrics.filter { $0.id == "ingress.admission" }
            #expect(admission.reduce(UInt64(0)) { $0 + $1.distribution.observedCount } == 3)
            #expect(admission.allSatisfy { $0.outcome == (scenario == .durableFailure ? .failure : .success) })
        } else { #expect(report.durableTransactions == 0 && report.setupDurableTransactions == 0) }
        if scenario == .handlerFailureAfterAcknowledgement {
            #expect(report.metrics.first { $0.id == "ingress.applicationResponse" && $0.outcome == .success }?.distribution.observedCount == 3)
            #expect(report.metrics.first { $0.id == "interaction.workflow" && $0.outcome == .failure }?.distribution.observedCount == 3)
        }
        if scenario == .deadlineRace { #expect(report.counts.deadlineMisses == 3) }
        if scenario == .invalidSignature {
            #expect(!report.metrics.contains { $0.id == "ingress.decode" || $0.id == "ingress.admission" })
        }
        if scenario == .duplicate {
            #expect(report.metrics.filter { $0.id == "ingress.admission" }.reduce(UInt64(0)) { $0 + $1.distribution.observedCount } == 3)
        }
    }

    /// Forces the automatic acknowledgement before edit even when the injected provider returns immediately.
    @Test func automaticDeferAtZeroProviderDelay() async throws {
        let report = try await InteractionTimingRunner().run(scenario: .automaticDefer, requests: 1, concurrency: 1, delay: .zero)
        #expect(report.counts.outcomes[.success] == 1)
        #expect(report.metrics.first { $0.id == "interaction.originalEdit" }?.distribution.observedCount == 1)
        #expect(report.cleanup.isEmpty)
    }

    /// Rejects invalid cohort limits before creating measured request work.
    @Test func limitsRejectBeforeWork() async {
        await #expect(throws: LoadFailure.self) {
            try await InteractionTimingRunner().run(scenario: .immediate, requests: 0, concurrency: 1)
        }
        await #expect(throws: LoadFailure.self) {
            try await InteractionTimingRunner().run(scenario: .immediate, requests: 1, concurrency: 2)
        }
    }
}
