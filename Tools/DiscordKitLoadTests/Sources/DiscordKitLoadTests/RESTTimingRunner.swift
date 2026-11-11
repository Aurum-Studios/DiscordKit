// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/RESTTimingRunner.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordCore
import DiscordHTTP
import DiscordLogging
import DiscordTransport
import Foundation

/// Finite offline REST policy fixtures; each case has its own comparable input identity.
enum RESTTimingScenario: String, Codable, CaseIterable, Sendable {
    case noCache, cacheMiss, cacheFresh, cacheExpiry, coalesced, independentKeys
    case delayedHeaders, delayedBody, streamedBody, largeBody, orderedMutation, orderedMutationDefaultV1
    case rateLimitRetry, serverRetry, retryExhausted, malformed, cancelled, uncertainMutation
}

/// Reviewed scheduler identity, kept separately from the scripted peer's learned rate headers.
struct RESTSchedulingReceipt: Codable, Equatable, Sendable {
    let profile: String
    let fairnessIntervalNanoseconds: UInt64
    let provisionalWindowNanoseconds: UInt64
    let initialGlobalRequestsPerSecond: Int
    let maximumConcurrentRequests: Int
    let maximumConcurrentRequestsPerIdentity: Int
    let maximumQueuedRequests: Int
    let maximumQueuedRequestsPerIdentity: Int
    let maximumQueuedBytes: Int
    let maximumQueuedBytesPerIdentity: Int
    let maximumMetadata: Int
    let maximumQueueAgeNanoseconds: UInt64
    let reservationLifetimeNanoseconds: UInt64
    let invalidRequestThreshold: Int
    let invalidRequestWindowNanoseconds: UInt64

    /// Captures the exact constructed scheduler policy outside all operation timers.
    init(policy: SchedulingPolicy, usesDefaults: Bool) {
        profile = usesDefaults ? "SchedulingPolicy-default-v1" : "legacy-tuned-v1"
        fairnessIntervalNanoseconds = Self.nanoseconds(policy.fairnessInterval)
        provisionalWindowNanoseconds = Self.nanoseconds(policy.provisionalWindow)
        initialGlobalRequestsPerSecond = policy.initialGlobalRequestsPerSecond
        maximumConcurrentRequests = policy.maximumConcurrentRequests
        maximumConcurrentRequestsPerIdentity = policy.maximumConcurrentRequestsPerIdentity
        maximumQueuedRequests = policy.maximumQueuedRequests
        maximumQueuedRequestsPerIdentity = policy.maximumQueuedRequestsPerIdentity
        maximumQueuedBytes = policy.maximumQueuedBytes
        maximumQueuedBytesPerIdentity = policy.maximumQueuedBytesPerIdentity
        maximumMetadata = policy.maximumMetadata
        maximumQueueAgeNanoseconds = Self.nanoseconds(policy.maximumQueueAge)
        reservationLifetimeNanoseconds = Self.nanoseconds(policy.reservationLifetime)
        invalidRequestThreshold = policy.invalidRequestThreshold
        invalidRequestWindowNanoseconds = Self.nanoseconds(policy.invalidRequestWindow)
    }

    /// Converts known positive bounded policy durations without reading a clock.
    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let parts = duration.components
        return UInt64(parts.seconds) * 1_000_000_000 + UInt64(parts.attoseconds / 1_000_000_000)
    }
}

/// Exact final ownership receipt, captured after all caller tasks and fixture cleanup join.
struct RESTTimingCleanup: Codable, Equatable, Sendable {
    let active: Int
    let queued: Int
    let ordered: Int
    let flights: Int
    let waiters: Int
    let cacheEntries: Int
    let transportBodies: Int
    let transportActive: Int

    /// Sum of all still-owned work counts; overlapping gauges remain explicit in individual fields.
    var remainingOwners: Int { active + queued + ordered + flights + waiters + cacheEntries + transportBodies + transportActive }

    /// True only when every separately owned resource has relinquished active work.
    var isEmpty: Bool {
        active == 0 && queued == 0 && ordered == 0 && flights == 0 && waiters == 0 &&
            cacheEntries == 0 && transportBodies == 0 && transportActive == 0
    }
}

