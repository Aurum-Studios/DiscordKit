// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/TransportTimingRunner.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordFoundationTransport
import DiscordNIOTransport
import DiscordTransport
import Foundation

/// Finite, credential-free transport workloads; sizes are semantic profile inputs.
enum TransportTimingCase: String, CaseIterable, Codable, Sendable {
    case empty = "transport.empty"
    case smallBody = "transport.smallBody"
    case streamedBody = "transport.streamedBody"
    case largeBody = "transport.largeBody"
    case smallUpload = "transport.smallUpload"
    case streamedUpload = "transport.streamedUpload"
    case largeUpload = "transport.largeUpload"
    case delayedHeaders = "transport.delayedHeaders"
    case delayedBody = "transport.delayedBody"
    case malformedBody = "transport.malformedBody"
    case cancelled = "transport.cancelled"
    case timedOut = "transport.timedOut"
    case body64KiBChunk257V1 = "transport.body64KiBChunk257V1"
    case body64KiBChunk65536V1 = "transport.body64KiBChunk65536V1"

    /// Exact response size checked while consuming every byte, including malformed cases.
    var responseBytes: Int {
        /// Returns the finite zero/small/streamed/large response dimension in bytes.
        get {
        switch self {
        case .empty: 0
        case .streamedBody, .body64KiBChunk257V1, .body64KiBChunk65536V1: 65_536
        case .largeBody: 1_048_576
        default: 256
        }
        }
    }

    /// Native adapter output/socket-read bound; historical cases retain their 16 KiB default.
    var responseChunkBytes: Int {
        /// Returns the single changed dimension for the versioned equal-payload chunk controls.
        get {
            switch self {
            case .body64KiBChunk257V1: 257
            case .body64KiBChunk65536V1: 65_536
            default: 16_384
            }
        }
    }

    /// Scripted producer bound, preserving historical streaming semantics.
    var scriptedResponseChunkBytes: Int {
        /// Mirrors native chunk controls without changing legacy one-chunk scripted responses.
        get {
            switch self {
            case .body64KiBChunk257V1, .body64KiBChunk65536V1: responseChunkBytes
            case .streamedBody: 1_024
            default: max(1, responseBytes)
            }
        }
    }

    /// Exact upload size; adapters currently collect bounded streamed inputs before sending.
    var uploadBytes: Int {
        /// Returns the finite POST input dimension, or zero for GET workloads.
        get {
        switch self {
        case .smallUpload: 256
        case .streamedUpload: 65_536
        case .largeUpload: 1_048_576
        default: 0
        }
        }
    }

    /// Producer chunk bound, independent of adapter socket buffering and write boundaries.
    var uploadChunkBytes: Int {
        /// Returns a positive pull limit; an absent upload still uses the inert bound one.
        get { self == .streamedUpload ? 1_024 : max(1, uploadBytes) }
    }
}

/// Adapter and reuse dimensions are declared independently of workload identity.
enum TransportTimingAdapter: String, CaseIterable, Codable, Sendable { case nio, foundation, scripted }
enum TransportConnectionMode: String, Codable, Sendable { case cold, warm }

/// Post-shutdown receipts distinguish available public counters from unavailable internals.
struct TransportTimingCleanup: Codable, Sendable {
    var ownedAdaptersClosed = false
    var poolActiveAfterShutdown: Int?
    var poolIdleAfterShutdown: Int?
    var peerConnections: PeerConnectionMetrics?
    var note = "Caller owns adapter shutdown; no shutdown receipt was supplied."
}

