// File: Tests/DiscordInteractionsTests/RuntimeIntervalResponderTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordLogging
import DiscordModels
import DiscordTestSupport
import Foundation
import Testing
@testable import DiscordInteractions

/// Finite numeric endpoint storage shared by sink and deadline children.
private final class ResponderIntervalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DiscordIntervalEvent] = []
    private var reads = 0

    /// Appends one fixed-shape endpoint without asynchronous work.
    func record(_ event: DiscordIntervalEvent) { lock.withLock { events.append(event) } }
    /// Counts only explicit interval-clock reads.
    func read() { lock.withLock { reads += 1 } }
    /// Copies endpoints and clock-read count atomically.
    func snapshot() -> (events: [DiscordIntervalEvent], reads: Int) { lock.withLock { (events, reads) } }
}

/// Explicit cleanup owner independent of sink cancellation.
private actor ResponderIntervalCleanup {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    /// Waits until the fixture owner releases sink cleanup.
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    /// Completes the sole cleanup waiter once.
    func release() { released = true; continuation?.resume(); continuation = nil }
}

/// Response interval endpoints preserve acknowledgement uncertainty, deadlines and joined cleanup.
@Suite("Runtime responder intervals", .timeLimit(.minutes(1)))
struct RuntimeIntervalResponderTests {
    /// Response sinks receive the actual stage context; public receipt offsets create no historical begins.
    /// - Parameter enabled: Independent detailed observation opt-in.
    /// - Throws: Unexpected model, response or virtual-clock failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true]) func successfulStagesAndDisabledClock(enabled: Bool) async throws {
        let clock = ManualClock(), recorder = ResponderIntervalRecorder(), origin = clock.now
        let responseClock = InteractionClock(clock)
        let intervals = DiscordIntervalTiming(clockDomain: 71, sink: recorder.record, now: {
            recorder.read(); return origin.duration(to: clock.now)
        })
        try clock.advance(by: .seconds(1))
        let admission = try InteractionAcknowledgementAdmission()
        let sink = InteractionResponseSink(initial: { _, timeout in
            #expect(timeout == .seconds(2))
            #expect((DiscordIntervalScope.context != nil) == enabled)
            try clock.advance(by: .milliseconds(20))
        }, editOriginal: { _, _ in
            #expect((DiscordIntervalScope.context != nil) == enabled)
            try clock.advance(by: .milliseconds(30))
            return try Message(data: Data(InteractionLifecycleTests.messageJSON.utf8))
        })
        let responder = InteractionResponder(interaction: try InteractionLifecycleTests.interaction(),
            deliveryMode: .gateway, clock: responseClock, sink: sink, admission: admission,
            receivedAt: .zero, intervals: enabled ? intervals : nil)
        #expect(recorder.snapshot().reads == 0)
        try await responder.deferResponse()
        _ = try await responder.editOriginal(InteractionMessageEdit(content: .value("fixture-final"), deferredResponse: true))
        let result = recorder.snapshot(), events = result.events
        if enabled {
            let terminal = events.filter { $0.kind == .ended }
            #expect(terminal.map(\.stage) == [.admission, .initialResponse, .originalEdit])
            #expect(terminal.map(\.elapsedNanoseconds) == [0, 20_000_000, 30_000_000])
            #expect(terminal.allSatisfy { $0.outcome == .succeeded && $0.validity == .valid })
            #expect(events.first?.timestampNanoseconds == 1_000_000_000)
            #expect(events.allSatisfy { $0.operation == .interactionResponse })
            let initial = events.first { $0.kind == .began && $0.stage == .initialResponse }
            #expect(events.first { $0.stage == .admission }?.context.parentID == initial?.context.operationID)
        } else { #expect(events.isEmpty && result.reads == 0) }
        #expect(DiscordIntervalScope.context == nil)
        #expect(await admission.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
    }

