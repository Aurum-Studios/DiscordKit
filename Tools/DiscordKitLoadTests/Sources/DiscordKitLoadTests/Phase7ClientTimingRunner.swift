// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/Phase7ClientTimingRunner.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordClient
import DiscordCore
import DiscordGateway
import DiscordHTTP
import DiscordLogging
import DiscordTransport
import Foundation

/// Finite client ownership scripts, using local injected peers and a noncredential sentinel only.
enum ClientTimingScenario: String, CaseIterable, Codable, Sendable {
    case construction = "client.construction"
    case lifecycle = "client.lifecycle"
    case cancelledDiscovery = "client.cancelledDiscovery"
    case discoveryFailure = "client.discoveryFailure"
    case projectionFailure = "client.projectionFailure"
    case slowSubscriber = "client.slowSubscriber"
}

/// Independently read resource receipts after every client task, callback and dependency close joins.
struct ClientTimingCleanup: Codable, Equatable, Sendable {
    let connections: Int
    let leases: Int
    let subscriptions: Int
    let bufferedEvents: Int
    let clientReservations: Int
    let restReservations: Int
    let bodies: Int
    let runOwners: Int
    let dependencies: Int
    /// Sums remaining observed ownership; counts are deliberately retained separately for diagnosis.
    var remainingOwners: Int {
        connections + leases + subscriptions + bufferedEvents + clientReservations + restReservations + bodies + runOwners + dependencies
    }
    /// Accepts cleanup only when every observed resource receipt is empty.
    var isEmpty: Bool { remainingOwners == 0 }
}

/// Bounded whole-population timing and joined ownership evidence, with no external readiness claim.
struct ClientTimingReport: Codable, Sendable {
    let scenario: String
    let requests: Int
    let concurrency: Int
    let counts: BenchmarkCounts
    let metrics: [BenchmarkMetric]
    let clockDomain: String
    let durationNanoseconds: UInt64
    let cleanup: ClientTimingCleanup
    let localReadyClients: Int
    let slowSubscriberRetainedEvents: Int
    let discoveryExecutions: Int
    let notes: [String]
}