/// Whole-population corrected measurements, separate from every legacy load report.
struct TransportTimingMeasurement: Codable, Sendable {
    let scenario: String
    let profileVersion: UInt32
    let configuredRequests: Int
    let concurrency: Int
    let maximumHarnessTasks: Int
    let receivedBytes: UInt64
    let uploadedBytes: UInt64
    /// First submitted request through last owned terminal, excluding final diagnostics/report work.
    let durationNanoseconds: UInt64?
    /// Full cohort driver including diagnostics and aggregate insertion; not service throughput time.
    let driverDurationNanoseconds: UInt64?
    let clockDomain: String
    let counts: BenchmarkCounts
    let metrics: [BenchmarkMetric]
    var adapter = "injected"
    var connectionMode = "caller-owned"
    var tls = false
    var warmupRequests = 0
    var warmupNanoseconds: UInt64 = 0
    var cleanup = TransportTimingCleanup()
    var unavailableMetrics = [
        "transport.poolWait": "Adapters expose no dedicated monotonic pool-acquire lifecycle hook; fail-fast refusal remains an outcome.",
        "transport.upload": "Producer pull/close is observable, but final socket write completion is not exposed; headers includes upload.",
        "transport.dns": "No dedicated DNS lifecycle hook; TLS fixtures use localhost, plain fixtures use literal loopback.",
        "transport.tls": "No dedicated TLS lifecycle hook; secure requests include verified TLS setup in their whole/header intervals.",
    ]
}

/// Corrected caller-boundary transport timing with a bounded replenished cohort.
struct TransportTimingRunner: Sendable {
    /// Runs exact finite work and joins every admitted operation before returning.
    ///
    /// Construction ends before the whole request starts. Headers measures adapter
    /// invocation to response metadata (and includes upload). Body covers caller
    /// validation through EOF/error, including cleanup automatically triggered by
    /// BodyStream. Body-close measures the caller's explicit awaited close; after
    /// EOF this is normally an idempotent join. Whole request ends after validation
    /// and awaited close, before any diagnostic actor hop or histogram mutation.
    /// No internal DNS, pool or socket-write duration is inferred by subtraction.
    /// - Parameters:
    ///   - scenario: One finite payload/failure population, fixed for this run.
    ///   - transport: Caller-owned adapter; its eventual pool shutdown is separate.
    ///   - url: Credential-free loopback HTTP/HTTPS URL; localhost permits fixture certificate verification.
    ///   - requests: Exact configured requests, in 1...100000.
    ///   - concurrency: Active cohort in 1...256; the CLI further caps smoke at 64.
    ///   - clock: Injected monotonic domain, virtual for semantics or real for cost.
    ///   - requestDeadline: Positive per-request deadline up to sixty seconds, or nil.
    ///   - maximumDuration: Optional admission window in (0, 3600] seconds; admitted work is joined.
    ///   - postTimerDiagnostics: Optional no-op by default; always runs after terminal timestamps.
    /// - Returns: All-outcome distributions and exact offered/terminal accounting.
    /// - Throws: Invalid dimensions/URL or aggregate-budget rejection before transport work.
    func run<C: Clock, T: HTTPTransport>(scenario: TransportTimingCase, transport: T, url: URL,
        requests: Int, concurrency: Int, clock: C, requestDeadline: Duration? = .seconds(10),
        maximumDuration: Duration? = nil,
        postTimerDiagnostics: @escaping @Sendable () async -> Void = {}) async throws -> TransportTimingMeasurement
    where C.Duration == Duration {
        guard (1...100_000).contains(requests), (1...256).contains(concurrency),
              requestDeadline.map({ $0 > .zero && $0 <= .seconds(60) }) ?? true,
              maximumDuration.map({ $0 > .zero && $0 <= .seconds(3_600) }) ?? true,
              ["http", "https"].contains(url.scheme ?? ""),
              ["127.0.0.1", "::1", "[::1]", "localhost"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.fragment == nil else { throw LoadFailure.invalidArguments }
        let configuration = try HistogramConfiguration(lowerBoundNanoseconds: 0,
            upperBoundNanoseconds: 1_000_000_000, bucketWidthNanoseconds: 100_000)
        let metricIDs = ["transport.request", "transport.headers", "transport.body", "transport.bodyClose", "transport.construct"]
        _ = try AggregateStatisticsBudget.validate(histograms: Array(repeating: configuration,
            count: metricIDs.count * BenchmarkOutcome.allCases.count), additionalBytes: 16_384)
        var histograms: [String: [BenchmarkOutcome: BoundedHistogram]] = [:]
        for id in metricIDs {
            histograms[id] = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map {
                ($0, BoundedHistogram(configuration: configuration))
            })
        }
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        var offered = 0
        var received: UInt64 = 0
        var uploaded: UInt64 = 0
        let domain = UUID().uuidString
        let start = clock.now
        var firstSubmission: C.Instant?
        var lastTerminal: C.Instant?
        let maximumTasks = min(requests, concurrency)
        await withTaskGroup(of: TransportTimingExchange<C.Instant>.self) { group in
            for _ in 0..<maximumTasks where !Task.isCancelled {
                offered += 1
                group.addTask { await exchange(scenario: scenario, transport: transport, url: url,
                    clock: clock, deadline: requestDeadline, postTimerDiagnostics: postTimerDiagnostics) }
            }
            while let result = await group.next() {
                firstSubmission = firstSubmission.map { min($0, result.submitted) } ?? result.submitted
                lastTerminal = lastTerminal.map { max($0, result.terminal) } ?? result.terminal
                outcomes[result.outcome]! += 1
                received += UInt64(result.receivedBytes)
                uploaded += UInt64(result.uploadedBytes)
                for (id, duration) in result.durations {
                    if let nanoseconds = try? BenchmarkTime.nanoseconds(duration: duration) {
                        histograms[id]![result.outcome]!.record(nanoseconds)
                    } else { histograms[id]![result.outcome]!.recordLoss() }
                }
                if Task.isCancelled { group.cancelAll() }
                else if offered < requests && (maximumDuration.map({ start.duration(to: clock.now) < $0 }) ?? true) {
                    offered += 1
                    group.addTask { await exchange(scenario: scenario, transport: transport, url: url,
                        clock: clock, deadline: requestDeadline, postTimerDiagnostics: postTimerDiagnostics) }
                }
            }
        }
        let end = clock.now
        let counts = BenchmarkCounts(offered: UInt64(offered), admitted: UInt64(offered) - outcomes[.rejected]!,
            completed: UInt64(offered), outcomes: outcomes, deadlineMisses: outcomes[.timedOut]!)
        try counts.validate()
        let metrics = metricIDs.sorted().flatMap { id in
            BenchmarkOutcome.allCases.compactMap { outcome -> BenchmarkMetric? in
                let snapshot = histograms[id]![outcome]!.snapshot()
                guard snapshot.observedCount > 0 || snapshot.droppedCount > 0 || snapshot.counterOverflow else { return nil }
                return BenchmarkMetric(id: id, outcome: outcome, clockDomain: domain, distribution: snapshot)
            }
        }
        return TransportTimingMeasurement(scenario: scenario.rawValue, profileVersion: 2,
            configuredRequests: requests, concurrency: concurrency, maximumHarnessTasks: offered == 0 ? 0 : maximumTasks,
            receivedBytes: received, uploadedBytes: uploaded,
            durationNanoseconds: firstSubmission.flatMap { first in lastTerminal.flatMap {
                try? BenchmarkTime.nanoseconds(duration: first.duration(to: $0))
            } } ?? (offered == 0 ? 0 : nil),
            driverDurationNanoseconds: try? BenchmarkTime.nanoseconds(duration: start.duration(to: end)),
            clockDomain: domain, counts: counts, metrics: metrics)
    }

