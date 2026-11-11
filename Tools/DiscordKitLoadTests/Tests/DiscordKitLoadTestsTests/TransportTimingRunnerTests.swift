// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/TransportTimingRunnerTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

@testable import DiscordKitLoadTests
import DiscordBenchmarkSupport
import DiscordNIOTransport
import DiscordTransport
import Foundation
import Testing

/// Exact caller boundaries, whole-population accounting and joined bounded ownership.
@Suite("Corrected transport timing")
struct TransportTimingRunnerTests {
    private let url = URL(string: "http://127.0.0.1:8080/payload")!

    /// Versioned controls hold complete immediate payload bytes fixed while varying
    /// only response chunk size; legacy native and scripted defaults stay intact.
    @Test func versionedChunkDimensionsPreserveLegacyFixtures() {
        #expect(TransportTimingCase.body64KiBChunk257V1.responseBytes == 65_536)
        #expect(TransportTimingCase.body64KiBChunk65536V1.responseBytes == 65_536)
        #expect(TransportTimingCase.body64KiBChunk257V1.responseChunkBytes == 257)
        #expect(TransportTimingCase.body64KiBChunk65536V1.responseChunkBytes == 65_536)
        for scenario in TransportTimingCase.allCases {
            if scenario == .body64KiBChunk257V1 || scenario == .body64KiBChunk65536V1 {
                #expect(scenario.uploadBytes == 0 && scenario.uploadChunkBytes == 1)
                #expect(scenario.scriptedResponseChunkBytes == scenario.responseChunkBytes)
            } else {
                #expect(scenario.responseChunkBytes == 16_384)
                #expect(scenario.scriptedResponseChunkBytes == (scenario == .streamedBody ? 1_024 : max(1, scenario.responseBytes)))
            }
        }
    }

    /// Scripted controls expose exact bounded chunks, including the odd control's
    /// one-byte final chunk, without peer delays, upload work or native resources.
    /// - Parameter scenario: One versioned fixed-byte response chunk control.
    /// - Throws: Fixture construction or unexpected body-read failure.
    @Test(arguments: [TransportTimingCase.body64KiBChunk257V1, .body64KiBChunk65536V1])
    func scriptedChunkControlsEmitExactPayload(scenario: TransportTimingCase) async throws {
        let response = try await ScriptedTimingTransport(scenario: scenario).execute(
            HTTPRequest(method: "GET", url: url), context: TransportContext(clock: ContinuousClock()))
        let body = try #require(response.body)
        do {
            var lengths: [Int] = [], received = Data()
            for try await chunk in body {
                #expect(chunk.count <= scenario.responseChunkBytes)
                lengths.append(chunk.count); received.append(chunk)
            }
            #expect(received == Data(repeating: 120, count: 65_536))
            #expect(lengths == (scenario == .body64KiBChunk257V1 ? Array(repeating: 257, count: 255) + [1] : [65_536]))
        } catch { await body.close(); throw error }
        await body.close()
    }

    /// One local immediate response per supported native adapter checks that both
    /// chunk controls reach the same payload and join all adapter/socket ownership.
    /// - Parameter scenario: One versioned fixed-byte response chunk control.
    /// - Throws: Local Python peer startup, adapter configuration or execution failure.
    @Test(arguments: [TransportTimingCase.body64KiBChunk257V1, .body64KiBChunk65536V1])
    func nativeChunkControlsCloseOwnedResources(scenario: TransportTimingCase) async throws {
        var adapters: [TransportTimingAdapter] = [.nio]
        #if canImport(Darwin)
        adapters.append(.foundation)
        #endif
        for adapter in adapters {
            let result = try await TransportTimingNativeSuite().run(adapter: adapter, scenario: scenario,
                requests: 1, concurrency: 1, warmupRequests: 0)
            #expect(result.counts.offered == 1 && result.counts.completed == 1)
            #expect(result.counts.outcomes[.success] == 1)
            #expect(result.receivedBytes == 65_536 && result.uploadedBytes == 0)
            #expect(result.cleanup.ownedAdaptersClosed)
            #expect(result.cleanup.peerConnections?.acceptedConnections == 1)
            #expect(result.cleanup.peerConnections?.activeConnections == 0)
            if adapter == .nio {
                #expect(result.cleanup.poolActiveAfterShutdown == 0 && result.cleanup.poolIdleAfterShutdown == 0)
            }
        }
    }