/// Times production client owners separately from caller dependency allocation and diagnostic sampling.
struct Phase7ClientTimingRunner: Sendable {
    /// Constructs finite independent clients, drives local protocol sessions and joins every owner.
    /// - Parameters:
    ///   - scenario: Explicit task-free, successful, rejected, cancelled or slow-consumer fixture.
    ///   - requests: Independent client attempts, in 1...100,000; external cancellation stops new waves.
    ///   - concurrency: Simultaneously owned clients, in 1...64 and no greater than requests.
    ///   - delay: Explicit projection/dependency delay, in zero through one second; included in owner time.
    /// - Returns: Every completed attempt outcome, bounded owner histograms and exact cleanup receipts.
    /// - Throws: Invalid limits, fixture allocation/configuration errors, or integrity failure after joined
    ///   cleanup when a script's actual result differs from its declared outcome/readiness/ownership.
    ///   Expected runtime errors become outcomes. External cancellation returns its joined partial population.
    func run(scenario: ClientTimingScenario, requests: Int = 8, concurrency: Int = 1,
             delay: Duration = .zero) async throws -> ClientTimingReport {
        guard (1...100_000).contains(requests), (1...64).contains(concurrency), concurrency <= requests,
              delay >= .zero, delay <= .seconds(1) else { throw LoadFailure.invalidArguments }
        let statistics = try RunStatistics(workloads: [.clientConstruction, .clientDiscovery, .clientIngestion,
            .clientLocalReady, .clientShutdown, .clientLifecycle])
        let clock = ContinuousClock(), origin = clock.now
        let intervals = DiscordIntervalTiming(clockDomain: UInt64.random(in: 1...UInt64.max), sink: { event in
            guard event.kind == .ended, event.operation == .clientLifecycle, event.stage != .construction,
                  let workload = clientTimingWorkload(event.stage) else { return }
            statistics.record(event.validity == .valid ? event.elapsedNanoseconds.map(Duration.nanoseconds) ?? .seconds(-1) : .seconds(-1),
                workload: workload, outcome: clientTimingOutcome(event.outcome))
        }, now: { origin.duration(to: clock.now) })
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        var completed = 0, ready = 0, drops = 0, discoveries = 0
        var invalidReceipt = false
        var cleanup = clientTimingSum([])
        for wave in stride(from: 0, to: requests, by: concurrency) {
            if Task.isCancelled { break }
            // Dependency allocation precedes client initializer hooks; every client uses private authorities.
            let fixtures = try (wave..<min(requests, wave + concurrency)).map { _ in
                try ClientTimingFixture(scenario: scenario, delay: delay, intervals: intervals, statistics: statistics)
            }
            await withTaskGroup(of: ClientTimingResult.self) { group in
                for fixture in fixtures { group.addTask { await fixture.execute(scenario: scenario) } }
                for await result in group {
                    completed += 1; outcomes[result.outcome, default: 0] += 1
                    ready += result.localReady ? 1 : 0; drops += result.drops; discoveries += result.discoveries
                    cleanup = clientTimingSum([cleanup, result.cleanup])
                    if !result.cleanup.isEmpty { invalidReceipt = true }
                    if !Task.isCancelled, !clientTimingAccepts(result, scenario: scenario) { invalidReceipt = true }
                }
            }
        }
        guard !invalidReceipt else {
            throw Phase7TimingError.integrityFailure("Client fixture outcome or joined ownership receipt disagrees with its selected script")
        }
        return ClientTimingReport(scenario: scenario.rawValue, requests: requests, concurrency: concurrency,
            counts: .init(offered: UInt64(completed), admitted: UInt64(completed), completed: UInt64(completed),
                outcomes: outcomes, deadlineMisses: 0), metrics: statistics.metrics(), clockDomain: statistics.clockDomain,
            durationNanoseconds: try BenchmarkTime.nanoseconds(duration: origin.duration(to: clock.now)),
            cleanup: cleanup, localReadyClients: ready, slowSubscriberRetainedEvents: drops,
            discoveryExecutions: discoveries, notes: [
                "Injected HTTP/WebSocket peers only; the sentinel is not a Discord credential and no network connection is opened.",
                "Construction measures the complete caller constructor call after dependency allocation, including synchronous opt-in observer callbacks; it launches no tasks and performs no I/O. The shorter runtime initializer-body hook is excluded from this histogram.",
                "Discovery measures shared budget reservation, one typed Gateway discovery and task-free shard preparation; it excludes socket startup.",
                "Local start spans run entry through projection/publication of every selected shard's first READY; this fixture does not qualify live Discord READY.",
                "Ingestion spans each raw event's cancellation check, private receiver, projection and public hub publication; subscriber handlers are independent.",
                "Shutdown measures each caller's actual wait through owner completion; lifecycle ends after children, leases, hub, budget and dependency cleanup join.",
                "Every started interval retains its local success, failure or cancellation outcome. Nested owner populations overlap and percentiles cannot be subtracted.",
                "Counts admit actual constructed clients, including discovery/projection failures; discovery executions and locally ready clients are separate receipts.",
                "Overall duration includes fixture allocation, caller orchestration and cleanup diagnostics; finite owner metrics retain their independent boundaries.",
                "The slow-subscriber receipt counts actual unread retained copies after the primary consumes both events, before joined shutdown discards them.",
                "Warmup uses independent clients and authorities. The construction-only scenario closes task-free clients without discovering or leasing."
            ])
    }
}

/// One attempt's terminal owner outcome and diagnostics sampled only after its terminal timestamp.
private struct ClientTimingResult: Sendable {
    let outcome: BenchmarkOutcome
    let localReady: Bool
    let drops: Int
    let discoveries: Int
    let cleanup: ClientTimingCleanup
}

/// One production composition with exclusively owned finite local dependencies and bounded subscription.
private struct ClientTimingFixture: Sendable {
    let client: DiscordClient<ContinuousClock, InProcessShardLeaseStore<ContinuousClock>>
    let peer: ClientTimingPeer
    let http: ClientTimingHTTP
    let hub: GatewayEventHub
    let budget: ClientResourceBudget
    let leases: InProcessShardLeaseStore<ContinuousClock>
    let coordinator: RateLimitCoordinator<ContinuousClock>
    let owners: ClientTimingOwners