    /// Owns one response through validation and cleanup, then performs optional diagnostics.
    /// - Parameters:
    ///   - scenario: Exact expected payload and controlled cancellation behavior.
    ///   - transport: Shared caller-owned adapter.
    ///   - url: Validated loopback endpoint.
    ///   - clock: Domain shared by all five direct caller intervals.
    ///   - deadline: Optional whole-exchange adapter deadline.
    ///   - postTimerDiagnostics: Work excluded from every returned direct interval.
    /// - Returns: At most five durations and safe numeric/categorical evidence.
    private func exchange<C: Clock, T: HTTPTransport>(scenario: TransportTimingCase, transport: T, url: URL,
        clock: C, deadline: Duration?, postTimerDiagnostics: @Sendable () async -> Void) async -> TransportTimingExchange<C.Instant>
    where C.Duration == Duration {
        let constructStart = clock.now
        let upload = TimingPayloadSource(bytes: scenario.uploadBytes, chunkBytes: scenario.uploadChunkBytes)
        // Profile validation makes this initializer infallible; construction still has its own boundary.
        let uploadBody = scenario.uploadBytes == 0 ? nil : try? BodyStream(maximumChunkBytes: scenario.uploadChunkBytes,
            next: { await upload.next() }, close: {})
        let request = HTTPRequest(method: scenario.uploadBytes > 0 ? "POST" : "GET", url: url, body: uploadBody)
        let constructEnd = clock.now
        let start = clock.now
        var durations = ["transport.construct": constructStart.duration(to: constructEnd)]
        var body: BodyStream?
        var bodyStart: C.Instant?
        var received = 0
        var outcome = BenchmarkOutcome.success
        do {
            let response = try await transport.execute(request,
                context: TransportContext(clock: clock, deadline: deadline.map { start.advanced(by: $0) }))
            let headersEnd = clock.now
            durations["transport.headers"] = start.duration(to: headersEnd)
            body = response.body
            bodyStart = clock.now
            guard response.status == 200 else { throw LoadFailure.unexpectedResponse }
            if scenario == .cancelled { withUnsafeCurrentTask { $0?.cancel() } }
            try Task.checkCancellation()
            if let body {
                for try await chunk in body {
                    guard chunk.count <= scenario.responseBytes - received,
                          chunk.allSatisfy({ $0 == 120 }) else { throw LoadFailure.unexpectedResponse }
                    received += chunk.count
                }
            }
            guard received == scenario.responseBytes else { throw LoadFailure.unexpectedResponse }
        } catch {
            if error is CancellationError { outcome = .cancelled }
            else if (error as? TransportFailure) == .deadlineExceeded { outcome = .timedOut }
            else if (error as? NIOAdapterFailure) == .capacityExceeded
                || (error as? FoundationTransportFailure) == .admissionRejected { outcome = .rejected }
            else { outcome = .failure }
            if durations["transport.headers"] == nil { durations["transport.headers"] = start.duration(to: clock.now) }
        }
        if let bodyStart { durations["transport.body"] = bodyStart.duration(to: clock.now) }
        if let body {
            let closeStart = clock.now
            await body.close()
            durations["transport.bodyClose"] = closeStart.duration(to: clock.now)
        }
        let terminal = clock.now
        durations["transport.request"] = start.duration(to: terminal)
        await postTimerDiagnostics()
        return TransportTimingExchange(outcome: outcome, receivedBytes: received,
            uploadedBytes: await upload.producedBytes(), durations: durations, submitted: start, terminal: terminal)
    }
}

