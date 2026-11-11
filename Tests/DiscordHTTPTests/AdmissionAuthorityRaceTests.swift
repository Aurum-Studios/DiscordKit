// File: Tests/DiscordHTTPTests/AdmissionAuthorityRaceTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordTestSupport
import DiscordTransport
import Foundation
import Testing
@testable import DiscordHTTP

/// Reentrant authority boundaries preserve local ownership and clean up late grants.
@Suite(.timeLimit(.minutes(1))) struct AdmissionAuthorityRaceTests {
    /// Even a backend ignoring cancellation cannot leak a grant after admission ends.
    /// - Parameter termination: The condition occurring while reserve is suspended.
    /// - Throws: Unexpected fixture or cleanup failures.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: AdmissionAuthorityTermination.allCases)
    func lateGrantIsReleasedWithoutSending(_ termination: AdmissionAuthorityTermination) async throws {
        let clock = ManualClock()
        let gate = AdmissionAuthorityGate()
        let store = AdmissionRaceStore(reserveRoute: "GET /slow", reserveGate: gate,
                                       failingReserveRoute: "GET /unavailable")
        let coordinator = RateLimitCoordinator(clock: clock, store: store)
        let request = RateLimitRequest(identity: .init(), route: "GET /slow", queuedBytes: 3)
        let pending = Task { try await coordinator.acquire(request, deadline: clock.now.advanced(by: .milliseconds(5))) }
        defer { pending.cancel(); gate.open() }
        try await gate.entered.wait()
        switch termination {
        case .cancellation: pending.cancel()
        case .close: await coordinator.close()
        case .deadline: try clock.advance(by: .milliseconds(5))
        case .unavailable:
            await #expect(throws: RateLimitFailure.coordinatorUnavailable) {
                _ = try await coordinator.acquire(.init(identity: .init(), route: "GET /unavailable"))
            }
        }
        gate.open()
        switch termination {
        case .cancellation:
            await #expect(throws: CancellationError.self) { _ = try await pending.value }
        case .close:
            await #expect(throws: RateLimitFailure.closed) { _ = try await pending.value }
        case .deadline:
            await #expect(throws: RateLimitFailure.deadlineExceeded) { _ = try await pending.value }
        case .unavailable:
            await #expect(throws: RateLimitFailure.coordinatorUnavailable) { _ = try await pending.value }
        }
        #expect(await store.notSentReleases == 1)
        #expect(await store.snapshot().activeCount == 0)
        #expect(await coordinator.snapshot().queuedCount == 0)
        #expect(await coordinator.snapshot().queuedBytes == 0)
        #expect(clock.pendingSleepCount == 0)
        await coordinator.close()
    }

    /// Clearing a suspended local admission immediately makes unrelated capacity useful.
    /// - Parameter refusal: A retry retains its authority deadline; a validation error removes its head.
    /// - Throws: Unexpected fixture, admission or cleanup failures.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [AdmissionAuthorityRefusal.retry, .invalidRequest])
    func clearedAdmissionWakesIndependentPartition(_ refusal: AdmissionAuthorityRefusal) async throws {
        let sleeping = TestBarrier()
        let clock = ManualClock(onSleepScheduled: { sleeping.open() })
        let gate = AdmissionAuthorityGate()
        let store = AdmissionRaceStore(reserveRoute: "GET /slow", reserveGate: gate, refusal: refusal)
        let coordinator = RateLimitCoordinator(clock: clock, store: store,
                                              policy: .init(maximumConcurrentRequests: 1))
        let slow = Task { try await coordinator.acquire(.init(identity: .init(), route: "GET /slow")) }
        defer { slow.cancel(); gate.open() }
        try await gate.entered.wait()
        let independent = Task { try await coordinator.acquire(.init(identity: .init(), route: "GET /independent")) }
        defer { independent.cancel() }
        try await sleeping.wait()
        #expect(await coordinator.snapshot().queuedCount == 2)
        gate.open()
        if refusal == .invalidRequest {
            await #expect(throws: RateLimitFailure.invalidRequest) { _ = try await slow.value }
        }
        let token = try await independent.value
        #expect(clock.now == ManualClock.Instant())
        #expect(await store.attempts(for: "GET /slow") == 1)
        try await coordinator.release(token, outcome: .notSent)
        if refusal == .retry {
            #expect(await coordinator.snapshot().queuedCount == 1)
            slow.cancel()
            await #expect(throws: CancellationError.self) { _ = try await slow.value }
        }
        #expect(await coordinator.snapshot().queuedCount == 0)
        #expect(await coordinator.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
        await coordinator.close()
    }

    /// A local partition remains held until shared completion or release has finished.
    /// - Parameter complete: Whether ownership ends through response learning or a failed-send release.
    /// - Throws: Unexpected fixture, admission or cleanup failures.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true])
    func finalizationRetainsPartitionUntilAuthorityReturns(_ complete: Bool) async throws {
        let sleeping = TestBarrier()
        let clock = ManualClock(onSleepScheduled: { sleeping.open() })
        let gate = AdmissionAuthorityGate()
        let store = AdmissionRaceStore(finalizationGate: gate)
        let coordinator = RateLimitCoordinator(clock: clock, store: store)
        let request = RateLimitRequest(identity: .init(), route: "POST /partition")
        let first = try await coordinator.acquire(request)
        let finalization = Task {
            if complete { try await coordinator.complete(first, status: 204, headers: []) }
            else { try await coordinator.release(first, outcome: .uncertain) }
        }
        defer { finalization.cancel(); gate.open() }
        try await gate.entered.wait()
        let next = Task { try await coordinator.acquire(request) }
        defer { next.cancel() }
        try await sleeping.wait()
        #expect(await store.attempts(for: request.route) == 1)
        #expect(await coordinator.snapshot().queuedCount == 1)
        #expect(await coordinator.snapshot().activeCount == 1)
        gate.open()
        try await finalization.value
        let successor = try await next.value
        #expect(clock.now == ManualClock.Instant())
        #expect(await store.attempts(for: request.route) == 2)
        try await coordinator.release(successor, outcome: .notSent)
        #expect(await coordinator.snapshot().queuedCount == 0)
        #expect(await coordinator.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
        await coordinator.close()
    }

    /// Authority failure wakes either local queue immediately and permanently blocks new admission.
    /// - Parameter ordering: Whether the parked follower is a whole-operation or rate waiter.
    /// - Throws: Unexpected fixture, admission or cleanup failures.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true])
    func authorityFailureWakesParkedWaiter(_ ordering: Bool) async throws {
        let sleeping = TestBarrier()
        let clock = ManualClock(onSleepScheduled: { sleeping.open() })
        let store = AdmissionRaceStore(failCompletion: true)
        let coordinator = RateLimitCoordinator(clock: clock, store: store)
        let request = RateLimitRequest(identity: .init(), route: "POST /owned")
        let token = try await coordinator.acquire(request)
        let entered = TestBarrier()
        let operationGate = TestBarrier()
        let owner: Task<Int, any Error>?
        let pending: Task<Void, any Error>
        if ordering {
            owner = Task {
                try await coordinator.withOrdering(request: request) {
                    entered.open()
                    try await operationGate.wait()
                    return 1
                }
            }
            try await entered.wait()
            pending = Task { _ = try await coordinator.withOrdering(request: request) { 2 } }
        } else {
            owner = nil
            pending = Task { _ = try await coordinator.acquire(request) }
        }
        defer { pending.cancel(); owner?.cancel(); operationGate.open() }
        try await sleeping.wait()
        await #expect(throws: RateLimitFailure.coordinatorUnavailable) {
            try await coordinator.complete(token, status: 204, headers: [])
        }
        await #expect(throws: RateLimitFailure.coordinatorUnavailable) { try await pending.value }
        operationGate.open()
        if let owner { #expect(try await owner.value == 1) }
        await #expect(throws: RateLimitFailure.coordinatorUnavailable) {
            _ = try await coordinator.acquire(.init(identity: .init(), route: "GET /later"))
        }
        #expect(clock.now == ManualClock.Instant())
        #expect(await coordinator.snapshot().queuedCount == 0)
        #expect(await coordinator.snapshot().activeCount == 0)
        #expect(await coordinator.snapshot().orderedOperationsCount == 0)
        #expect(clock.pendingSleepCount == 0)
        await coordinator.close()
    }
}