/// Full-population metrics and exact counts from an entirely local bounded scripted transport.
struct RESTTimingReport: Codable, Sendable {
    let scenario: RESTTimingScenario
    let requests: Int
    let concurrency: Int
    let counts: BenchmarkCounts
    let wireExchanges: Int
    let setupWireExchanges: Int
    let subscribers: Int
    let peakActive: Int
    let seconds: Double
    let metrics: [BenchmarkMetric]
    let clockDomain: String
    let durationNanoseconds: UInt64
    let cleanup: RESTTimingCleanup
    let scheduling: RESTSchedulingReceipt?
    let notes: [String]
}

/// Runs finite closed-loop cohorts through the actual RESTClient pipeline, with no sockets or credentials.
struct RESTTimingRunner: Sendable {
    /// Measures every caller result/error before correctness checks, snapshots, aggregation or serialization.
    /// - Parameters:
    ///   - scenario: One finite fixture identity; response semantics never depend on arbitrary labels.
    ///   - requests: Total measured logical callers, in 1...100,000.
    ///   - concurrency: Fixed maximum active cohort, in 1...256 and no greater than requests.
    ///   - delay: Artificial phase delay in 0...1 second; cache expiry always waits for its explicit TTL.
    /// - Returns: Histograms partitioned by every terminal outcome, exact exchange/subscriber ownership,
    ///   separately counted setup exchanges and joined cleanup. Sparse tails remain unqualified.
    /// - Throws: Invalid bounds or fixture construction failure. Individual operation failures are counted.
    func run(scenario: RESTTimingScenario, requests: Int = 32, concurrency: Int = 4,
             delay: Duration = .milliseconds(2)) async throws -> RESTTimingReport {
        guard (1...100_000).contains(requests), (1...256).contains(concurrency), concurrency <= requests,
              delay >= .zero, delay <= .seconds(1) else { throw LoadFailure.invalidArguments }
        let statistics = try RunStatistics(workloads: [.restRequest, .restConstruct, .restOrderWait,
            .restCacheLookup, .restDecode, .restRetryWait, .restAdmission, .restHeaders, .restBody,
            .restSubscriber, .restExecution])
        let owner = RESTTimingOwner(scenario: scenario, concurrency: concurrency, delay: delay, statistics: statistics)
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        var measuredCalls = 0, completed = 0
        var firstSubmission: ContinuousClock.Instant?
        var lastTerminal: ContinuousClock.Instant?
        if scenario == .cacheFresh, !Task.isCancelled {
            do {
                _ = try await owner.setupClient.execute(endpoint(scenario: scenario, ordinal: 0))
            } catch {
                if !Task.isCancelled { _ = await owner.shutdown(); throw error }
            }
        }
        let clock = ContinuousClock()
        waveLoop: for first in stride(from: 0, to: requests, by: concurrency) {
            if Task.isCancelled { break }
            let count = min(concurrency, requests - first)
            if scenario == .cacheExpiry {
                // Setup and the expiry wait precede every caller-visible operation timestamp.
                do {
                    for ordinal in first..<(first + count) {
                        _ = try await owner.setupClient.execute(endpoint(scenario: scenario, ordinal: ordinal))
                    }
                    try await clock.sleep(for: .milliseconds(4))
                } catch {
                    if Task.isCancelled { break waveLoop }
                    _ = await owner.shutdown(); throw error
                }
            }
            if scenario == .coalesced { await owner.transport.holdHeaders() }
            let descriptors = try (first..<(first + count)).map {
                try endpoint(scenario: scenario, ordinal: scenario == .coalesced ? first : $0)
            }
            let measuredWireBefore = await owner.transport.snapshot().calls
            await withTaskGroup(of: RESTCallResult.self) { group in
                for descriptor in descriptors {
                    group.addTask {
                        let start = clock.now
                        let result: BenchmarkOutcome
                        do {
                            _ = try await owner.client.execute(descriptor)
                            result = .success
                        } catch { result = restOutcome(error) }
                        let terminal = clock.now
                        statistics.record(start.duration(to: terminal), workload: .restRequest, outcome: result)
                        return RESTCallResult(outcome: result, submitted: start, terminal: terminal)
                    }
                }
                if scenario == .coalesced {
                    // Synchronization occurs in the driver, never as a diagnostic actor hop inside
                    // the measured caller. It establishes exact subscriber ownership before release.
                    let synchronizationDeadline = clock.now.advanced(by: .seconds(10))
                    while await owner.coalescer.snapshot().waiters < count {
                        if Task.isCancelled || clock.now >= synchronizationDeadline { group.cancelAll(); break }
                        await Task.yield()
                    }
                    await owner.transport.releaseHeaders()
                }
                for await result in group {
                    outcomes[result.outcome, default: 0] += 1; completed += 1
                    firstSubmission = firstSubmission.map { min($0, result.submitted) } ?? result.submitted
                    lastTerminal = lastTerminal.map { max($0, result.terminal) } ?? result.terminal
                }
            }
            measuredCalls += await owner.transport.snapshot().calls - measuredWireBefore
        }
        let wire = await owner.transport.snapshot()
        let cleanup = await owner.shutdown()
        let metrics = statistics.metrics()
        let subscriberCount = metrics.filter { $0.id == "rest.subscriber" }
            .reduce(UInt64(0)) { $0 + $1.distribution.observedCount }
        let measuredDuration = firstSubmission.flatMap { first in lastTerminal.map { first.duration(to: $0) } } ?? .zero
        let parts = measuredDuration.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return RESTTimingReport(scenario: scenario, requests: requests, concurrency: concurrency,
            counts: BenchmarkCounts(offered: UInt64(completed), admitted: UInt64(completed), completed: UInt64(completed),
                outcomes: outcomes, deadlineMisses: 0), wireExchanges: measuredCalls,
            setupWireExchanges: wire.calls - measuredCalls, subscribers: Int(subscriberCount), peakActive: wire.peakActive,
            seconds: seconds, metrics: metrics, clockDomain: statistics.clockDomain,
            durationNanoseconds: try BenchmarkTime.nanoseconds(duration: measuredDuration), cleanup: cleanup,
            scheduling: owner.scheduling,
            notes: ["Offline scripted adapter: zero sockets and credentials. Real RESTClient owns rate, order, retry, cache, decode and subscriber semantics.",
                "Caller timers stop at execute result/error before aggregation and owner snapshots. Setup cache priming and expiry waits are excluded from operation distributions.",
                "Throughput spans first measured submission through last measured terminal, including inter-wave setup, driver work and expiry gaps; initial setup and final diagnostics are excluded.",
                "Cohorts are bounded at \(concurrency); every outcome is observed with fixed histogram storage. No numerical qualification is claimed.",
                "429 delay is owned by rate admission; retryWait records only actual policy backoff sleeps. Decode includes validation and caller decoding as separate invocations.",
                "Same-key cohorts use an explicit fixture header gate released after exact subscriber registration; this coordination is artificial header service."])
    }