/// Bounded operation evidence handed to the single aggregate owner after completion.
private struct TransportTimingExchange<Instant: InstantProtocol>: Sendable where Instant.Duration == Duration {
    let outcome: BenchmarkOutcome
    let receivedBytes: Int
    let uploadedBytes: Int
    let durations: [String: Duration]
    let submitted: Instant
    let terminal: Instant
}

/// Demand-driven deterministic bytes with no retained population-sized upload buffer.
private actor TimingPayloadSource {
    private var remaining: Int
    private let chunkBytes: Int
    private var produced = 0

    /// Stores only numeric dimensions; no payload allocation occurs until a pull.
    /// - Parameters:
    ///   - bytes: Nonnegative remaining bytes, at most the profile's one-MiB ceiling.
    ///   - chunkBytes: Positive maximum allocation per demand-driven pull.
    init(bytes: Int, chunkBytes: Int) { remaining = bytes; self.chunkBytes = chunkBytes }

    /// Allocates one bounded chunk and returns EOF after exactly the declared size.
    /// - Returns: ASCII-x bytes no larger than the configured chunk size, or nil at EOF.
    func next() -> Data? {
        guard remaining > 0 else { return nil }
        let count = min(remaining, chunkBytes)
        remaining -= count; produced += count
        return Data(repeating: 120, count: count)
    }

    /// Reports consumed producer bytes; this is not a socket-write completion metric.
    /// - Returns: Exact cumulative bytes returned by this producer, including partial exchanges.
    func producedBytes() -> Int { produced }
}

/// Portable semantics fixture, explicitly labeled without native socket qualification.
struct ScriptedTimingTransport: HTTPTransport {
    let scenario: TransportTimingCase