/// Independent termination conditions applied while an authority call ignores cancellation.
enum AdmissionAuthorityTermination: CaseIterable, Sendable {
    case cancellation, close, deadline, unavailable
}

/// Recoverable results that free an in-progress local admission slot.
enum AdmissionAuthorityRefusal: Sendable {
    case retry, invalidRequest
}

/// Deliberately cancellation-insensitive backend gate for testing cleanup of late grants.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private final class AdmissionAuthorityGate: @unchecked Sendable {
    let entered = TestBarrier()
    private let lock = NSLock()
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?

    /// Suspends one authority operation until the test opens the gate, even if canceled.
    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if opened { return true }
                precondition(self.continuation == nil)
                self.continuation = continuation
                return false
            }
            if resume { continuation.resume() }
            entered.open()
        }
    }

    /// Releases the pending authority callback and makes subsequent calls immediate.
    func open() {
        let continuation = lock.withLock {
            opened = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

/// Minimal external authority whose boundaries are controlled independently of its caller.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private actor AdmissionRaceStore: RateLimitStore {
    typealias Instant = ManualClock.Instant
    private let reserveRoute: String?
    private let reserveGate: AdmissionAuthorityGate?
    private let refusal: AdmissionAuthorityRefusal?
    private let failingReserveRoute: String?
    private let finalizationGate: AdmissionAuthorityGate?
    private let failCompletion: Bool
    private var delayed = false
    private var reserved: [UUID: RateLimitReservation<Instant>] = [:]
    private var reserveAttempts: [String: Int] = [:]
    private(set) var notSentReleases = 0

    /// Configures the first delayed reserve and optional completion/release boundary.
    /// - Parameters:
    ///   - reserveRoute: Route whose first reserve waits at the supplied gate.
    ///   - reserveGate: Explicit gate that ignores caller cancellation.
    ///   - refusal: Optional retry or safe validation error after that gate opens.
    ///   - failingReserveRoute: Route that reports permanent authority unavailability.
    ///   - finalizationGate: Optional gate shared by completion and release callbacks.
    ///   - failCompletion: Whether a completed token reports authority unavailability.
    init(reserveRoute: String? = nil, reserveGate: AdmissionAuthorityGate? = nil,
         refusal: AdmissionAuthorityRefusal? = nil, failingReserveRoute: String? = nil,
         finalizationGate: AdmissionAuthorityGate? = nil, failCompletion: Bool = false) {
        self.reserveRoute = reserveRoute
        self.reserveGate = reserveGate
        self.refusal = refusal
        self.failingReserveRoute = failingReserveRoute
        self.finalizationGate = finalizationGate
        self.failCompletion = failCompletion
    }

    /// Returns a controlled first result and otherwise grants a unique bounded-lifetime token.
    /// - Parameters:
    ///   - request: Scope retained unchanged in the token.
    ///   - now: Supplied virtual authority time.
    /// - Returns: A grant or the scripted one-second retry boundary.
    /// - Throws: The scripted closed authority or validation failure.
    func reserve(_ request: RateLimitRequest, now: Instant) async throws -> RateLimitAdmission<Instant> {
        reserveAttempts[request.route, default: 0] += 1
        if request.route == failingReserveRoute { throw RateLimitFailure.coordinatorUnavailable }
        if request.route == reserveRoute, !delayed, let reserveGate {
            delayed = true
            await reserveGate.wait()
            switch refusal {
            case .retry: return .retry(at: now.advanced(by: .seconds(1)))
            case .invalidRequest: throw RateLimitFailure.invalidRequest
            case nil: break
            }
        }
        let token = RateLimitReservation(id: UUID(), request: request, expiresAt: now.advanced(by: .seconds(60)))
        reserved[token.id] = token
        return .admitted(token)
    }

    /// Waits at the backend boundary before consuming ownership and optionally failing closed.
    /// - Parameters:
    ///   - reservation: Token to consume once.
    ///   - status: Unused fixture response status.
    ///   - headers: Unused fixture metadata.
    ///   - retryAfter: Unused fixture retry body.
    ///   - global: Unused fixture global body.
    ///   - now: Unused fixture observation time.
    /// - Throws: Unknown ownership or configured permanent authority failure.
    func complete(_ reservation: RateLimitReservation<Instant>, status: Int, headers: [HTTPHeader],
                  retryAfter: Duration?, global: Bool, now: Instant) async throws {
        if let finalizationGate { await finalizationGate.wait() }
        guard reserved.removeValue(forKey: reservation.id) != nil else { throw RateLimitFailure.unknownReservation }
        if failCompletion { throw RateLimitFailure.coordinatorUnavailable }
    }

    /// Consumes ownership exactly once and records no-send cleanup without refund behavior.
    /// - Parameters:
    ///   - reservation: Token to consume once.
    ///   - outcome: Explicit no-send or uncertain outcome.
    ///   - now: Unused fixture release time.
    /// - Throws: Unknown ownership.
    func release(_ reservation: RateLimitReservation<Instant>, outcome: RateLimitReleaseOutcome, now: Instant) async throws {
        if let finalizationGate { await finalizationGate.wait() }
        guard reserved.removeValue(forKey: reservation.id) != nil else { throw RateLimitFailure.unknownReservation }
        if outcome == .notSent { notSentReleases += 1 }
    }

    /// Returns how many times a route reached the external reserve boundary.
    /// - Parameter route: The fixed test route to count.
    /// - Returns: Exact callback count for that route.
    func attempts(for route: String) -> Int { reserveAttempts[route, default: 0] }

    /// Reports owned tokens without adding independent queue or metadata state.
    /// - Returns: Exact active reservation count for cleanup assertions.
    func snapshot() -> SchedulingSnapshot {
        .init(queuedCount: 0, queuedBytes: 0, activeCount: reserved.count, metadataCount: 0)
    }
}