    /// Full-body EOF cleanup is included; a subsequent fifty-millisecond diagnostic is excluded.
    @Test func successfulEndpointExcludesDiagnostics() async throws {
        let clock = TransportTimingTestClock()
        let owner = TimingTestOwner(clock: clock, mode: .success)
        let result = try await TransportTimingRunner().run(scenario: .smallBody,
            transport: TimingTestTransport(owner: owner), url: url, requests: 1,
            concurrency: 1, clock: clock, requestDeadline: nil,
            postTimerDiagnostics: { clock.advance(.milliseconds(50)) })
        #expect(result.counts.outcomes[.success] == 1)
        #expect(maximum(result, "transport.request", .success) == 14_000_000)
        #expect(maximum(result, "transport.headers", .success) == 2_000_000)
        #expect(maximum(result, "transport.body", .success) == 12_000_000)
        #expect(maximum(result, "transport.bodyClose", .success) == 0)
        #expect(maximum(result, "transport.construct", .success) == 0)
        #expect(result.durationNanoseconds == 14_000_000)
        #expect(result.driverDurationNanoseconds == 64_000_000)
        #expect(await owner.closedCount() == 1)
        #expect(await owner.liveCount() == 0)
        #expect(result.metrics.allSatisfy { $0.clockDomain == result.clockDomain })
        #expect(result.receivedBytes == 256)
        #expect(result.unavailableMetrics["transport.upload"] != nil)
    }

    /// Malformed data closes the owner before the terminal timestamp and diagnostic hop.
    @Test func failedBodyIncludesAwaitedClose() async throws {
        let clock = TransportTimingTestClock()
        let owner = TimingTestOwner(clock: clock, mode: .malformed)
        let result = try await TransportTimingRunner().run(scenario: .smallBody,
            transport: TimingTestTransport(owner: owner), url: url, requests: 1,
            concurrency: 1, clock: clock, requestDeadline: nil,
            postTimerDiagnostics: { clock.advance(.milliseconds(50)) })
        #expect(result.counts.outcomes[.failure] == 1)
        #expect(maximum(result, "transport.request", .failure) == 10_000_000)
        #expect(maximum(result, "transport.body", .failure) == 3_000_000)
        #expect(maximum(result, "transport.bodyClose", .failure) == 5_000_000)
        #expect(result.durationNanoseconds == 10_000_000)
        #expect(result.driverDurationNanoseconds == 60_000_000)
        #expect(await owner.closedCount() == 1)
        #expect(await owner.liveCount() == 0)
    }

    /// Cancellation after headers closes the transferred body exactly once before completion.
    @Test func cancellationJoinsOwnedClose() async throws {
        let clock = TransportTimingTestClock()
        let owner = TimingTestOwner(clock: clock, mode: .success)
        let result = try await TransportTimingRunner().run(scenario: .cancelled,
            transport: TimingTestTransport(owner: owner), url: url, requests: 4,
            concurrency: 2, clock: clock, requestDeadline: nil)
        #expect(result.counts.offered == 4)
        #expect(result.counts.outcomes[.cancelled] == 4)
        #expect(result.counts.outcomes[.success] == 0)
        #expect(await owner.closedCount() == 4)
        #expect(await owner.liveCount() == 0)
        #expect(result.metrics.filter { $0.id == "transport.bodyClose" }.first?.distribution.observedCount == 4)
    }

    /// Every failure category has a whole/header/construct observation, without fictitious body data.
    @Test func headerFailuresHaveDistinctPopulations() async throws {
        for (mode, outcome) in [(TimingTestOwner.Mode.failure, BenchmarkOutcome.failure),
                                (.rejected, .rejected), (.timedOut, .timedOut), (.cancelled, .cancelled)] {
            let clock = TransportTimingTestClock()
            let owner = TimingTestOwner(clock: clock, mode: mode)
            let result = try await TransportTimingRunner().run(scenario: .smallBody,
                transport: TimingTestTransport(owner: owner), url: url, requests: 3,
                concurrency: 1, clock: clock, requestDeadline: nil)
            #expect(result.counts.outcomes[outcome] == 3)
            #expect(result.counts.admitted == (outcome == .rejected ? 0 : 3))
            #expect(result.counts.deadlineMisses == (outcome == .timedOut ? 3 : 0))
            #expect(result.metrics.count == 3)
            #expect(result.metrics.allSatisfy { $0.outcome == outcome && $0.distribution.observedCount == 3 })
            #expect(await owner.liveCount() == 0)
            try result.counts.validate()
        }
    }

