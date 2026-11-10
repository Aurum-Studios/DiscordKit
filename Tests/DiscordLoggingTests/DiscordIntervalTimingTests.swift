// File: Tests/DiscordLoggingTests/DiscordIntervalTimingTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordLogging
import Foundation
import Testing

/// Fixed-workload fixture; every clock/record access is synchronized without calling an owner.
private final class IntervalFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: Duration = .zero
    private var reads = 0
    private var events: [DiscordIntervalEvent] = []

    /// Reads and counts the injected clock without advancing it.
    /// - Returns: Current virtual offset.
    func now() -> Duration { lock.withLock { reads += 1; return offset } }

    /// Replaces virtual time, including deliberate invalid/regressing offsets.
    /// - Parameter value: New clock offset, with no monotonicity enforcement in this adversarial fixture.
    func set(_ value: Duration) { lock.withLock { offset = value } }

    /// Advances virtual time to quantify callback inclusion exactly.
    /// - Parameter value: Duration consumed by the fixture work or observer.
    func advance(_ value: Duration) { lock.withLock { offset += value } }

    /// Stores one endpoint within a test's finite population.
    /// - Parameter event: Content-free event produced by an enabled observer.
    func record(_ event: DiscordIntervalEvent) { lock.withLock { events.append(event) } }

    /// Copies the test observations atomically.
    /// - Returns: Endpoint history and exact clock-read count.
    func snapshot() -> (events: [DiscordIntervalEvent], reads: Int) {
        lock.withLock { (events, reads) }
    }

    /// Configures a test observer without consulting the fixture clock or sink.
    /// - Parameter domain: Explicit identity for this fixture's origin.
    /// - Returns: Observer with the fixture's synchronized numeric storage.
    func timing(domain: UInt64 = 1) -> DiscordIntervalTiming {
        DiscordIntervalTiming(clockDomain: domain, sink: record, now: now)
    }
}

/// Proves fixed-size propagation works at an actual actor boundary with explicit numeric context.
private actor IntervalActor {
    /// Emits and ends an owner interval in the caller's task-local context.
    /// - Parameter timing: Enabled observer sharing the parent's clock domain.
    /// - Returns: Context seen inside the actor, without claiming preceding actor queue residence.
    func run(_ timing: DiscordIntervalTiming) -> DiscordIntervalContext {
        let interval = timing.begin(.interactionResponse, stage: .initialResponse)
        interval.end()
        return interval.context
    }
}

/// Deterministic endpoints, concurrency, clock validity and callback-cost contracts.
@Suite("Detailed interval model", .timeLimit(.minutes(1)))
struct DiscordIntervalTimingTests {
    /// Configuration/nil hooks do no clock work; ending repeatedly cannot overwrite the first outcome.
    @Test func disabledAndOnceOnly() {
        let fixture = IntervalFixture(), timing = fixture.timing()
        let disabled: DiscordIntervalTiming? = nil
        disabled?.begin(.rest, stage: .operation).end()
        #expect(fixture.snapshot().events.isEmpty && fixture.snapshot().reads == 0)
        fixture.set(.nanoseconds(10))
        let interval = timing.begin(.rest, stage: .operation)
        fixture.set(.nanoseconds(35))
        interval.end(.uncertain)
        interval.end(.succeeded)
        let snapshot = fixture.snapshot()
        #expect(snapshot.reads == 2)
        #expect(snapshot.events.map(\.kind) == [.began, .ended])
        #expect(snapshot.events.map(\.timestampNanoseconds) == [10, 35])
        #expect(snapshot.events.last?.elapsedNanoseconds == 25)
        #expect(snapshot.events.last?.outcome == .uncertain)
        #expect(snapshot.events.allSatisfy { $0.validity == .valid })
    }

    /// Timestamps precede callbacks; start/child callbacks remain visible in enclosing observed costs.
    @Test func callbackCostsAndNestedBoundaries() throws {
        let fixture = IntervalFixture()
        let timing = DiscordIntervalTiming(clockDomain: 2, sink: { event in
            fixture.record(event)
            fixture.advance(.nanoseconds(event.kind == .began ? 3 : 5))
        }, now: fixture.now)
        let parent = timing.begin(.rest, stage: .operation)
        try DiscordIntervalScope.$context.withValue(parent.context) {
            let child = timing.begin(.httpExchange, stage: .headers, attempt: 1)
            fixture.advance(.nanoseconds(7))
            child.end()
            let terminal = try #require(fixture.snapshot().events.last)
            #expect(terminal.timestampNanoseconds == 13 && terminal.elapsedNanoseconds == 10)
            #expect(terminal.context.parentID == parent.context.operationID)
            #expect(terminal.context.attempt == 1)
        }
        #expect(DiscordIntervalScope.context == nil)
        parent.end()
        let terminal = try #require(fixture.snapshot().events.last)
        #expect(terminal.timestampNanoseconds == 18 && terminal.elapsedNanoseconds == 18)
        #expect(fixture.now() == .nanoseconds(23))
    }