    /// Known no-send rejection and unknown send failure retain different terminal outcomes.
    /// - Parameter uncertain: Whether sink entry lacks positive non-submission evidence.
    /// - Throws: Unexpected model or clock failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true]) func failureClassification(uncertain: Bool) async throws {
        let clock = ManualClock(), recorder = ResponderIntervalRecorder(), origin = clock.now
        let intervals = DiscordIntervalTiming(clockDomain: 72, sink: recorder.record,
            now: { origin.duration(to: clock.now) })
        let admission = try InteractionAcknowledgementAdmission()
        let responder = InteractionResponder(interaction: try InteractionLifecycleTests.interaction(),
            deliveryMode: .gateway, clock: InteractionClock(clock), sink: InteractionResponseSink(initial: { _, _ in
                try clock.advance(by: .milliseconds(15))
                if uncertain { throw TestSupportFailure.scripted("fixture-send-failure") }
                throw InteractionDeliveryError.notSubmitted
            }), admission: admission, intervals: intervals)
        await #expect(throws: (any Error).self) { try await responder.deferResponse() }
        let events = recorder.snapshot().events
        #expect(events.last?.stage == .initialResponse)
        #expect(events.last?.outcome == (uncertain ? .uncertain : .failed))
        #expect(events.last?.elapsedNanoseconds == 15_000_000)
        #expect(events.filter { $0.kind == .began }.count == events.filter { $0.kind == .ended }.count)
        #expect(await responder.snapshot() == (uncertain ? .indeterminate : .pending))
        #expect(await admission.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
    }

    /// An uncertain edit closes once after continuation release and preserves confirmed acknowledgement.
    /// - Throws: Unexpected model, acknowledgement or virtual-clock failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func uncertainOriginalEdit() async throws {
        let clock = ManualClock(), recorder = ResponderIntervalRecorder(), origin = clock.now
        let intervals = DiscordIntervalTiming(clockDomain: 77, sink: recorder.record,
            now: { origin.duration(to: clock.now) })
        let admission = try InteractionAcknowledgementAdmission()
        let responder = InteractionResponder(interaction: try InteractionLifecycleTests.interaction(),
            deliveryMode: .gateway, clock: InteractionClock(clock), sink: InteractionResponseSink(initial: { _, _ in },
                editOriginal: { _, _ in
                    try clock.advance(by: .milliseconds(18)); throw InteractionDeliveryError.indeterminate
                }), admission: admission, intervals: intervals)
        try await responder.deferResponse()
        await #expect(throws: InteractionDeliveryError.indeterminate) {
            try await responder.editOriginal(InteractionMessageEdit(content: .value("fixture-edit"), deferredResponse: true))
        }
        let edits = recorder.snapshot().events.filter { $0.stage == .originalEdit }
        #expect(edits.map(\.kind) == [.began, .ended])
        #expect(edits.last?.outcome == .uncertain && edits.last?.elapsedNanoseconds == 18_000_000)
        #expect(await responder.snapshot() == .acknowledged(.deferredChannelMessageWithSource))
        #expect(await admission.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
    }

    /// Cancellation and the exact deadline race close only after entered sink cleanup and admission release.
    /// - Parameter deadline: True races the response deadline; false cancels its calling task.
    /// - Throws: Unexpected fixture or synchronization failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true]) func terminalWaitsForCleanup(deadline: Bool) async throws {
        let clock = ManualClock(), recorder = ResponderIntervalRecorder(), origin = clock.now
        let intervals = DiscordIntervalTiming(clockDomain: 73, sink: recorder.record,
            now: { origin.duration(to: clock.now) })
        let entered = TestBarrier(), blocked = TestBarrier(), cleanupEntered = TestBarrier()
        let cleanup = ResponderIntervalCleanup(), admission = try InteractionAcknowledgementAdmission()
        let responder = InteractionResponder(interaction: try InteractionLifecycleTests.interaction(),
            deliveryMode: .gateway, clock: InteractionClock(clock), sink: InteractionResponseSink(initial: { _, _ in
                entered.open()
                do { try await blocked.wait() }
                catch { cleanupEntered.open(); await cleanup.wait(); throw error }
            }), admission: admission, intervals: intervals)
        let task = Task { try await responder.deferResponse() }
        try await entered.wait()
        if deadline {
            while clock.pendingSleepCount != 1 { try Task.checkCancellation(); await Task.yield() }
            try clock.advance(by: .seconds(3))
        } else { task.cancel() }
        try await cleanupEntered.wait()
        #expect(!recorder.snapshot().events.contains { $0.kind == .ended && $0.stage == .initialResponse })
        #expect(await admission.snapshot().activeCount == 1)
        try clock.advance(by: .milliseconds(25)); await cleanup.release()
        await #expect(throws: (any Error).self) { try await task.value }
        let events = recorder.snapshot().events
        #expect(events.last?.outcome == .uncertain)
        #expect(events.last?.elapsedNanoseconds == (deadline ? 3_025_000_000 : 25_000_000))
        #expect(events.filter { $0.kind == .ended && $0.stage == .initialResponse }.count == 1)
        #expect(await responder.snapshot() == .indeterminate)
        #expect(await admission.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
    }

    /// Pre-cancellation stops before admission, preserving pending ownership and closing only the initial stage.
    /// - Throws: Unexpected model or finite admission construction failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func cancellationBeforeSink() async throws {
        let clock = ManualClock(), recorder = ResponderIntervalRecorder()
        let intervals = DiscordIntervalTiming(clockDomain: 74, sink: recorder.record, now: { .zero })
        let admission = try InteractionAcknowledgementAdmission()
        let responder = InteractionResponder(interaction: try InteractionLifecycleTests.interaction(),
            deliveryMode: .gateway, clock: InteractionClock(clock), sink: InteractionResponseSink(initial: { _, _ in
                Issue.record("Cancelled response must not enter its sink")
            }), admission: admission, intervals: intervals)
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; try await responder.deferResponse() }
        await #expect(throws: CancellationError.self) { try await task.value }
        let events = recorder.snapshot().events
        #expect(events.map(\.kind) == [.began, .ended])
        #expect(events.last?.outcome == .cancelled)
        #expect(await responder.snapshot() == .pending)
        #expect(await admission.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
    }

    /// Synchronous begin-observer cost remains inside the real deadline and cannot authorize a late send.
    /// - Throws: Unexpected fixture construction failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func observerCostCanConsumeTheDeadline() async throws {
        let clock = ManualClock(), recorder = ResponderIntervalRecorder(), origin = clock.now
        let intervals = DiscordIntervalTiming(clockDomain: 75, sink: { event in
            recorder.record(event)
            if event.kind == .began && event.stage == .initialResponse {
                do { try clock.advance(by: .seconds(3)) }
                catch { Issue.record("Fixture clock must accept its finite forward step") }
            }
        }, now: { origin.duration(to: clock.now) })
        let admission = try InteractionAcknowledgementAdmission()
        let responder = InteractionResponder(interaction: try InteractionLifecycleTests.interaction(),
            deliveryMode: .gateway, clock: InteractionClock(clock), sink: InteractionResponseSink(initial: { _, _ in
                Issue.record("Expired response must not invoke its sink")
            }), admission: admission, intervals: intervals)
        await #expect(throws: InteractionLifecycleError.deadlineExceeded) { try await responder.deferResponse() }
        let events = recorder.snapshot().events
        #expect(events.map(\.kind) == [.began, .ended])
        #expect(events.first?.timestampNanoseconds == 0)
        #expect(events.last?.elapsedNanoseconds == 3_000_000_000)
        #expect(events.last?.outcome == .failed)
        #expect(await responder.snapshot() == .expired)
        #expect(await admission.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
    }

    /// An auto-defer timer carries handler context into its response and cannot finish the active handler.
    /// - Throws: Unexpected model, response or deferral-policy failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func autoDeferHandlerContextAndTimerCleanup() async throws {
        let clock = ManualClock(), recorder = ResponderIntervalRecorder(), origin = clock.now
        let intervals = DiscordIntervalTiming(clockDomain: 76, sink: recorder.record,
            now: { origin.duration(to: clock.now) })
        let admission = try InteractionAcknowledgementAdmission()
        let responder = InteractionResponder(interaction: try InteractionLifecycleTests.interaction(),
            deliveryMode: .gateway, clock: InteractionClock(clock), sink: InteractionResponseSink(initial: { _, _ in
                try clock.advance(by: .milliseconds(11))
            }), admission: admission, intervals: intervals)
        let entered = TestBarrier(), blocked = TestBarrier()
        let task = Task {
            try await responder.runWithAutoDefer(policy: .init(mode: .message(ephemeral: true))) {
                #expect(DiscordIntervalScope.context?.operationID == recorder.snapshot().events.first?.context.operationID)
                entered.open(); try await blocked.wait()
                return 42
            }
        }
        try await entered.wait()
        while clock.pendingSleepCount != 1 { try Task.checkCancellation(); await Task.yield() }
        try clock.advance(by: .seconds(2))
        while !recorder.snapshot().events.contains(where: { $0.kind == .ended && $0.stage == .initialResponse }) {
            try Task.checkCancellation(); await Task.yield()
        }
        #expect(!recorder.snapshot().events.contains { $0.kind == .ended && $0.stage == .handler })
        #expect(await admission.snapshot().activeCount == 0)
        try clock.advance(by: .milliseconds(5)); blocked.open()
        #expect(try await task.value == 42)
        let events = recorder.snapshot().events
        let handler = events.first { $0.kind == .began && $0.stage == .handler }
        #expect(events.first { $0.stage == .initialResponse }?.context.parentID == handler?.context.operationID)
        #expect(events.last?.stage == .handler && events.last?.outcome == .succeeded)
        #expect(events.last?.elapsedNanoseconds == 2_016_000_000)
        #expect(events.filter { $0.kind == .began }.count == events.filter { $0.kind == .ended }.count)
        #expect(await admission.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
    }
}