    /// All size and streaming profiles consume exact uploads/responses without raw sample retention.
    @Test func finitePayloadMatrixAndSerialization() async throws {
        for scenario in TransportTimingCase.allCases where scenario != .delayedHeaders && scenario != .delayedBody {
            let result = try await TransportTimingRunner().run(scenario: scenario,
                transport: ScriptedTimingTransport(scenario: scenario), url: url,
                requests: 3, concurrency: 2, clock: ContinuousClock(), requestDeadline: nil)
            let expected: BenchmarkOutcome = scenario == .malformedBody ? .failure
                : scenario == .cancelled ? .cancelled : scenario == .timedOut ? .timedOut : .success
            #expect(result.counts.completed == 3)
            #expect(result.counts.outcomes[expected] == 3)
            #expect(result.uploadedBytes == UInt64(scenario.uploadBytes * 3))
            if expected == .success { #expect(result.receivedBytes == UInt64(scenario.responseBytes * 3)) }
            #expect(result.maximumHarnessTasks == 2)
            let data = try JSONEncoder().encode(result)
            let decoded = try JSONDecoder().decode(TransportTimingMeasurement.self, from: data)
            #expect(decoded.metrics == result.metrics)
            #expect(decoded.counts == result.counts)
            #expect(data.count < 4 * 1_024 * 1_024)
        }
    }

    /// No tasks are allocated per logical request; cancellation joins suspended header work.
    @Test func cancellationStopsReplenishmentAndJoins() async throws {
        let gate = TimingSuspension()
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            try await TransportTimingRunner().run(scenario: .smallBody,
                transport: TimingSuspendedTransport(gate: gate, signal: signal.continuation),
                url: url, requests: 100_000, concurrency: 3, clock: ContinuousClock(), requestDeadline: nil)
        }
        var iterator = signal.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        let result = try await task.value
        signal.continuation.finish()
        #expect(result.counts.offered == 3)
        #expect(result.counts.completed == 3)
        #expect(result.counts.outcomes[.cancelled] == 3)
        #expect(result.maximumHarnessTasks == 3)
        #expect(await gate.liveCount() == 0)
    }

    /// A regressing injected clock creates explicit aggregate loss, never a qualifying zero.
    @Test func regressingClockIsLoss() async throws {
        let clock = TransportTimingTestClock()
        let result = try await TransportTimingRunner().run(scenario: .empty,
            transport: TimingRegressingTransport(clock: clock), url: url,
            requests: 1, concurrency: 1, clock: clock, requestDeadline: nil)
        let request = try #require(result.metrics.first { $0.id == "transport.request" })
        #expect(request.distribution.droppedCount == 1)
        #expect(request.p50 == .unavailable(.aggregateLoss))
        #expect(result.durationNanoseconds == nil)
    }

    /// The admission window stops new work while preserving every already offered terminal result.
    @Test func durationCapDoesNotCreateBacklog() async throws {
        let clock = TransportTimingTestClock()
        let owner = TimingTestOwner(clock: clock, mode: .success)
        let result = try await TransportTimingRunner().run(scenario: .smallBody,
            transport: TimingTestTransport(owner: owner), url: url,
            requests: 100_000, concurrency: 1, clock: clock, requestDeadline: nil,
            maximumDuration: .milliseconds(10))
        #expect(result.counts.offered == 1)
        #expect(result.counts.completed == 1)
        #expect(await owner.liveCount() == 0)
    }

    /// A delayed producer cannot publish bytes once its inclusive adapter deadline has passed.
    @Test func delayedBodyHonorsDeadlineBeforeReturningBytes() async throws {
        let clock = TransportTimingTestClock()
        let result = try await TransportTimingRunner().run(scenario: .delayedBody,
            transport: ScriptedTimingTransport(scenario: .delayedBody), url: url,
            requests: 1, concurrency: 1, clock: clock, requestDeadline: .milliseconds(1))
        #expect(result.counts.outcomes[.timedOut] == 1)
        #expect(result.receivedBytes == 0)
        #expect(maximum(result, "transport.request", .timedOut) == 2_000_000)
        #expect(result.metrics.contains { $0.id == "transport.bodyClose" && $0.outcome == .timedOut })
    }