    /// Allocates private test authorities before the client's measured initializer body.
    /// - Parameters:
    ///   - scenario: Finite injected discovery, projection or subscription behavior.
    ///   - delay: Bounded explicit projection and dependency-cleanup wait; cancellation remains cooperative.
    ///   - intervals: Opt-in observer shared by this run's independent compositions.
    ///   - statistics: Bounded collector receiving one full caller constructor duration; the shorter
    ///     initializer-body hook is ignored by the runtime sink to prevent duplicate populations.
    /// - Throws: Invalid fixed fixture limits or observer-independent dependency construction failures.
    init(scenario: ClientTimingScenario, delay: Duration, intervals: DiscordIntervalTiming, statistics: RunStatistics) throws {
        let clock = ContinuousClock()
        peer = ClientTimingPeer()
        http = ClientTimingHTTP(scenario: scenario)
        hub = GatewayEventHub(configuration: try .init(maximumSubscriptions: 2, maximumBufferedEvents: 8,
            maximumBufferedBytes: 16_384, maximumEventsPerSubscription: 4))
        budget = try ClientResourceBudget(maximumClients: 1, maximumShards: 1)
        leases = try InProcessShardLeaseStore(clock: clock, maximumLeases: 1)
        coordinator = RateLimitCoordinator(clock: clock)
        owners = ClientTimingOwners()
        let token = try BotToken("synthetic-local-client-only")
        let rest = RESTClient(credential: .bot(token), identity: RateLimitIdentity(), transport: http,
            coordinator: coordinator, clock: clock, retryPolicy: .init(maximumAttempts: 1))
        let authority = try ClientAuthority(botID: UserID(rawValue: 1), clock: clock, budget: budget)
        let owners = owners
        let configuration = try ClientConfiguration(intents: [], maximumShards: 1,
            shard: .init(maximumBufferedEvents: 4, maximumBufferedBytes: 16_384, maximumReconnectAttempts: 0))
        let services = ServiceContext(rest: rest)
        let constructorStart = clock.now
        client = DiscordClient(token: token, configuration: configuration,
            services: services, transport: peer, clock: clock, leases: leases,
            authority: authority, events: hub, project: { _ in
                if scenario == .projectionFailure { throw GatewayFailure.invalidPayload }
                if delay > .zero { try await clock.sleep(for: delay) }
            }, cleanup: {
                // Mandatory cleanup still finishes when the owning task was cancelled.
                if delay > .zero { try? await clock.sleep(for: delay) }
                await owners.releaseDependency()
            }, intervals: intervals)
        let constructorEnd = clock.now
        statistics.record(constructorStart.duration(to: constructorEnd), workload: .clientConstruction, outcome: .success)
    }

