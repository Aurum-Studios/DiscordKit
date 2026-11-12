// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/SyntheticCommandTimingRunnerTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation
import Testing
@testable import DiscordKitLoadTests

/// Real typed invocation parity and complete outcome evidence without numerical performance gates.
@Suite("Synthetic command timing", .timeLimit(.minutes(1)))
struct SyntheticCommandTimingRunnerTests {
    /// Both authoring paths execute identical response and failure semantics with a partial final cohort.
    /// - Parameter scenario: One finite immediate/deferred/provider-failure/cancellation case.
    /// - Throws: Setup, route/schema, sink parity or count validation failures.
    @Test(arguments: SyntheticCommandTimingScenario.allCases)
    func completeEquivalentPopulations(scenario: SyntheticCommandTimingScenario) async throws {
        let value = try await SyntheticCommandTimingRunner().run(scenario: scenario,
            requests: 7, concurrency: 3, delay: .zero)
        try value.counts.validate()
        #expect(value.counts.offered == 7 && value.counts.admitted == 7)
        #expect(value.counts.completed == 7)
        #expect(value.counts.outcomes[scenario.expectedOutcome] == 7)
        #expect(value.cleanup.remainingOwners == 0)
        #expect(value.cleanup.handlers == 0 && value.cleanup.acknowledgements == 0)
        #expect(value.cleanup.acknowledgementBytes == 0)
        #expect(value.metrics.filter { $0.id == "synthetic.invoke" }.reduce(0) { $0 + $1.distribution.observedCount } == 7)
        #expect(value.metrics.filter { $0.id == "synthetic.providerWait" }.reduce(0) { $0 + $1.distribution.observedCount } == 7)
        #expect(value.metrics.filter { $0.id == "command.arguments" }.reduce(0) { $0 + $1.distribution.observedCount } == 7)
        #expect(!value.metrics.contains { $0.id.hasPrefix("ingress.") || $0.id.hasPrefix("gateway.") })
        #expect(value.metrics.allSatisfy { $0.distribution.droppedCount == 0 && !$0.distribution.counterOverflow })
        #expect(value.callbacks == (scenario.expectedOutcome == .success ? 7 : 0))
        #expect(value.edits == (scenario.isDeferred ? 7 : 0))
    }

    /// Cancels after a deferred callback actually confirms, preserving its evidence without workflow success.
    /// - Parameter scenario: Equivalent handwritten or lowered deferred route.
    /// - Throws: Unexpected setup, sink parity or cancellation-cleanup failure.
    @Test(arguments: [SyntheticCommandTimingScenario.directDeferred, .dslDeferred])
    func deferredParentCancellationRetainsConfirmation(scenario: SyntheticCommandTimingScenario) async throws {
        let initial = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            defer { initial.continuation.finish() }
            return try await SyntheticCommandTimingRunner().run(scenario: scenario,
                requests: 100, concurrency: 1, delay: .seconds(1),
                onInitialResponse: { _ = initial.continuation.yield(()) })
        }
        var iterator = initial.stream.makeAsyncIterator()
        let confirmed: Void? = await iterator.next()
        task.cancel()
        let value = try await task.value
        try #require(confirmed != nil)
        try value.counts.validate()
        #expect(value.callbacks == 1)
        #expect(value.edits == 0)
        #expect(value.counts.outcomes[.success, default: 0] == 0)
        #expect(value.counts.outcomes[.cancelled, default: 0] + value.counts.outcomes[.uncertain, default: 0] == 1)
        #expect(value.counts.completed == 1)
        #expect(value.counts.offered == 1 && value.counts.admitted == 1)
        #expect(value.cleanup.remainingOwners == 0)
        #expect(value.cleanup.handlers == 0 && value.cleanup.acknowledgements == 0)
        #expect(value.cleanup.acknowledgementBytes == 0)
    }

    /// A cancelled caller starts no cohort, handler, callback or replacement work on either route path.
    /// - Parameter scenario: Every success, deferred, failure and cancellation family.
    /// - Throws: Unexpected setup or empty-population validation failure.
    @Test(arguments: SyntheticCommandTimingScenario.allCases)
    func preCancelledDriverStartsNoWork(scenario: SyntheticCommandTimingScenario) async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SyntheticCommandTimingRunner().run(scenario: scenario,
                requests: 7, concurrency: 3, delay: .zero)
        }
        let value = try await task.value
        try value.counts.validate()
        #expect(value.counts.offered == 0 && value.counts.admitted == 0 && value.counts.completed == 0)
        #expect(value.callbacks == 0 && value.edits == 0 && value.metrics.isEmpty)
        #expect(value.cleanup.handlers == 0 && value.cleanup.acknowledgements == 0)
        #expect(value.cleanup.acknowledgementBytes == 0)
    }

    /// Invalid cardinalities and delays fail before constructing runtime authorities.
    @Test func rejectsInvalidBounds() async {
        for (requests, concurrency, delay) in [(0, 1, Duration.zero), (1, 2, .zero), (1, 1, .seconds(-1))] {
            await #expect(throws: LoadFailure.invalidArguments) {
                try await SyntheticCommandTimingRunner().run(scenario: .directImmediate,
                    requests: requests, concurrency: concurrency, delay: delay)
            }
        }
    }
}
