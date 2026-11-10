// File: Tests/DiscordHTTPTests/RESTIntervalTimingTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordCore
import DiscordLogging
import DiscordTestSupport
import DiscordTransport
import Foundation
import Testing
@testable import DiscordHTTP

/// Finite thread-safe fixture retaining only numeric interval events and clock-read counts.
private final class RESTIntervalObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DiscordIntervalEvent] = []
    private var clockReads = 0
    private var scalars: [OperationTimingSample] = []

    /// Retains one event synchronously without invoking any protocol owner.
    /// - Parameter event: Content-free detailed lifecycle event.
    func record(_ event: DiscordIntervalEvent) { lock.withLock { events.append(event) } }
    /// Retains one legacy scalar observation without constructing a detailed lifecycle from it.
    /// - Parameter sample: Existing fixed phase, outcome and elapsed duration.
    func recordScalar(_ sample: OperationTimingSample) { lock.withLock { scalars.append(sample) } }
    /// Counts an explicit instrumentation read independently from the protocol clock.
    func read() { lock.withLock { clockReads += 1 } }
    /// Copies the fixture's bounded observations under one lock acquisition.
    /// - Returns: Lifecycle events, instrumentation-clock reads and independently recorded scalar samples.
    func snapshot() -> (events: [DiscordIntervalEvent], reads: Int, scalars: [OperationTimingSample]) {
        lock.withLock { (events, clockReads, scalars) }
    }
}

/// Cancellation-independent close gate proving terminal events follow actual body ownership.
private actor RESTIntervalCleanup {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    /// Waits for explicit release even when the owning request has been cancelled.
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    /// Releases the single close owner, including release-before-wait races.
    func release() { released = true; continuation?.resume(); continuation = nil }
}

