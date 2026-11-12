// File: Tests/DiscordHTTPTests/AdmissionNotificationTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordTestSupport
import DiscordTransport
import Foundation
import Synchronization
import Testing
@testable import DiscordHTTP

/// Deterministic acceptance of notification handoff, bounded timers and FIFO fairness.
@Suite struct AdmissionNotificationTests {
    /// Waits for actor-observed registration without moving virtual or wall-clock time.
    /// - Parameters:
    ///   - coordinator: Queue owner under test.
    ///   - count: Exact expected count after a newly submitted caller parks.
    /// - Throws: A bounded fixture failure if the expected queue state never appears.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    private func queued<C: Clock>(_ coordinator: RateLimitCoordinator<C>, count: Int) async throws where C.Duration == Duration {
        for _ in 0..<10_000 {
            if await coordinator.snapshot().queuedCount == count { return }
            await Task.yield()
        }
        Issue.record("Admission queue did not reach the expected registration count")
        throw TestSupportFailure.scripted("queue registration did not settle")
    }

    /// Waits for a rearmed shared timer to register before advancing virtual time.
    /// - Parameters:
    ///   - calls: Synchronized clock registration count.
    ///   - count: Minimum expected registrations.
    /// - Throws: A bounded fixture failure if the timer never rearms.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    private func sleeps(_ calls: borrowing Mutex<Int>, count: Int) async throws {
        for _ in 0..<10_000 {
            if calls.withLock({ $0 }) >= count { return }
            await Task.yield()
        }
        Issue.record("Shared admission timer did not register")
        throw TestSupportFailure.scripted("timer registration did not settle")
    }

    /// Releases a held default-policy owner at several points in the old poll cycle.
    /// Every already queued successor completes in exact FIFO order at the same
    /// virtual instant, and one queue-deadline sleeper covers the entire cohort.
    /// - Parameters:
    ///   - callers: Number of queued successors, covering ordinary and stressed cohorts.
    ///   - releaseOffset: Owner release point inside the former ten-millisecond cycle.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [1, 4, 16, 64], [Duration.zero, .milliseconds(1), .milliseconds(9)])
    func orderingHandoffHasNoPollingDelay(_ callers: Int, _ releaseOffset: Duration) async throws {
        let scheduled = TestBarrier(), entered = TestBarrier(), release = TestBarrier()
        let calls = Mutex(0)
        let clock = ManualClock(onSleepScheduled: { calls.withLock { $0 += 1 }; scheduled.open() })
        let coordinator = RateLimitCoordinator(clock: clock)
        let request = RateLimitRequest(identity: .init(), route: "POST /notification/order", queuedBytes: 3)
        let order = AdmissionNotificationOrder()
        let owner = Task {
            try await coordinator.withOrdering(request: request) {
                entered.open()
                try await release.wait()
            }
        }
        defer { release.open(); owner.cancel() }
        try await entered.wait()
        var successors: [Task<Void, any Error>] = []
        defer { successors.forEach { $0.cancel() } }
        for index in 0..<callers {
            successors.append(Task {
                try await coordinator.withOrdering(request: request) { await order.append(index) }
            })
            try await queued(coordinator, count: index + 1)
        }
        try await scheduled.wait()
        #expect(clock.pendingSleepCount == 1)
        #expect(calls.withLock { $0 } == 1)
        try clock.advance(by: releaseOffset)
        release.open()
        try await owner.value
        for successor in successors { try await successor.value }
        #expect(await order.values == Array(0..<callers))
        #expect(clock.now.offset == releaseOffset)
        #expect(calls.withLock { $0 } == 1)
        await coordinator.close()
        #expect(clock.pendingSleepCount == 0)
        let snapshot = await coordinator.snapshot()
        #expect(snapshot.queuedCount == 0 && snapshot.queuedBytes == 0 && snapshot.orderedOperationsCount == 0)
    }

    /// Shows local rate concurrency hands off directly after authoritative release.
    /// A learned allowance supplies sufficient real quota; notification never refunds
    /// it. The same-partition cohort preserves exact FIFO using the default policy.
    /// - Parameter callers: Finite queued population exercising timer sharing.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [1, 4, 16, 64])
    func rateHandoffHasNoPollingDelay(_ callers: Int) async throws {
        let scheduled = TestBarrier(), calls = Mutex(0)
        let clock = ManualClock(onSleepScheduled: { calls.withLock { $0 += 1 }; scheduled.open() })
        let coordinator = RateLimitCoordinator(clock: clock)
        let request = RateLimitRequest(identity: .init(), route: "POST /notification/rate", usesGlobalLimit: false)
        let learned = try await coordinator.acquire(request)
        try await coordinator.complete(learned, status: 200, headers: [
            .init(name: "X-RateLimit-Limit", value: "128"),
            .init(name: "X-RateLimit-Remaining", value: "127"),
            .init(name: "X-RateLimit-Reset-After", value: "30")
        ])
        let owner = try await coordinator.acquire(request)
        let order = AdmissionNotificationOrder()
        var successors: [Task<Void, any Error>] = []
        defer { successors.forEach { $0.cancel() } }
        for index in 0..<callers {
            successors.append(Task {
                let token = try await coordinator.acquire(request)
                await order.append(index)
                try await coordinator.release(token, outcome: .notSent)
            })
            try await queued(coordinator, count: index + 1)
        }
        try await scheduled.wait()
        #expect(clock.pendingSleepCount == 1)
        try await coordinator.release(owner, outcome: .uncertain)
        for successor in successors { try await successor.value }
        #expect(await order.values == Array(0..<callers))
        #expect(clock.now.offset == .zero)
        #expect(calls.withLock { $0 } == 1)
        await coordinator.close()
        #expect(clock.pendingSleepCount == 0)
        let snapshot = await coordinator.snapshot()
        #expect(snapshot.queuedCount == 0 && snapshot.queuedBytes == 0 && snapshot.activeCount == 0)
    }

    /// A blocked hot identity cannot starve an independent identity; equal-weight
    /// control and ordinary partitions of that identity retain oldest-first access.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func independentIdentityAndSchedulingClassesStayFair() async throws {
        let entered = TestBarrier(), release = TestBarrier()
        let clock = ManualClock()
        let coordinator = RateLimitCoordinator(clock: clock,
            policy: .init(maximumConcurrentRequests: 2, maximumConcurrentRequestsPerIdentity: 1))
        let hot = RateLimitIdentity(), order = AdmissionNotificationOrder()
        let owner = Task {
            try await coordinator.withOrdering(request: .init(identity: hot, route: "POST /hot")) {
                entered.open()
                try await release.wait()
            }
        }
        defer { release.open(); owner.cancel() }
        try await entered.wait()
        let ordinary = Task {
            try await coordinator.withOrdering(request: .init(identity: hot, route: "POST /hot")) {
                await order.append(1)
            }
        }
        defer { ordinary.cancel() }
        try await queued(coordinator, count: 1)
        let control = Task {
            try await coordinator.withOrdering(request: .init(identity: hot, route: "POST /control", schedulingClass: .control)) {
                await order.append(2)
            }
        }
        defer { control.cancel() }
        try await queued(coordinator, count: 2)
        try await coordinator.withOrdering(request: .init(identity: .init(), route: "POST /hot")) {
            await order.append(0)
        }
        #expect(await order.values == [0])
        release.open()
        try await owner.value
        try await ordinary.value
        try await control.value
        #expect(await order.values == [0, 1, 2])
        #expect(clock.now.offset == .zero)
        await coordinator.close()
        #expect(clock.pendingSleepCount == 0)
    }

    /// Local ownership remains asleep across many old polling intervals and only
    /// the inclusive deadline rejects the waiter; no intermediate timer is created.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func idleOrderingUsesOnlyItsQueueDeadline() async throws {
        let entered = TestBarrier(), release = TestBarrier(), scheduled = TestBarrier()
        let calls = Mutex(0)
        let clock = ManualClock(onSleepScheduled: { calls.withLock { $0 += 1 }; scheduled.open() })
        let coordinator = RateLimitCoordinator(clock: clock)
        let request = RateLimitRequest(identity: .init(), route: "POST /idle")
        let owner = Task {
            try await coordinator.withOrdering(request: request) { entered.open(); try await release.wait() }
        }
        defer { release.open(); owner.cancel() }
        try await entered.wait()
        let pending = Task { try await coordinator.withOrdering(request: request) { 1 } }
        defer { pending.cancel() }
        try await scheduled.wait()
        try clock.advance(by: .seconds(29))
        #expect(await coordinator.snapshot().queuedCount == 1)
        #expect(calls.withLock { $0 } == 1)
        #expect(clock.pendingSleepCount == 1)
        try clock.advance(by: .seconds(1))
        await #expect(throws: RateLimitFailure.deadlineExceeded) { _ = try await pending.value }
        release.open()
        try await owner.value
        await coordinator.close()
        #expect(clock.pendingSleepCount == 0)
        #expect(await coordinator.snapshot().queuedCount == 0)
    }

    /// Rate and ordering queues share one nearest-deadline timer. An earlier rate
    /// deadline replaces the joined sleep, then cancellation cleans ordering bytes
    /// exactly once without an obsolete timer callback reviving the registration.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func mixedQueuesRearmOneTimerAndCancelExactlyOnce() async throws {
        let entered = TestBarrier(), release = TestBarrier(), scheduled = TestBarrier()
        let calls = Mutex(0)
        let clock = ManualClock(onSleepScheduled: { calls.withLock { $0 += 1 }; scheduled.open() })
        let coordinator = RateLimitCoordinator(clock: clock)
        let request = RateLimitRequest(identity: .init(), route: "POST /mixed", queuedBytes: 7)
        let token = try await coordinator.acquire(request)
        let owner = Task {
            try await coordinator.withOrdering(request: request) { entered.open(); try await release.wait() }
        }
        defer { release.open(); owner.cancel() }
        try await entered.wait()
        let ordering = Task {
            try await coordinator.withOrdering(request: request, deadline: .init(offset: .milliseconds(10))) { 1 }
        }
        defer { ordering.cancel() }
        try await scheduled.wait()
        let rate = Task { try await coordinator.acquire(request, deadline: .init(offset: .milliseconds(5))) }
        defer { rate.cancel() }
        try await queued(coordinator, count: 2)
        try await sleeps(calls, count: 2)
        #expect(clock.pendingSleepCount == 1)
        try clock.advance(by: .milliseconds(5))
        await #expect(throws: RateLimitFailure.deadlineExceeded) { _ = try await rate.value }
        ordering.cancel()
        await #expect(throws: CancellationError.self) { _ = try await ordering.value }
        release.open()
        try await owner.value
        try await coordinator.release(token, outcome: .notSent)
        await coordinator.close()
        #expect(clock.pendingSleepCount == 0)
        let snapshot = await coordinator.snapshot()
        #expect(snapshot.queuedCount == 0 && snapshot.queuedBytes == 0 && snapshot.activeCount == 0)
        try clock.advance(by: .seconds(1))
        #expect(await coordinator.snapshot().queuedCount == 0)
    }

    /// Local completion notifications cannot bypass a fractional authority reset.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func unrelatedReleasePreservesAuthorityRetryDeadline() async throws {
        let scheduled = TestBarrier()
        let clock = ManualClock(onSleepScheduled: { scheduled.open() })
        let coordinator = RateLimitCoordinator(clock: clock)
        let request = RateLimitRequest(identity: .init(), route: "GET /limited")
        let owner = try await coordinator.acquire(request)
        try await coordinator.complete(owner, status: 429, headers: [], retryAfter: .milliseconds(125))
        let pending = Task { try await coordinator.acquire(request) }
        defer { pending.cancel() }
        try await scheduled.wait()
        let unrelated = try await coordinator.acquire(.init(identity: .init(), route: "GET /unrelated"))
        try await coordinator.release(unrelated, outcome: .notSent)
        try clock.advance(by: .milliseconds(124))
        let blocked = await coordinator.snapshot()
        #expect(blocked.queuedCount == 1 && blocked.activeCount == 0)
        try clock.advance(by: .milliseconds(1))
        let next = try await pending.value
        #expect(clock.now.offset == .milliseconds(125))
        try await coordinator.release(next, outcome: .notSent)
        await coordinator.close()
        #expect(clock.pendingSleepCount == 0)
    }

    /// A timer task may first run after the authority's retry instant has elapsed.
    /// It must recheck admission immediately instead of parking until the queue deadline.
    /// - Throws: Unexpected authority, clock or cancellation cleanup failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(.timeLimit(.minutes(1))) func elapsedRetryBeforeTimerStartupWakesImmediately() async throws {
        let clock = AdmissionTimerStartupClock()
        let store = AdmissionTimerStartupStore(clock: clock)
        let coordinator = RateLimitCoordinator(clock: clock, store: store)
        let request = RateLimitRequest(identity: .init(), route: "GET /late-timer", usesGlobalLimit: false)
        let owner = try await coordinator.acquire(request)
        try await coordinator.complete(owner, status: 429, headers: [], retryAfter: .milliseconds(125))
        let pending = Task { try await coordinator.acquire(request) }
        defer { pending.cancel() }
        try await clock.sleepEntered.wait()
        let firstDeadline = try #require(clock.sleepDeadlines.first)
        #expect(firstDeadline.offset == .milliseconds(125))
        if firstDeadline.offset != .milliseconds(125) {
            // Keep the regression finite even when the broken timer chooses thirty seconds.
            pending.cancel()
            await #expect(throws: CancellationError.self) { _ = try await pending.value }
        } else {
            let token = try await pending.value
            #expect(await store.attempts == 3)
            try await coordinator.release(token, outcome: .notSent)
        }
        await coordinator.close()
        #expect(clock.now.offset == .milliseconds(125))
        #expect(clock.pendingSleepCount == 0)
        let snapshot = await coordinator.snapshot()
        #expect(snapshot.queuedCount == 0 && snapshot.activeCount == 0)
    }

    /// A completion in another coordinator still requires and receives a finite
    /// authority retry wake; process-local notifications cannot represent that event.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func sharedAuthorityChangesUseFallbackTimer() async throws {
        let scheduled = TestBarrier()
        let clock = ManualClock(onSleepScheduled: { scheduled.open() })
        let policy = SchedulingPolicy(maximumConcurrentRequests: 1)
        let store = InProcessRateLimitStore<ManualClock.Instant>(policy: policy)
        let remote = RateLimitCoordinator(clock: clock, store: store, policy: policy)
        let local = RateLimitCoordinator(clock: clock, store: store, policy: policy)
        let owner = try await remote.acquire(.init(identity: .init(), route: "GET /remote"))
        let pending = Task { try await local.acquire(.init(identity: .init(), route: "GET /local")) }
        defer { pending.cancel() }
        try await scheduled.wait()
        try await remote.release(owner, outcome: .notSent)
        #expect(await local.snapshot().queuedCount == 1)
        try clock.advance(by: .milliseconds(9))
        #expect(await local.snapshot().activeCount == 0)
        try clock.advance(by: .milliseconds(1))
        let token = try await pending.value
        try await local.release(token, outcome: .notSent)
        await local.close()
        await remote.close()
        #expect(clock.pendingSleepCount == 0)
        #expect(await store.snapshot().activeCount == 0)
    }
    /// A shared timer fault removes admission's ability to enforce future deadlines.
    /// All parked queues fail closed together while previously held owners can
    /// still release their ordering lease and authoritative reservation normally.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func clockFailureRejectsEveryParkedQueueAndPreservesCleanup() async throws {
        let clock = AdmissionFailingClock()
        let coordinator = RateLimitCoordinator(clock: clock)
        let entered = TestBarrier(), release = TestBarrier()
        let request = RateLimitRequest(identity: .init(), route: "POST /clock-failure", queuedBytes: 5)
        let token = try await coordinator.acquire(request)
        let owner = Task {
            try await coordinator.withOrdering(request: request) { entered.open(); try await release.wait() }
        }
        defer { release.open(); owner.cancel() }
        try await entered.wait()
        let firstOrdering = Task { try await coordinator.withOrdering(request: request) { 1 } }
        defer { firstOrdering.cancel() }
        try await queued(coordinator, count: 1)
        let firstRate = Task { try await coordinator.acquire(request) }
        defer { firstRate.cancel() }
        try await queued(coordinator, count: 2)
        let secondOrdering = Task { try await coordinator.withOrdering(request: request) { 2 } }
        defer { secondOrdering.cancel() }
        try await queued(coordinator, count: 3)
        let secondRate = Task { try await coordinator.acquire(request) }
        defer { secondRate.cancel() }
        try await queued(coordinator, count: 4)
        try await clock.sleepEntered.wait()
        #expect(clock.pendingSleepCount == 1)
        clock.failSleep()
        await #expect(throws: RateLimitFailure.coordinatorUnavailable) { _ = try await firstOrdering.value }
        await #expect(throws: RateLimitFailure.coordinatorUnavailable) { _ = try await firstRate.value }
        await #expect(throws: RateLimitFailure.coordinatorUnavailable) { _ = try await secondOrdering.value }
        await #expect(throws: RateLimitFailure.coordinatorUnavailable) { _ = try await secondRate.value }
        await #expect(throws: RateLimitFailure.coordinatorUnavailable) { _ = try await coordinator.acquire(request) }
        await #expect(throws: RateLimitFailure.coordinatorUnavailable) {
            _ = try await coordinator.withOrdering(request: request) { 3 }
        }
        let rejected = await coordinator.snapshot()
        #expect(rejected.queuedCount == 0 && rejected.queuedBytes == 0)
        #expect(rejected.activeCount == 1 && rejected.orderedOperationsCount == 1)
        #expect(clock.pendingSleepCount == 0)
        try await coordinator.release(token, outcome: .notSent)
        release.open()
        try await owner.value
        await coordinator.close()
        let drained = await coordinator.snapshot()
        #expect(drained.queuedCount == 0 && drained.queuedBytes == 0)
        #expect(drained.activeCount == 0 && drained.orderedOperationsCount == 0)
        #expect(clock.pendingSleepCount == 0)
        #expect(clock.failureWaiterCount == 0 && release.waitingCount == 0)
    }

}