    /// Builds the immutable finite input before a measured caller starts its clock.
    /// - Parameters:
    ///   - scenario: Fixture policy selecting explicit reuse, decoding and replay semantics.
    ///   - ordinal: Bounded run-local representation ordinal; never a persistent identity.
    /// - Returns: Credential-free descriptor whose response is validated as JSON.
    /// - Throws: Checked-in endpoint or body validation failure.
    private func endpoint(scenario: RESTTimingScenario, ordinal: Int) throws -> Endpoint<Data> {
        try restEndpoint(scenario: scenario, ordinal: ordinal)
    }
}

/// One joined caller result with timestamps captured before its histogram mutation or diagnostics.
private struct RESTCallResult: Sendable {
    let outcome: BenchmarkOutcome
    let submitted: ContinuousClock.Instant
    let terminal: ContinuousClock.Instant
}

/// Reusable real REST fixture for the separately scheduled bounded arrival driver.
actor RESTArrivalFixture {
    private let owner: RESTTimingOwner
    private let scenario: RESTTimingScenario
    private let independentPartitions: Int

    /// Prepares one bounded shared scheduler and adapter without starting requests.
    /// - Parameters:
    ///   - concurrency: Positive maximum admitted operations, no greater than 256.
    ///   - delay: Artificial per-exchange header delay, in 0...1 second.
    ///   - orderedDefault: Selects actual default scheduling and whole-operation mutation ordering.
    ///   - independentPartitions: Bounded partition count; one means a shared mutation partition.
    ///   - observeAdmission: Enables direct RESTClient.execute entry observation for a versioned fixture.
    /// - Throws: Invalid bounds before allocating runtime owners.
    init(concurrency: Int, delay: Duration, orderedDefault: Bool = false,
        independentPartitions: Int = 1, observeAdmission: Bool = false) throws {
        guard (1...256).contains(concurrency), (1...256).contains(independentPartitions),
            delay >= .zero, delay <= .seconds(1) else {
            throw LoadFailure.invalidArguments
        }
        scenario = orderedDefault ? .orderedMutationDefaultV1 : .delayedHeaders
        self.independentPartitions = independentPartitions
        owner = RESTTimingOwner(scenario: scenario, concurrency: concurrency, delay: delay,
            statistics: nil, observeAdmission: observeAdmission)
    }

    /// Executes one actual no-cache request through the shared bounded admission owner.
    /// - Parameter ordinal: Bounded driver ordinal, used only to separate request representations.
    /// - Returns: Existing finite terminal classification; no exception description or request data is retained.
    func execute(ordinal: Int) async -> BenchmarkOutcome {
        do { _ = try await owner.client.execute(restEndpoint(scenario: scenario, ordinal: ordinal,
            partition: independentPartitions > 1 ? String(ordinal % independentPartitions) : nil)); return .success }
        catch { return restOutcome(error) }
    }

    /// Executes one request while a task-local bounded cell records genuine RESTClient.execute entry.
    /// - Parameter ordinal: Finite driver ordinal; correlation never enters reports or runtime keys.
    /// - Returns: The actual terminal outcome and directly observed admission when the hook is enabled.
    func executeMeasured(ordinal: Int) async -> ArrivalOperationResult {
        let admission = RESTArrivalAdmission()
        let result = await RESTArrivalAdmissionContext.$current.withValue(admission) { await execute(ordinal: ordinal) }
        return ArrivalOperationResult(outcome: result, admittedNanoseconds: admission.timestamp())
    }

    /// Returns the scheduler policy receipt after setup, without starting a request.
    func schedulingReceipt() -> RESTSchedulingReceipt { owner.scheduling }

    /// Closes separately owned resources after the arrival driver has joined its tasks.
    /// - Returns: Exact final ownership counts; this work belongs outside service clocks.
    func shutdown() async -> RESTTimingCleanup { await owner.shutdown() }
}

