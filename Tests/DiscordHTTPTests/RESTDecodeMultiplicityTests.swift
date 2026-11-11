// File: Tests/DiscordHTTPTests/RESTDecodeMultiplicityTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordCore
import DiscordTestSupport
import DiscordTransport
import Foundation
import Testing
@testable import DiscordHTTP

/// Finite decoder-count and identity regressions without network requests or timing sleeps.
@Suite("REST decoder multiplicity", .timeLimit(.minutes(1)))
struct RESTDecodeMultiplicityTests {
    /// An unshared response returns its first validated result at representative bounded body sizes.
    /// The reference result makes an accidental second invocation observable independently of byte equality.
    /// - Parameter byteCount: Complete body size, covering 1, 16 and 256 KiB.
    /// - Throws: Unexpected descriptor, scripted-body or execution failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [1_024, 16 * 1_024, 256 * 1_024])
    func unsharedSuccessDecodesOnce(byteCount: Int) async throws {
        let bytes = Data(repeating: 97, count: byteCount), calls = RESTDecoderCalls()
        let clock = ManualClock(), coordinator = RateLimitCoordinator(clock: clock)
        let transport = try ScriptedHTTPTransport(steps: [{ _ in try Self.response(bytes) }])
        let client = RESTClient(credential: .none, identity: .init(), transport: transport,
            coordinator: coordinator, clock: clock)
        let endpoint = try Self.endpoint(calls: calls)
        let result = try await client.execute(endpoint)
        #expect(result.bytes == bytes && result.invocation == 1)
        #expect(calls.count == 1)
        #expect(await transport.executionCount == 1)
        #expect(await coordinator.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
        await coordinator.close()
    }

    /// A cache miss decodes once before retention, and each subsequent cache caller decodes independently.
    /// A coalescing policy without an injected coalescer also follows the unshared fast path.
    /// - Parameter coalescing: Endpoint opt-in; this fixture deliberately has no shared-flight owner.
    /// - Throws: Unexpected descriptor, cache or execution failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true])
    func cacheMissAndHitDecodeOncePerCaller(coalescing: Bool) async throws {
        let bytes = Data("cached".utf8), calls = RESTDecoderCalls(), clock = ManualClock()
        let coordinator = RateLimitCoordinator(clock: clock), cache = ReadCache(clock: clock)
        let transport = try ScriptedHTTPTransport(steps: [{ _ in try Self.response(bytes) }])
        let client = RESTClient(credential: .none, identity: .init(), transport: transport,
            coordinator: coordinator, clock: clock, cache: cache)
        let endpoint = try Self.endpoint(calls: calls,
            readPolicy: .init(coalescing: coalescing, timeToLive: .seconds(10)))
        let first = try await client.execute(endpoint)
        #expect(first.invocation == 1 && first.bytes == bytes && calls.count == 1)
        #expect(await cache.snapshot().entries == 1)
        let second = try await client.execute(endpoint)
        #expect(second.invocation == 2 && second.bytes == bytes && first !== second)
        #expect(calls.count == 2)
        #expect(await transport.executionCount == 1)
        #expect(await coordinator.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
        await cache.removeAll(); await coordinator.close()
    }