    /// Owns the run task, cancels it on any driver error, then awaits shutdown and every task result.
    /// - Parameter scenario: Same validated finite script used to allocate this fixture.
    /// - Returns: Exact joined result; runtime failure and cancellation remain reportable outcomes.
    func execute(scenario: ClientTimingScenario) async -> ClientTimingResult {
        var result = BenchmarkOutcome.success, localReady = false, retained = 0
        if scenario == .construction {
            await client.shutdown()
        } else {
            do {
                let subscription = try await hub.subscribe()
                let slow = scenario == .slowSubscriber
                    ? try await hub.subscribe(policy: .dropNewest, maximumEvents: 1) : nil
                await owners.startRun()
                let run = Task { () -> BenchmarkOutcome in
                    let outcome: BenchmarkOutcome
                    do { try await client.run(); outcome = .success }
                    catch { outcome = error is CancellationError ? .cancelled : .failure }
                    await owners.finishRun()
                    return outcome
                }
                do {
                    if scenario == .cancelledDiscovery {
                        while await http.executionCount == 0 { try Task.checkCancellation(); await Task.yield() }
                        run.cancel()
                    } else if scenario == .discoveryFailure || scenario == .projectionFailure {
                        // Error owners finish subscriptions; awaiting their task retains joined cleanup.
                    } else {
                        var iterator = subscription.makeAsyncIterator()
                        guard try await iterator.next()?.name == "READY", try await iterator.next()?.name == "CLIENT_TIMING" else {
                            throw LoadFailure.unexpectedResponse
                        }
                        localReady = await client.snapshot().ready
                        if scenario == .slowSubscriber { retained = await hub.snapshot().bufferedEvents }
                    }
                } catch { result = error is CancellationError ? .cancelled : .failure; run.cancel() }
                if scenario == .discoveryFailure || scenario == .projectionFailure || scenario == .cancelledDiscovery {
                    let terminal = await run.value
                    if result == .success { result = terminal }
                    await client.shutdown()
                } else {
                    await client.shutdown()
                    let terminal = await run.value
                    if result == .success { result = terminal }
                }
                // Retain the slow subscription until after cleanup; it must not own any remaining copy.
                _ = slow
            } catch {
                result = error is CancellationError ? .cancelled : .failure
                await client.shutdown()
            }
        }
        let hubState = await hub.snapshot(), rateState = await coordinator.snapshot()
        return ClientTimingResult(outcome: result, localReady: localReady,
            drops: retained, discoveries: await http.executionCount,
            cleanup: .init(connections: await peer.activeConnections(), leases: await leases.retainedLeaseCount(),
                subscriptions: hubState.subscriptions, bufferedEvents: hubState.bufferedEvents,
                clientReservations: await budget.snapshot().clients, restReservations: rateState.activeCount + rateState.queuedCount,
                bodies: await http.bodyOwners(), runOwners: await owners.runs, dependencies: await owners.dependencies))
    }
}

/// One discovery exchange with explicit body ownership and cancellable suspended-discovery script.
private actor ClientTimingHTTP: HTTPTransport {
    private let scenario: ClientTimingScenario
    private var body: ClientTimingBody?
    private(set) var executionCount = 0
    /// Selects one finite local HTTP behavior before any request can execute.
    /// - Parameter scenario: Malformed, suspended or ordinary discovery response; no external request occurs.
    init(scenario: ClientTimingScenario) { self.scenario = scenario }
    /// Transfers one bounded discovery response or waits cancellably for the cancellation fixture.
    /// - Parameters:
    ///   - request: Production v10 Gateway discovery request; its credential is never inspected or recorded.
    ///   - context: Existing cancellation/deadline source.
    /// - Returns: Local successful HTTP response containing valid or deliberately malformed discovery JSON.
    /// - Throws: Cancellation/context failure or impossible fixed body-stream configuration failure.
    func execute<C: Clock>(_ request: HTTPRequest, context: TransportContext<C>) async throws -> HTTPResponse where C.Duration == Duration {
        try context.check(); executionCount += 1
        if scenario == .cancelledDiscovery { try await ContinuousClock().sleep(for: .seconds(60)); throw CancellationError() }
        let json = scenario == .discoveryFailure ? "{}" : #"{"url":"wss://gateway.discord.gg","shards":1,"session_start_limit":{"total":10,"remaining":10,"reset_after":60000,"max_concurrency":1}}"#
        let source = ClientTimingBody(Data(json.utf8)); body = source
        return HTTPResponse(status: 200, body: try BodyStream(maximumChunkBytes: 4096,
            next: { await source.take() }, close: { await source.close() }))
    }
    /// Reads actual body-close receipt after the run task has terminated.
    /// - Returns: One if transferred response-body ownership was never closed, otherwise zero.
    func bodyOwners() async -> Int { await body?.remainingOwners() ?? 0 }
}

