// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/GatewayTimingRunner.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordBotDSL
import DiscordClient
import DiscordCommandDSL
import DiscordCommands
import DiscordDSL
import DiscordHTTP
import DiscordInteractions
import DiscordModels
import DiscordCore
import DiscordGateway
import DiscordLogging
import DiscordTransport
import Foundation

/// Reviewed local JSON socket and consumer populations; no case opens a network connection.
enum GatewayTimingScenario: String, CaseIterable, Codable, Sendable {
    case burst = "gateway.burst"
    case slowSubscriber = "gateway.slowSubscriber"
    case slowHandler = "gateway.slowHandler"
    case reconnect = "gateway.reconnect"
    case callbackError = "gateway.callbackError"
    case cancelled = "gateway.cancelled"
    case overloadRecovery = "gateway.overloadRecovery"
    case trustedInteraction = "gateway.trustedInteraction"
    case trustedDeferred = "gateway.trustedDeferred"
    case trustedUncertain = "gateway.trustedUncertain"
}

/// Exact independent resource receipts after socket, dispatcher and hub cleanup have joined.
struct GatewayTimingCleanup: Codable, Equatable, Sendable {
    let connections: Int
    let leases: Int
    let subscriptions: Int
    let bufferedEvents: Int
    let activeHandlers: Int
    let waitingHandlers: Int
    let pendingRequests: Int
    let applicationWrites: Int
    var acknowledgementReservations = 0
    var clientReservations = 0
    var restOwners = 0
    var remainingOwners: Int {
        /// Sums independently sampled still-owned resources; overlapping counters remain explicit fields.
        get { connections + leases + subscriptions + bufferedEvents + activeHandlers + waitingHandlers + pendingRequests + applicationWrites + acknowledgementReservations + clientReservations + restOwners }
    }
}

/// Whole offered dispatch population; control/Hello/READY events are measured but excluded from logical counts.
struct GatewayTimingReport: Codable, Sendable {
    let scenario: String
    let configuredRequests: Int
    let concurrency: Int
    let rate: Int
    let clockDomain: String
    let counts: BenchmarkCounts
    let metrics: [BenchmarkMetric]
    let durationNanoseconds: UInt64?
    let duplicateFrames: Int
    let reconnects: Int
    let slowSubscriberDrops: Int
    let recoverySucceeded: Bool
    let cleanup: GatewayTimingCleanup
    var initialResponseSends = 0
    var continuationSends = 0
    var controlWhileHandlerBlocked = false
    let notes: [String]
}