    /// Consumes uploads and returns finite delayed/malformed response fixtures.
    /// - Parameters:
    ///   - request: Single-use upload owned and closed by this execution.
    ///   - context: Clock/cancellation/deadline propagated into body reads.
    /// - Returns: A body matching the selected fixture, with no network requests.
    /// - Throws: Cancellation, deadline or malformed upload errors after joined cleanup.
    func execute<C: Clock>(_ request: HTTPRequest, context: TransportContext<C>) async throws -> HTTPResponse
    where C.Duration == Duration {
        do {
            try context.check()
            var bytes = 0
            if let upload = request.body {
                for try await chunk in upload {
                    guard chunk.allSatisfy({ $0 == 120 }) else { throw LoadFailure.unexpectedResponse }
                    bytes += chunk.count
                }
                await upload.close()
            }
            guard bytes == scenario.uploadBytes else { throw LoadFailure.unexpectedResponse }
            if scenario == .timedOut { throw TransportFailure.deadlineExceeded }
            if scenario == .delayedHeaders { try await context.clock.sleep(for: .milliseconds(2)) }
            try context.check()
            let source = TimingPayloadSource(bytes: scenario.responseBytes, chunkBytes: scenario.scriptedResponseChunkBytes)
            // Preserve the historical streamed fixture's declared upper bound.
            let maximumChunkBytes = scenario == .streamedBody ? max(1, scenario.responseBytes) : scenario.scriptedResponseChunkBytes
            let body = try BodyStream(maximumChunkBytes: maximumChunkBytes, next: {
                try context.check()
                if scenario == .delayedBody { try await context.clock.sleep(for: .milliseconds(2)) }
                try context.check()
                if scenario == .malformedBody { return Data([121]) }
                return await source.next()
            }, close: {})
            return HTTPResponse(status: 200, body: body)
        } catch { await request.body?.close(); throw error }
    }
}

/// Reuses the generic runner with separately owned native/scripted adapters and peers.
struct TransportTimingNativeSuite {
    /// Runs cold or warm native loopback work and captures shutdown receipts afterward.
    ///
    /// Cold mode creates a fresh adapter per exchange inside the measured invocation;
    /// its request/body timing includes adapter creation and joined adapter shutdown.
    /// Warm mode constructs once and executes separate warmup before measured work.
    /// NIO TLS trusts only the repository's local fixture certificate and retains
    /// full chain/hostname verification. Foundation's public adapter has no private
    /// trust-root injection, so private-PKI TLS is explicitly unsupported there.
    /// - Parameters:
    ///   - adapter: Supported native adapter or explicitly scripted fixture.
    ///   - scenario: Finite local payload/error fixture.
    ///   - requests: Bounded measured count, validated before subprocess startup.
    ///   - concurrency: Replenished cohort capped at 256; adapter capacity is at most 8.
    ///   - warmupRequests: Separate process/adapter warm work in 0...10000; cold connections remain fresh.
    ///   - connectionMode: Cold adapter-per-exchange or warm shared pool.
    ///   - tls: Enables certificate-verified NIO loopback HTTPS; scripted/Foundation reject it.
    ///   - maxWarmupDuration: Warmup window, at most sixty seconds; zero requires no warmup requests.
    ///   - maxMeasuredDuration: Measured admission window, positive and at most 3600 seconds (soak).
    /// - Returns: Corrected measurements plus joined adapter and peer shutdown evidence.
    /// - Throws: Invalid dimensions, unsupported capability, peer startup or transport setup errors.
    func run(adapter: TransportTimingAdapter, scenario: TransportTimingCase, requests: Int,
        concurrency: Int, warmupRequests: Int = 1, connectionMode: TransportConnectionMode = .warm,
        tls: Bool = false, maxWarmupDuration: Duration = .seconds(1),
        maxMeasuredDuration: Duration = .seconds(10)) async throws -> TransportTimingMeasurement {
        guard (1...100_000).contains(requests), (1...256).contains(concurrency),
              (0...10_000).contains(warmupRequests),
              maxWarmupDuration >= .zero, maxWarmupDuration <= .seconds(60),
              warmupRequests == 0 || maxWarmupDuration > .zero,
              maxMeasuredDuration > .zero, maxMeasuredDuration <= .seconds(3_600),
              !tls || adapter == .nio else { throw LoadFailure.invalidArguments }
        let owned = try NativeTimingTransport(adapter: adapter, scenario: scenario,
            mode: connectionMode, maximumConnections: min(8, concurrency), tls: tls)
        let peer: TimingLocalPeer?
        do { peer = adapter == .scripted ? nil : try TimingLocalPeer.start(scenario: scenario, tls: tls) }
        catch { _ = await owned.shutdown(); throw error }
        let url = peer?.url ?? URL(string: "http://127.0.0.1/fixture")!
        let requestDeadline: Duration = scenario == .timedOut ? .milliseconds(1) : .seconds(10)
        do {
            var warmupNanoseconds: UInt64 = 0
            var actualWarmupRequests = 0
            if warmupRequests > 0 {
                let warmup = try await TransportTimingRunner().run(scenario: scenario, transport: owned, url: url,
                    requests: warmupRequests, concurrency: min(concurrency, warmupRequests), clock: ContinuousClock(),
                    requestDeadline: requestDeadline,
                    maximumDuration: maxWarmupDuration, postTimerDiagnostics: { await owned.afterTimerDiagnostics() })
                warmupNanoseconds = warmup.driverDurationNanoseconds ?? 0
                actualWarmupRequests = Int(warmup.counts.offered)
            }
            var measurement = try await TransportTimingRunner().run(scenario: scenario, transport: owned, url: url,
                requests: requests, concurrency: concurrency, clock: ContinuousClock(),
                requestDeadline: requestDeadline,
                maximumDuration: maxMeasuredDuration, postTimerDiagnostics: { await owned.afterTimerDiagnostics() })
            let receipt = await owned.shutdown()
            measurement.adapter = adapter.rawValue
            measurement.connectionMode = connectionMode.rawValue
            measurement.tls = tls
            measurement.warmupRequests = actualWarmupRequests
            measurement.warmupNanoseconds = warmupNanoseconds
            measurement.cleanup = TransportTimingCleanup(ownedAdaptersClosed: true,
                poolActiveAfterShutdown: receipt?.active, poolIdleAfterShutdown: receipt?.idle,
                peerConnections: peer?.stop(), note: adapter == .foundation
                    ? "Foundation close awaited; private socket/buffer counts unavailable."
                    : "All owned adapters closed and joined; NIO public pool counts sampled only afterward.")
            return measurement
        } catch {
            _ = await owned.shutdown()
            _ = peer?.stop()
            throw error
        }
    }
}

