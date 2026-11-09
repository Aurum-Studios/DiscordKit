// File: Tests/DiscordInteractionsTests/MC29ResponderTimingTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordCore
import DiscordModels
import DiscordTestSupport
import DiscordTransport
import Foundation
import Testing
@testable import DiscordInteractions

/// Small synchronous recorder for enabled response observations and disabled-clock assertions.
private final class MC29ResponseObservations: @unchecked Sendable {
    /// Serializes finite fixture observations across sink and deadline children.
    private let lock = NSLock()
    /// Content-free samples retained only for one bounded test.
    private var samples: [OperationTimingSample] = []
    /// Instrumentation clock reads, excluding existing protocol deadline reads.
    private var reads = 0
    /// Appends one fixed-shape sample without actor hops or asynchronous work.
    /// - Parameter sample: Protocol stage, result and duration only.
    func record(_ sample: OperationTimingSample) { lock.withLock { samples.append(sample) } }
    /// Counts one explicit observer clock read.
    func read() { lock.withLock { reads += 1 } }
    /// Copies finite observations atomically.
    /// - Returns: Current samples and instrumentation-read count.
    func snapshot() -> (samples: [OperationTimingSample], reads: Int) { lock.withLock { (samples, reads) } }
}

/// Deliberately cancellation-independent cleanup gate proves a result cannot precede joined cleanup.
private actor MC29ResponseCleanup {
    /// Whether the test owner has released cleanup.
    private var released = false
    /// Sole owned cleanup continuation, if cleanup arrived first.
    private var continuation: CheckedContinuation<Void, Never>?
    /// Waits for explicit owner release even when the sink task has already been cancelled.
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    /// Releases the sole cleanup exactly once, including release-before-wait.
    func release() { released = true; continuation?.resume(); continuation = nil }
}

