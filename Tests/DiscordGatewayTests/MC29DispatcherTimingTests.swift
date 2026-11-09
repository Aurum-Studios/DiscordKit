// File: Tests/DiscordGatewayTests/MC29DispatcherTimingTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordTestSupport
import DiscordTransport
import Foundation
import Testing
@testable import DiscordGateway

/// Thread-safe finite observer; no event identities or payloads enter its timing storage.
private final class MC29DispatcherObservations: @unchecked Sendable {
    /// Protects observation state shared by dispatcher child tasks.
    private let lock = NSLock()
    /// Fixed-shape samples from one finite test.
    private var samples: [OperationTimingSample] = []
    /// Explicit instrumentation clock-read count.
    private var reads = 0
    /// Appends a sample synchronously without spawning work.
    /// - Parameter sample: Fixed phase, outcome and elapsed duration.
    func record(_ sample: OperationTimingSample) { lock.withLock { samples.append(sample) } }
    /// Counts a clock read for the disabled-path assertion.
    func read() { lock.withLock { reads += 1 } }
    /// Copies observations under one lock.
    /// - Returns: Bounded samples and clock-read count.
    func snapshot() -> (samples: [OperationTimingSample], reads: Int) { lock.withLock { (samples, reads) } }
}

/// Cancellation-independent final cleanup makes premature joined observations observable in a test.
private actor MC29DispatcherCleanup {
    /// Whether cleanup may finish.
    private var released = false
    /// Sole cleanup waiter; no retry or background owner exists.
    private var continuation: CheckedContinuation<Void, Never>?
    /// Suspends independently of cancellation until explicitly released by the fixture owner.
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    /// Releases cleanup, including release-before-arrival, once.
    func release() { released = true; continuation?.resume(); continuation = nil }
}