/// Offline lifecycle tests separate logical callers, physical attempts and coalesced subscribers.
@Suite("REST detailed intervals", .timeLimit(.minutes(1)))
struct RESTIntervalTimingTests {
    /// Deterministic body-close time is retained and a nil hook performs no reads or callbacks.
    /// - Parameter enabled: Explicit detailed observer opt-in.
    /// - Throws: Unexpected fixture construction, clock or execution failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true]) func exactStagesAndDisabledClock(enabled: Bool) async throws {
        let clock = ManualClock(), observations = RESTIntervalObservations()
        let origin = clock.now
        let intervals = DiscordIntervalTiming(clockDomain: 29, sink: observations.record, now: {
            observations.read(); return origin.duration(to: clock.now)
        })
        #expect(observations.snapshot().reads == 0)
        let resources = ResourceCounter(), bodyLease = await resources.acquire()
        let body = try BodyStream(maximumChunkBytes: 1, next: {
            try clock.advance(by: .milliseconds(30)); return nil
        }, close: {
            try? clock.advance(by: .milliseconds(40)); await bodyLease.release()
        })
        let transport = try ScriptedHTTPTransport(steps: [{ _ in
            try clock.advance(by: .milliseconds(20))
            return HTTPResponse(status: 204, body: body)
        }])
        let coordinator = RateLimitCoordinator(clock: clock)
        let client = RESTClient(credential: .none, identity: RateLimitIdentity(), transport: transport,
            coordinator: coordinator, clock: clock, intervals: enabled ? intervals : nil)
        let endpoint = try Endpoint(method: "GET", path: ["intervals"], authentication: .none,
            successStatuses: [204], retrySafety: .safe, decode: { $0 })
        #expect(try await client.execute(endpoint).isEmpty)
        let snapshot = observations.snapshot()
        if enabled {
            let ends = snapshot.events.filter { $0.kind == .ended }
            #expect(ends.map(\.stage) == [.admission, .headers, .body, .operation, .operation])
            #expect(ends.map(\.elapsedNanoseconds) == [0, 20_000_000, 70_000_000, 90_000_000, 90_000_000])
            #expect(ends.allSatisfy { $0.outcome == .succeeded && $0.validity == .valid })
            let logical = try #require(ends.last)
            let exchange = try #require(ends.first { $0.operation == .httpExchange && $0.stage == .operation })
            #expect(logical.operation == .rest && logical.context.parentID == nil)
            #expect(exchange.context.parentID == logical.context.operationID)
            #expect(exchange.context.attempt == 1)
            #expect(ends.prefix(3).allSatisfy { $0.context.parentID == exchange.context.operationID && $0.context.attempt == 1 })
            #expect(snapshot.events.filter { $0.kind == .began }.count == ends.count)
            #expect(Set(ends.map { $0.context.operationID }).count == ends.count)
            #expect(snapshot.reads > 0)
        } else {
            #expect(snapshot.events.isEmpty && snapshot.reads == 0)
        }
        #expect(await coordinator.snapshot().activeCount == 0)
        let resourceSnapshot = await resources.snapshot()
        #expect(resourceSnapshot.live == 0 && resourceSnapshot.acquired == 1 && resourceSnapshot.released == 1)
        #expect(clock.pendingSleepCount == 0)
        await coordinator.close()
    }

    /// Owner timestamps exclude their own sinks and retain preceding scalar and nested observer cost.
    /// - Throws: Unexpected fixture construction, virtual-clock advance or request failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func scalarAndDetailedCallbacksKeepTheirActualBoundaries() async throws {
        let clock = ManualClock(), observations = RESTIntervalObservations()
        let origin = clock.now
        let timing = OperationTiming(sink: { sample in
            observations.recordScalar(sample)
            try? clock.advance(by: .nanoseconds(5))
        }, now: { origin.duration(to: clock.now) })
        let intervals = DiscordIntervalTiming(clockDomain: 35, sink: { event in
            observations.record(event)
            try? clock.advance(by: .nanoseconds(event.kind == .began ? 3 : 7))
        }, now: { origin.duration(to: clock.now) })
        let transport = try ScriptedHTTPTransport(steps: [{ _ in
            try clock.advance(by: .nanoseconds(11))
            return HTTPResponse(status: 204)
        }])
        let coordinator = RateLimitCoordinator(clock: clock)
        let client = RESTClient(credential: .none, identity: RateLimitIdentity(), transport: transport,
            coordinator: coordinator, clock: clock, timing: timing, intervals: intervals)
        let endpoint = try Endpoint(method: "GET", path: ["callbacks"], authentication: .none,
            successStatuses: [204], retrySafety: .safe, decode: { $0 })
        #expect(try await client.execute(endpoint).isEmpty)
        let snapshot = observations.snapshot()
        #expect(snapshot.scalars.map(\.phase) == [.httpAdmission, .httpHeaders, .httpBody, .httpExecutionJoined])
        #expect(snapshot.scalars.map(\.elapsed) == [.nanoseconds(3), .nanoseconds(14), .nanoseconds(3), .nanoseconds(69)])
        let ends = snapshot.events.filter { $0.kind == .ended }
        #expect(ends.map(\.stage) == [.admission, .headers, .body, .operation, .operation])
        #expect(ends.map(\.elapsedNanoseconds) == [8, 19, 8, 59, 74])
        #expect(ends.map(\.timestampNanoseconds) == [14, 40, 55, 62, 74])
        #expect(origin.duration(to: clock.now) == .nanoseconds(81))
        #expect(await coordinator.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
        await coordinator.close()
    }

    /// Two transport attempts share one logical caller while retaining distinct numeric interval owners.
    /// - Throws: Unexpected fixture construction, clock or request failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func retryAttemptsRemainChildrenOfOneLogicalOperation() async throws {
        let clock = ManualClock(), observations = RESTIntervalObservations()
        let origin = clock.now
        let intervals = DiscordIntervalTiming(clockDomain: 30, sink: observations.record,
            now: { origin.duration(to: clock.now) })
        let transport = try ScriptedHTTPTransport(steps: [{ _ in
            try clock.advance(by: .milliseconds(3))
            throw TestSupportFailure.scripted("private transport failure")
        }, { _ in
            try clock.advance(by: .milliseconds(5))
            return HTTPResponse(status: 204)
        }])
        let coordinator = RateLimitCoordinator(clock: clock)
        let client = RESTClient(credential: .none, identity: RateLimitIdentity(), transport: transport,
            coordinator: coordinator, clock: clock,
            retryPolicy: .init(maximumAttempts: 2, initialBackoff: .zero), intervals: intervals)
        let endpoint = try Endpoint(method: "GET", path: ["retry"], authentication: .none,
            successStatuses: [204], retrySafety: .safe, decode: { $0 })
        let task = Task { try await client.execute(endpoint) }
        defer { task.cancel() }
        // Failed sends preserve the existing conservative one-second unknown-route debit.
        // Observe the second admission's real begin before advancing its wait explicitly.
        while !observations.snapshot().events.contains(where: {
            $0.kind == .began && $0.stage == .admission && $0.context.attempt == 2
        }) {
            try Task.checkCancellation(); await Task.yield()
        }
        #expect(await transport.executionCount == 1)
        try clock.advance(by: .seconds(1))
        #expect(try await task.value.isEmpty)
        let ends = observations.snapshot().events.filter { $0.kind == .ended }
        let logical = try #require(ends.first { $0.operation == .rest })
        let attempts = ends.filter { $0.operation == .httpExchange && $0.stage == .operation }
        #expect(ends.filter { $0.operation == .rest }.count == 1)
        #expect(attempts.map { $0.context.attempt } == [1, 2])
        #expect(attempts.map(\.outcome) == [.failed, .succeeded])
        #expect(attempts.map(\.elapsedNanoseconds) == [3_000_000, 1_005_000_000])
        #expect(attempts.allSatisfy { $0.context.parentID == logical.context.operationID })
        #expect(logical.elapsedNanoseconds == 1_008_000_000 && logical.outcome == .succeeded)
        #expect(Set(ends.map { $0.context.operationID }).count == ends.count)
        #expect(await transport.executionCount == 2)
        #expect(await coordinator.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
        await coordinator.close()
    }

    /// A fresh cached response has one logical caller interval and no fabricated exchange or subscriber.
    /// - Throws: Unexpected fixture construction or request failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func cacheHitHasNoWireIntervals() async throws {
        let clock = ManualClock(), observations = RESTIntervalObservations()
        let intervals = DiscordIntervalTiming(clockDomain: 31, sink: observations.record, now: { .zero })
        let transport = try ScriptedHTTPTransport(steps: [{ _ in HTTPResponse(status: 204) }])
        let coordinator = RateLimitCoordinator(clock: clock), cache = ReadCache(clock: clock)
        let client = RESTClient(credential: .none, identity: RateLimitIdentity(), transport: transport,
            coordinator: coordinator, clock: clock, cache: cache, intervals: intervals)
        let endpoint = try Endpoint(method: "GET", path: ["cached"], authentication: .none,
            successStatuses: [204], retrySafety: .safe,
            readPolicy: .init(timeToLive: .seconds(10)), decode: { $0 })
        #expect(try await client.execute(endpoint).isEmpty)
        let before = observations.snapshot().events.count
        #expect(try await client.execute(endpoint).isEmpty)
        let hit = Array(observations.snapshot().events.dropFirst(before))
        #expect(hit.map(\.kind) == [.began, .ended])
        #expect(hit.allSatisfy { $0.operation == .rest && $0.stage == .operation })
        #expect(hit.last?.outcome == .succeeded)
        #expect(await transport.executionCount == 1)
        #expect(await coordinator.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
        await cache.removeAll(); await coordinator.close()
    }

    /// Cancelling the initiating subscriber ends only that caller; the surviving flight retains its owner.
    /// - Throws: Unexpected fixture construction, synchronization or request failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func sharedExchangeOutlivesInitiatingSubscriber() async throws {
        let clock = ManualClock(), observations = RESTIntervalObservations(), blocked = TestBarrier()
        let origin = clock.now
        let intervals = DiscordIntervalTiming(clockDomain: 32, sink: observations.record,
            now: { origin.duration(to: clock.now) })
        let transport = try ScriptedHTTPTransport(steps: [{ _ in
            try await blocked.wait(); return HTTPResponse(status: 204)
        }])
        let coordinator = RateLimitCoordinator(clock: clock), coalescer = RequestCoalescer()
        let client = RESTClient(credential: .none, identity: RateLimitIdentity(), transport: transport,
            coordinator: coordinator, clock: clock, coalescer: coalescer, intervals: intervals)
        let endpoint = try Endpoint(method: "GET", path: ["shared"], authentication: .none,
            successStatuses: [204], retrySafety: .safe, readPolicy: .init(), decode: { $0 })
        let first = Task { try await client.execute(endpoint) }
        while blocked.waitingCount == 0 { try Task.checkCancellation(); await Task.yield() }
        let firstLogical = try #require(observations.snapshot().events.first { $0.operation == .rest })
        let second = Task { try await client.execute(endpoint) }
        while await coalescer.snapshot().waiters < 2 { try Task.checkCancellation(); await Task.yield() }
        try clock.advance(by: .milliseconds(10))
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await coalescer.snapshot().waiters == 1)
        #expect(!observations.snapshot().events.contains {
            $0.kind == .ended && $0.operation == .httpExchange && $0.stage == .operation
        })
        try clock.advance(by: .milliseconds(20))
        blocked.open()
        #expect(try await second.value.isEmpty)
        let ends = observations.snapshot().events.filter { $0.kind == .ended }
        let exchanges = ends.filter { $0.operation == .httpExchange && $0.stage == .operation }
        let subscribers = ends.filter { $0.operation == .httpSubscriber }
        #expect(exchanges.count == 1)
        #expect(exchanges.first?.context.parentID == firstLogical.context.operationID)
        #expect(exchanges.first?.outcome == .succeeded)
        #expect(subscribers.map(\.outcome) == [.cancelled, .succeeded])
        #expect(subscribers.map(\.elapsedNanoseconds) == [10_000_000, 30_000_000])
        #expect(Set(subscribers.compactMap { $0.context.parentID }).count == 2)
        #expect(ends.filter { $0.operation == .rest }.map(\.outcome) == [.cancelled, .succeeded])
        #expect(ends.filter { $0.operation == .httpExchange && $0.stage == .admission }.count == 1)
        #expect(await transport.executionCount == 1)
        let sharedSnapshot = await coalescer.snapshot()
        #expect(sharedSnapshot.flights == 0 && sharedSnapshot.waiters == 0)
        #expect(await coordinator.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
        await coalescer.close(); await coordinator.close()
    }

    /// Cancellation and deadline expiry cannot emit body, exchange or caller terminals before close joins.
    /// - Parameter deadline: Chooses clock expiry rather than explicit task cancellation.
    /// - Throws: Unexpected fixture construction, synchronization or clock failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true]) func terminalEventsFollowBodyCleanup(deadline: Bool) async throws {
        let clock = ManualClock(), observations = RESTIntervalObservations()
        let origin = clock.now
        let intervals = DiscordIntervalTiming(clockDomain: 33, sink: observations.record,
            now: { origin.duration(to: clock.now) })
        let entered = TestBarrier(), blocked = TestBarrier(), closeEntered = TestBarrier()
        let cleanup = RESTIntervalCleanup()
        let resources = ResourceCounter(), bodyLease = await resources.acquire()
        let body = try BodyStream(maximumChunkBytes: 1, next: {
            entered.open(); try await blocked.wait(); return nil
        }, close: {
            closeEntered.open(); await cleanup.wait(); await bodyLease.release()
        })
        let transport = try ScriptedHTTPTransport(steps: [{ _ in HTTPResponse(status: 204, body: body) }])
        let coordinator = RateLimitCoordinator(clock: clock)
        let client = RESTClient(credential: .none, identity: RateLimitIdentity(), transport: transport,
            coordinator: coordinator, clock: clock, intervals: intervals)
        let endpoint = try Endpoint(method: "GET", path: ["cleanup"], authentication: .none,
            successStatuses: [204], retrySafety: .safe, decode: { $0 })
        let task = Task { try await client.execute(endpoint, deadline: deadline ? clock.now.advanced(by: .seconds(1)) : nil) }
        try await entered.wait()
        if deadline { try clock.advance(by: .seconds(1)) } else { task.cancel() }
        try await closeEntered.wait()
        #expect(!observations.snapshot().events.contains {
            $0.kind == .ended && ($0.stage == .body || $0.stage == .operation)
        })
        #expect(await coordinator.snapshot().activeCount == 1)
        #expect(await resources.snapshot().live == 1)
        try clock.advance(by: .milliseconds(7))
        await cleanup.release()
        if deadline {
            await #expect(throws: TransportFailure.deadlineExceeded) { try await task.value }
        } else {
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        let terminals = observations.snapshot().events.filter {
            $0.kind == .ended && ($0.stage == .body || $0.stage == .operation)
        }
        #expect(terminals.count == 3)
        #expect(terminals.last?.elapsedNanoseconds == (deadline ? 1_007_000_000 : 7_000_000))
        #expect(terminals.last?.outcome == (deadline ? .failed : .cancelled))
        let resourceSnapshot = await resources.snapshot()
        #expect(resourceSnapshot.live == 0 && resourceSnapshot.acquired == 1 && resourceSnapshot.released == 1)
        #expect(await coordinator.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
        await coordinator.close()
    }

    /// Pre-cancelled callers create no attempts and unsafe submissions retain uncertainty throughout.
    /// - Parameter submitted: Chooses an ambiguous unsafe send instead of cancellation before work.
    /// - Throws: Unexpected fixture construction or execution failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true]) func cancellationBeforeWorkAndUnsafeUncertainty(submitted: Bool) async throws {
        let clock = ManualClock(), observations = RESTIntervalObservations()
        let intervals = DiscordIntervalTiming(clockDomain: 34, sink: observations.record, now: { .zero })
        let transport = try ScriptedHTTPTransport(steps: [{ _ in
            throw TestSupportFailure.scripted("private unsafe failure")
        }])
        let coordinator = RateLimitCoordinator(clock: clock)
        let client = RESTClient(credential: .none, identity: RateLimitIdentity(), transport: transport,
            coordinator: coordinator, clock: clock, intervals: intervals)
        let endpoint = try Endpoint(method: "POST", path: ["private-route"], authentication: .none, decode: { $0 })
        if submitted {
            await #expect(throws: DiscordError.unknownMutationOutcome(.connectionLostAfterSubmission)) {
                try await client.execute(endpoint)
            }
        } else {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await client.execute(endpoint)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        let ends = observations.snapshot().events.filter { $0.kind == .ended }
        if submitted {
            #expect(ends.map(\.stage) == [.admission, .headers, .operation, .operation])
            #expect(ends.map(\.outcome) == [.succeeded, .uncertain, .uncertain, .uncertain])
            #expect(await transport.executionCount == 1)
        } else {
            #expect(ends.count == 1 && ends.first?.operation == .rest && ends.first?.outcome == .cancelled)
            #expect(await transport.executionCount == 0)
        }
        #expect(!String(reflecting: observations.snapshot().events).contains("private"))
        #expect(await coordinator.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
        await coordinator.close()
    }
}