/// Records operation entry order using the same actor isolation as production callers.
private actor AdmissionNotificationOrder {
    private(set) var values: [Int] = []

    /// Appends one observed entry after admission, before ownership is released.
    /// - Parameter value: Fixture-local submission index.
    func append(_ value: Int) { values.append(value) }
}

/// Injects one controlled, non-cancellation clock error after the shared timer parks.
/// Instants stay fixed at zero: this fixture tests timer failure rather than expiry.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private final class AdmissionFailingClock: Clock, Sendable {
    typealias Instant = ManualClock.Instant
    let sleepEntered = TestBarrier()
    private let failure = TestBarrier()
    private let pending = Mutex(0)

    /// Returns the fixture's fixed monotonic origin without advancing time.
    var now: Instant { Instant() }

    /// Reports nanosecond resolution to satisfy the clock contract.
    var minimumResolution: Duration { .nanoseconds(1) }

    /// Counts clock-sleep calls still awaiting injected failure or cancellation.
    var pendingSleepCount: Int { pending.withLock { $0 } }

    /// Exposes fixture gate ownership for exact teardown assertions.
    var failureWaiterCount: Int { failure.waitingCount }

    /// Suspends until explicitly failed, supporting prompt ordinary cancellation.
    /// - Parameters:
    ///   - deadline: Accepted clock-local target; no normal expiry is simulated.
    ///   - tolerance: Accepted for Clock conformance; no early success is returned.
    /// - Throws: Cancellation or the injected fixture error after failSleep().
    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        try Task.checkCancellation()
        pending.withLock { $0 += 1 }
        defer { pending.withLock { $0 -= 1 } }
        sleepEntered.open()
        try await failure.wait()
        throw TestSupportFailure.scripted("injected clock failure")
    }

    /// Makes the parked timer throw without advancing the clock or signaling admission.
    func failSleep() { failure.open() }
}