/// Confirms initial/edit success boundaries without forging Gateway receipt provenance.
@Suite("MC-29 responder timing", .timeLimit(.minutes(1)))
struct MC29ResponderTimingTests {
    /// Public Gateway selection and receipt offsets preserve deadlines but never manufacture trusted socket samples.
    /// - Parameter enabled: Explicit timing opt-in; nil still performs the same acknowledged lifecycle.
    /// - Throws: Unexpected fixture, monotonic clock or response failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true]) func successfulSinkAndOriginalEdit(enabled: Bool) async throws {
        let clock = ManualClock(), observations = MC29ResponseObservations()
        let origin = clock.now, responseClock = InteractionClock(clock)
        let timing = OperationTiming(sink: observations.record, now: {
            observations.read(); return origin.duration(to: clock.now)
        })
        try clock.advance(by: .seconds(1))
        let admission = try InteractionAcknowledgementAdmission()
        let sink = InteractionResponseSink(initial: { _, timeout in
            #expect(timeout == .seconds(2))
            try clock.advance(by: .milliseconds(20))
        }, editOriginal: { _, _ in
            try clock.advance(by: .milliseconds(30))
            return try Message(data: Data(InteractionLifecycleTests.messageJSON.utf8))
        })
        let responder = InteractionResponder(interaction: try InteractionLifecycleTests.interaction(),
            deliveryMode: .gateway, clock: responseClock, sink: sink, admission: admission,
            receivedAt: .zero, timing: enabled ? timing : nil)
        #expect(observations.snapshot().reads == 0)
        try await responder.deferResponse()
        try clock.advance(by: .seconds(1))
        _ = try await responder.editOriginal(InteractionMessageEdit(content: .value("private-final"), deferredResponse: true))
        let result = observations.snapshot()
        if enabled {
            #expect(result.samples.map(\.phase) == [.interactionInitialResponse,
                .interactionAcknowledgementToOriginalEdit, .interactionOriginalEdit])
            #expect(result.samples.map(\.elapsed) == [.milliseconds(20), .milliseconds(1_030), .milliseconds(30)])
            #expect(result.samples.allSatisfy { $0.outcome == .succeeded })
        } else { #expect(result.samples.isEmpty && result.reads == 0) }
        #expect(await responder.snapshot() == .acknowledged(.deferredChannelMessageWithSource))
        #expect(await admission.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
    }

    /// Known no-send rejection and unknown submission remain distinct and never emit successful response samples.
    /// - Parameter uncertain: Whether the sink lacks positive non-submission evidence.
    /// - Throws: Unexpected model, admission or monotonic clock failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true]) func initialFailureClassification(uncertain: Bool) async throws {
        let clock = ManualClock(), observations = MC29ResponseObservations()
        let origin = clock.now
        let timing = OperationTiming(sink: observations.record, now: { origin.duration(to: clock.now) })
        let admission = try InteractionAcknowledgementAdmission()
        let sink = InteractionResponseSink(initial: { _, _ in
            try clock.advance(by: .milliseconds(15))
            if uncertain { throw TestSupportFailure.scripted("private-response-error") }
            throw InteractionDeliveryError.notSubmitted
        })
        let responder = InteractionResponder(interaction: try InteractionLifecycleTests.interaction(),
            deliveryMode: .gateway, clock: InteractionClock(clock), sink: sink, admission: admission, timing: timing)
        await #expect(throws: (any Error).self) { try await responder.deferResponse() }
        #expect(observations.snapshot().samples == [OperationTimingSample(phase: .interactionInitialResponse,
            outcome: uncertain ? .uncertain : .failed, elapsed: .milliseconds(15))])
        #expect(await responder.snapshot() == (uncertain ? .indeterminate : .pending))
        #expect(await admission.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
    }

    /// Cancellation cannot publish a completed response observation while an entered sink still owns cleanup.
    /// - Throws: Unexpected fixture construction or synchronization failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func cancellationObservationWaitsForSinkCleanup() async throws {
        let clock = ManualClock(), observations = MC29ResponseObservations()
        let origin = clock.now
        let timing = OperationTiming(sink: observations.record, now: { origin.duration(to: clock.now) })
        let blocked = TestBarrier(), entered = TestBarrier(), cleanupEntered = TestBarrier()
        let cleanup = MC29ResponseCleanup(), admission = try InteractionAcknowledgementAdmission()
        let sink = InteractionResponseSink(initial: { _, _ in
            entered.open()
            do { try await blocked.wait() }
            catch { cleanupEntered.open(); await cleanup.wait(); throw error }
        })
        let responder = InteractionResponder(interaction: try InteractionLifecycleTests.interaction(),
            deliveryMode: .gateway, clock: InteractionClock(clock), sink: sink, admission: admission, timing: timing)
        let task = Task { try await responder.deferResponse() }
        try await entered.wait()
        task.cancel()
        try await cleanupEntered.wait()
        #expect(observations.snapshot().samples.isEmpty)
        #expect(await admission.snapshot().activeCount == 1)
        try clock.advance(by: .milliseconds(25))
        await cleanup.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(observations.snapshot().samples == [OperationTimingSample(phase: .interactionInitialResponse,
            outcome: .uncertain, elapsed: .milliseconds(25))])
        #expect(await responder.snapshot() == .indeterminate)
        #expect(await admission.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
    }

    /// An indeterminate original edit never publishes successful completion or erases confirmed initial ownership.
    /// - Throws: Unexpected offline model, admission or response fixture failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func uncertainOriginalEditRetainsAcknowledgement() async throws {
        let clock = ManualClock(), observations = MC29ResponseObservations()
        let origin = clock.now
        let timing = OperationTiming(sink: observations.record, now: { origin.duration(to: clock.now) })
        let admission = try InteractionAcknowledgementAdmission()
        let responder = InteractionResponder(interaction: try InteractionLifecycleTests.interaction(),
            deliveryMode: .gateway, clock: InteractionClock(clock),
            sink: InteractionResponseSink(initial: { _, _ in }, editOriginal: { _, _ in
                try clock.advance(by: .milliseconds(18)); throw InteractionDeliveryError.indeterminate
            }), admission: admission, timing: timing)
        try await responder.deferResponse()
        await #expect(throws: InteractionDeliveryError.indeterminate) {
            try await responder.editOriginal(InteractionMessageEdit(content: .value("private-edit"), deferredResponse: true))
        }
        #expect(observations.snapshot().samples.map(\.phase) == [.interactionInitialResponse, .interactionOriginalEdit])
        #expect(observations.snapshot().samples.last == OperationTimingSample(phase: .interactionOriginalEdit,
            outcome: .uncertain, elapsed: .milliseconds(18)))
        #expect(await responder.snapshot() == .acknowledged(.deferredChannelMessageWithSource))
        #expect(await admission.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
    }

    /// Opt-in timing leaves the exact original three-second boundary closed before any response sink runs.
    /// - Throws: Unexpected fixture construction or monotonic clock failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func instrumentationDoesNotExtendInitialDeadline() async throws {
        let clock = ManualClock(), observations = MC29ResponseObservations()
        let origin = clock.now
        let timing = OperationTiming(sink: observations.record, now: { origin.duration(to: clock.now) })
        let admission = try InteractionAcknowledgementAdmission()
        let responder = InteractionResponder(interaction: try InteractionLifecycleTests.interaction(),
            deliveryMode: .gateway, clock: InteractionClock(clock),
            sink: InteractionResponseSink(initial: { _, _ in Issue.record("Expired response must not send") }),
            admission: admission, receivedAt: .zero, timing: timing)
        try clock.advance(by: .seconds(3))
        await #expect(throws: InteractionLifecycleError.deadlineExceeded) { try await responder.deferResponse() }
        #expect(observations.snapshot().samples.map(\.outcome) == [.failed])
        #expect(await responder.snapshot() == .expired)
        #expect(await admission.snapshot().activeCount == 0)
    }
}
