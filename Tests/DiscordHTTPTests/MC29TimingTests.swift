// File: Tests/DiscordHTTPTests/MC29TimingTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordCore
import DiscordTestSupport
import DiscordTransport
import Foundation
import Testing
@testable import DiscordHTTP

/// Bounded thread-safe offline recorder; no application, route, token or body enters recorded samples.
private final class MC29HTTPObservations: @unchecked Sendable {
    /// Protects the small per-test sample array and timing-clock counter.
    private let lock = NSLock()
    /// Samples retained only by this finite fixture.
    private var samples: [OperationTimingSample] = []
    /// Number of explicit instrumentation-clock reads.
    private var clockReads = 0

    /// Adds a sample synchronously, as required by the observer contract.
    /// - Parameter sample: Fixed phase, outcome and duration only.
    func record(_ sample: OperationTimingSample) { lock.withLock { samples.append(sample) } }
    /// Counts an instrumentation-clock read without consulting protocol state.
    func read() { lock.withLock { clockReads += 1 } }
    /// Copies bounded observations atomically for deterministic assertions.
    /// - Returns: Samples and clock-read count from one lock acquisition.
    func snapshot() -> (samples: [OperationTimingSample], reads: Int) {
        lock.withLock { (samples, clockReads) }
    }
}

/// Cancellation-independent bounded body cleanup proves observations cannot outrun resource ownership.
private actor MC29HTTPCleanup {
    /// Whether the fixture owner has released cleanup.
    private var released = false
    /// Sole body-cleanup continuation, resumed exactly once.
    private var continuation: CheckedContinuation<Void, Never>?
    /// Waits for explicit release even after the operation task has been cancelled.
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    /// Releases cleanup once, including release-before-wait.
    func release() { released = true; continuation?.resume(); continuation = nil }
}