/// Advances only when the new timer task first observes time after an authority retry.
/// The acquiring task retains the old instant, reproducing a delayed task start without wall-clock sleeps or polling.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private final class AdmissionTimerStartupClock: Clock, Sendable {
    typealias Instant = ManualClock.Instant
    private struct State {
        var acquiringTask: Int?
        var retry: Instant?
        var advanced = false
        var deadlines: [Instant] = []
    }
    private let state = Mutex(State())
    private let clock = ManualClock()
    let sleepEntered = TestBarrier()

    /// Samples transient task identity without retaining an unsafe task handle.
    private var currentTask: Int? { withUnsafeCurrentTask { $0?.hashValue } }
    /// Gives the delayed timer its already elapsed retry instant on first observation.
    var now: Instant {
        state.withLock { state in
            if let owner = state.acquiringTask, owner != currentTask, !state.advanced, let retry = state.retry {
                state.advanced = true
                try? clock.advance(by: clock.now.duration(to: retry))
            }
            return clock.now
        }
    }
    /// Preserves the backing manual clock's resolution and sleeper ownership.
    var minimumResolution: Duration { clock.minimumResolution }
    /// Copies requested timer targets, including targets that are already due.
    var sleepDeadlines: [Instant] { state.withLock { $0.deadlines } }
    /// Reports retained manual-clock registrations after cleanup joins.
    var pendingSleepCount: Int { clock.pendingSleepCount }

    /// Arms one task boundary after the real authority refuses admission.
    /// - Parameter retry: Actual retry instant returned by the in-process authority.
    func arm(at retry: Instant) {
        state.withLock { state in
            guard state.acquiringTask == nil else { return }
            state.acquiringTask = currentTask
            state.retry = retry
        }
    }

    /// Records the driver's selected target before honoring ordinary clock semantics.
    /// - Parameters:
    ///   - deadline: Selected retry or queue-expiry target.
    ///   - tolerance: Optional clock tolerance passed through unchanged.
    /// - Throws: Cancellation or the backing clock's bounded registration failure.
    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        state.withLock { $0.deadlines.append(deadline) }
        sleepEntered.open()
        try await clock.sleep(until: deadline, tolerance: tolerance)
    }
}

