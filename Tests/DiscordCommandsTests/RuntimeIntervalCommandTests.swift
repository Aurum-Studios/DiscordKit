// File: Tests/DiscordCommandsTests/RuntimeIntervalCommandTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordCore
import DiscordLogging
import DiscordTestSupport
import Foundation
import Testing
@testable import DiscordCommands

/// Route caller entry includes its actor hop; preparation and handler remain independent owned work.
@Suite(.timeLimit(.minutes(1))) struct RuntimeIntervalCommandTests {
    /// Measures synchronous argument preparation independently and releases admission after success or failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true]) func preparationFailureAndRecovery(fail: Bool) async throws {
        let clock = ManualClock(), origin = clock.now, events = CommandIntervalEvents()
        let intervals = DiscordIntervalTiming(clockDomain: 604, sink: events.record, now: { origin.duration(to: clock.now) })
        let route = CommandRoute(key: try .command(name: "ping"), prepare: { _ in
            try clock.advance(by: .milliseconds(3))
            if fail { throw DiscordError.validation(.invalidValue) }
            return { try clock.advance(by: .milliseconds(7)) }
        })
        let router = try CommandRouter(routes: [route], intervals: intervals)
        let context = try CommandsTestFixtures.context(type: 2, data: CommandsTestFixtures.commandData())
        if fail {
            await #expect(throws: DiscordError.validation(.invalidValue)) { try await router.route(context) }
        } else { #expect(try await router.route(context)) }
        let ended = events.values.filter { $0.kind == .ended }
        #expect(ended.filter { $0.stage == .preparation }.map(\.elapsedNanoseconds) == [3_000_000])
        #expect(ended.filter { $0.stage == .operation }.map(\.elapsedNanoseconds) == [fail ? 3_000_000 : 10_000_000])
        #expect(ended.filter { $0.stage == .handler }.count == (fail ? 0 : 1))
        #expect(ended.last?.outcome == (fail ? .failed : .succeeded))
        #expect(events.values.filter { $0.kind == .began }.count == ended.count)
        let parent = events.values.first { $0.stage == .operation }?.context.operationID
        #expect(events.values.filter { $0.stage != .operation }.allSatisfy { $0.context.parentID == parent })
        #expect(await router.activeHandlerCount == 0)
    }

    /// Proves fail-fast overload and cancellation terminate every interval after handler ownership releases.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func overloadAndCancellationJoin() async throws {
        let events = CommandIntervalEvents(), entered = TestBarrier(), blocked = TestBarrier()
        let intervals = DiscordIntervalTiming(clockDomain: 605, sink: events.record, now: { .zero })
        let router = try CommandRouter(routes: [.init(key: .command(name: "ping"), handler: { _ in
            entered.open(); try await blocked.wait()
        })], maximumConcurrentHandlers: 1, intervals: intervals)
        let context = try CommandsTestFixtures.context(type: 2, data: CommandsTestFixtures.commandData())
        let task = Task { try await router.route(context) }
        try await entered.wait()
        await #expect(throws: DiscordError.validation(.limitExceeded)) { try await router.route(context) }
        #expect(await router.activeHandlerCount == 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await router.activeHandlerCount == 0)
        let ended = events.values.filter { $0.kind == .ended }
        #expect(ended.filter { $0.stage == .admission }.map(\.outcome) == [.succeeded, .failed])
        #expect(ended.filter { $0.stage == .operation }.map(\.outcome) == [.failed, .cancelled])
        #expect(ended.filter { $0.stage == .handler }.map(\.outcome) == [.cancelled])
        #expect(events.values.filter { $0.kind == .began }.count == ended.count)
    }
}

private final class CommandIntervalEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DiscordIntervalEvent] = []
    /// Copies an independent endpoint snapshot under the recorder lock.
    var values: [DiscordIntervalEvent] { lock.withLock { stored } }
    /// Records one finite test endpoint synchronously.
    func record(_ event: DiscordIntervalEvent) { lock.withLock { stored.append(event) } }
}