/// Erases only a finite adapter choice while keeping generic Clock execution intact.
private enum TimingAdapterResource: Sendable {
    case nio(NIOHTTPTransport), scripted(ScriptedTimingTransport)
    #if canImport(Darwin)
    case foundation(FoundationHTTPTransport)
    #endif

    /// Allocates one native owner before any warm measured request starts.
    /// - Parameters:
    ///   - adapter: Finite native or scripted implementation.
    ///   - scenario: Exact payload/error selection and versioned native chunk-size control.
    ///   - maximumConnections: Positive per-owner connection or operation capacity.
    ///   - tls: Whether NIO replaces system roots with the repository's local fixture root.
    /// - Returns: An unconnected owner with separately awaited shutdown.
    /// - Throws: Configuration or local certificate loading failure; no peer is started here.
    static func make(adapter: TransportTimingAdapter, scenario: TransportTimingCase,
        maximumConnections: Int, tls: Bool) throws -> Self {
        switch adapter {
        case .nio:
            let roots = tls ? try Data(contentsOf: TimingLocalPeer.certificate).map { $0 } : nil
            return .nio(try NIOHTTPTransport(configuration: NIOHTTPConfiguration(maximumConnections: maximumConnections,
                maximumConnectionsPerOrigin: maximumConnections, chunkBytes: scenario.responseChunkBytes),
                tls: TLSPolicy(additionalTrustRootsPEM: roots)))
        case .foundation:
            #if canImport(Darwin)
            return .foundation(FoundationHTTPTransport(configuration: try FoundationTransportConfiguration(
                maximumConcurrentOperations: maximumConnections, responseChunkBytes: scenario.responseChunkBytes)))
            #else
            throw FoundationTransportFailure.unavailableCapability
            #endif
        case .scripted: return .scripted(ScriptedTimingTransport(scenario: scenario))
        }
    }

