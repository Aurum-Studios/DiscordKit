// File: Tests/DiscordGatewayTests/PerformanceDispatcherTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordTestSupport
import Testing
@testable import DiscordGateway

/// Bounded entry observations distinguish FIFO admission from task creation or callback completion.
private actor PerformanceHandlerEntries {
    /// Finite callback entries; callback task creation and subscription admission never append here.
    private var values: [Int64] = []

    /// Records one callback after shared admission succeeds.
    /// - Parameter sequence: The finite fixture's unique event sequence.
    func append(_ sequence: Int64) { values.append(sequence) }

    /// Returns the admitted callback sequence for deterministic order assertions.
    func snapshot() -> [Int64] { values }
}

/// Barrier-driven qualification of bounded handoff and independent subscription progress.
@Suite("Performance dispatcher invariants", .timeLimit(.minutes(1)))
struct PerformanceDispatcherTests {
    /// A long FIFO crosses prefix reclamation while cancellation removes only its own request.
    /// Cancellation before and after reclamation must preserve capacity counts and survivor order;
    /// every callback holds the sole permit until its explicit gate is released.
    /// - Throws: Unexpected event, subscription, dispatcher or barrier failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func queuedCancellationAndFIFOAfterPrefixReclamation() async throws {
        let count = 70
        let authority = try GatewayHandlerAuthority(maximumActiveHandlers: 1, maximumWaitingHandlers: count)
        let dispatcher = GatewayEventHandlerDispatcher(configuration: try .init(), authority: authority)
        let entries = PerformanceHandlerEntries()
        let hubs = try (0...count).map { _ in GatewayEventHub(configuration: try .init()) }
        let started = (0...count).map { _ in TestBarrier() }
        let released = (0...count).map { _ in TestBarrier() }
        var tasks: [Task<Void, any Error>] = []
        for index in 0...count {
            let subscription = try await hubs[index].subscribe()
            let task = Task {
                try await dispatcher.run(subscription: subscription) { event in
                    await entries.append(event.sequence ?? -1)
                    started[index].open()
                    try await released[index].wait()
                }
            }
            tasks.append(task)
            await hubs[index].publish(try makeDeliveryEvent(Int64(index)))
            if index == 0 { try await started[0].wait() }
            else {
                while await authority.snapshot().waitingHandlers != index {
                    try Task.checkCancellation()
                    await Task.yield()
                }
            }
        }
        var cancelled: Set<Int> = [7, 42]
        for index in cancelled {
            tasks[index].cancel()
            await #expect(throws: CancellationError.self) { try await tasks[index].value }
        }
        #expect(await authority.snapshot().waitingHandlers == count - cancelled.count)
        var previous = 0
        for index in 1...count {
            if cancelled.contains(index) { continue }
            released[previous].open()
            try await started[index].wait()
            if index == 66 {
                // The first 64 live waiters have transferred; cancellation now searches the reclaimed suffix.
                tasks[69].cancel()
                await #expect(throws: CancellationError.self) { try await tasks[69].value }
                cancelled.insert(69)
            }
            let expected = (0...index).filter { !cancelled.contains($0) }.map(Int64.init)
            #expect(await entries.snapshot() == expected)
            let state = await authority.snapshot()
            #expect(state.activeHandlers == 1)
            #expect(state.waitingHandlers == (0...count).filter {
                $0 > index && !cancelled.contains($0)
            }.count)
            previous = index
        }
        released[previous].open()
        for hub in hubs { await hub.finish() }
        for index in 0...count where !cancelled.contains(index) { try await tasks[index].value }
        #expect(await authority.snapshot().activeHandlers == 0)
        #expect(await authority.snapshot().waitingHandlers == 0)
        for hub in hubs { #expect(await hub.snapshot().subscriptions == 0) }
    }

    /// A suspended callback can overflow its own input while a fast subscription observes every event.
    /// Publication and the fast consumer progress before callback release; the slow run then surfaces
    /// the exact continuity failure and joins its callback, input task and aggregate permit cleanup.
    /// - Throws: Unexpected fixture failure or continuity behavior.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func slowHandlerOverflowKeepsFastSubscriptionProgressing() async throws {
        let hub = GatewayEventHub(configuration: try .init(maximumEventsPerSubscription: 4))
        let slow = try await hub.subscribe(), fast = try await hub.subscribe()
        let authority = try GatewayHandlerAuthority(maximumActiveHandlers: 1)
        let dispatcher = GatewayEventHandlerDispatcher(configuration: try .init(maximumRetainedEvents: 1),
            authority: authority)
        let entered = TestBarrier(), released = TestBarrier()
        let task = Task {
            try await dispatcher.run(subscription: slow) { event in
                #expect(event.sequence == 1)
                entered.open()
                try await released.wait()
            }
        }
        var iterator = fast.makeAsyncIterator()
        await hub.publish(try makeDeliveryEvent(1))
        #expect(try await iterator.next()?.sequence == 1)
        try await entered.wait()
        for sequence in 2...6 {
            let result = await hub.publish(try makeDeliveryEvent(Int64(sequence)))
            #expect(result.terminated == (sequence == 6 ? 1 : 0))
            #expect(try await iterator.next()?.sequence == Int64(sequence))
        }
        #expect(await authority.snapshot().activeHandlers == 1)
        #expect(await hub.snapshot().bufferedEvents == 0)
        released.open()
        await #expect(throws: GatewayEventDeliveryFailure.resynchronizationRequired) { try await task.value }
        #expect(await authority.snapshot().activeHandlers == 0)
        #expect(await authority.snapshot().waitingHandlers == 0)
        #expect(await hub.snapshot().subscriptions == 1)
        await hub.finish()
        #expect(try await iterator.next() == nil)
        #expect(await hub.snapshot().subscriptions == 0)
    }
}