    /// Invalid endpoints/caps fail before adapter work, and pre-cancelled runs offer nothing.
    @Test func validationAndPreCancellation() async throws {
        let clock = TransportTimingTestClock()
        let owner = TimingTestOwner(clock: clock, mode: .success)
        for text in ["http://example.com/", "http://secret@127.0.0.1/", "http://127.0.0.1/#secret", "ftp://127.0.0.1/"] {
            await #expect(throws: LoadFailure.invalidArguments) {
                try await TransportTimingRunner().run(scenario: .smallBody,
                    transport: TimingTestTransport(owner: owner), url: URL(string: text)!,
                    requests: 1, concurrency: 1, clock: clock)
            }
        }
        for concurrency in [0, 257] {
            await #expect(throws: LoadFailure.invalidArguments) {
                try await TransportTimingRunner().run(scenario: .smallBody,
                    transport: TimingTestTransport(owner: owner), url: url,
                    requests: 1, concurrency: concurrency, clock: clock)
            }
        }
        for deadline in [Duration.zero, .seconds(61)] {
            await #expect(throws: LoadFailure.invalidArguments) {
                try await TransportTimingRunner().run(scenario: .smallBody,
                    transport: TimingTestTransport(owner: owner), url: url,
                    requests: 1, concurrency: 1, clock: clock, requestDeadline: deadline)
            }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TransportTimingRunner().run(scenario: .smallBody,
                transport: TimingTestTransport(owner: owner), url: url,
                requests: 100, concurrency: 2, clock: clock)
        }
        let result = try await task.value
        #expect(result.counts.offered == 0)
        #expect(result.maximumHarnessTasks == 0)
        #expect(result.metrics.isEmpty)
        #expect(await owner.calledCount() == 0)
    }

    /// Reads the exact in-range maximum; bucket estimates remain separately bounded evidence.
    private func maximum(_ result: TransportTimingMeasurement, _ id: String, _ outcome: BenchmarkOutcome) -> UInt64? {
        result.metrics.first { $0.id == id && $0.outcome == outcome }?.distribution.maxInRangeNanoseconds
    }
}

/// Lock-protected injected clock; tests advance it without wall-clock deadlines.
private final class TransportTimingTestClock: Clock, @unchecked Sendable {
    typealias Instant = ContinuousClock.Instant
    private let lock = NSLock()
    private var value = ContinuousClock().now
    /// Thread-safe virtual instant; wall time is consulted only at clock construction.
    var now: Instant {
        /// Reads one exact current value without advancing it.
        get { lock.lock(); defer { lock.unlock() }; return value }
    }
    /// Declared one-nanosecond precision of explicit semantic fixture advances.
    var minimumResolution: Duration {
        /// Returns the fixed precision without a clock read.
        get { .nanoseconds(1) }
    }
    /// Advances by an exact duration; negative input deliberately permits invalid-clock tests.
    /// - Parameter duration: Exact clock step; no real-time sleep or background task occurs.
    func advance(_ duration: Duration) { lock.lock(); value = value.advanced(by: duration); lock.unlock() }
    /// Advances directly to a requested deadline for single-threaded semantic fixtures.
    /// - Parameters:
    ///   - deadline: Virtual target; present/past deadlines leave time unchanged.
    ///   - tolerance: Ignored because this clock schedules no timers.
    /// - Throws: Cancellation before any virtual-time mutation.
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        lock.withLock { if deadline > value { value = deadline } }
    }
}

/// Deterministic fixture owner with exact cleanup accounting and configurable failures.
private actor TimingTestOwner {
    enum Mode: Sendable { case success, malformed, failure, rejected, timedOut, cancelled }
    let clock: TransportTimingTestClock
    let mode: Mode
    private var live = 0
    private var closed = 0
    private var called = 0
    /// Stores semantic fixture configuration without starting a request.
    /// - Parameters:
    ///   - clock: Shared virtual domain advanced by headers, body pulls and close.
    ///   - mode: Success/malformed body or one finite header-failure category.
    init(clock: TransportTimingTestClock, mode: Mode) { self.clock = clock; self.mode = mode }
    /// Emits two milliseconds of header work and a body with separately advanced pull/close work.
    /// - Returns: A single-consumer 256-byte response with one owner cleanup closure.
    /// - Throws: The configured finite header failure, or invalid stream configuration.
    func response() throws -> HTTPResponse {
        called += 1
        clock.advance(.milliseconds(2))
        switch mode {
        case .failure: throw LoadFailure.unexpectedResponse
        case .rejected: throw NIOAdapterFailure.capacityExceeded
        case .timedOut: throw TransportFailure.deadlineExceeded
        case .cancelled: throw CancellationError()
        case .success, .malformed: break
        }
        live += 1
        let source = TimingTestBody(clock: clock, malformed: mode == .malformed)
        return HTTPResponse(status: 200, body: try BodyStream(maximumChunkBytes: 256,
            next: { await source.next() }, close: { await self.closeOne() }))
    }
    /// Models awaited native cleanup exactly once through BodyStream ownership.
    func closeOne() { clock.advance(.milliseconds(5)); live -= 1; closed += 1 }
    /// Returns the exact number of transferred bodies whose cleanup has not completed.
    func liveCount() -> Int { live }
    /// Returns the exact number of completed exactly-once owner cleanup calls.
    func closedCount() -> Int { closed }
    /// Returns offered adapter invocations independently of successful header transfers.
    func calledCount() -> Int { called }
}