    /// Forwards exactly once without replaying failures or guessing uncertainty.
    /// - Parameters:
    ///   - request: Single-use request whose upload ownership transfers to the adapter.
    ///   - context: Clock, cancellation and optional deadline propagated unchanged.
    /// - Returns: Response metadata with transferred body ownership.
    /// - Throws: The selected adapter's original typed failure after its execution cleanup.
    func execute<C: Clock>(_ request: HTTPRequest, context: TransportContext<C>) async throws -> HTTPResponse
    where C.Duration == Duration {
        switch self {
        case .nio(let value): try await value.execute(request, context: context)
        #if canImport(Darwin)
        case .foundation(let value): try await value.execute(request, context: context)
        #endif
        case .scripted(let value): try await value.execute(request, context: context)
        }
    }

    /// Awaits the selected native owner's shutdown; scripted mode owns no sockets.
    func close() async {
        switch self {
        case .nio(let value): await value.close()
        #if canImport(Darwin)
        case .foundation(let value): await value.close()
        #endif
        case .scripted: break
        }
    }

    /// Reads NIO's public counters only after close; unavailable counters remain nil.
    /// - Returns: Active/idle pool slots for NIO, or nil for Foundation/scripted internals.
    func counts() async -> (active: Int, idle: Int)? {
        if case .nio(let value) = self { return await value.connectionCounts() }
        return nil
    }
}

/// Owns a warm pool or bounded cold owners; response close joins cold pool shutdown.
private actor NativeTimingTransport: HTTPTransport {
    let adapter: TransportTimingAdapter
    let scenario: TransportTimingCase
    let mode: TransportConnectionMode
    let maximumConnections: Int
    let tls: Bool
    private let warm: TimingAdapterResource?
    private var cold: [UUID: TimingAdapterResource] = [:]
    private var closedAwaitingDiagnostic: [UUID: TimingAdapterResource] = [:]
    private var closedColdCounts: (active: Int, idle: Int)?

    /// Creates the warm adapter outside every measured interval; cold owners are deferred.
    /// - Parameters:
    ///   - adapter: Finite adapter implementation.
    ///   - scenario: Exact payload/error fixture and native chunk-size control.
    ///   - mode: Shared warm owner or fresh owner per cold exchange.
    ///   - maximumConnections: Positive capacity applied separately to each native owner.
    ///   - tls: Enables explicit verified local fixture trust for NIO.
    /// - Throws: Warm owner configuration/certificate errors before peer startup.
    init(adapter: TransportTimingAdapter, scenario: TransportTimingCase, mode: TransportConnectionMode,
        maximumConnections: Int, tls: Bool) throws {
        self.adapter = adapter; self.scenario = scenario; self.mode = mode
        self.maximumConnections = maximumConnections; self.tls = tls
        warm = mode == .warm ? try TimingAdapterResource.make(adapter: adapter, scenario: scenario,
            maximumConnections: maximumConnections, tls: tls) : nil
    }

    /// Transfers response ownership once; cold cleanup becomes a child of body close.
    /// - Parameters:
    ///   - request: Single-use request; cold execution creates its owner inside this call.
    ///   - context: Unchanged caller clock, cancellation and deadline.
    /// - Returns: A response whose cold body close also joins native owner shutdown.
    /// - Throws: Adapter/setup failures after joined cold-owner shutdown; no replay occurs.
    func execute<C: Clock>(_ request: HTTPRequest, context: TransportContext<C>) async throws -> HTTPResponse
    where C.Duration == Duration {
        if let warm { return try await warm.execute(request, context: context) }
        let resource = try TimingAdapterResource.make(adapter: adapter, scenario: scenario,
            maximumConnections: maximumConnections, tls: tls)
        let id = UUID()
        cold[id] = resource
        do {
            let response = try await resource.execute(request, context: context)
            guard let body = response.body else {
                await finishCold(id)
                return response
            }
            let cursor = TimingBodyCursor(body)
            return HTTPResponse(status: response.status, headers: response.headers,
                body: try BodyStream(maximumChunkBytes: 1_048_576, next: { try await cursor.next() }, close: {
                    await body.close()
                    await self.finishCold(id)
                }))
        } catch { await finishCold(id); throw error }
    }

    /// Closes one cold adapter before releasing its bounded registry entry.
    /// - Parameter id: Ephemeral owner token; absent tokens are already closed.
    private func finishCold(_ id: UUID) async {
        guard let resource = cold[id] else { return }
        await resource.close()
        cold[id] = nil
        closedAwaitingDiagnostic[id] = resource
    }

    /// Samples closed cold owners only after each request terminal timestamp.
    /// The caller joins this hook before replenishment, bounding retained closed
    /// owners by the active cohort. Public pool diagnostics never extend a request.
    func afterTimerDiagnostics() async {
        let resources = Array(closedAwaitingDiagnostic.values)
        closedAwaitingDiagnostic.removeAll(keepingCapacity: true)
        for resource in resources {
            if let counts = await resource.counts() {
                closedColdCounts = ((closedColdCounts?.active ?? 0) + counts.active,
                    (closedColdCounts?.idle ?? 0) + counts.idle)
            }
        }
    }

    /// Joins all native owners after the runner's cohort has completed.
    /// - Returns: Public NIO active/idle slots after close, or nil when counters are unavailable.
    func shutdown() async -> (active: Int, idle: Int)? {
        if let warm { await warm.close(); return await warm.counts() }
        for id in Array(cold.keys) { await finishCold(id) }
        await afterTimerDiagnostics()
        return closedColdCounts
    }
}