/// Per-worker task-local correlation, inherited through the execute call without a shared map.
private enum RESTArrivalAdmissionContext {
    @TaskLocal static var current: RESTArrivalAdmission?
}

/// A single transient timestamp cell; it is released before the worker takes its next arrival.
private final class RESTArrivalAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64?

    /// Records only the first actual RESTClient.execute entry in the operation's clock domain.
    func include(_ offset: Duration) {
        guard let timestamp = try? BenchmarkTime.nanoseconds(duration: offset) else { return }
        lock.withLock { if value == nil { value = timestamp } }
    }

    /// Reads the directly captured timestamp after execute has returned.
    func timestamp() -> UInt64? { lock.withLock { value } }
}

/// Fixed owners and observer adapters, prepared outside measured caller operations.
private struct RESTTimingOwner: Sendable {
    let coordinator: RateLimitCoordinator<ContinuousClock>
    let cache: ReadCache<ContinuousClock>
    let coalescer: RequestCoalescer
    let transport: RESTScriptTransport
    let client: RESTClient<ContinuousClock>
    let setupClient: RESTClient<ContinuousClock>
    let scheduling: RESTSchedulingReceipt

    /// Prepares bounded owners and optional full-population observers; setup uses an unobserved client.
    /// - Parameters:
    ///   - scenario: Finite scripted wire behavior.
    ///   - concurrency: Validated positive maximum admitted cohort.
    ///   - delay: Validated artificial phase delay.
    ///   - statistics: Shared fixed-storage collector; nil disables legacy phase observers.
    ///   - observeAdmission: Enables genuine RESTClient.execute entry in the shared uptime clock domain.
    init(scenario: RESTTimingScenario, concurrency: Int, delay: Duration, statistics: RunStatistics?,
        observeAdmission: Bool = false) {
        let clock = ContinuousClock()
        let policy = scenario == .orderedMutationDefaultV1 ? SchedulingPolicy() : SchedulingPolicy(maximumQueuedRequests: concurrency * 2,
            maximumQueuedRequestsPerIdentity: concurrency * 2, maximumQueuedBytes: 1_048_576,
            maximumQueuedBytesPerIdentity: 1_048_576, maximumConcurrentRequests: concurrency,
            maximumConcurrentRequestsPerIdentity: concurrency, maximumMetadata: 4_096,
            maximumQueueAge: .seconds(10), fairnessInterval: .microseconds(100),
            provisionalWindow: .microseconds(1), initialGlobalRequestsPerSecond: 1_000_000)
        scheduling = RESTSchedulingReceipt(policy: policy, usesDefaults: scenario == .orderedMutationDefaultV1)
        coordinator = RateLimitCoordinator(clock: clock, policy: policy)
        cache = ReadCache(clock: clock, policy: ReadCachePolicy(maximumEntries: max(128, concurrency),
            maximumBytes: 1_048_576, maximumEntriesPerIdentity: max(128, concurrency), maximumBytesPerIdentity: 1_048_576))
        coalescer = RequestCoalescer(maximumFlights: concurrency, maximumFlightsPerIdentity: concurrency,
            maximumWaiters: concurrency, maximumWaitersPerFlight: concurrency)
        transport = RESTScriptTransport(scenario: scenario, delay: delay)
        let origin = clock.now
        let timing = statistics.map { statistics in OperationTiming(sink: { sample in
            let workload: BenchmarkWorkload
            switch sample.phase {
            case .httpAdmission: workload = .restAdmission
            case .httpHeaders: workload = .restHeaders
            case .httpBody: workload = .restBody
            case .httpCoalescedSubscriber: workload = .restSubscriber
            case .httpExecutionJoined: workload = .restExecution
            default: return
            }
            let outcome: BenchmarkOutcome
            switch sample.outcome {
            case .succeeded: outcome = .success
            case .failed: outcome = .failure
            case .cancelled: outcome = .cancelled
            case .uncertain: outcome = .uncertain
            }
            statistics.record(sample.elapsed, workload: workload, outcome: outcome)
        }, now: { origin.duration(to: clock.now) }) }
        let phases = statistics.map { statistics in RESTTiming(sink: { sample in
            let workload: BenchmarkWorkload
            switch sample.phase {
            case .construction: workload = .restConstruct
            case .ordering: workload = .restOrderWait
            case .cacheLookup: workload = .restCacheLookup
            case .decode: workload = .restDecode
            case .retryWait: workload = .restRetryWait
            }
            let outcome: BenchmarkOutcome
            switch sample.outcome {
            case .succeeded: outcome = .success
            case .failed: outcome = .failure
            case .cancelled: outcome = .cancelled
            case .uncertain: outcome = .uncertain
            }
            // Invalid observer clock differences remain explicit histogram loss, not zero latency.
            if let elapsed = sample.elapsed { statistics.record(elapsed, workload: workload, outcome: outcome) }
            else { statistics.record(.seconds(-1), workload: workload, outcome: outcome) }
        }, now: { origin.duration(to: clock.now) }) }
        let arrivalPhases: RESTTiming? = observeAdmission ? RESTTiming(sink: { _ in }, onOwnerAdmission: {
            RESTArrivalAdmissionContext.current?.include($0)
        }) : nil
        let identity = RateLimitIdentity()
        let retry = RetryPolicy(maximumAttempts: 2, initialBackoff: delay, maximumBackoff: delay)
        client = RESTClient(credential: .none, identity: identity, transport: transport, coordinator: coordinator,
            clock: clock, cache: cache, coalescer: coalescer, retryPolicy: retry,
            maximumResponseBytes: 262_144, maximumExchangeDuration: .seconds(10), timing: timing, phaseTiming: arrivalPhases ?? phases)
        setupClient = RESTClient(credential: .none, identity: identity, transport: transport, coordinator: coordinator,
            clock: clock, cache: cache, coalescer: coalescer, retryPolicy: retry,
            maximumResponseBytes: 262_144, maximumExchangeDuration: .seconds(10))
    }