/// Timing preserves task caps, aggregate FIFO admission and structured callback cleanup.
@Suite("MC-29 dispatcher timing", .timeLimit(.minutes(1)))
struct MC29DispatcherTimingTests {
    /// Disabled observation creates no timing scope/clock reads; enabled work retains the original callback cap.
    /// - Parameter enabled: Explicit observer opt-in.
    /// - Throws: Unexpected hub, event or dispatcher failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true]) func nilClockAndLocalCapacity(enabled: Bool) async throws {
        let clock = ManualClock(), observations = MC29DispatcherObservations()
        let origin = clock.now
        let timing = OperationTiming(sink: observations.record, now: {
            observations.read(); return origin.duration(to: clock.now)
        })
        let hub = GatewayEventHub(configuration: try .init()), first = TestBarrier(), blocked = TestBarrier()
        let finished = TestBarrier()
        let subscription = try await hub.subscribe()
        let dispatcher = GatewayEventHandlerDispatcher(configuration: try .init(maximumConcurrentHandlers: 1),
            serializesPerShard: false, timing: enabled ? timing : nil)
        #expect(observations.snapshot().reads == 0)
        let task = Task {
            try await dispatcher.run(subscription: subscription) { event in
                #expect((OperationTimingScope.gatewayAdmission != nil) == enabled)
                if event.sequence == 1 { first.open(); try await blocked.wait() }
                else { #expect(blocked.waitingCount == 0); finished.open() }
            }
        }
        await hub.publish(try makeDeliveryEvent(1))
        try await first.wait()
        await hub.publish(try makeDeliveryEvent(2))
        blocked.open()
        try await finished.wait()
        await hub.finish()
        try await task.value
        let result = observations.snapshot()
        if enabled {
            #expect(result.samples.filter { $0.phase == .gatewayLocalQueue }.count == 2)
            #expect(result.samples.last?.phase == .gatewayRunJoined)
            #expect(result.samples.allSatisfy { $0.outcome == .succeeded })
        } else { #expect(result.samples.isEmpty && result.reads == 0) }
        #expect(OperationTimingScope.gatewayAdmission == nil)
        #expect(await hub.snapshot().subscriptions == 0)
    }

    /// Shared admission waiting is measured before the numeric admission origin is installed for the callback.
    /// - Throws: Unexpected bounded authority, clock, event or dispatcher failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func sharedWaitExcludesAdmittedTime() async throws {
        let clock = ManualClock(), observations = MC29DispatcherObservations()
        let origin = clock.now
        let timing = OperationTiming(sink: observations.record, now: { origin.duration(to: clock.now) })
        let authority = try GatewayHandlerAuthority(maximumActiveHandlers: 1)
        let firstHub = GatewayEventHub(configuration: try .init()), secondHub = GatewayEventHub(configuration: try .init())
        let firstSubscription = try await firstHub.subscribe(), secondSubscription = try await secondHub.subscribe()
        let entered = TestBarrier(), blocked = TestBarrier(), completed = TestBarrier()
        let first = GatewayEventHandlerDispatcher(configuration: try .init(), authority: authority)
        let second = GatewayEventHandlerDispatcher(configuration: try .init(), authority: authority, timing: timing)
        let firstTask = Task {
            try await first.run(subscription: firstSubscription) { _ in entered.open(); try await blocked.wait() }
        }
        await firstHub.publish(try makeDeliveryEvent(1))
        try await entered.wait()
        let secondTask = Task {
            try await second.run(subscription: secondSubscription) { _ in
                #expect(OperationTimingScope.gatewayAdmission == .milliseconds(25))
                completed.open()
            }
        }
        await secondHub.publish(try makeDeliveryEvent(2))
        while await authority.snapshot().waitingHandlers != 1 { try Task.checkCancellation(); await Task.yield() }
        try clock.advance(by: .milliseconds(25))
        blocked.open()
        try await completed.wait()
        await firstHub.finish(); await secondHub.finish()
        try await firstTask.value; try await secondTask.value
        let shared = observations.snapshot().samples.filter { $0.phase == .gatewaySharedAdmission }
        #expect(shared == [OperationTimingSample(phase: .gatewaySharedAdmission, outcome: .succeeded,
            elapsed: .milliseconds(25))])
        #expect(await authority.snapshot().activeHandlers == 0)
        #expect(await authority.snapshot().waitingHandlers == 0)
    }

    /// A cancelled run emits its joined milestone after callbacks, authority release and subscription cleanup finish.
    /// - Throws: Unexpected fixture or synchronization failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func cancellationSampleFollowsJoinedCleanup() async throws {
        let clock = ManualClock(), observations = MC29DispatcherObservations()
        let origin = clock.now
        let timing = OperationTiming(sink: observations.record, now: { origin.duration(to: clock.now) })
        let hub = GatewayEventHub(configuration: try .init()), authority = try GatewayHandlerAuthority(maximumActiveHandlers: 1)
        let subscription = try await hub.subscribe(), cleanup = MC29DispatcherCleanup()
        let entered = TestBarrier(), blocked = TestBarrier(), cleanupEntered = TestBarrier()
        let dispatcher = GatewayEventHandlerDispatcher(configuration: try .init(), authority: authority, timing: timing)
        let task = Task {
            try await dispatcher.run(subscription: subscription) { _ in
                entered.open()
                do { try await blocked.wait() }
                catch { cleanupEntered.open(); await cleanup.wait(); throw error }
            }
        }
        await hub.publish(try makeDeliveryEvent(1))
        try await entered.wait()
        task.cancel()
        try await cleanupEntered.wait()
        #expect(!observations.snapshot().samples.contains { $0.phase == .gatewayRunJoined })
        #expect(await authority.snapshot().activeHandlers == 1)
        try clock.advance(by: .milliseconds(30))
        await cleanup.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(observations.snapshot().samples.last == OperationTimingSample(phase: .gatewayRunJoined,
            outcome: .cancelled, elapsed: .milliseconds(30)))
        #expect(await authority.snapshot().activeHandlers == 0)
        #expect(await hub.snapshot().subscriptions == 0)
    }
}
