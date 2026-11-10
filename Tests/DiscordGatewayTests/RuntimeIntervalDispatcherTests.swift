// File: Tests/DiscordGatewayTests/RuntimeIntervalDispatcherTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordLogging
import DiscordTestSupport
import Foundation
import Testing
@testable import DiscordGateway

/// Bounded test-owned numeric endpoints, protected across concurrent callbacks.
private final class DispatcherIntervalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DiscordIntervalEvent] = []
    private var reads = 0

    /// Retains one finite fixture endpoint synchronously.
    func record(_ event: DiscordIntervalEvent) { lock.withLock { events.append(event) } }
    /// Counts an injected instrumentation-clock read.
    func read() { lock.withLock { reads += 1 } }
    /// Copies numeric endpoints and read count atomically.
    func snapshot() -> (events: [DiscordIntervalEvent], reads: Int) { lock.withLock { (events, reads) } }
}

/// Cancellation-independent fixture gate exposes the exact joined-cleanup boundary.
private actor DispatcherIntervalCleanup {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    /// Waits until the test owner explicitly releases callback cleanup.
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    /// Releases cleanup once, including release-before-arrival.
    func release() { released = true; continuation?.resume(); continuation = nil }
}

/// Actual queue, admission, callback and joined-run boundaries retain distinct identities.
@Suite("Runtime dispatcher intervals", .timeLimit(.minutes(1)))
struct RuntimeIntervalDispatcherTests {
    /// Concurrent handlers receive independent explicit contexts, and nil reads no interval clock.
    /// - Parameter enabled: Independent detailed observation opt-in.
    /// - Throws: Unexpected fixture, callback or clock failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true]) func concurrentChildrenAndDisabledClock(enabled: Bool) async throws {
        let clock = ManualClock(), recorder = DispatcherIntervalRecorder(), origin = clock.now
        let intervals = DiscordIntervalTiming(clockDomain: 61, sink: recorder.record, now: {
            recorder.read(); return origin.duration(to: clock.now)
        })
        let hub = GatewayEventHub(configuration: try .init()), entered = TestBarrier(), secondEntered = TestBarrier(), released = TestBarrier()
        let subscription = try await hub.subscribe()
        let dispatcher = GatewayEventHandlerDispatcher(configuration: try .init(maximumConcurrentHandlers: 2),
            serializesPerShard: false, intervals: enabled ? intervals : nil)
        #expect(recorder.snapshot().reads == 0)
        let task = Task {
            try await dispatcher.run(subscription: subscription) { event in
                #expect((DiscordIntervalScope.context != nil) == enabled)
                let child = enabled ? intervals.begin(.rest, stage: .operation) : nil
                if event.sequence == 1 { entered.open() } else { secondEntered.open() }
                try await released.wait()
                child?.end()
            }
        }
        await hub.publish(try makeDeliveryEvent(1)); await hub.publish(try makeDeliveryEvent(2))
        try await entered.wait(); try await secondEntered.wait()
        try clock.advance(by: .milliseconds(17))
        released.open()
        await hub.finish(); try await task.value
        let result = recorder.snapshot(), events = result.events
        if enabled {
            let handlers = events.filter { $0.kind == .began && $0.stage == .handler }
            let children = events.filter { $0.kind == .began && $0.operation == .rest }
            #expect(handlers.count == 2 && children.count == 2)
            #expect(Set(handlers.map { $0.context.operationID }).count == 2)
            #expect(Set(children.compactMap { $0.context.parentID }) == Set(handlers.map { $0.context.operationID }))
            #expect(events.filter { $0.kind == .ended && $0.stage == .handler }
                .allSatisfy { $0.elapsedNanoseconds == 17_000_000 && $0.outcome == .succeeded })
            #expect(events.last?.stage == .operation && events.last?.operation == .gatewayDispatch)
            #expect(events.filter { $0.kind == .began }.count == events.filter { $0.kind == .ended }.count)
        } else { #expect(events.isEmpty && result.reads == 0) }
        #expect(DiscordIntervalScope.context == nil)
        #expect(await hub.snapshot().subscriptions == 0)
    }

    /// A retained local queue and active callback close only after cooperative cancellation cleanup joins.
    /// - Throws: Unexpected fixture or synchronization failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func cancellationClosesPendingIntervalsAfterJoin() async throws {
        let clock = ManualClock(), recorder = DispatcherIntervalRecorder(), origin = clock.now
        let intervals = DiscordIntervalTiming(clockDomain: 62, sink: recorder.record,
            now: { origin.duration(to: clock.now) })
        let hub = GatewayEventHub(configuration: try .init()), authority = try GatewayHandlerAuthority(maximumActiveHandlers: 1)
        let subscription = try await hub.subscribe(), cleanup = DispatcherIntervalCleanup()
        let entered = TestBarrier(), blocked = TestBarrier(), cleanupEntered = TestBarrier()
        let dispatcher = GatewayEventHandlerDispatcher(configuration: try .init(maximumConcurrentHandlers: 1),
            authority: authority, intervals: intervals)
        let task = Task {
            try await dispatcher.run(subscription: subscription) { _ in
                entered.open()
                do { try await blocked.wait() }
                catch { cleanupEntered.open(); await cleanup.wait(); throw error }
            }
        }
        await hub.publish(try makeDeliveryEvent(1)); try await entered.wait()
        await hub.publish(try makeDeliveryEvent(2))
        while recorder.snapshot().events.filter({ $0.kind == .began && $0.stage == .localQueue }).count != 2 {
            try Task.checkCancellation(); await Task.yield()
        }
        task.cancel(); try await cleanupEntered.wait()
        #expect(!recorder.snapshot().events.contains { $0.kind == .ended && ($0.stage == .handler || $0.stage == .operation) })
        #expect(await authority.snapshot().activeHandlers == 1)
        try clock.advance(by: .milliseconds(30)); await cleanup.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        let events = recorder.snapshot().events, terminal = events.filter { $0.kind == .ended }
        #expect(terminal.last?.stage == .operation && terminal.last?.outcome == .cancelled)
        #expect(terminal.last?.elapsedNanoseconds == 30_000_000)
        #expect(terminal.filter { $0.stage == .localQueue && $0.outcome == .cancelled }.count == 1)
        #expect(events.filter { $0.kind == .began }.count == terminal.count)
        #expect(await authority.snapshot().activeHandlers == 0)
        #expect(await authority.snapshot().waitingHandlers == 0)
        #expect(await hub.snapshot().subscriptions == 0)
    }

    /// Shared-admission wait excludes callback execution and releases the authority before run termination.
    /// - Throws: Unexpected bounded owner or virtual-clock failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func sharedAdmissionHasAnHonestBoundary() async throws {
        let clock = ManualClock(), recorder = DispatcherIntervalRecorder(), origin = clock.now
        let intervals = DiscordIntervalTiming(clockDomain: 63, sink: recorder.record,
            now: { origin.duration(to: clock.now) })
        let authority = try GatewayHandlerAuthority(maximumActiveHandlers: 1)
        let firstHub = GatewayEventHub(configuration: try .init()), secondHub = GatewayEventHub(configuration: try .init())
        let firstSubscription = try await firstHub.subscribe(), secondSubscription = try await secondHub.subscribe()
        let entered = TestBarrier(), blocked = TestBarrier(), completed = TestBarrier()
        let first = GatewayEventHandlerDispatcher(configuration: try .init(), authority: authority)
        let second = GatewayEventHandlerDispatcher(configuration: try .init(), authority: authority, intervals: intervals)
        let firstTask = Task { try await first.run(subscription: firstSubscription) { _ in entered.open(); try await blocked.wait() } }
        await firstHub.publish(try makeDeliveryEvent(1)); try await entered.wait()
        let secondTask = Task {
            try await second.run(subscription: secondSubscription) { _ in
                try clock.advance(by: .milliseconds(9)); completed.open()
            }
        }
        await secondHub.publish(try makeDeliveryEvent(2))
        while await authority.snapshot().waitingHandlers != 1 { try Task.checkCancellation(); await Task.yield() }
        try clock.advance(by: .milliseconds(25)); blocked.open(); try await completed.wait()
        await firstHub.finish(); await secondHub.finish()
        try await firstTask.value; try await secondTask.value
        let terminal = recorder.snapshot().events.filter { $0.kind == .ended }
        #expect(terminal.first { $0.stage == .admission }?.elapsedNanoseconds == 25_000_000)
        #expect(terminal.first { $0.stage == .handler }?.elapsedNanoseconds == 9_000_000)
        #expect(await authority.snapshot().activeHandlers == 0)
    }

    /// Pre-cancelled runs still close their real owner interval and sole subscription without callbacks.
    /// - Throws: Unexpected fixture failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func cancellationBeforeWork() async throws {
        let recorder = DispatcherIntervalRecorder()
        let intervals = DiscordIntervalTiming(clockDomain: 64, sink: recorder.record, now: { .zero })
        let hub = GatewayEventHub(configuration: try .init()), subscription = try await hub.subscribe()
        let dispatcher = GatewayEventHandlerDispatcher(configuration: try .init(), intervals: intervals)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await dispatcher.run(subscription: subscription) { _ in Issue.record("Cancelled run cannot invoke a handler") }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(recorder.snapshot().events.map(\.kind) == [.began, .ended])
        #expect(recorder.snapshot().events.last?.outcome == .cancelled)
        #expect(await hub.snapshot().subscriptions == 0)
    }
}