    /// Joins owners and removes retained snapshots before reading resource counts.
    /// - Returns: Exact scheduler, flight, cache and adapter ownership after shutdown.
    func shutdown() async -> RESTTimingCleanup {
        await coalescer.close(); await coordinator.close(); await cache.removeAll()
        let scheduler = await coordinator.snapshot(), flights = await coalescer.snapshot()
        let cached = await cache.snapshot(), wire = await transport.snapshot()
        return RESTTimingCleanup(active: scheduler.activeCount, queued: scheduler.queuedCount,
            ordered: scheduler.orderedOperationsCount, flights: flights.flights, waiters: flights.waiters,
            cacheEntries: cached.entries, transportBodies: wire.bodies, transportActive: wire.active)
    }
}

/// Constructs finite request representations, with explicit cache and replay policies.
/// - Parameters:
///   - scenario: Reviewed fixture identity selecting wire and decoding semantics.
///   - ordinal: Bounded run-local request number.
/// - Returns: Immutable descriptor prepared before caller measurement.
/// - Throws: Descriptor or JSON body validation errors.
private func restEndpoint(scenario: RESTTimingScenario, ordinal: Int, partition: String? = nil) throws -> Endpoint<Data> {
    let reuse: ReadPolicy?
    switch scenario {
    case .cacheMiss, .cacheFresh: reuse = ReadPolicy(coalescing: false, timeToLive: .seconds(60))
    case .cacheExpiry: reuse = ReadPolicy(coalescing: false, timeToLive: .milliseconds(2))
    case .coalesced, .independentKeys: reuse = ReadPolicy()
    default: reuse = nil
    }
    let unsafe = scenario == .orderedMutation || scenario == .orderedMutationDefaultV1 || scenario == .uncertainMutation
    return try Endpoint(method: unsafe ? "POST" : "GET", path: ["timing", "fixture"],
        route: "/timing/fixture", query: [QueryItem(name: "ordinal", value: String(scenario == .cacheFresh ? 0 : ordinal))],
        authentication: .none, majorParameter: partition, body: unsafe ? RequestBody.json(JSONValue.object(["fixture": .bool(true)])) : nil,
        retrySafety: unsafe ? .unsafe : .safe, readPolicy: reuse, decode: { data in
            _ = try JSONValue.parse(data); return data
        })
}

