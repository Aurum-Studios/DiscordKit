// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/VoiceLifecycleTimingTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation
import Testing
@testable import DiscordKitLoadTests

/// Offline control lifetimes, actual readiness and independently joined ownership evidence.
@Suite("Voice lifecycle timing", .timeLimit(.minutes(1)))
struct VoiceLifecycleTimingTests {
    /// A partial final cohort preserves every caller and both fresh generations of a move.
    @Test(arguments: VoiceLifecycleTimingCase.allCases)
    func completePopulationsAndCleanup(_ scenario: VoiceLifecycleTimingCase) async throws {
        let report = try await VoiceLifecycleTimingRunner().run(scenario: scenario, requests: 5, concurrency: 2)
        try report.counts.validate()
        let outcome: BenchmarkOutcome = scenario == .termination ? .failure : .success
        #expect(report.counts.offered == 5 && report.counts.admitted == 5 && report.counts.completed == 5)
        #expect(report.counts.outcomes[outcome] == 5)
        #expect(report.counts.outcomes.filter { $0.key != outcome }.allSatisfy { $0.value == 0 })
        #expect(samples(report, "voice.lifecycleJoined", outcome) == 5)
        let sessions = scenario == .move ? 10 : 5
        #expect(report.installedSessions == sessions)
        #expect(report.discoveryRequests == sessions)
        #expect(samples(report, "voice.join") == UInt64(sessions))
        #expect(samples(report, "voice.credentials") == UInt64(sessions))
        #expect(samples(report, "voice.handshake") == UInt64(sessions))
        #expect(samples(report, "voice.secureReady") == UInt64(sessions))
        #expect(samples(report, "voice.shutdown") == 5)
        #expect(samples(report, "voice.heartbeat") == (scenario == .heartbeat || scenario == .lifecycleJoined ? 5 : 0))
        #expect(samples(report, "voice.reconnect") == (scenario == .reconnect || scenario == .lifecycleJoined ? 5 : 0))
        #expect(samples(report, "voice.speaking") == (scenario == .speaking || scenario == .lifecycleJoined ? 5 : 0))
        #expect(samples(report, "voice.termination", .failure) == (scenario == .termination ? 5 : 0))
        #expect(report.reconnects == (scenario == .reconnect || scenario == .lifecycleJoined ? 5 : 0))
        #expect(report.connectionAttempts == sessions + report.reconnects)
        #expect(report.terminalFailures == (scenario == .termination ? 5 : 0))
        #expect(report.cleanup.completed == true && report.cleanup.remainingOwners == 0)
        #expect(report.ownership.remainingOwners == 0)
        #expect(report.metrics.allSatisfy { $0.clockDomain == report.clockDomain && $0.distribution.droppedCount == 0 })
        if scenario == .heartbeat || scenario == .lifecycleJoined { #expect(report.heartbeatACKs >= 5) }
        let data = try JSONEncoder().encode(report)
        let restored = try JSONDecoder().decode(VoiceLifecycleTimingMeasurement.self, from: data)
        #expect(restored.ownership == report.ownership && restored.scenario == report.scenario)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("synthetic-token") && !json.contains("synthetic-session") && !json.contains("voice.invalid"))
    }

    /// Time admission closes after the first cohort, retaining the exact joined partial population.
    @Test func boundedAdmissionAndSingleCaller() async throws {
        let partial = try await VoiceLifecycleTimingRunner().run(scenario: .lifecycleJoined,
            requests: 100, concurrency: 2, maximumDuration: .nanoseconds(1))
        #expect(partial.counts.offered == 2 && partial.counts.completed == 2)
        #expect(partial.cleanup.completed == true && partial.ownership.remainingOwners == 0)
        let single = try await VoiceLifecycleTimingRunner().run(scenario: .move, requests: 1, concurrency: 1)
        #expect(single.installedSessions == 2 && single.counts.completed == 1)
        #expect(single.maximumHarnessTasks == 1 && single.ownership.remainingOwners == 0)
    }

    /// Cancellation after actual readiness preserves the admitted cohort and joins every runtime child.
    @Test func cancellationAfterReadinessJoinsAllOwners() async throws {
        let gate = VoiceLifecycleTestGate()
        let task = Task {
            try await VoiceLifecycleTimingRunner(onReady: { await gate.arrive() })
                .run(scenario: .lifecycleJoined, requests: 20, concurrency: 2)
        }
        await gate.waitForBoth()
        task.cancel()
        await gate.release()
        let report = try await task.value
        try report.counts.validate()
        #expect(report.counts.offered == 2 && report.counts.completed == 2)
        #expect(report.counts.outcomes[.cancelled] == 2)
        #expect(samples(report, "voice.lifecycleJoined", .cancelled) == 2)
        #expect(report.cleanup.completed == true && report.ownership.remainingOwners == 0)
    }

    /// Invalid bounds and precancellation cannot create a manager or transport owner.
    @Test func invalidDimensionsAndPrecancelledWork() async throws {
        for (requests, concurrency) in [(0, 1), (100_001, 1), (1, 2), (257, 257)] {
            await #expect(throws: LoadFailure.invalidArguments) {
                try await VoiceLifecycleTimingRunner().run(scenario: .join, requests: requests, concurrency: concurrency)
            }
        }
        for duration in [Duration.zero, .seconds(-1), .seconds(3_601)] {
            await #expect(throws: LoadFailure.invalidArguments) {
                try await VoiceLifecycleTimingRunner().run(scenario: .join, maximumDuration: duration)
            }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await VoiceLifecycleTimingRunner().run(scenario: .join)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// Counts the complete observed population for one finite metric and terminal outcome.
    private func samples(_ report: VoiceLifecycleTimingMeasurement, _ id: String,
                         _ outcome: BenchmarkOutcome = .success) -> UInt64 {
        report.metrics.filter { $0.id == id && $0.outcome == outcome }.reduce(0) { $0 + $1.distribution.observedCount }
    }
}

/// Two finite ready callbacks deliberately park until the test has cancelled their parent.
private actor VoiceLifecycleTestGate {
    private var arrivals = 0
    private var entered: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Records actual secure readiness and parks this callback until explicit test release.
    func arrive() async {
        arrivals += 1
        if arrivals == 2 { entered?.resume(); entered = nil }
        await withCheckedContinuation { waiters.append($0) }
    }
    /// Waits for both initial cohort members before cancelling their parent task.
    func waitForBoth() async {
        if arrivals == 2 { return }
        await withCheckedContinuation { entered = $0 }
    }
    /// Releases the finite ready cohort after cancellation so joined cleanup can finish.
    func release() { let pending = waiters; waiters.removeAll(); for waiter in pending { waiter.resume() } }
}
