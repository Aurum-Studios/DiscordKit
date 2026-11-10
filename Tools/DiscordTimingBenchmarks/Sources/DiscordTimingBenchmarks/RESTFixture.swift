// File: Tools/DiscordTimingBenchmarks/Sources/DiscordTimingBenchmarks/RESTFixture.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordCore
import DiscordHTTP
import DiscordLogging
import DiscordTransport
import Foundation

/// Actual HTTPTransport seam returning bounded local 204 fixtures without sockets, credentials or Discord I/O.
final class TimingFixtureTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count: UInt64 = 0

    /// Executes one scripted HEAD/204 response with large finite rate budget and zero fixture reset wait.
    /// - Parameters:
    ///   - request: Owner-built request; only HEAD fixtures are accepted.
    ///   - context: Real owner's cancellation/deadline context; no request is sent to its URL.
    /// - Returns: Empty 204 response with fixed synthetic rate headers; no body owner is created.
    /// - Throws: Integrity error for an unexpected request or the current task's cancellation.
    func execute<C: Clock>(_ request: HTTPRequest, context: TransportContext<C>) async throws -> HTTPResponse
        where C.Duration == Duration {
        try Task.checkCancellation()
        guard request.method == "HEAD" else { throw TimingBenchmarkError.integrityFailure("Unexpected fixture method") }
        lock.withLock { count += 1 }
        return HTTPResponse(status: 204, headers: [
            .init(name: "X-RateLimit-Limit", value: "10000000"),
            .init(name: "X-RateLimit-Remaining", value: "9999999"),
            .init(name: "X-RateLimit-Reset-After", value: "0"),
            .init(name: "X-RateLimit-Bucket", value: "instrumentation-fixture"),
        ])
    }

    /// Reads completed local transport calls after all REST clients have joined.
    /// - Returns: Exact request count for checksum/once-only request accounting.
    func snapshot() -> UInt64 { lock.withLock { count } }
}

/// Independent per-worker REST/rate owners, constructed before the measured cohort starts.
struct TimingRESTFixture: Sendable {
    let transport: TimingFixtureTransport
    let coordinator: RateLimitCoordinator<ContinuousClock>
    let client: RESTClient<ContinuousClock>
    let endpoint: Endpoint<UInt64>

    /// Configures one real REST pipeline with an entirely local transport and selected scalar hooks.
    /// - Parameter timing: Nil or explicitly supplied genuine scalar observer.
    /// - Throws: Validation failure for the fixed HEAD endpoint, never a live network error.
    init(timing: OperationTiming?) throws {
        let clock = ContinuousClock()
        transport = TimingFixtureTransport()
        coordinator = RateLimitCoordinator(clock: clock)
        client = RESTClient(credential: .none, identity: RateLimitIdentity(), transport: transport,
            coordinator: coordinator, clock: clock, timing: timing)
        endpoint = try Endpoint(method: "HEAD", path: ["instrumentation-fixture"], authentication: .none,
            successStatuses: [204], usesGlobalLimit: false, retrySafety: .safe, decode: { bytes in
                guard bytes.isEmpty else { throw TimingBenchmarkError.integrityFailure("Nonempty 204 fixture") }
                return 204
            })
    }

    /// Verifies no request permit remains, then shuts down the separately owned rate authority.
    /// - Returns: Exact active owner count before explicit authority shutdown; zero is required.
    func close() async -> UInt64 {
        await DiscordLog.$loggerFactory.withValue({ label in
            Logger(label: label) { _ in SwiftLogNoOpLogHandler() }
        }) {
            let active = await coordinator.snapshot().activeCount
            await coordinator.close()
            return UInt64(active)
        }
    }
}