/// Direct REST timing tests separate shared wire work from independently cancelled subscribers.
@Suite("MC-29 HTTP timing", .timeLimit(.minutes(1)))
struct MC29TimingTests {
    /// Header and body intervals preserve body-close ownership, while disabled observers read no timing clock.
    /// - Parameter enabled: Explicit instrumentation opt-in; disabled still executes the identical request.
    /// - Throws: Unexpected injected transport, body or clock failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true]) func headersBodyAndNilClock(enabled: Bool) async throws {
        let clock = ManualClock(), observations = MC29HTTPObservations()
        let origin = clock.now
        let timing = OperationTiming(sink: observations.record, now: {
            observations.read(); return origin.duration(to: clock.now)
        })
        #expect(observations.snapshot().reads == 0)
        let body = try BodyStream(maximumChunkBytes: 1, next: {
            try clock.advance(by: .milliseconds(30)); return nil
        }, close: { try? clock.advance(by: .milliseconds(40)) })
        let transport = try ScriptedHTTPTransport(steps: [{ _ in
            try clock.advance(by: .milliseconds(20))
            return HTTPResponse(status: 204, body: body)
        }])
        let coordinator = RateLimitCoordinator(clock: clock)
        let client = RESTClient(credential: .none, identity: RateLimitIdentity(), transport: transport,
            coordinator: coordinator, clock: clock, timing: enabled ? timing : nil)
        let endpoint = try Endpoint(method: "GET", path: ["timing"], authentication: .none,
            successStatuses: [204], retrySafety: .safe, decode: { $0 })
        let bytes = try await client.execute(endpoint)
        #expect(bytes.isEmpty)
        let result = observations.snapshot()
        if enabled {
            #expect(result.samples.map(\.phase) == [.httpAdmission, .httpHeaders, .httpBody, .httpExecutionJoined])
            #expect(result.samples.map(\.elapsed) == [.zero, .milliseconds(20), .milliseconds(70), .milliseconds(90)])
            #expect(result.samples.allSatisfy { $0.outcome == .succeeded })
            #expect(result.reads > 0)
        } else {
            #expect(result.samples.isEmpty && result.reads == 0)
        }
        #expect(await coordinator.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
        await coordinator.close()
    }

    /// A cancelled subscriber reports its own wait without terminating a still-needed shared exchange.
    /// - Throws: Unexpected request, synchronization or clock failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func coalescedSubscribersDoNotDuplicateExchangeSamples() async throws {
        let clock = ManualClock(), observations = MC29HTTPObservations(), blocked = TestBarrier()
        let origin = clock.now
        let timing = OperationTiming(sink: observations.record, now: { origin.duration(to: clock.now) })
        let transport = try ScriptedHTTPTransport(steps: [{ _ in
            try await blocked.wait()
            return HTTPResponse(status: 204)
        }])
        let coordinator = RateLimitCoordinator(clock: clock), coalescer = RequestCoalescer()
        let client = RESTClient(credential: .none, identity: RateLimitIdentity(), transport: transport,
            coordinator: coordinator, clock: clock, coalescer: coalescer, timing: timing)
        let endpoint = try Endpoint(method: "GET", path: ["shared-timing"], authentication: .none,
            successStatuses: [204], retrySafety: .safe, readPolicy: .init(), decode: { $0 })
        let first = Task { try await client.execute(endpoint) }
        while blocked.waitingCount == 0 { try Task.checkCancellation(); await Task.yield() }
        let second = Task { try await client.execute(endpoint) }
        while await coalescer.snapshot().waiters < 2 { try Task.checkCancellation(); await Task.yield() }
        try clock.advance(by: .milliseconds(10))
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(await coalescer.snapshot().waiters == 1)
        #expect(observations.snapshot().samples.filter { $0.phase == .httpHeaders }.isEmpty)
        try clock.advance(by: .milliseconds(20))
        blocked.open()
        let bytes = try await first.value
        #expect(bytes.isEmpty)
        let samples = observations.snapshot().samples
        #expect(samples.filter { $0.phase == .httpAdmission }.count == 1)
        #expect(samples.filter { $0.phase == .httpHeaders }.count == 1)
        #expect(samples.filter { $0.phase == .httpBody }.count == 1)
        #expect(samples.filter { $0.phase == .httpCoalescedSubscriber }.map(\.outcome) == [.cancelled, .succeeded])
        #expect(samples.filter { $0.phase == .httpCoalescedSubscriber }.map(\.elapsed) == [.milliseconds(10), .milliseconds(30)])
        #expect(await transport.executionCount == 1)
        #expect(await coordinator.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
        await coalescer.close(); await coordinator.close()
    }

    /// Body and whole-call cancellation samples wait for response cleanup and rate-reservation release.
    /// - Throws: Unexpected fixture, body or synchronization failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func cancellationSamplesFollowBodyCleanup() async throws {
        let clock = ManualClock(), observations = MC29HTTPObservations()
        let origin = clock.now
        let timing = OperationTiming(sink: observations.record, now: { origin.duration(to: clock.now) })
        let entered = TestBarrier(), blocked = TestBarrier(), cleanupEntered = TestBarrier()
        let cleanup = MC29HTTPCleanup()
        let body = try BodyStream(maximumChunkBytes: 1, next: {
            entered.open(); try await blocked.wait(); return nil
        }, close: { cleanupEntered.open(); await cleanup.wait() })
        let transport = try ScriptedHTTPTransport(steps: [{ _ in HTTPResponse(status: 204, body: body) }])
        let coordinator = RateLimitCoordinator(clock: clock)
        let client = RESTClient(credential: .none, identity: RateLimitIdentity(), transport: transport,
            coordinator: coordinator, clock: clock, timing: timing)
        let endpoint = try Endpoint(method: "GET", path: ["cancel-body"], authentication: .none,
            successStatuses: [204], retrySafety: .safe, decode: { $0 })
        let task = Task { try await client.execute(endpoint) }
        try await entered.wait()
        task.cancel()
        try await cleanupEntered.wait()
        #expect(!observations.snapshot().samples.contains { $0.phase == .httpBody || $0.phase == .httpExecutionJoined })
        #expect(await coordinator.snapshot().activeCount == 1)
        try clock.advance(by: .milliseconds(7))
        await cleanup.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        let samples = observations.snapshot().samples
        #expect(samples.filter { $0.phase == .httpBody || $0.phase == .httpExecutionJoined }.map(\.outcome) == [.cancelled, .cancelled])
        #expect(samples.last?.elapsed == .milliseconds(7))
        #expect(await coordinator.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
        await coordinator.close()
    }

    /// Potentially submitted unsafe sends remain uncertain and emit no successful header/body boundary.
    /// - Throws: Unexpected fixture construction or clock failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func unsafeUncertaintyNeverBecomesSuccess() async throws {
        let clock = ManualClock(), observations = MC29HTTPObservations()
        let origin = clock.now
        let timing = OperationTiming(sink: observations.record, now: { origin.duration(to: clock.now) })
        let transport = try ScriptedHTTPTransport(steps: [{ _ in
            try clock.advance(by: .milliseconds(12))
            throw TestSupportFailure.scripted("private-error-must-not-enter-sample")
        }])
        let coordinator = RateLimitCoordinator(clock: clock)
        let client = RESTClient(credential: .none, identity: RateLimitIdentity(), transport: transport,
            coordinator: coordinator, clock: clock, timing: timing)
        let endpoint = try Endpoint(method: "POST", path: ["private-route"], authentication: .none, decode: { $0 })
        await #expect(throws: DiscordError.unknownMutationOutcome(.connectionLostAfterSubmission)) {
            try await client.execute(endpoint)
        }
        let samples = observations.snapshot().samples
        #expect(samples.map(\.phase) == [.httpAdmission, .httpHeaders, .httpExecutionJoined])
        #expect(samples.map(\.outcome) == [.succeeded, .uncertain, .uncertain])
        #expect(samples.last?.elapsed == .milliseconds(12))
        #expect(!String(reflecting: samples).contains("private-"))
        #expect(await transport.executionCount == 1)
        #expect(await coordinator.snapshot().activeCount == 0)
        await coordinator.close()
    }
}