    /// Shared ownership validates once before publication, then creates one distinct typed result per caller.
    /// Only bytes enter the cache; a later hit must construct a new result using its current decoder.
    /// - Throws: Unexpected descriptor, shared-flight, scripted-body or execution failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func sharedSubscribersDecodeIndependently() async throws {
        let bytes = Data("shared".utf8), calls = RESTDecoderCalls(), clock = ManualClock()
        let coordinator = RateLimitCoordinator(clock: clock), cache = ReadCache(clock: clock)
        let coalescer = RequestCoalescer(), gate = TestBarrier()
        let transport = try ScriptedHTTPTransport(steps: [{ _ in
            try await gate.wait(); return try Self.response(bytes)
        }])
        let client = RESTClient(credential: .none, identity: .init(), transport: transport,
            coordinator: coordinator, clock: clock, cache: cache, coalescer: coalescer)
        let endpoint = try Self.endpoint(calls: calls, readPolicy: .init(timeToLive: .seconds(10)))
        let tasks = (0..<4).map { _ in Task { try await client.execute(endpoint) } }
        while await coalescer.snapshot().waiters < 4 { try Task.checkCancellation(); await Task.yield() }
        #expect(calls.count == 0)
        gate.open()
        var values: [RESTDecodedFixture] = []
        for task in tasks { values.append(try await task.value) }
        #expect(calls.count == 5)
        #expect(Set(values.map(\.invocation)) == Set(2...5))
        #expect(Set(values.map(ObjectIdentifier.init)).count == 4)
        #expect(values.allSatisfy { $0.bytes == bytes })
        #expect(await cache.snapshot().entries == 1)
        let hit = try await client.execute(endpoint)
        #expect(hit.bytes == bytes && hit.invocation == 6 && calls.count == 6)
        #expect(await transport.executionCount == 1)
        #expect(await coalescer.snapshot().flights == 0)
        #expect(await coalescer.snapshot().waiters == 0)
        #expect(await coordinator.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
        await coalescer.close(); await cache.removeAll(); await coordinator.close()
    }

    /// Cancelling one joined subscriber performs no decoder work for that caller and preserves the survivor.
    /// The held response proves cancellation completes before successful shared-byte validation begins.
    /// - Throws: Unexpected fixture setup, cancellation normalization or survivor failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test func cancelledSubscriberDoesNotDecodeOrCancelSurvivor() async throws {
        let bytes = Data("survivor".utf8), calls = RESTDecoderCalls(), clock = ManualClock()
        let coordinator = RateLimitCoordinator(clock: clock), coalescer = RequestCoalescer()
        let gate = TestBarrier()
        let transport = try ScriptedHTTPTransport(steps: [{ _ in
            try await gate.wait(); return try Self.response(bytes)
        }])
        let client = RESTClient(credential: .none, identity: .init(), transport: transport,
            coordinator: coordinator, clock: clock, coalescer: coalescer)
        let endpoint = try Self.endpoint(calls: calls, readPolicy: .init())
        let cancelled = Task { try await client.execute(endpoint) }
        while await coalescer.snapshot().waiters < 1 { try Task.checkCancellation(); await Task.yield() }
        let survivor = Task { try await client.execute(endpoint) }
        while await coalescer.snapshot().waiters < 2 { try Task.checkCancellation(); await Task.yield() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(calls.count == 0)
        #expect(await coalescer.snapshot().waiters == 1)
        gate.open()
        let result = try await survivor.value
        #expect(result.bytes == bytes && result.invocation == 2 && calls.count == 2)
        #expect(await transport.executionCount == 1)
        #expect(await coalescer.snapshot().flights == 0)
        #expect(await coalescer.snapshot().waiters == 0)
        #expect(await coordinator.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
        await coalescer.close(); await coordinator.close()
    }

    /// A failed owner decoder rejects malformed success bytes before either retention or subscriber decoding.
    /// A second valid exchange can populate the cache, and its later hit still decodes independently.
    /// - Parameter shared: Whether three subscribers join one owner or one caller executes unshared.
    /// - Throws: Unexpected descriptor, shared-flight or successful recovery failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true])
    func malformedSuccessNeverRetained(shared: Bool) async throws {
        let valid = Data("valid".utf8), calls = RESTDecoderCalls(), clock = ManualClock()
        let coordinator = RateLimitCoordinator(clock: clock), cache = ReadCache(clock: clock)
        let coalescer = RequestCoalescer(), gate = TestBarrier()
        let transport = try ScriptedHTTPTransport(steps: [{ _ in
            try await gate.wait(); return try Self.response(Data("malformed".utf8))
        }, { _ in try Self.response(valid) }])
        let client = RESTClient(credential: .none, identity: .init(), transport: transport,
            coordinator: coordinator, clock: clock, cache: cache, coalescer: coalescer)
        let endpoint = try Self.endpoint(calls: calls,
            readPolicy: .init(coalescing: shared, timeToLive: .seconds(10)), acceptedBytes: valid)
        let tasks = (0..<(shared ? 3 : 1)).map { _ in Task { try await client.execute(endpoint) } }
        if shared {
            while await coalescer.snapshot().waiters < 3 { try Task.checkCancellation(); await Task.yield() }
        } else {
            while gate.waitingCount == 0 { try Task.checkCancellation(); await Task.yield() }
        }
        gate.open()
        for task in tasks {
            await #expect(throws: DiscordError.transport(.invalidResponse)) { try await task.value }
        }
        #expect(calls.count == 1)
        #expect(await cache.snapshot().entries == 0)
        #expect(await coalescer.snapshot().flights == 0)
        #expect(await coalescer.snapshot().waiters == 0)
        let recovered = try await client.execute(endpoint)
        #expect(recovered.bytes == valid && recovered.invocation == (shared ? 3 : 2))
        #expect(await cache.snapshot().entries == 1)
        let hit = try await client.execute(endpoint)
        #expect(hit.bytes == valid && hit.invocation == (shared ? 4 : 3))
        #expect(calls.count == (shared ? 4 : 3))
        #expect(await transport.executionCount == 2)
        #expect(await coordinator.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
        await coalescer.close(); await cache.removeAll(); await coordinator.close()
    }

    /// Rejected HTTP attempts do not invoke the success decoder; a permitted retry decodes once on success.
    /// Zero backoff and explicit bucket headroom keep this retry assertion independent of real time.
    /// - Parameter retry: Whether the finite policy permits recovery from a scripted 503.
    /// - Throws: Unexpected descriptor, API classification or successful retry failure.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true])
    func apiFailureDoesNotDecode(retry: Bool) async throws {
        let bytes = Data("recovered".utf8), calls = RESTDecoderCalls(), clock = ManualClock()
        let coordinator = RateLimitCoordinator(clock: clock)
        let transport = try ScriptedHTTPTransport(steps: [{ _ in
            #expect(calls.count == 0)
            return try Self.response(Data(), status: 503)
        }, { _ in
            #expect(calls.count == 0)
            return try Self.response(bytes)
        }])
        let client = RESTClient(credential: .none, identity: .init(), transport: transport,
            coordinator: coordinator, clock: clock,
            retryPolicy: .init(maximumAttempts: retry ? 2 : 1, initialBackoff: .zero, maximumBackoff: .zero))
        let endpoint = try Self.endpoint(calls: calls)
        if retry {
            let result = try await client.execute(endpoint)
            #expect(result.bytes == bytes && result.invocation == 1 && calls.count == 1)
        } else {
            await #expect(throws: APIResponseError.self) { try await client.execute(endpoint) }
            #expect(calls.count == 0)
        }
        #expect(await transport.executionCount == (retry ? 2 : 1))
        #expect(await coordinator.snapshot().activeCount == 0)
        #expect(clock.pendingSleepCount == 0)
        await coordinator.close()
    }

    /// Completion checks still reject cancellation or deadline expiry raised inside the single decoder.
    /// Unsafe submitted mutations preserve their uncertainty category instead of replaying or returning success.
    /// - Parameters:
    ///   - cancelled: Cancels the current decoder task when true; otherwise advances virtual time past the deadline.
    ///   - unsafe: Selects a submitted mutation or a demonstrably safe GET operation.
    /// - Throws: Unexpected descriptor setup or cleanup failure; execution is expected to fail safely.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test(arguments: [false, true], [false, true])
    func decoderCompletionPreservesCancellationAndDeadline(cancelled: Bool, unsafe: Bool) async throws {
        let calls = RESTDecoderCalls(), clock = ManualClock()
        let coordinator = RateLimitCoordinator(clock: clock)
        let transport = try ScriptedHTTPTransport(steps: [{ _ in try Self.response(Data()) }])
        let client = RESTClient(credential: .none, identity: .init(), transport: transport,
            coordinator: coordinator, clock: clock)
        let endpoint = try Endpoint(method: unsafe ? "POST" : "GET", path: ["decode-completion"],
            authentication: .none, retrySafety: unsafe ? .unsafe : .safe, decode: { bytes in
                let invocation = calls.next()
                if cancelled {
                    withUnsafeCurrentTask { $0?.cancel() }
                } else {
                    try clock.advance(by: .seconds(1))
                }
                return RESTDecodedFixture(bytes: bytes, invocation: invocation)
            })
        let task = Task { try await client.execute(endpoint, deadline: clock.now.advanced(by: .milliseconds(100))) }
        if unsafe {
            let expected = DiscordError.unknownMutationOutcome(cancelled ? .cancelledAfterSubmission : .deadlineAfterSubmission)
            await #expect(throws: expected) { try await task.value }
        } else if cancelled {
            await #expect(throws: CancellationError.self) { try await task.value }
        } else {
            await #expect(throws: TransportFailure.deadlineExceeded) { try await task.value }
        }
        #expect(calls.count == 1)
        #expect(await transport.executionCount == 1)
        #expect(await coordinator.snapshot().activeCount == 0)
        #expect(await coordinator.snapshot().orderedOperationsCount == 0)
        #expect(clock.pendingSleepCount == 0)
        await coordinator.close()
    }

    /// Creates a raw local fixture whose decoder counts entries and returns a fresh immutable reference.
    /// - Parameters:
    ///   - calls: Lock-protected invocation owner, shared with deterministic assertions.
    ///   - readPolicy: Optional explicit byte-reuse contract; nil disables reuse.
    ///   - acceptedBytes: Optional exact success body; other bodies throw a secret-bearing fixture error.
    /// - Returns: Safe GET descriptor without authentication or external protocol dependencies.
    /// - Throws: Descriptor validation errors; decoder errors are deliberately normalized by RESTClient.
    private static func endpoint(calls: RESTDecoderCalls, readPolicy: ReadPolicy? = nil,
                                 acceptedBytes: Data? = nil) throws -> Endpoint<RESTDecodedFixture> {
        try Endpoint(method: "GET", path: ["decode-count"], authentication: .none,
            retrySafety: .safe, readPolicy: readPolicy, decode: { bytes in
                let invocation = calls.next()
                if let acceptedBytes, bytes != acceptedBytes {
                    throw TestSupportFailure.scripted("private_decoder_failure")
                }
                return RESTDecodedFixture(bytes: bytes, invocation: invocation)
            })
    }

    /// Creates a single-use materialized response with rate headroom for deterministic recovery exchanges.
    /// - Parameters:
    ///   - bytes: Complete bounded fixture body, including empty bodies.
    ///   - status: Scripted status, default 200.
    /// - Returns: Fresh response body and one consistent synthetic rate bucket.
    /// - Throws: Unexpected request-body fixture validation errors.
    private static func response(_ bytes: Data, status: Int = 200) throws -> HTTPResponse {
        HTTPResponse(status: status, headers: [
            .init(name: "X-RateLimit-Bucket", value: "decode-count"),
            .init(name: "X-RateLimit-Limit", value: "100"),
            .init(name: "X-RateLimit-Remaining", value: "99"),
            .init(name: "X-RateLimit-Reset-After", value: "1")
        ], body: try RequestBody(bytes: bytes, contentType: "application/octet-stream").makeStream())
    }
}

/// Immutable reference whose identity proves typed results are never shared between independent callers.
private final class RESTDecodedFixture: Sendable {
    let bytes: Data
    let invocation: Int

    /// Retains exact decoded bytes and the invocation that created this independent result.
    /// - Parameters:
    ///   - bytes: Complete successful body without transformation.
    ///   - invocation: Positive invocation ordinal allocated atomically by the fixture counter.
    init(bytes: Data, invocation: Int) { self.bytes = bytes; self.invocation = invocation }
}

/// Lock-protected bounded fixture counter; decoder closures remain synchronous and sendable.
private final class RESTDecoderCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    /// Copies the total decoder entries, including deliberately rejected bodies.
    var count: Int { lock.withLock { stored } }

    /// Allocates a unique invocation ordinal without suspending or retaining response payloads.
    /// - Returns: Positive ordinal for this decoder entry.
    func next() -> Int { lock.withLock { stored += 1; return stored } }
}