    /// Structured children inherit distinct IDs; detached and delayed callbacks require explicit context.
    /// - Throws: Unexpected missing parent observations.
    @Test func structuredActorAndDetachedPropagation() async throws {
        let fixture = IntervalFixture(), timing = fixture.timing()
        let parent = timing.begin(.rest, stage: .operation, attempt: 4)
        await DiscordIntervalScope.$context.withValue(parent.context) {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        let child = timing.begin(.httpExchange, stage: .body)
                        #expect(child.context.parentID == parent.context.operationID)
                        #expect(child.context.attempt == 4)
                        child.end()
                    }
                }
            }
            let actorContext = await IntervalActor().run(timing)
            #expect(actorContext.parentID == parent.context.operationID)
            await Task.detached {
                #expect(DiscordIntervalScope.context == nil)
                let independent = timing.begin(.httpSubscriber, stage: .subscriber)
                #expect(independent.context.parentID == nil)
                independent.end()
                let restored = timing.begin(.httpExchange, stage: .body, parent: parent.context)
                #expect(restored.context.parentID == parent.context.operationID)
                restored.end()
            }.value
        }
        #expect(DiscordIntervalScope.context == nil)
        parent.end()
        let snapshot = fixture.snapshot()
        let starts = snapshot.events.filter { $0.kind == .began }
        #expect(starts.count == 20)
        #expect(Set(starts.map { $0.context.operationID }).count == starts.count)
        #expect(snapshot.events.filter { $0.kind == .ended }.count == starts.count)
    }

    /// A terminal race performs one clock read and one callback after the initial begin.
    @Test func concurrentEndAndCopiedObserver() async {
        let fixture = IntervalFixture(), timing = fixture.timing(), copy = timing
        let interval = timing.begin(.rest, stage: .operation)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 { group.addTask { interval.end(.cancelled) } }
        }
        #expect(fixture.snapshot().reads == 2)
        #expect(fixture.snapshot().events.map(\.kind) == [.began, .ended])
        let other = copy.begin(.rest, stage: .operation)
        #expect(interval.context.operationID.namespace == other.context.operationID.namespace)
        #expect(interval.context.operationID != other.context.operationID)
        other.end()
    }

    /// Mixed-domain contexts cannot create a parent link or a qualifying finite duration.
    @Test func rejectsMixedClockParent() throws {
        let fixture = IntervalFixture()
        let parent = fixture.timing(domain: 1).begin(.rest, stage: .operation, attempt: 3)
        let child = fixture.timing(domain: 2).begin(.httpExchange, stage: .body, parent: parent.context)
        child.end()
        let event = try #require(fixture.snapshot().events.last)
        #expect(event.context.clockDomain == 2 && event.context.parentID == nil && event.context.attempt == nil)
        #expect(event.validity == .mixedClockDomain && event.elapsedNanoseconds == nil)
        parent.end()
    }

    /// Negative offsets, checked overflow and real regression remain explicitly invalid, including subnanoseconds.
    /// - Parameters:
    ///   - start: Adversarial initial clock value.
    ///   - end: Terminal clock value.
    ///   - validity: Required invalidity classification.
    @Test(arguments: [
        (Duration.nanoseconds(-1), Duration.zero, DiscordIntervalValidity.timestampOutOfRange),
        (.zero, .seconds(Int64.max), .timestampOutOfRange),
        (.seconds(Int64.max), .seconds(Int64.max), .timestampOutOfRange),
        (.nanoseconds(20), .nanoseconds(19), .clockRegression),
        (Duration(secondsComponent: 0, attosecondsComponent: 2),
         Duration(secondsComponent: 0, attosecondsComponent: 1), .clockRegression),
    ]) func invalidClocks(start: Duration, end: Duration, validity: DiscordIntervalValidity) throws {
        let fixture = IntervalFixture(), timing = fixture.timing()
        fixture.set(start)
        let interval = timing.begin(.rest, stage: .operation)
        fixture.set(end)
        interval.end(.failed)
        let event = try #require(fixture.snapshot().events.last)
        #expect(event.validity == validity && event.elapsedNanoseconds == nil)
        #expect(event.outcome == .failed)
    }

    /// The maximum representable endpoint and fractional nanoseconds use checked integer conversion.
    @Test func integerBoundaryAndFraction() throws {
        let fixture = IntervalFixture(), timing = fixture.timing()
        let interval = timing.begin(.rest, stage: .operation)
        fixture.set(.nanoseconds(Int64.max))
        interval.end()
        let event = try #require(fixture.snapshot().events.last)
        #expect(event.timestampNanoseconds == Int64.max && event.elapsedNanoseconds == Int64.max)
        fixture.set(Duration(secondsComponent: 0, attosecondsComponent: 1_999_999_999))
        let fractional = timing.begin(.rest, stage: .operation)
        fractional.end()
        #expect(fixture.snapshot().events.last?.timestampNanoseconds == 1)
        #expect(fixture.snapshot().events.last?.elapsedNanoseconds == 0)
    }

    /// Each result is purely descriptive; an abandoned handle invents no completion on deallocation.
    @Test(arguments: [DiscordIntervalOutcome.succeeded, .failed, .cancelled, .uncertain])
    func explicitOutcomesAndIncompleteHandles(outcome: DiscordIntervalOutcome) {
        let fixture = IntervalFixture(), timing = fixture.timing()
        timing.begin(.rest, stage: .operation).end(outcome)
        _ = timing.begin(.httpExchange, stage: .headers)
        let snapshot = fixture.snapshot()
        #expect(snapshot.events.map(\.kind) == [.began, .ended, .began])
        #expect(snapshot.events[1].outcome == outcome)
        #expect(snapshot.reads == 3)
    }
}
