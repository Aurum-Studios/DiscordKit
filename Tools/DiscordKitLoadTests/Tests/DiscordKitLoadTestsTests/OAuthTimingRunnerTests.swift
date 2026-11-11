// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/OAuthTimingRunnerTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation
import Testing
@testable import DiscordKitLoadTests

/// Offline token ownership populations and barrier-based concurrency checks, with no latency budgets.
@Suite("OAuth timing suite", .timeLimit(.minutes(1)))
struct OAuthTimingRunnerTests {
    /// Every selected workflow preserves complete caller and backend populations through a partial cohort.
    /// - Parameter scenario: Finite injected workflow; credentials and external I/O are never required.
    /// - Throws: Unexpected fixture setup, coordinator invariant or report serialization failures.
    @Test(arguments: OAuthTimingScenario.allCases)
    func wholePopulationsAndJoinedCleanup(scenario: OAuthTimingScenario) async throws {
        let report = try await OAuthTimingRunner().run(scenario: scenario, requests: 7, concurrency: 3, delay: .zero)
        try report.counts.validate()
        #expect(report.scenario == scenario.rawValue)
        #expect(report.counts.offered == 7 && report.counts.admitted == 7 && report.counts.completed == 7)
        let expected: BenchmarkOutcome = scenario == .conflict ? .failure : scenario == .joinedCancellation ? .cancelled : .success
        #expect(report.counts.outcomes[expected] == 7)
        #expect(report.counts.outcomes.filter { $0.key != expected }.allSatisfy { $0.value == 0 })
        #expect(count(report, scenario == .storage ? "oauth.install" : scenario == .revoke ? "oauth.revoke" : "oauth.lookup") == 7)
        #expect(report.metrics.allSatisfy { $0.distribution.droppedCount == 0 && $0.clockDomain == report.clockDomain })
        #expect(report.cleanup.completed == true && report.cleanup.remainingOwners == 0)
        #expect(report.remainingFlights == 0 && report.remainingWaiters == 0 && report.remainingMutations == 0)
        #expect(report.remainingBackendCalls == 0 && report.remainingStorageRecords == 0)
        let flights = scenario.sharesFlight ? 3 : scenario == .refresh ? 7 : 0
        #expect(report.refreshCalls == flights)
        #expect(count(report, "oauth.refresh.io") == UInt64(flights))
        #expect(count(report, "oauth.refresh.joined") == UInt64(flights))
        #expect(report.storageLoads == (scenario.sharesFlight ? 3 : 7))
        #expect(count(report, "oauth.storage.load") == UInt64(report.storageLoads))
        let exchanges = scenario == .lookup || scenario == .joinedCancellation ? 0 : scenario.sharesFlight ? 3 : 7
        #expect(report.storageCAS == exchanges)
        #expect(count(report, "oauth.storage.cas") == UInt64(exchanges))
        #expect(report.storageConflicts == (scenario == .conflict ? 3 : 0))
        #expect(report.conflicts == (scenario == .conflict ? 7 : 0))
        #expect(report.revokeCalls == (scenario == .revoke ? 7 : 0))
        #expect(count(report, "oauth.revoke.io") == UInt64(report.revokeCalls))
        #expect(report.cancelledReaders == (scenario == .joinedCancellation ? 7 : 0))
        #expect(report.coalescedReaders == (scenario.sharesFlight ? 4 : 0))
        #expect(report.maximumWaiters == (scenario.sharesFlight ? 3 : 0))
        #expect(count(report, "oauth.close") == UInt64(scenario.sharesFlight ? 3 : 7))
        let data = try JSONEncoder().encode(report)
        let restored = try JSONDecoder().decode(OAuthTimingReport.self, from: data)
        #expect(restored.scenario == report.scenario && restored.cleanup == report.cleanup)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("synthetic-original") && !json.contains("synthetic-rotated") && !json.contains("synthetic-refresh"))
    }

    /// A single-reader cohort still performs one flight; a saturated cohort deterministically retains every reader.
    /// - Throws: Unexpected offline coordinator or cleanup failures.
    @Test func singleReaderAndContendedFlights() async throws {
        for concurrency in [1, 64] {
            let report = try await OAuthTimingRunner().run(scenario: .singleFlight,
                requests: concurrency, concurrency: concurrency, delay: .zero)
            #expect(report.refreshCalls == 1 && report.storageCAS == 1)
            #expect(report.coalescedReaders == concurrency - 1)
            #expect(report.maximumWaiters == concurrency)
            #expect(report.counts.outcomes[.success] == UInt64(concurrency))
            #expect(report.cleanup.completed == true && report.cleanup.remainingOwners == 0)
        }
    }