/// A bounded finite response producer advances body work separately from its close owner.
private actor TimingTestBody {
    let clock: TransportTimingTestClock
    let malformed: Bool
    private var pulled = false
    /// Binds one finite producer to its shared virtual domain.
    /// - Parameters:
    ///   - clock: Domain advanced on each pull.
    ///   - malformed: True returns ASCII-y bytes so caller validation must close early.
    init(clock: TransportTimingTestClock, malformed: Bool) { self.clock = clock; self.malformed = malformed }
    /// First pull costs three milliseconds; EOF costs four and triggers owner cleanup.
    /// - Returns: Exactly one 256-byte chunk, followed by nil.
    func next() -> Data? {
        if pulled { clock.advance(.milliseconds(4)); return nil }
        pulled = true
        clock.advance(.milliseconds(3))
        return Data(repeating: malformed ? 121 : 120, count: 256)
    }
}

/// Thin generic Clock transport keeps exact owner work outside unrelated context checks.
private struct TimingTestTransport: HTTPTransport {
    let owner: TimingTestOwner
    /// Transfers the configured owner response without unrelated clock reads.
    /// - Parameters:
    ///   - request: Unused GET metadata; fixture profiles do not upload here.
    ///   - context: Unused deadline wrapper; semantic tests explicitly disable deadline races.
    /// - Returns: The owner's finite response or configured typed header failure.
    /// - Throws: The owner's selected error after its controlled virtual-clock advance.
    func execute<C: Clock>(_ request: HTTPRequest, context: TransportContext<C>) async throws -> HTTPResponse
    where C.Duration == Duration { try await owner.response() }
}

/// Deliberately invalid clock fixture proves the aggregate loss path.
private struct TimingRegressingTransport: HTTPTransport {
    let clock: TransportTimingTestClock
    /// Produces invalid negative timing while preserving a successful empty response.
    /// - Parameters:
    ///   - request: Unused empty GET request.
    ///   - context: Unused clock wrapper; the captured fixture clock deliberately regresses.
    /// - Returns: Empty success metadata with no fabricated body lifecycle.
    func execute<C: Clock>(_ request: HTTPRequest, context: TransportContext<C>) async throws -> HTTPResponse
    where C.Duration == Duration { clock.advance(.milliseconds(-1)); return HTTPResponse(status: 200) }
}

/// Counts cooperative suspension ownership without timers or unbounded wait registries.
private actor TimingSuspension {
    private var live = 0
    /// Increments exact ownership before a bounded header task begins suspension.
    func begin() { live += 1 }
    /// Decrements ownership after cooperative cancellation has been observed.
    func end() { live -= 1 }
    /// Returns currently admitted header owners, zero only after joined cancellation.
    func liveCount() -> Int { live }
}

/// Suspends bounded header work until task cancellation, then joins its ownership decrement.
private struct TimingSuspendedTransport: HTTPTransport {
    let gate: TimingSuspension
    let signal: AsyncStream<Void>.Continuation
    /// Holds one operation until cancellation, then awaits its ownership decrement.
    /// - Parameters:
    ///   - request: Unused GET metadata; no upload/body ownership transfers.
    ///   - context: Unused deadline wrapper; the caller disables deadline races.
    /// - Returns: Never returns a response; every suspension is cancelled by its test owner.
    /// - Throws: Cancellation after exact live ownership cleanup.
    func execute<C: Clock>(_ request: HTTPRequest, context: TransportContext<C>) async throws -> HTTPResponse
    where C.Duration == Duration {
        await gate.begin()
        signal.yield(())
        do {
            while true { try Task.checkCancellation(); await Task.yield() }
        } catch { await gate.end(); throw error }
    }
}