/// Bounded pull-body storage distinguishes consuming EOF from releasing the transferred owner.
private actor ClientTimingBody {
    private var bytes: Data?
    private var closed = false
    /// Retains one complete finite fixture body, outside any measured collection boundary.
    /// - Parameter bytes: Nonempty discovery JSON smaller than the configured 4096-byte chunk.
    init(_ bytes: Data) { self.bytes = bytes }
    /// Transfers bytes once, then returns EOF without falsely marking ownership closed.
    /// - Returns: The first body chunk or nil after transfer/close.
    func take() -> Data? { defer { bytes = nil }; return bytes }
    /// Releases response-body ownership and unread bytes idempotently.
    func close() { closed = true; bytes = nil }
    /// Reports whether the actual close callback ran, independently of EOF.
    /// - Returns: Zero after close, otherwise one.
    func remainingOwners() -> Int { closed ? 0 : 1 }
}

/// Task-free transport retaining at most one scripted socket until its explicit close receipt.
private actor ClientTimingPeer: WebSocketTransport {
    private var socket: ClientTimingSocket?
    /// Transfers the only local connection after validating context; no socket/network API is called.
    /// - Parameters:
    ///   - request: Production upgrade request, neither inspected nor retained.
    ///   - context: Existing cancellation/deadline source.
    /// - Returns: A bounded local peer implementing Hello, Identify and a single application dispatch.
    /// - Throws: Context failure or script exhaustion if reconnect unexpectedly occurs.
    func connectWebSocket<C: Clock>(_ request: HTTPRequest, context: TransportContext<C>) async throws -> any WebSocketConnection where C.Duration == Duration {
        try context.check()
        guard socket == nil else { throw TransportFailure.scriptExhausted }
        let connection = ClientTimingSocket(); socket = connection; return connection
    }
    /// Reads the retained connection's explicit close receipt after owner completion.
    /// - Returns: One only while the local connection is still open; zero before construction or after close.
    func activeConnections() async -> Int { await socket?.remainingOwners() ?? 0 }
}