/// Forwards the real authority contract and arms only its first deferred reservation.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private actor AdmissionTimerStartupStore: RateLimitStore {
    typealias Instant = ManualClock.Instant
    private let store = InProcessRateLimitStore<Instant>()
    private let clock: AdmissionTimerStartupClock
    private(set) var attempts = 0

    /// Shares the regression clock without altering production rate policy.
    /// - Parameter clock: Task-boundary clock used by the coordinator.
    init(clock: AdmissionTimerStartupClock) { self.clock = clock }
    /// Preserves each real admission result and exposes the first retry's task boundary.
    func reserve(_ request: RateLimitRequest, now: Instant) async throws -> RateLimitAdmission<Instant> {
        attempts += 1
        let result = try await store.reserve(request, now: now)
        if case .retry(let retry) = result { clock.arm(at: retry) }
        return result
    }
    /// Forwards response learning with unchanged scopes, metadata and observation time.
    func complete(_ reservation: RateLimitReservation<Instant>, status: Int, headers: [HTTPHeader],
                  retryAfter: Duration?, global: Bool, now: Instant) async throws {
        try await store.complete(reservation, status: status, headers: headers,
                                 retryAfter: retryAfter, global: global, now: now)
    }
    /// Forwards terminal ownership cleanup without refunding rate quota.
    func release(_ reservation: RateLimitReservation<Instant>, outcome: RateLimitReleaseOutcome, now: Instant) async throws {
        try await store.release(reservation, outcome: outcome, now: now)
    }
    /// Forwards aggregate ownership evidence for final cleanup assertions.
    func snapshot() async -> SchedulingSnapshot { await store.snapshot() }
}