/// Bounded credential-free protocol fixture through production shard, hub and dispatcher owners.
struct GatewayTimingRunner: Sendable {
    /// Offers a finite stream, joins all callbacks and socket work, then snapshots all ownership counters.
    /// - Parameters:
    ///   - scenario: Reviewed traffic and failure behavior.
    ///   - requests: Offered application dispatches, in 1...100000.
    ///   - concurrency: Callback task limit, in 1...256, no greater than requests.
    ///   - delay: Slow callback/subscriber delay, in 0...1 second.
    ///   - rate: Scheduled upstream rate for slow-handler/recovery cases; other cases offer unpaced traffic.
    /// - Returns: All terminal outcomes, actual runtime interval populations, and joined cleanup receipts.
    /// - Throws: Invalid dimensions or fixture construction failure. Callback/refusal outcomes are counted.
    func run(scenario: GatewayTimingScenario, requests: Int = 32, concurrency: Int = 4,
             delay: Duration = .milliseconds(2), rate: Int = 1_000) async throws -> GatewayTimingReport {
        guard (1...100_000).contains(requests), (1...256).contains(concurrency), concurrency <= requests,
              delay >= .zero, delay <= .seconds(1), (1...1_000_000).contains(rate) else { throw LoadFailure.invalidArguments }
        if scenario == .trustedInteraction || scenario == .trustedDeferred || scenario == .trustedUncertain {
            return try await trustedGatewayRun(scenario: scenario, requests: requests, concurrency: concurrency, delay: delay, rate: rate)
        }
        let workloads: [BenchmarkWorkload] = [.gatewaySession, .gatewaySocketReceipt, .gatewayDecode,
            .gatewayIngestionQueue, .gatewayPublication, .gatewayHubResidence, .gatewayDispatch,
            .gatewayLocalQueue, .gatewayAdmission, .gatewayHandler, .gatewayHeartbeatACK, .gatewayReconnect, .gatewayShutdown]
        let statistics = try RunStatistics(workloads: workloads)
        let clock = ContinuousClock(), origin = clock.now
        let intervals = DiscordIntervalTiming(clockDomain: 606, sink: { event in
            guard event.kind == .ended, let outcome = event.outcome,
                  let workload = gatewayWorkload(event.operation, event.stage) else { return }
            let elapsed = event.validity == .valid ? event.elapsedNanoseconds.map(Duration.nanoseconds) ?? .seconds(-1) : .seconds(-1)
            let result: BenchmarkOutcome
            switch outcome {
            case .succeeded: result = .success
            case .failed: result = .failure
            case .cancelled: result = .cancelled
            case .uncertain: result = .uncertain
            }
            statistics.record(elapsed, workload: workload, outcome: result)
        }, now: { origin.duration(to: clock.now) })
        let leases = try InProcessShardLeaseStore(clock: clock, maximumLeases: 1)
        let discovery = try GatewayDiscovery(json: JSONValue.parse(Data(#"{"url":"wss://gateway.discord.gg","shards":1,"session_start_limit":{"total":10,"remaining":10,"reset_after":60000,"max_concurrency":1}}"#.utf8)))
        let startup = InProcessGatewayStartupCoordinator(botID: UserID(rawValue: 1), limit: discovery.sessionStartLimit, clock: clock)
        let peer = GatewayTimingTransport()
        let shard = GatewayShard(identity: try ShardIdentity(botID: UserID(rawValue: 1), topologyGeneration: 0, index: 0, count: 1),
            token: try BotToken("synthetic-local-only"), intents: 1, discovery: discovery, transport: peer,
            clock: clock, leases: leases, startup: startup,
            configuration: try GatewayShardConfiguration(maximumBufferedEvents: 8, maximumBufferedBytes: 32_768,
                maximumReconnectAttempts: 1, retryBase: .milliseconds(1), retryMaximum: .milliseconds(1)),
            intervals: intervals, random: { 0 })
        let cap = scenario == .overloadRecovery ? 1 : min(1_024, max(8, requests))
        let configuration = try GatewayEventHubConfiguration(maximumSubscriptions: 4, maximumBufferedEvents: cap + 2,
            maximumBufferedBytes: 4_194_304, maximumEventsPerSubscription: cap)
        let hub = GatewayEventHub(configuration: configuration, intervals: intervals)
        let subscription = try await hub.subscribe(policy: .dropNewest)
        let slow = scenario == .slowSubscriber ? try await hub.subscribe(policy: .dropNewest, maximumEvents: 1) : nil
        let authority = try GatewayHandlerAuthority(maximumActiveHandlers: scenario == .overloadRecovery ? 1 : concurrency,
            maximumWaitingHandlers: scenario == .overloadRecovery ? 0 : concurrency)
        let state = GatewayTimingResults()
        let dispatcher = GatewayEventHandlerDispatcher(configuration: try .init(maximumConcurrentHandlers: concurrency,
            maximumRetainedEvents: max(1, concurrency * 2)), authority: authority, serializesPerShard: false, intervals: intervals)
        let shardTask = Task { do { try await shard.run(); return BenchmarkOutcome.success }
            catch { return error is CancellationError ? BenchmarkOutcome.cancelled : .failure } }
        let handlerTask = Task {
            do {
                try await dispatcher.run(subscription: subscription) { _ in
                    await state.enter()
                    do {
                        if scenario == .overloadRecovery {
                            while await !state.controlReady() { try Task.checkCancellation(); await Task.yield() }
                        }
                        if scenario == .slowHandler || scenario == .overloadRecovery || scenario == .cancelled {
                            try await clock.sleep(for: scenario == .cancelled ? .seconds(60) : delay)
                        }
                        if scenario == .callbackError { await state.finish(.failure); throw LoadFailure.unexpectedResponse }
                        await state.finish(.success)
                    } catch {
                        if error is CancellationError { await state.finish(.cancelled) }
                        throw error
                    }
                }
            } catch { /* The exact invocation outcomes and refused remainder are counted below. */ }
            await state.dispatcherFinished()
        }
        let started = clock.now
        var offered = 0, refused = 0, duplicates = 0, reconnects = 0, slowDrops = 0
        var wasCancelled = false
        var driverFailure: (any Error)?
        do {
            _ = try await shard.nextEvents() // READY belongs to protocol setup, not the application population.
            var sequence: Int64 = 1
            for ordinal in 0..<requests {
                try Task.checkCancellation()
                if scenario == .slowHandler || scenario == .overloadRecovery {
                    try await clock.sleep(until: started.advanced(by: .nanoseconds(Int64(ordinal) * (1_000_000_000 / Int64(rate)))), tolerance: nil)
                }
                if scenario == .reconnect, ordinal == requests / 2 {
                    let socket = try await peer.current()
                    await socket.emit(.text(#"{"op":7,"d":null}"#))
                    guard let resumed = try await shard.nextEvents(), let value = resumed.last?.sequence else { throw LoadFailure.unexpectedResponse }
                    sequence = value; reconnects += 1
                }
                let socket = try await peer.current()
                sequence += 1
                let frame = WebSocketMessage.text("{\"op\":0,\"s\":\(sequence),\"t\":\"FUTURE_TIMING\",\"d\":{\"fixture\":true}}")
                offered += 1
                await socket.emit(frame)
                guard let batch = try await shard.nextEvents(), batch.count == 1 else { throw LoadFailure.unexpectedResponse }
                let publication = await hub.publish(batch[0])
                if publication.delivered == (slow == nil ? 0 : 1), await state.done() { refused += 1 }
                else if publication.delivered == 0 { refused += 1 }
                if scenario == .overloadRecovery, ordinal == 0 {
                    while await state.entered() == 0 { try Task.checkCancellation(); await Task.yield() }
                    let prior = await socket.heartbeatWrites()
                    await socket.emit(.text(#"{"op":1,"d":null}"#))
                    while await socket.heartbeatWrites() <= prior { try Task.checkCancellation(); await Task.yield() }
                    await state.confirmControl()
                }
                // In the slow-subscriber fixture the second bounded queue is never drained.
                slowDrops += scenario == .slowSubscriber ? publication.dropped : 0
                if ordinal % 8 == 0 { await socket.emit(frame); duplicates += 1 }
            }
            if scenario == .cancelled {
                while await state.entered() == 0 { try Task.checkCancellation(); await Task.yield() }
                handlerTask.cancel()
            }
            while true {
                let values = await state.snapshot()
                if values.done || values.finished + refused >= offered { break }
                try Task.checkCancellation(); await Task.yield()
            }
        } catch {
            wasCancelled = error is CancellationError || Task.isCancelled
            if !wasCancelled { driverFailure = error }
        }
        // Every unstructured fixture task has an explicit owner and an awaited terminal boundary.
        if wasCancelled { handlerTask.cancel() }
        await hub.finish(); await handlerTask.value
        await shard.stop(); shardTask.cancel(); _ = await shardTask.value
        await slow?.cancel()
        if let driverFailure { throw driverFailure }
        var recoverySucceeded = false
        if scenario == .overloadRecovery, !Task.isCancelled {
            // A fresh subscription/dispatcher reuses the same authority after the overloaded run joins.
            let recoveryHub = GatewayEventHub(configuration: configuration, intervals: intervals)
            let recoverySubscription = try await recoveryHub.subscribe()
            let recovered = GatewayTimingResults()
            let recoveryTask = Task {
                do { try await dispatcher.run(subscription: recoverySubscription) { _ in await recovered.finish(.success) } }
                catch { }
            }
            await recoveryHub.publish(try GatewayEvent(shard: shard.identity, name: "RECOVERY", sequence: 1, data: .null))
            do {
                while await recovered.snapshot().finished == 0 { try Task.checkCancellation(); await Task.yield() }
                recoverySucceeded = true
            } catch { recoveryTask.cancel() }
            await recoveryHub.finish(); await recoveryTask.value
            let recoveredState = await recoveryHub.snapshot()
            guard recoveredState.subscriptions == 0, recoveredState.bufferedEvents == 0 else { throw LoadFailure.unexpectedResponse }
        }
        let terminal = clock.now
        let values = await state.snapshot()
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        outcomes[.success] = UInt64(values.success)
        outcomes[.failure] = UInt64(values.failure)
        outcomes[.cancelled] = UInt64(values.cancelled)
        let remainder = max(0, offered - values.finished)
        let rejectedBeforeCancellation = min(refused, remainder)
        outcomes[.rejected] = UInt64(rejectedBeforeCancellation)
        outcomes[wasCancelled || scenario == .cancelled ? .cancelled : .rejected, default: 0] += UInt64(remainder - rejectedBeforeCancellation)
        let counts = BenchmarkCounts(offered: UInt64(offered), admitted: UInt64(values.invocations),
            completed: UInt64(offered), outcomes: outcomes, deadlineMisses: 0)
        try counts.validate()
        let shardState = await shard.snapshot(), hubState = await hub.snapshot(), handlers = await authority.snapshot()
        let cleanup = GatewayTimingCleanup(connections: await peer.activeConnections(), leases: await leases.retainedLeaseCount(),
            subscriptions: hubState.subscriptions, bufferedEvents: shardState.bufferedEvents + hubState.bufferedEvents,
            activeHandlers: handlers.activeHandlers, waitingHandlers: handlers.waitingHandlers,
            pendingRequests: shardState.pendingRequests, applicationWrites: shardState.applicationWrites)
        return GatewayTimingReport(scenario: scenario.rawValue, configuredRequests: requests, concurrency: concurrency, rate: rate,
            clockDomain: statistics.clockDomain, counts: counts, metrics: statistics.metrics(),
            durationNanoseconds: try? BenchmarkTime.nanoseconds(duration: started.duration(to: terminal)),
            duplicateFrames: duplicates, reconnects: reconnects, slowSubscriberDrops: slowDrops,
            recoverySucceeded: recoverySucceeded, cleanup: cleanup,
            controlWhileHandlerBlocked: await state.controlReady(),
            notes: ["Scripted credential-free uncompressed JSON WebSocket peer; zero network sockets and no Discord service measurements.",
                "Counts cover offered application dispatches; Hello/READY, duplicate frames, heartbeats, resume and recovery sentinel are separate protocol work.",
                "Queued copies refused or discarded before callback entry are rejected; callback cancellation and errors retain separate outcomes.",
                "Slow-handler/recovery arrivals follow absolute monotonic rate deadlines; source backpressure and scheduler lateness remain inside gross duration.",
                "Heartbeat ACK intervals require write confirmation before ACK receipt; an ACK already received at confirmation has no fabricated duration.",
                "Runtime interval scopes carry numeric timing context only; public replay events acquire no trusted interaction receipt."])
    }
}

/// Maps real runtime terminal events to the finite versioned metric catalog.
private func gatewayWorkload(_ operation: DiscordIntervalOperation, _ stage: DiscordIntervalStage) -> BenchmarkWorkload? {
    switch (operation, stage) {
    case (.gatewaySession, .operation): .gatewaySession
    case (.gatewaySession, .heartbeatACK): .gatewayHeartbeatACK
    case (.gatewaySession, .reconnect): .gatewayReconnect
    case (.gatewaySession, .shutdown): .gatewayShutdown
    case (.gatewayFrame, .socketReceipt): .gatewaySocketReceipt
    case (.gatewayFrame, .decode): .gatewayDecode
    case (.gatewayFrame, .ingestionQueue): .gatewayIngestionQueue
    case (.gatewayPublication, .operation): .gatewayPublication
    case (.gatewayPublication, .hubResidence): .gatewayHubResidence
    case (.gatewayDispatch, .operation): .gatewayDispatch
    case (.gatewayDispatch, .localQueue): .gatewayLocalQueue
    case (.gatewayDispatch, .admission): .gatewayAdmission
    case (.gatewayDispatch, .handler): .gatewayHandler
    default: nil
    }
}

/// Fixed-size logical population accounting; no per-dispatch timestamp or payload retention.
private actor GatewayTimingResults {
    private var success = 0, failure = 0, cancelled = 0, uncertain = 0, invocations = 0
    private var stopped = false
    private var confirmedControl = false
    /// Opens the first saturated callback only after the independent control write has completed.
    func confirmControl() { confirmedControl = true }
    /// Reports whether a heartbeat progressed while the shared handler permit was deliberately held.
    func controlReady() -> Bool { confirmedControl }
    /// Counts one callback only after the dispatcher grants its shared authority.
    func enter() { invocations += 1 }
    /// Classifies one terminal callback without retaining its input or timestamp.
    func finish(_ result: BenchmarkOutcome) {
        switch result { case .success: success += 1; case .cancelled: cancelled += 1; case .uncertain: uncertain += 1; default: failure += 1 }
    }
    /// Signals that the owning dispatcher/runtime has joined every callback.
    func dispatcherFinished() { stopped = true }
    /// Returns the actual callback-entry population independently of queued offers.
    func entered() -> Int { invocations }
    /// Reports terminal dispatcher ownership to stop waiting after a fail-fast callback.
    func done() -> Bool { stopped }
    /// Copies fixed-size logical counts after independent callback completions.
    func snapshot() -> (success: Int, failure: Int, cancelled: Int, uncertain: Int, invocations: Int, finished: Int, done: Bool) {
        (success, failure, cancelled, uncertain, invocations, success + failure + cancelled + uncertain, stopped)
    }
}

/// At most two generations; each socket stores a finite producer/consumer credit window.
private actor GatewayTimingTransport: WebSocketTransport {
    private var sockets: [GatewayTimingSocket] = []
    /// Checks the injected context and creates at most two independently owned socket generations.
    func connectWebSocket<C: Clock>(_ request: HTTPRequest, context: TransportContext<C>) async throws -> any WebSocketConnection where C.Duration == Duration {
        try context.check()
        guard sockets.count < 2 else { throw TransportFailure.scriptExhausted }
        let socket = GatewayTimingSocket()
        sockets.append(socket)
        return socket
    }
    /// Returns the most recently admitted generation, failing before discovery opens a socket.
    func current() throws -> GatewayTimingSocket {
        guard let socket = sockets.last else { throw TransportFailure.scriptExhausted }; return socket
    }
    /// Reads each bounded scripted socket after its shutdown has joined.
    func activeConnections() async -> Int {
        var count = 0
        for socket in sockets { if await !socket.isClosed() { count += 1 } }
        return count
    }
}

/// Single-reader bounded scripted socket, with cancellation owned by awaited close.
private actor GatewayTimingSocket: WebSocketSessionConnection {
    private var frames: [WebSocketMessage] = [.text(#"{"op":10,"d":{"heartbeat_interval":60000}}"#)]
    private var waiter: CheckedContinuation<WebSocketMessage?, any Error>?
    private var closed = false
    private var heartbeats = 0
    /// Reads actual transport heartbeat writes independently of callback admission.
    func heartbeatWrites() -> Int { heartbeats }
    /// Offers a scripted frame through a four-frame credit window without per-frame tasks.
    func emit(_ message: WebSocketMessage) async {
        while frames.count >= 4, !closed { await Task.yield() }
        guard !closed else { return }
        if let waiter { self.waiter = nil; waiter.resume(returning: message) }
        else { frames.append(message) }
    }
    /// Interprets bounded Identify, Resume and heartbeat commands and supplies their protocol replies.
    func send<C: Clock>(_ message: WebSocketMessage, context: TransportContext<C>) async throws where C.Duration == Duration {
        try context.check()
        guard !closed, case .text(let text) = message,
              case .object(let data) = try JSONValue.parse(Data(text.utf8)),
              case .number(let opcode) = data["op"] else { throw TransportFailure.closed }
        switch opcode.rawValue {
        case "2": await emit(.text(#"{"op":0,"s":1,"t":"READY","d":{"session_id":"local","resume_gateway_url":"wss://gateway.discord.gg"}}"#))
        case "6":
            guard case .object(let body) = data["d"], case .number(let seq) = body["seq"], let sequence = Int64(seq.rawValue) else { throw TransportFailure.scriptExhausted }
            await emit(.text("{\"op\":0,\"s\":\(sequence + 1),\"t\":\"RESUMED\",\"d\":{}}"))
        case "1": heartbeats += 1; await emit(.text(#"{"op":11,"d":null}"#))
        default: break
        }
    }
    /// Transfers one frame or parks the sole read continuation; cancellation owns awaited socket close.
    func receive<C: Clock>(context: TransportContext<C>) async throws -> WebSocketMessage? where C.Duration == Duration {
        try context.check()
        return try await withTaskCancellationHandler {
            if !frames.isEmpty { return frames.removeFirst() }
            if closed { return nil }
            return try await withCheckedThrowingContinuation { waiter = $0 }
        } onCancel: { Task { await self.close() } }
    }
    /// Discards queued frames and resumes the sole reader exactly once.
    func close() { closed = true; frames.removeAll(); waiter?.resume(returning: nil); waiter = nil }
    /// Closes this generation while allowing the shard to retain its resumable session.
    func closeForReconnect() { close() }
    /// Returns no peer close frame for the scripted server-requested reconnect.
    func peerCloseCode() -> Int? { nil }
    /// Reports local adapter ownership after explicit close or cancellation.
    func isClosed() -> Bool { closed }
}

/// Actual client ingestion establishes receipt provenance; public broadcast copies never enter this bridge.
private func trustedGatewayRun(scenario: GatewayTimingScenario, requests: Int, concurrency: Int,
                               delay: Duration, rate: Int) async throws -> GatewayTimingReport {
    let statistics = try RunStatistics(workloads: [.gatewayReceiveToAdmission, .gatewayReceiveToAcknowledgement,
        .gatewayAdmissionToAcknowledgement, .gatewayInitialResponse, .gatewayOriginalEdit,
        .gatewayAcknowledgementToOriginalEdit, .gatewayLocalQueue, .gatewayAdmission, .gatewayDispatch])
    let clock = ContinuousClock(), origin = clock.now
    let timing = OperationTiming(sink: { sample in
        let metric: BenchmarkWorkload
        switch sample.phase {
        case .gatewayReceiveToAdmission: metric = .gatewayReceiveToAdmission
        case .gatewayReceiveToAcknowledgement: metric = .gatewayReceiveToAcknowledgement
        case .gatewayAdmissionToAcknowledgement: metric = .gatewayAdmissionToAcknowledgement
        case .interactionInitialResponse: metric = .gatewayInitialResponse
        case .interactionOriginalEdit: metric = .gatewayOriginalEdit
        case .interactionAcknowledgementToOriginalEdit: metric = .gatewayAcknowledgementToOriginalEdit
        case .gatewayLocalQueue: metric = .gatewayLocalQueue
        case .gatewaySharedAdmission: metric = .gatewayAdmission
        case .gatewayRunJoined: metric = .gatewayDispatch
        default: return
        }
        let outcome: BenchmarkOutcome
        switch sample.outcome { case .succeeded: outcome = .success; case .failed: outcome = .failure
        case .cancelled: outcome = .cancelled; case .uncertain: outcome = .uncertain }
        statistics.record(sample.elapsed, workload: metric, outcome: outcome)
    }, now: { origin.duration(to: clock.now) })
    let leases = try InProcessShardLeaseStore(clock: clock, maximumLeases: 1)
    let budget = try ClientResourceBudget(maximumClients: 1, maximumShards: 1)
    let authority = try ClientAuthority(botID: UserID(rawValue: 1), clock: clock, budget: budget)
    let coordinators = (0..<3).map { _ in RateLimitCoordinator(clock: clock) }
    let discovery = GatewayTimingHTTP(mode: .discovery, delay: .zero)
    let initial = GatewayTimingHTTP(mode: scenario == .trustedUncertain ? .uncertain : .initial, delay: delay)
    let continuation = GatewayTimingHTTP(mode: .continuation, delay: delay)
    let token = try BotToken("synthetic-local-only")
    let botREST = RESTClient(credential: .bot(token), identity: RateLimitIdentity(), transport: discovery,
        coordinator: coordinators[0], clock: clock, retryPolicy: .init(maximumAttempts: 1))
    let services = ServiceContext(rest: botREST)
    let serviceAdapter = BotServiceAdapter(services: services, clock: clock, initialClient: { interaction in
        RESTClient(credential: .interaction(interaction.token), identity: RateLimitIdentity(), transport: initial,
            coordinator: coordinators[1], clock: clock, retryPolicy: .init(maximumAttempts: 1))
    }, continuationServices: { interaction in
        ServiceContext(rest: RESTClient(credential: .interaction(interaction.token), identity: RateLimitIdentity(),
            transport: continuation, coordinator: coordinators[2], clock: clock, retryPolicy: .init(maximumAttempts: 1)))
    })
    let transport = GatewayTimingTransport(), publicEvents = GatewayEventHub(configuration: try .init())
    let client = DiscordClient(token: token, configuration: try ClientConfiguration(intents: [], maximumShards: 1,
        shard: .init(maximumBufferedEvents: 512, maximumReconnectAttempts: 0)), services: services,
        transport: transport, clock: clock, leases: leases, authority: authority, events: publicEvents)
    let state = GatewayTimingResults(), admission = try InteractionAcknowledgementAdmission()
    let handlerAuthority = try GatewayHandlerAuthority(maximumActiveHandlers: concurrency, maximumWaitingHandlers: concurrency)
    let commands = try CommandCompilation.compile(ExistingCommandFamily(id: "timing", definitions: [
        CommandDefinition.slash(name: "timing", description: "Local timing fixture")
    ], routes: [CommandRoute(key: .command(name: "timing"), handler: { context in
        await state.enter()
        do {
            if scenario == .trustedDeferred {
                try await context.responder.deferResponse()
                try await clock.sleep(for: delay)
                _ = try await context.responder.editOriginal(InteractionMessageEdit(content: .value("local-final"), deferredResponse: true))
            } else { try await context.responder.reply(InteractionMessageCreate(content: .value("local-response"))) }
            await state.finish(.success)
        } catch {
            if error is CancellationError { await state.finish(.cancelled) }
            else if case .unknownMutationOutcome = error as? DiscordError { await state.finish(.uncertain) }
            else { await state.finish(.failure) }
            // This fixture deliberately observes the terminal responder state and does not replay a send.
        }
    })]))
    let interactions = try GatewayInteractionAdapter(applicationID: ApplicationID(rawValue: 9), commands: commands,
        services: serviceAdapter, clock: clock, admission: admission,
        configuration: .init(maximumConcurrentHandlers: concurrency, maximumRetainedEvents: concurrency * 2),
        authority: handlerAuthority, maximumPendingInteractions: max(256, concurrency), maximumConcurrentHandlers: concurrency,
        serializesPerShard: false, timing: timing)
    let runtime = try BotRuntime(client: client, events: EventCompilation.compile(EmptyBotDefinition(), intents: []),
        handlerConfiguration: .init(maximumConcurrentHandlers: concurrency), interactions: interactions)
    let runtimeTask = Task { () -> (any Error)? in
        do { try await runtime.run(); await state.dispatcherFinished(); return nil }
        catch { await state.dispatcherFinished(); return error }
    }
    let started = clock.now
    var offered = 0, duplicates = 0
    var driverFailure: (any Error)?
    do {
        while await !client.snapshot().ready {
            if await state.done() { throw LoadFailure.unexpectedResponse }
            try Task.checkCancellation(); await Task.yield()
        }
        for first in stride(from: 0, to: requests, by: concurrency) {
            try Task.checkCancellation()
            let count = min(concurrency, requests - first), socket = try await transport.current()
            for ordinal in first..<(first + count) {
                let payload = "{\"id\":\"\(ordinal + 1)\",\"application_id\":\"9\",\"type\":2,\"token\":\"synthetic-local-interaction-\(ordinal + 1)\",\"version\":1,\"data\":{\"id\":\"3\",\"name\":\"timing\",\"type\":1},\"app_permissions\":\"0\",\"entitlements\":[],\"authorizing_integration_owners\":{},\"attachment_size_limit\":1048576}"
                let frame = WebSocketMessage.text("{\"op\":0,\"s\":\(ordinal + 2),\"t\":\"INTERACTION_CREATE\",\"d\":\(payload)}")
                offered += 1; await socket.emit(frame)
                if ordinal % 8 == 0 { await socket.emit(frame); duplicates += 1 }
            }
            while await state.snapshot().finished < offered {
                if await state.done() { throw LoadFailure.unexpectedResponse }
                try Task.checkCancellation(); await Task.yield()
            }
        }
    } catch { if !(error is CancellationError) && !Task.isCancelled { driverFailure = error } }
    if Task.isCancelled { runtimeTask.cancel() }
    await runtime.requestStop()
    _ = try? await runtime.shutdown()
    let runtimeFailure = await runtimeTask.value
    for coordinator in coordinators { await coordinator.close() }
    if let driverFailure { throw driverFailure }
    if let runtimeFailure, !(runtimeFailure is CancellationError), !Task.isCancelled { throw runtimeFailure }
    let terminal = clock.now, values = await state.snapshot()
    var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
    outcomes[.success] = UInt64(values.success); outcomes[.failure] = UInt64(values.failure)
    outcomes[.uncertain] = UInt64(values.uncertain)
    outcomes[.cancelled] = UInt64(values.cancelled + max(0, offered - values.finished))
    let counts = BenchmarkCounts(offered: UInt64(offered), admitted: UInt64(values.invocations), completed: UInt64(offered),
        outcomes: outcomes, deadlineMisses: 0)
    try counts.validate()
    let clientState = await client.snapshot(), hubState = await publicEvents.snapshot(), callbacks = await handlerAuthority.snapshot()
    var cleanup = GatewayTimingCleanup(connections: await transport.activeConnections(), leases: await leases.retainedLeaseCount(),
        subscriptions: hubState.subscriptions, bufferedEvents: hubState.bufferedEvents + clientState.shards.reduce(0) { $0 + $1.bufferedEvents },
        activeHandlers: callbacks.activeHandlers, waitingHandlers: callbacks.waitingHandlers,
        pendingRequests: clientState.shards.reduce(0) { $0 + $1.pendingRequests }, applicationWrites: clientState.shards.reduce(0) { $0 + $1.applicationWrites })
    cleanup.acknowledgementReservations = await admission.snapshot().activeCount
    cleanup.clientReservations = await budget.snapshot().clients
    for coordinator in coordinators {
        let scheduler = await coordinator.snapshot()
        cleanup.restOwners += scheduler.activeCount + scheduler.queuedCount + scheduler.orderedOperationsCount
    }
    return GatewayTimingReport(scenario: scenario.rawValue, configuredRequests: requests, concurrency: concurrency, rate: rate,
        clockDomain: statistics.clockDomain, counts: counts, metrics: statistics.metrics(),
        durationNanoseconds: try? BenchmarkTime.nanoseconds(duration: started.duration(to: terminal)), duplicateFrames: duplicates,
        reconnects: 0, slowSubscriberDrops: 0, recoverySucceeded: false, cleanup: cleanup,
        initialResponseSends: await initial.executionCount(), continuationSends: await continuation.executionCount(),
        notes: ["Actual DiscordClient socket ingestion and public BotRuntime composition establish the trusted private interaction receipt; no public event or test-only receipt constructor is used.",
            "Scripted credential-free WebSocket discovery and HTTP confirmation; zero network sockets, Discord credentials or registration requests.",
            "Receipt-to-admission and receipt/admission-to-confirmed-response are direct legacy scalar owner measurements, never reconstructed detailed interval starts.",
            "Unconfirmed initial sends emit uncertain initial-response duration and no successful receive-to-acknowledgement population; no replay or edit is attempted.",
            "Private adapter queue/router counters have no public API; BotRuntime shutdown joins their documented cleanup. Public client, socket, lease, callback, rate and acknowledgement gauges are read independently."])
}

/// Opaque fixture failure distinguishes submission uncertainty from a confirmed response.
private enum GatewayTimingSendFailure: Error { case unconfirmed }

/// Separately injected discovery, initial-response and continuation HTTP owners; no network or retry loop.
private actor GatewayTimingHTTP: HTTPTransport {
    enum Mode { case discovery, initial, uncertain, continuation }
    private let mode: Mode
    private let delay: Duration
    private var executions = 0
    /// Stores one inert HTTP behavior and a bounded artificial response delay.
    init(mode: Mode, delay: Duration) { self.mode = mode; self.delay = delay }
    /// Returns actual HTTP attempts, independently of logical response or uncertain-send outcome.
    func executionCount() -> Int { executions }

    /// Confirms local HTTP completion or throws an opaque unconfirmed-send error after adapter entry.
    func execute<C: Clock>(_ request: HTTPRequest, context: TransportContext<C>) async throws -> HTTPResponse where C.Duration == Duration {
        try context.check()
        executions += 1
        switch mode {
        case .discovery:
            guard request.method == "GET", request.url.path == "/api/v10/gateway/bot" else { throw TransportFailure.scriptExhausted }
        case .initial, .uncertain:
            guard request.method == "POST", request.url.path.contains("/interactions/"), request.url.path.hasSuffix("/callback") else { throw TransportFailure.scriptExhausted }
            _ = try JSONValue.parse(await ResponseBody.collect(request.body, maximumBytes: 65_536))
        case .continuation:
            guard request.method == "PATCH", request.url.path.hasSuffix("/messages/@original") else { throw TransportFailure.scriptExhausted }
            _ = try JSONValue.parse(await ResponseBody.collect(request.body, maximumBytes: 65_536))
        }
        if delay > .zero { try await context.clock.sleep(for: delay) }
        if mode == .uncertain { throw GatewayTimingSendFailure.unconfirmed }
        if mode == .initial {
            return HTTPResponse(status: 204, headers: [
                HTTPHeader(name: "X-RateLimit-Limit", value: "100000"),
                HTTPHeader(name: "X-RateLimit-Remaining", value: "99999"),
                HTTPHeader(name: "X-RateLimit-Reset-After", value: "0.001")])
        }
        let payload = mode == .discovery
            ? #"{"url":"wss://gateway.discord.gg","shards":1,"session_start_limit":{"total":10,"remaining":10,"reset_after":60000,"max_concurrency":1}}"#
            : #"{"id":"7","channel_id":"4","author":{"id":"5","username":"local","discriminator":"0","avatar":null},"content":"local-final","timestamp":"2026-10-18T12:00:00Z","edited_timestamp":null,"tts":false,"mention_everyone":false,"mentions":[],"mention_roles":[],"attachments":[],"embeds":[],"pinned":false,"type":20}"#
        return HTTPResponse(status: 200, body: try RequestBody(bytes: Data(payload.utf8), contentType: "application/json").makeStream())
    }
}