/// Single-reader peer with three finite frames and one explicitly owned read continuation.
private actor ClientTimingSocket: WebSocketConnection {
    private var frames: [WebSocketMessage] = [.text(#"{"op":10,"d":{"heartbeat_interval":60000}}"#)]
    private var waiter: CheckedContinuation<WebSocketMessage?, any Error>?
    private var closed = false
    /// Accepts real production Identify/heartbeat writes and injects only their bounded fixture replies.
    /// - Parameters:
    ///   - message: Complete outgoing v10 control JSON; bytes are not retained.
    ///   - context: Existing cancellation/deadline source.
    /// - Throws: Context, malformed JSON or closed-connection failure.
    func send<C: Clock>(_ message: WebSocketMessage, context: TransportContext<C>) async throws where C.Duration == Duration {
        try context.check()
        guard !closed, case .text(let text) = message, case .object(let data) = try JSONValue.parse(Data(text.utf8)),
              case .number(let opcode) = data["op"] else { throw TransportFailure.closed }
        if opcode.rawValue == "2" {
            emit(.text(#"{"op":0,"s":1,"t":"READY","d":{"session_id":"local","resume_gateway_url":"wss://gateway.discord.gg"}}"#))
            emit(.text(#"{"op":0,"s":2,"t":"CLIENT_TIMING","d":{"fixture":true}}"#))
        } else if opcode.rawValue == "1" { emit(.text(#"{"op":11,"d":null}"#)) }
    }
    /// Delivers one finite peer reply directly to the sole reader, otherwise retains bounded setup frames.
    /// - Parameter frame: Reviewed Hello/READY/dispatch/heartbeat fixture; no user payload is accepted.
    private func emit(_ frame: WebSocketMessage) {
        guard !closed else { return }
        if let waiter { self.waiter = nil; waiter.resume(returning: frame) } else { frames.append(frame) }
    }
    /// Transfers one frame or parks a single reader; cancellation triggers the same awaited owner close.
    /// - Parameter context: Existing cancellation/deadline source.
    /// - Returns: Next finite frame, or nil when the owner closes the connection.
    /// - Throws: Context failure; cancellation ultimately joins explicit socket close.
    func receive<C: Clock>(context: TransportContext<C>) async throws -> WebSocketMessage? where C.Duration == Duration {
        try context.check()
        return try await withTaskCancellationHandler {
            if !frames.isEmpty { return frames.removeFirst() }
            if closed { return nil }
            return try await withCheckedThrowingContinuation { waiter = $0 }
        } onCancel: { Task { await self.close() } }
    }
    /// Releases the reader and queued frames exactly once; repeat cleanup remains harmless.
    func close() { closed = true; frames.removeAll(); waiter?.resume(returning: nil); waiter = nil }
    /// Reports active adapter ownership independently of the run task's result.
    /// - Returns: Zero after actual close, otherwise one.
    func remainingOwners() -> Int { closed ? 0 : 1 }
}

/// Explicit task and dependency counters, mutated only by their actual lifetime owners.
private actor ClientTimingOwners {
    private(set) var runs = 0
    private(set) var dependencies = 1
    /// Registers the only run task before handing it execution ownership.
    func startRun() { runs += 1 }
    /// Releases run ownership only after production run returns through structured cleanup.
    func finishRun() { runs -= 1 }
    /// Records the actual exactly-once client cleanup callback after optional dependency delay.
    func releaseDependency() { dependencies -= 1 }
}

/// Maps only actual client owner stages to fixed catalog-seven identities.
/// - Parameter stage: Runtime-established finite boundary.
/// - Returns: Matching metric, or nil for unrelated boundaries.
private func clientTimingWorkload(_ stage: DiscordIntervalStage) -> BenchmarkWorkload? {
    switch stage {
    case .construction: .clientConstruction
    case .discovery: .clientDiscovery
    case .ingestion: .clientIngestion
    case .localReady: .clientLocalReady
    case .shutdown: .clientShutdown
    case .operation: .clientLifecycle
    default: nil
    }
}

/// Preserves each local interval's established result, including invalid/absent terminal policy.
/// - Parameter outcome: Actual terminal classification from a client owner.
/// - Returns: Matching whole-population category; an absent terminal result is a failure.
private func clientTimingOutcome(_ outcome: DiscordIntervalOutcome?) -> BenchmarkOutcome {
    switch outcome {
    case .succeeded: .success
    case .cancelled: .cancelled
    case .uncertain: .uncertain
    case .failed, nil: .failure
    }
}

/// Reduces independent cleanup receipts after all finite waves have joined.
/// - Parameter receipts: One read-back per completed client; empty after cancellation before the first wave.
/// - Returns: Field-preserving aggregate; no missing receipt is silently interpreted as released ownership.
private func clientTimingSum(_ receipts: [ClientTimingCleanup]) -> ClientTimingCleanup {
    .init(connections: receipts.reduce(0) { $0 + $1.connections }, leases: receipts.reduce(0) { $0 + $1.leases },
        subscriptions: receipts.reduce(0) { $0 + $1.subscriptions }, bufferedEvents: receipts.reduce(0) { $0 + $1.bufferedEvents },
        clientReservations: receipts.reduce(0) { $0 + $1.clientReservations }, restReservations: receipts.reduce(0) { $0 + $1.restReservations },
        bodies: receipts.reduce(0) { $0 + $1.bodies }, runOwners: receipts.reduce(0) { $0 + $1.runOwners },
        dependencies: receipts.reduce(0) { $0 + $1.dependencies })
}

/// Checks actual post-join scenario receipts independently of aggregate histogram completeness.
/// - Parameters:
///   - result: Joined attempt outcome and separately sampled resource/ready/subscriber receipts.
///   - scenario: Selected finite fixture whose expected behavior must remain stable in optimized runs.
/// - Returns: True only for the exact outcome, discovery count and local-ready/retained-copy population.
private func clientTimingAccepts(_ result: ClientTimingResult, scenario: ClientTimingScenario) -> Bool {
    let expected: BenchmarkOutcome
    switch scenario {
    case .construction, .lifecycle, .slowSubscriber: expected = .success
    case .cancelledDiscovery: expected = .cancelled
    case .discoveryFailure, .projectionFailure: expected = .failure
    }
    return result.outcome == expected && result.discoveries == (scenario == .construction ? 0 : 1)
        && result.localReady == (scenario == .lifecycle || scenario == .slowSubscriber)
        && result.drops == (scenario == .slowSubscriber ? 1 : 0)
}