/// Maps only reviewed typed failures, never arbitrary error text, to whole-population outcome labels.
/// - Parameter error: Existing execution error after all owned cleanup joins.
/// - Returns: Finite classification retaining uncertainty and cancellation semantics.
private func restOutcome(_ error: any Error) -> BenchmarkOutcome {
    if case .unknownMutationOutcome = error as? DiscordError { return .uncertain }
    if error is CancellationError || (error as? DiscordError) == .cancelled { return .cancelled }
    if (error as? TransportFailure) == .deadlineExceeded || (error as? RateLimitFailure) == .deadlineExceeded { return .timedOut }
    if let failure = error as? RateLimitFailure, failure == .queueFull || failure == .metadataFull { return .rejected }
    return .failure
}

/// Bounded scripted adapter; response byte generation is pull-based with no background producer or sockets.
private actor RESTScriptTransport: HTTPTransport {
    private let scenario: RESTTimingScenario
    private let delay: Duration
    private var calls = 0, active = 0, bodies = 0, peakActive = 0
    private var retrying: Set<String> = []
    private var held = false
    private var headerWaiters: [CheckedContinuation<Void, Never>] = []

    /// Stores finite behavior without creating a task or beginning an exchange.
    /// - Parameters:
    ///   - scenario: Reviewed response behavior.
    ///   - delay: Artificial header, body or retry delay.
    init(scenario: RESTTimingScenario, delay: Duration) { self.scenario = scenario; self.delay = delay }

    /// Holds the next coalesced wave at a real injected header-service boundary.
    func holdHeaders() { held = true }
    /// Releases the bounded exchange waiters after exact subscribers have registered.
    func releaseHeaders() {
        held = false
        let waiters = headerWaiters; headerWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Executes exactly one scripted exchange and transfers a pull body to the caller.
    /// - Parameters:
    ///   - request: Real REST-constructed request; only its finite ordinal participates in retry state.
    ///   - context: Original cooperative cancellation/deadline context.
    /// - Returns: Scripted status, rate headers and bounded response body.
    /// - Throws: Actual cancellation/context errors, or the explicit uncertain-mutation fixture failure.
    func execute<C: Clock>(_ request: HTTPRequest, context: TransportContext<C>) async throws -> HTTPResponse
        where C.Duration == Duration {
        try context.check()
        calls += 1; active += 1; peakActive = max(peakActive, active)
        do {
            if held { await withCheckedContinuation { headerWaiters.append($0) } }
            if scenario == .delayedHeaders || scenario == .orderedMutationDefaultV1, delay > .zero { try await context.clock.sleep(for: delay) }
            try context.check()
            if scenario == .uncertainMutation { throw TransportFailure.closed }
            let key = request.url.query ?? ""
            let firstRetry = (scenario == .rateLimitRetry || scenario == .serverRetry) && retrying.insert(key).inserted
            if !firstRetry { retrying.remove(key) }
            let status = scenario == .retryExhausted ? 503 : (firstRetry ? (scenario == .rateLimitRetry ? 429 : 503) : 200)
            let data: Data
            if status == 429 { data = Data("{\"retry_after\":0.001,\"global\":false}".utf8) }
            else if scenario == .malformed { data = Data("[malformed".utf8) }
            else if scenario == .largeBody { data = Data(("\"" + String(repeating: "x", count: 131_072) + "\"").utf8) }
            else { data = Data("{\"fixture\":true}".utf8) }
            let source = RESTScriptBody(data: data, chunkBytes: scenario == .streamedBody || scenario == .largeBody ? 4_096 : max(1, data.count),
                delay: scenario == .delayedBody ? delay : .zero, cancelled: scenario == .cancelled)
            bodies += 1
            let body = try BodyStream(maximumChunkBytes: max(4_096, data.count), next: { try await source.next() },
                close: { await source.close(); await self.bodyClosed() })
            return HTTPResponse(status: status, headers: [
                HTTPHeader(name: "X-RateLimit-Bucket", value: "offline-timing"),
                HTTPHeader(name: "X-RateLimit-Limit", value: "1000000"),
                HTTPHeader(name: "X-RateLimit-Remaining", value: "1000000"),
                HTTPHeader(name: "X-RateLimit-Reset-After", value: "0.001")], body: body)
        } catch { active -= 1; throw error }
    }

    /// Releases response ownership exactly once, invoked only by BodyStream's joined close owner.
    private func bodyClosed() { active -= 1; bodies -= 1 }

    /// Reads numeric counters after logical callers finish, outside their timers.
    /// - Returns: Exchanges and live/peak ownership; no request labels are retained in output.
    func snapshot() -> (calls: Int, active: Int, bodies: Int, peakActive: Int) { (calls, active, bodies, peakActive) }
}

/// A single bounded body with explicit EOF and cancellation-aware injected service delay.
private actor RESTScriptBody {
    private let data: Data
    private let chunkBytes: Int
    private let delay: Duration
    private let cancelled: Bool
    private var offset = 0

    /// Retains one finite fixture body; no producer task or chunk queue is created.
    /// - Parameters:
    ///   - data: At most 131,074 response bytes.
    ///   - chunkBytes: Positive pull chunk bound.
    ///   - delay: Injected delay before each nonempty pull.
    ///   - cancelled: Emits the fixture's typed cancellation at the body boundary.
    init(data: Data, chunkBytes: Int, delay: Duration, cancelled: Bool) {
        self.data = data; self.chunkBytes = chunkBytes; self.delay = delay; self.cancelled = cancelled
    }

    /// Pulls one slice or returns EOF, honoring actual task cancellation as well as the explicit fixture.
    /// - Returns: At most chunkBytes bytes, or nil once complete/closed.
    /// - Throws: Typed cancellation or clock sleep failure.
    func next() async throws -> Data? {
        if cancelled { withUnsafeCurrentTask { $0?.cancel() }; try Task.checkCancellation() }
        guard offset < data.count else { return nil }
        if delay > .zero { try await ContinuousClock().sleep(for: delay) }
        try Task.checkCancellation()
        let end = min(data.count, offset + chunkBytes)
        defer { offset = end }
        return data.subdata(in: offset..<end)
    }

    /// Makes later pulls reach EOF; BodyStream separately guarantees once-only cleanup.
    func close() { offset = data.count }
}