    /// Cancellation is a whole caller population while the backend records its separately joined cancellation once.
    /// - Throws: Unexpected held-flight or cleanup invariant failure.
    @Test func joinedCancellationDoesNotReplayOrPersist() async throws {
        let report = try await OAuthTimingRunner().run(scenario: .joinedCancellation, requests: 12, concurrency: 4, delay: .zero)
        #expect(report.counts.outcomes[.cancelled] == 12)
        #expect(report.refreshCalls == 3 && report.storageLoads == 3 && report.storageCAS == 0)
        #expect(count(report, "oauth.refresh.io", outcome: .cancelled) == 3)
        #expect(count(report, "oauth.refresh.joined", outcome: .cancelled) == 3)
        #expect(count(report, "oauth.lookup", outcome: .cancelled) == 12)
        #expect(report.cleanup.completed == true && report.cleanup.remainingOwners == 0)
    }

    /// External cancellation after actual admission returns the whole started cohort and joins its refresh.
    /// - Throws: Unexpected partial-population or cancellation-join failures.
    @Test func externalCancellationReturnsJoinedPartialPopulation() async throws {
        let barrier = OAuthTimingCancellationBarrier()
        let task = Task {
            try await OAuthTimingRunner(onSharedAdmission: { await barrier.arriveAndWait() })
                .run(scenario: .singleFlight, requests: 9, concurrency: 3, delay: .zero)
        }
        await barrier.waitForArrival()
        task.cancel()
        await barrier.release()
        let report = try await task.value
        try report.counts.validate()
        #expect(report.counts.offered == 3 && report.counts.completed == 3)
        #expect(report.counts.outcomes[.cancelled] == 3)
        #expect(count(report, "oauth.lookup", outcome: .cancelled) == 3)
        #expect(report.refreshCalls == 1 && report.storageCAS == 0)
        #expect(report.cleanup.completed == true && report.cleanup.remainingOwners == 0)
    }

    /// Invalid dimensions and precancellation are rejected before any fixture authority is allocated.
    /// - Throws: Unexpected argument or task lifecycle failure.
    @Test func invalidBoundsAndPrecancelledWork() async throws {
        for (requests, concurrency, delay) in [(0, 1, Duration.zero), (1, 2, .zero),
            (100_001, 1, .zero), (257, 257, .zero), (1, 1, .seconds(-1)), (1, 1, .seconds(2))] {
            await #expect(throws: LoadFailure.invalidArguments) {
                try await OAuthTimingRunner().run(scenario: .lookup, requests: requests, concurrency: concurrency, delay: delay)
            }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await OAuthTimingRunner().run(scenario: .singleFlight, requests: 4, concurrency: 4, delay: .zero)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// Counts all observed histogram mass for a finite identity and optional terminal outcome.
    /// - Parameters:
    ///   - report: Joined report under test.
    ///   - id: Registered catalog identity.
    ///   - outcome: Optional exact outcome partition; nil includes every outcome.
    /// - Returns: Complete observed population, including any censored tail mass.
    private func count(_ report: OAuthTimingReport, _ id: String, outcome: BenchmarkOutcome? = nil) -> UInt64 {
        report.metrics.filter { $0.id == id && (outcome == nil || $0.outcome == outcome) }
            .reduce(0) { $0 + $1.distribution.observedCount }
    }
}

/// A two-sided explicit barrier proving external cancellation happens after real owner admission.
private actor OAuthTimingCancellationBarrier {
    private var arrived = false
    private var released = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?

    /// Signals owner admission and holds the runner until the test has canceled its owning task.
    func arriveAndWait() async {
        arrived = true
        arrival?.resume(); arrival = nil
        if !released { await withCheckedContinuation { continuation = $0 } }
    }

    /// Awaits the runner's actual shared-reader barrier without a scheduling or wall-time assumption.
    func waitForArrival() async {
        if !arrived { await withCheckedContinuation { arrival = $0 } }
    }

    /// Lets the canceled runner perform its normal joined cleanup and publish partial evidence.
    func release() {
        released = true
        continuation?.resume(); continuation = nil
    }
}