/// Serializes a single response iterator without any additional queue or task.
private actor TimingBodyCursor {
    private var iterator: BodyStream.AsyncIterator
    /// Creates an iterator while retaining the original body's exactly-once owner.
    /// - Parameter body: Single-consumer response stream; no pull occurs during initialization.
    init(_ body: BodyStream) { iterator = body.makeAsyncIterator() }
    /// Pulls and stores one iterator value across suspension; one caller is permitted.
    /// - Returns: One bounded chunk or nil at EOF.
    /// - Throws: Source/cancellation failure after the underlying stream's owned cleanup.
    func next() async throws -> Data? {
        var cursor = iterator
        defer { iterator = cursor }
        return try await cursor.next()
    }
}

/// Local fixture process with optional repository-owned certificate-verified TLS.
private struct TimingLocalPeer {
    let peer: LocalPeer
    /// Credential-free loopback endpoint established by the owned peer handshake.
    var url: URL {
        /// Returns the exact validated bound port and HTTP/HTTPS fixture origin.
        get { peer.url }
    }
    static let repository = LoadPaths.packageDirectory.deletingLastPathComponent().deletingLastPathComponent()
    static let certificate = repository.appendingPathComponent("Tests/DiscordNIOTransportTests/Resources/localhost-cert.pem")

    /// Starts only the bounded loopback fixture; setup occurs outside every request timer.
    /// - Parameters:
    ///   - scenario: Finite request/response/delay policy passed as a subprocess argument.
    ///   - tls: Enables the committed localhost certificate/key pair, never insecure TLS.
    /// - Returns: A running peer whose owner must stop it on all subsequent exits.
    /// - Throws: Process launch or malformed handshake errors after terminating/reaping a started peer.
    static func start(scenario: TransportTimingCase, tls: Bool) throws -> Self {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", LoadPaths.packageDirectory.appendingPathComponent("scripts/local_peer.py").path,
            "--payload-bytes", String(scenario.responseBytes), "--timing-case", scenario.rawValue]
        if tls {
            process.arguments! += ["--tls-cert", certificate.path, "--tls-key",
                repository.appendingPathComponent("Tests/DiscordNIOTransportTests/Resources/localhost-key.pem").path]
        }
        process.standardOutput = pipe
        try process.run()
        do {
            let data = pipe.fileHandleForReading.availableData
            guard let text = String(data: data, encoding: .utf8),
                  let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (1...65_535).contains(port),
                  let url = URL(string: "\(tls ? "https://localhost" : "http://127.0.0.1"):\(port)/payload") else {
                throw LoadFailure.peerStartup
            }
            return Self(peer: LocalPeer(process: process, output: pipe.fileHandleForReading, url: url))
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
    }

    /// Terminates and reaps the peer after adapter shutdown, retaining aggregate counters.
    /// - Returns: Final physical-socket counts, or nil if the peer omitted its bounded receipt.
    func stop() -> PeerConnectionMetrics? { peer.stop() }
}
