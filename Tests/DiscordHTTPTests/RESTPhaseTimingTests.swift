// File: Tests/DiscordHTTPTests/RESTPhaseTimingTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordCore
import DiscordTestSupport
import DiscordTransport
import Foundation
import Testing
@testable import DiscordHTTP

/// Thread-safe finite observer fixture, with independently counted instrumentation-clock reads.
private final class RESTPhaseObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [RESTTimingSample] = []
    private var reads = 0
    /// Records one content-free sample without calling a runtime owner.
    /// - Parameter sample: Fixed phase and existing boundary result.
    func record(_ sample: RESTTimingSample) { lock.withLock { samples.append(sample) } }
    /// Counts one enabled observer clock read; this is independent of protocol-clock reads.
    func read() { lock.withLock { reads += 1 } }
    /// Copies the finite evidence atomically after owned tasks have joined.
    /// - Returns: Samples and instrumentation reads.
    func snapshot() -> (samples: [RESTTimingSample], reads: Int) { lock.withLock { (samples, reads) } }
}

/// Confirms the new pipeline observer is opt-in and measures actual endpoints without changing policies.
@Suite("REST pipeline phase timing", .timeLimit(.minutes(1)))
struct RESTPhaseTimingTests {
    /// Explicit owner entry is observed before pipeline work without changing legacy phase populations.
    /// - Parameter enabled: Whether the separate admission callback is requested.
    /// - Throws: Unexpected fixture or request failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true]) func actualOwnerAdmissionIsIndependent(enabled: Bool) async throws {
        let clock = ManualClock(), origin = clock.now, admissions = RESTOwnerAdmissions()
        let observations = RESTPhaseObservations()
        let callback: (@Sendable (Duration) -> Void)? = enabled ? { @Sendable instant in admissions.record(instant) } : nil
        let observer = RESTTiming(sink: observations.record, now: {
            observations.read(); return origin.duration(to: clock.now)
        }, onOwnerAdmission: callback)
        #expect(observations.snapshot().reads == 0)
        let transport = try ScriptedHTTPTransport(steps: [{ _ in
            #expect(admissions.values == (enabled ? [.nanoseconds(17)] : []))
            return HTTPResponse(status: 204)
        }])
        let coordinator = RateLimitCoordinator(clock: clock)
        let client = RESTClient(credential: .none, identity: RateLimitIdentity(), transport: transport,
            coordinator: coordinator, clock: clock, phaseTiming: observer)
        let endpoint = try Endpoint<Data>(method: "HEAD", path: ["admission"], authentication: .none,
            successStatuses: [204], decode: { $0 })
        try clock.advance(by: .nanoseconds(17))
        #expect(try await client.execute(endpoint).isEmpty)
        #expect(observations.snapshot().samples.map(\.phase) == [.ordering, .construction, .decode, .decode])
        #expect(observations.snapshot().reads == (enabled ? 9 : 8))
        #expect(await coordinator.snapshot().activeCount == 0)
        await coordinator.close()
    }

    /// Construction and decoder clocks stop before their callback; ordering ends before service.
    /// - Parameter enabled: Explicit observer opt-in; nil performs no instrumentation reads.
    /// - Throws: Unexpected virtual-clock advance, setup or execution failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true]) func exactEndpointsAndNilObserver(enabled: Bool) async throws {
        let clock = ManualClock(), observations = RESTPhaseObservations()
        let origin = clock.now
        let observer = RESTTiming(sink: { sample in
            observations.record(sample); try? clock.advance(by: .nanoseconds(5))
        }, now: { observations.read(); return origin.duration(to: clock.now) })
        #expect(observations.snapshot().reads == 0)
        let body = try RequestBody.stream(contentType: "application/octet-stream", maximumBytes: 16) {
            try clock.advance(by: .nanoseconds(7))
            return try BodyStream(maximumChunkBytes: 16, next: { nil }, close: {})
        }
        let endpoint = try Endpoint(method: "POST", path: ["phase-timing"], authentication: .none,
            successStatuses: [204], body: body, retrySafety: .unsafe, decode: { data in
                try clock.advance(by: .nanoseconds(3)); return data
            })
        let transport = try ScriptedHTTPTransport(steps: [{ _ in
            try clock.advance(by: .nanoseconds(11)); return HTTPResponse(status: 204)
        }])
        let coordinator = RateLimitCoordinator(clock: clock)
        let client = RESTClient(credential: .none, identity: RateLimitIdentity(), transport: transport,
            coordinator: coordinator, clock: clock, phaseTiming: enabled ? observer : nil)
        #expect(try await client.execute(endpoint).isEmpty)
        let snapshot = observations.snapshot()
        if enabled {
            #expect(snapshot.samples.map(\.phase) == [.ordering, .construction, .decode, .decode])
            #expect(snapshot.samples.map(\.elapsed) == [.zero, .nanoseconds(7), .nanoseconds(3), .nanoseconds(3)])
            #expect(snapshot.samples.allSatisfy { $0.outcome == .succeeded })
            #expect(snapshot.reads == 8)
            #expect(origin.duration(to: clock.now) == .nanoseconds(44))
        } else {
            #expect(snapshot.samples.isEmpty && snapshot.reads == 0)
            #expect(origin.duration(to: clock.now) == .nanoseconds(24))
        }
        #expect(await coordinator.snapshot().activeCount == 0)
        #expect(await coordinator.snapshot().orderedOperationsCount == 0)
        await coordinator.close()
    }

    /// Failed request construction ends before admission cleanup; invalid responses end their real decoder.
    /// - Parameter constructionFailure: Selects a local builder failure or a remote malformed response.
    /// - Throws: Unexpected fixture setup or error normalization behavior.
    @Test(arguments: [false, true]) func failuresRemainTyped(constructionFailure: Bool) async throws {
        let observations = RESTPhaseObservations(), clock = ContinuousClock()
        let body = try RequestBody.stream(contentType: "application/octet-stream", maximumBytes: 16) {
            if constructionFailure { throw DiscordError.validation(.invalidValue) }
            return try BodyStream(maximumChunkBytes: 16, next: { nil }, close: {})
        }
        let endpoint = try Endpoint<Data>(method: "POST", path: ["phase-failure"], authentication: .none,
            body: body, retrySafety: .unsafe, decode: { _ in throw DiscordError.validation(.invalidValue) })
        let transport = try ScriptedHTTPTransport(steps: [{ _ in HTTPResponse(status: 200) }])
        let coordinator = RateLimitCoordinator(clock: clock)
        let client = RESTClient(credential: .none, identity: RateLimitIdentity(), transport: transport,
            coordinator: coordinator, clock: clock, phaseTiming: RESTTiming(sink: observations.record))
        await #expect(throws: constructionFailure ? DiscordError.validation(.invalidValue) : DiscordError.transport(.invalidResponse)) {
            try await client.execute(endpoint)
        }
        let failed = observations.snapshot().samples.filter { $0.outcome == .failed }
        #expect(failed.map(\.phase) == [constructionFailure ? .construction : .decode])
        #expect(await transport.executionCount == (constructionFailure ? 0 : 1))
        #expect(await coordinator.snapshot().activeCount == 0)
        #expect(await coordinator.snapshot().orderedOperationsCount == 0)
        await coordinator.close()
    }

    /// Fresh cache lookup returns without exchange construction, while both miss and hit are observed.
    /// - Throws: Unexpected fixture construction, cache retention or execution failure.
    @Test func enabledCacheLookupAndFreshHit() async throws {
        let clock = ContinuousClock(), observations = RESTPhaseObservations()
        let coordinator = RateLimitCoordinator(clock: clock), cache = ReadCache(clock: clock)
        let transport = try ScriptedHTTPTransport(steps: [{ _ in HTTPResponse(status: 204) }])
        let client = RESTClient(credential: .none, identity: RateLimitIdentity(), transport: transport,
            coordinator: coordinator, clock: clock, cache: cache, phaseTiming: RESTTiming(sink: observations.record))
        let endpoint = try Endpoint<Data>(method: "GET", path: ["cached-phases"], authentication: .none,
            successStatuses: [204], retrySafety: .safe,
            readPolicy: ReadPolicy(coalescing: false, timeToLive: .seconds(60)), decode: { $0 })
        _ = try await client.execute(endpoint)
        _ = try await client.execute(endpoint)
        #expect(await transport.executionCount == 1)
        #expect(observations.snapshot().samples.map(\.phase) ==
            [.cacheLookup, .construction, .decode, .decode, .cacheLookup, .decode])
        await cache.removeAll(); await coordinator.close()
    }

    /// Cancelling an accepted explicit retry records its real failed sleep and performs no replay.
    /// - Throws: Unexpected fixture setup or cancellation normalization behavior.
    @Test func acceptedRetryCancellationJoins() async throws {
        let clock = ContinuousClock(), observations = RESTPhaseObservations()
        let origin = clock.now
        let transport = try ScriptedHTTPTransport(steps: [{ _ in HTTPResponse(status: 503) }])
        let coordinator = RateLimitCoordinator(clock: clock)
        let observer = RESTTiming(sink: observations.record, now: {
            observations.read(); return origin.duration(to: clock.now)
        })
        let client = RESTClient(credential: .none, identity: RateLimitIdentity(), transport: transport,
            coordinator: coordinator, clock: clock,
            retryPolicy: RetryPolicy(maximumAttempts: 2, initialBackoff: .seconds(10), maximumBackoff: .seconds(10)),
            phaseTiming: observer)
        let endpoint = try Endpoint<Data>(method: "GET", path: ["cancel-backoff"], authentication: .none,
            retrySafety: .safe, decode: { $0 })
        let task = Task { try await client.execute(endpoint) }
        while observations.snapshot().reads < 3 { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let waits = observations.snapshot().samples.filter { $0.phase == .retryWait }
        #expect(waits.count == 1 && waits[0].outcome == .cancelled)
        #expect(await transport.executionCount == 1)
        #expect(await coordinator.snapshot().activeCount == 0)
        await coordinator.close()
    }

    /// Regression is explicitly invalid; a once-only token never calls the sink twice or invents zero latency.
    @Test func regressionAndOnceOnlyTerminal() {
        let observations = RESTPhaseObservations()
        let observer = RESTTiming(sink: observations.record, now: { .nanoseconds(-1) })
        let token = RESTTimingToken(phase: .decode, start: .nanoseconds(1), sink: observations.record,
            now: { .zero })
        token.end(); token.end(error: CancellationError())
        let snapshot = observations.snapshot()
        #expect(snapshot.samples.count == 1)
        #expect(snapshot.samples[0].elapsed == nil && snapshot.samples[0].outcome == .succeeded)
        _ = observer
    }
}

/// Bounded test recorder for absolute admission offsets; no submitted request data is retained.
private final class RESTOwnerAdmissions: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Duration] = []
    /// Copies admission endpoints after synchronous callback delivery.
    var values: [Duration] { lock.withLock { stored } }
    /// Retains one absolute observer-clock endpoint for the finite test.
    /// - Parameter instant: Actual REST execution entry offset.
    func record(_ instant: Duration) { lock.withLock { stored.append(instant) } }
}
