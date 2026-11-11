// File: Tests/DiscordGatewayTests/RuntimeIntervalGatewayTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordLogging
import DiscordTestSupport
import Foundation
import Testing
@testable import DiscordGateway

private let helloPayload = #"{"op":10,"d":{"heartbeat_interval":10000}}"#
private let readyPayload = #"{"op":0,"s":1,"t":"READY","d":{"session_id":"session","resume_gateway_url":"wss://resume.discord.gg/"}}"#

/// Finite test-owned lifecycle receipts; the runtime observer retains no event history.
private final class GatewayIntervalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DiscordIntervalEvent] = []
    private var reads = 0
    /// Retains a bounded fixture endpoint under a concurrent-safe lock.
    func record(_ event: DiscordIntervalEvent) { lock.withLock { events.append(event) } }
    /// Counts only enabled instrumentation clock reads.
    func read() { lock.withLock { reads += 1 } }
    /// Copies current numeric observations and clock-read accounting atomically.
    func snapshot() -> (events: [DiscordIntervalEvent], reads: Int) { lock.withLock { (events, reads) } }
}

/// Real socket receipt, bounded queues, duplicate filtering and independent control work are observed.
@Suite("Runtime Gateway intervals", .timeLimit(.minutes(1)))
struct RuntimeIntervalGatewayTests {
    /// Parse includes duplicate frames; only accepted frames acquire raw-queue intervals.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true]) func socketDecodeAndRawResidence(enabled: Bool) async throws {
        let measured = ManualClock(), origin = measured.now, recorder = GatewayIntervalRecorder()
        let intervals = DiscordIntervalTiming(clockDomain: 606, sink: recorder.record, now: {
            recorder.read(); return origin.duration(to: measured.now)
        })
        let identified = TestBarrier(), queued = TestBarrier(), idle = TestBarrier(onWaitScheduled: { queued.open() })
        let socket = GatewayTestSocket(steps: [
            { .text(helloPayload) },
            { try await identified.wait(); return .text(readyPayload) },
            { .text(#"{"op":0,"s":2,"t":"FUTURE","d":null}"#) },
            { .text(#"{"op":0,"s":2,"t":"DUPLICATE","d":null}"#) },
            { try await idle.wait(); return nil }
        ], onSend: { envelope in if envelope.opcode == 2 { identified.open() } })
        let fixture = try makeRuntime(sockets: [socket], intervals: enabled ? intervals : nil)
        #expect(recorder.snapshot().reads == 0)
        let task = Task { try await fixture.shard.run() }
        try await queued.wait()
        try measured.advance(by: .milliseconds(17))
        #expect(await fixture.shard.drainEvents().map(\.name) == ["READY", "FUTURE"])
        await fixture.shard.stop(); try await task.value
        let result = recorder.snapshot(), events = result.events
        if enabled {
            #expect(events.filter { $0.kind == .began && $0.stage == .decode }.count == 4)
            #expect(events.filter { $0.kind == .ended && $0.stage == .socketReceipt }.count == 3)
            let retained = events.filter { $0.kind == .ended && $0.stage == .ingestionQueue }
            #expect(retained.count == 2)
            #expect(retained.allSatisfy { $0.elapsedNanoseconds == 17_000_000 && $0.outcome == .succeeded })
            #expect(events.last?.stage == .operation && events.last?.operation == .gatewaySession)
            let validations = events.filter { $0.kind == .ended && $0.stage == .leaseValidation }
            let session = events.first { $0.kind == .began && $0.operation == .gatewaySession && $0.stage == .operation }
            #expect(!validations.isEmpty)
            #expect(validations.allSatisfy { $0.outcome == .succeeded && $0.context.parentID == session?.context.operationID })
            #expect(events.filter { $0.kind == .began }.count == events.filter { $0.kind == .ended }.count)
        } else { #expect(events.isEmpty && result.reads == 0) }
        #expect(await fixture.leases.retainedLeaseCount() == 0)
        #expect(fixture.clock.pendingSleepCount == 0)
    }

    /// A rejected overlapping run allocates no interval and cannot replace the accepted owner's context.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func concurrentRunRejectionPreservesObserverOwnership() async throws {
        let recorder = GatewayIntervalRecorder()
        let intervals = DiscordIntervalTiming(clockDomain: 610, sink: recorder.record, now: { .zero })
        let entered = TestBarrier(), blocked = TestBarrier()
        let socket = GatewayTestSocket(steps: [])
        let fixture = try makeRuntime(sockets: [socket], connectGate: blocked, connectEntered: entered, intervals: intervals)
        let task = Task { try await fixture.shard.run() }
        try await entered.wait()
        await #expect(throws: GatewayFailure.alreadyRunning) { try await fixture.shard.run() }
        #expect(recorder.snapshot().events.filter { $0.kind == .began && $0.stage == .operation }.count == 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let events = recorder.snapshot().events
        let owner = try #require(events.first { $0.kind == .began && $0.stage == .operation })
        #expect(events.first { $0.kind == .began && $0.stage == .shutdown }?.context.parentID == owner.context.operationID)
        #expect(events.last?.stage == .operation && events.last?.outcome == .cancelled)
        #expect(events.filter { $0.kind == .began }.count == events.filter { $0.kind == .ended }.count)
        #expect(await fixture.leases.retainedLeaseCount() == 0)
    }

    /// Per-subscriber residence closes at dequeue, eviction, overflow or joined cancellation exactly once.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func hubResidencePreservesOutcomesAndCapacity() async throws {
        let clock = ManualClock(), origin = clock.now, recorder = GatewayIntervalRecorder()
        let intervals = DiscordIntervalTiming(clockDomain: 607, sink: recorder.record,
            now: { origin.duration(to: clock.now) })
        let hub = GatewayEventHub(configuration: try .init(maximumEventsPerSubscription: 1), intervals: intervals)
        let lossy = try await hub.subscribe(policy: .dropOldest), strict = try await hub.subscribe()
        await hub.publish(try makeDeliveryEvent(1))
        try clock.advance(by: .milliseconds(3))
        let result = await hub.publish(try makeDeliveryEvent(2))
        #expect(result.delivered == 1 && result.terminated == 1)
        var iterator = lossy.makeAsyncIterator()
        try clock.advance(by: .milliseconds(7))
        #expect(try await iterator.next()?.sequence == 2)
        var failed = strict.makeAsyncIterator()
        await #expect(throws: GatewayEventDeliveryFailure.resynchronizationRequired) { _ = try await failed.next() }
        await hub.publish(try makeDeliveryEvent(3))
        try clock.advance(by: .milliseconds(5))
        await hub.finish()
        let events = recorder.snapshot().events
        let retained = events.filter { $0.kind == .ended && $0.stage == .hubResidence }
        #expect(retained.count == 4)
        #expect(retained.filter { $0.outcome == .failed && $0.elapsedNanoseconds == 3_000_000 }.count == 2)
        #expect(retained.filter { $0.outcome == .succeeded && $0.elapsedNanoseconds == 7_000_000 }.count == 1)
        #expect(retained.filter { $0.outcome == .cancelled && $0.elapsedNanoseconds == 5_000_000 }.count == 1)
        #expect(events.filter { $0.kind == .began }.count == events.filter { $0.kind == .ended }.count)
        #expect(await hub.snapshot().subscriptions == 0)
        #expect(await hub.snapshot().bufferedEvents == 0)
    }

    /// Malformed socket JSON produces a failed parse and failed joined operation without phantom queue data.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func malformedDecodeAndCancellationCloseEveryHandle() async throws {
        let recorder = GatewayIntervalRecorder()
        let intervals = DiscordIntervalTiming(clockDomain: 608, sink: recorder.record, now: { .zero })
        let socket = GatewayTestSocket(steps: [{ .text(helloPayload) }, { .text("{") }])
        let fixture = try makeRuntime(sockets: [socket], retries: 0, intervals: intervals)
        await #expect(throws: (any Error).self) { try await fixture.shard.run() }
        let events = recorder.snapshot().events
        #expect(events.filter { $0.kind == .ended && $0.stage == .decode && $0.outcome == .failed }.count == 1)
        #expect(events.filter { $0.kind == .ended && $0.stage == .socketReceipt && $0.outcome == .failed }.count == 1)
        #expect(!events.contains { $0.stage == .ingestionQueue })
        #expect(events.last?.stage == .operation && events.last?.outcome == .failed)
        #expect(events.filter { $0.kind == .began }.count == events.filter { $0.kind == .ended }.count)
        #expect(await fixture.leases.retainedLeaseCount() == 0)
    }

    /// A pending recovery interval retains terminal invalid-Hello or retry-exhaustion failure.
    /// - Parameter invalidHello: True rejects the replacement Hello; false exhausts the retry budget.
    /// - Throws: Unexpected fixture or synchronization failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true]) func failedReconnectRetainsFailure(invalidHello: Bool) async throws {
        let recorder = GatewayIntervalRecorder(), identified = TestBarrier()
        let intervals = DiscordIntervalTiming(clockDomain: 611, sink: recorder.record, now: { .zero })
        let first = GatewayTestSocket(steps: [
            { .text(helloPayload) },
            { try await identified.wait(); return .text(readyPayload) },
            { .text(#"{"op":7,"d":null}"#) }
        ], onSend: { envelope in if envelope.opcode == 2 { identified.open() } })
        let second = GatewayTestSocket(steps: invalidHello
            ? [{ .text(#"{"op":10,"d":{"heartbeat_interval":0}}"#) }]
            : [{ .text(helloPayload) }, { nil }])
        let fixture = try makeRuntime(sockets: [first, second], retries: 1, jitter: 0, intervals: intervals)
        await #expect(throws: invalidHello ? GatewayFailure.invalidPayload : GatewayFailure.retryLimitExceeded) {
            try await fixture.shard.run()
        }
        let events = recorder.snapshot().events
        #expect(events.filter { $0.kind == .began && $0.stage == .reconnect }.count == 1)
        #expect(events.filter { $0.kind == .ended && $0.stage == .reconnect }.map(\.outcome) == [.failed])
        #expect(events.last?.stage == .operation && events.last?.outcome == .failed)
        #expect(events.filter { $0.kind == .began }.count == events.filter { $0.kind == .ended }.count)
        #expect(await fixture.leases.retainedLeaseCount() == 0)
        #expect(fixture.clock.pendingSleepCount == 0)
    }

    /// Caller cancellation while recovery backoff is pending ends recovery after joined cleanup.
    /// - Throws: Unexpected fixture, protocol or cancellation-cleanup failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func cancelledPendingReconnectRetainsCancellation() async throws {
        let recorder = GatewayIntervalRecorder(), identified = TestBarrier()
        let intervals = DiscordIntervalTiming(clockDomain: 612, sink: recorder.record, now: { .zero })
        let first = GatewayTestSocket(steps: [
            { .text(helloPayload) },
            { try await identified.wait(); return .text(readyPayload) },
            { .text(#"{"op":7,"d":null}"#) }
        ], onSend: { envelope in if envelope.opcode == 2 { identified.open() } })
        let fixture = try makeRuntime(sockets: [first], retries: 1, jitter: 1, intervals: intervals)
        let task = Task { try await fixture.shard.run() }
        while !recorder.snapshot().events.contains(where: { $0.kind == .began && $0.stage == .reconnect }) {
            try Task.checkCancellation(); await Task.yield()
        }
        #expect(!recorder.snapshot().events.contains { $0.kind == .ended && $0.stage == .reconnect })
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let events = recorder.snapshot().events
        #expect(events.filter { $0.kind == .ended && $0.stage == .reconnect }.map(\.outcome) == [.cancelled])
        #expect(events.last?.stage == .operation && events.last?.outcome == .cancelled)
        #expect(events.filter { $0.kind == .began }.count == events.filter { $0.kind == .ended }.count)
        #expect(await fixture.leases.retainedLeaseCount() == 0)
        #expect(fixture.clock.pendingSleepCount == 0)
    }

    /// Heartbeat ACK, reconnect/Resume, a fast subscription and socket shutdown all complete while
    /// a separate subscription's callback remains suspended. Its structured cleanup joins afterward.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func controlLaneACKAndResumeAreIndependent() async throws {
        let measured = ManualClock(), origin = measured.now, recorder = GatewayIntervalRecorder()
        let intervals = DiscordIntervalTiming(clockDomain: 609, sink: recorder.record,
            now: { origin.duration(to: measured.now) })
        let identified = TestBarrier(), ackAllowed = TestBarrier(), firstReady = TestBarrier()
        let firstIdle = TestBarrier(onWaitScheduled: { firstReady.open() })
        let resumed = TestBarrier(), secondReady = TestBarrier(), secondIdle = TestBarrier(onWaitScheduled: { secondReady.open() })
        let first = GatewayTestSocket(steps: [
            { .text(helloPayload) },
            { try await identified.wait(); return .text(readyPayload) },
            { try await ackAllowed.wait(); return .text(#"{"op":11,"d":null}"#) },
            { try await firstIdle.wait(); return .text(#"{"op":7,"d":null}"#) }
        ], onSend: { envelope in if envelope.opcode == 2 { identified.open() } })
        let second = GatewayTestSocket(steps: [
            { .text(helloPayload) },
            { try await resumed.wait(); return .text(#"{"op":0,"s":2,"t":"RESUMED","d":{}}"#) },
            { try await secondIdle.wait(); return nil }
        ], onSend: { envelope in if envelope.opcode == 6 { resumed.open() } })
        let fixture = try makeRuntime(sockets: [first, second], jitter: 0, intervals: intervals)
        let hub = GatewayEventHub(configuration: try .init())
        let slow = try await hub.subscribe(), fast = try await hub.subscribe()
        let handlerEntered = TestBarrier(), handlerRelease = TestBarrier()
        let dispatcher = GatewayEventHandlerDispatcher(configuration: try .init(maximumRetainedEvents: 1))
        let handlerTask = Task {
            try await dispatcher.run(subscription: slow) { event in
                #expect(event.sequence == 1)
                handlerEntered.open()
                try await handlerRelease.wait()
            }
        }
        let task = Task { try await fixture.shard.run() }
        let ready = try #require(try await fixture.shard.nextEvents()?.first)
        #expect(await hub.publish(ready).delivered == 2)
        var fastIterator = fast.makeAsyncIterator()
        #expect(try await fastIterator.next()?.sequence == 1)
        try await handlerEntered.wait()
        while !recorder.snapshot().events.contains(where: { $0.kind == .began && $0.stage == .heartbeatACK }) {
            try Task.checkCancellation(); await Task.yield()
        }
        try measured.advance(by: .milliseconds(11)); ackAllowed.open(); try await firstReady.wait()
        #expect(recorder.snapshot().events.contains { $0.kind == .ended && $0.stage == .heartbeatACK && $0.elapsedNanoseconds == 11_000_000 })
        firstIdle.open(); try await secondReady.wait()
        #expect(recorder.snapshot().events.contains { $0.kind == .ended && $0.stage == .reconnect && $0.outcome == .succeeded })
        let resumedEvent = try #require(try await fixture.shard.nextEvents()?.first)
        #expect(resumedEvent.sequence == 2)
        #expect(await hub.publish(resumedEvent).delivered == 2)
        #expect(try await fastIterator.next()?.sequence == 2)
        #expect(handlerRelease.waitingCount == 1)
        task.cancel(); await #expect(throws: CancellationError.self) { try await task.value }
        let events = recorder.snapshot().events
        #expect(events.last?.stage == .operation && events.last?.outcome == .cancelled)
        #expect(events.filter { $0.kind == .began }.count == events.filter { $0.kind == .ended }.count)
        #expect(await fixture.leases.retainedLeaseCount() == 0)
        #expect(fixture.clock.pendingSleepCount == 0)
        #expect(handlerRelease.waitingCount == 1)
        handlerTask.cancel()
        await #expect(throws: CancellationError.self) { try await handlerTask.value }
        await hub.finish()
        #expect(handlerRelease.waitingCount == 0)
        #expect(await hub.snapshot().subscriptions == 0)
        #expect(await hub.snapshot().bufferedEvents == 0)
    }
}
