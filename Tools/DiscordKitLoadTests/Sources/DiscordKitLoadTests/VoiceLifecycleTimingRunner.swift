// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/VoiceLifecycleTimingRunner.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordCore
import DiscordModels
import DiscordTransport
import DiscordVoice
import Foundation

/// Finite injected lifecycle scripts; all events, credentials and peers are synthetic.
enum VoiceLifecycleTimingCase: String, CaseIterable, Codable, Sendable {
    case join = "voice.join"
    case move = "voice.move"
    case credentialRendezvous = "voice.credentials"
    case handshake = "voice.handshake"
    case secureReady = "voice.secureReady"
    case heartbeat = "voice.heartbeat"
    case reconnect = "voice.reconnect"
    case speaking = "voice.speaking"
    case termination = "voice.termination"
    case shutdown = "voice.shutdown"
    case lifecycleJoined = "voice.lifecycleJoined"
}

/// Independent public-manager and injected-adapter receipts collected after joined stop.
struct VoiceLifecycleTimingCleanup: Codable, Equatable, Sendable {
    let retainedGuilds: Int
    let retainedOperations: Int
    let runningSessions: Int
    let sockets: Int
    let datagrams: Int
    let backends: Int
    let waiters: Int
    /// Sums independently read manager, session, adapter and waiter ownership after teardown.
    var remainingOwners: UInt64 {
        UInt64(retainedGuilds + retainedOperations + runningSessions + sockets + datagrams + backends + waiters)
    }
}

/// Complete caller population and honestly overlapping observed child intervals.
struct VoiceLifecycleTimingMeasurement: Codable, Sendable {
    let scenario: String
    let profileVersion: UInt32
    let configuredRequests: Int
    let concurrency: Int
    let maximumHarnessTasks: Int
    let clockDomain: String
    let counts: BenchmarkCounts
    let metrics: [BenchmarkMetric]
    let durationNanoseconds: UInt64
    let cleanup: BenchmarkCleanup
    let ownership: VoiceLifecycleTimingCleanup
    let installedSessions: Int
    let connectionAttempts: Int
    let discoveryRequests: Int
    let heartbeatACKs: Int
    let reconnects: Int
    let speakingCommands: Int
    let terminalFailures: Int
    let notes: [String]
}

/// Scripted VoiceManager and VoiceSession ownership, with no real socket or device access.
struct VoiceLifecycleTimingRunner: Sendable {
    private let onReady: (@Sendable () async -> Void)?

    /// Observes actual secure readiness for deterministic cancellation tests; nil adds no callback.
    init(onReady: (@Sendable () async -> Void)? = nil) { self.onReady = onReady }

    /// Runs a bounded replenished cohort and joins every admitted manager, session and adapter.
    /// - Parameters:
    ///   - scenario: Finite lifecycle workflow; termination deliberately supplies a terminal peer close.
    ///   - requests: Exact offered workflows, in 1...100000.
    ///   - concurrency: Maximum active independent workflows, in 1...256, no greater than requests.
    ///   - maximumDuration: Optional positive admission interval through one hour.
    /// - Returns: Whole joined-lifecycle outcomes, observed child boundaries and zero-owner receipts.
    /// - Throws: Invalid dimensions, precancellation, allocation failure or a violated fixture invariant.
    func run(scenario: VoiceLifecycleTimingCase, requests: Int = 16, concurrency: Int = 4,
             maximumDuration: Duration? = nil) async throws -> VoiceLifecycleTimingMeasurement {
        guard (1...100_000).contains(requests), (1...256).contains(concurrency), concurrency <= requests,
              maximumDuration.map({ $0 > .zero && $0 <= .seconds(3_600) }) ?? true else {
            throw LoadFailure.invalidArguments
        }
        try Task.checkCancellation()
        let statistics = try RunStatistics(workloads: [.voiceJoin, .voiceSecureReady, .voiceCredentialRendezvous,
            .voiceHandshake, .voiceHeartbeat, .voiceReconnect, .voiceSpeaking, .voiceTermination, .voiceShutdown, .voiceLifecycle])
        let clock = ContinuousClock(), began = clock.now
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        var offered = 0, installed = 0, connections = 0, discoveries = 0, heartbeats = 0
        var reconnects = 0, speaking = 0, failures = 0
        var remainingGuilds = 0, remainingOperations = 0, remainingSessions = 0
        var remainingSockets = 0, remainingDatagrams = 0, remainingBackends = 0, remainingWaiters = 0
        var valid = true
        await withTaskGroup(of: VoiceLifecycleTimingResult.self) { group in
            for _ in 0..<min(requests, concurrency) {
                offered += 1
                group.addTask { await voiceLifecycleExchange(scenario, statistics: statistics, onReady: onReady) }
            }
            while let result = await group.next() {
                outcomes[result.outcome, default: 0] += 1
                valid = valid && result.valid
                installed += result.installed; connections += result.connections; discoveries += result.discoveries
                heartbeats += result.heartbeats; reconnects += result.reconnects; speaking += result.speaking
                failures += result.terminalFailures
                remainingGuilds += result.cleanup.retainedGuilds; remainingOperations += result.cleanup.retainedOperations
                remainingSessions += result.cleanup.runningSessions; remainingSockets += result.cleanup.sockets
                remainingDatagrams += result.cleanup.datagrams; remainingBackends += result.cleanup.backends
                remainingWaiters += result.cleanup.waiters
                if Task.isCancelled { group.cancelAll() }
                else if offered < requests && (maximumDuration.map({ began.duration(to: clock.now) < $0 }) ?? true) {
                    offered += 1
                    group.addTask { await voiceLifecycleExchange(scenario, statistics: statistics, onReady: onReady) }
                }
            }
        }
        let ended = clock.now
        let cleanup = VoiceLifecycleTimingCleanup(retainedGuilds: remainingGuilds, retainedOperations: remainingOperations,
            runningSessions: remainingSessions, sockets: remainingSockets, datagrams: remainingDatagrams,
            backends: remainingBackends, waiters: remainingWaiters)
        guard valid, cleanup.remainingOwners == 0 else { throw LoadFailure.unexpectedResponse }
        let counts = BenchmarkCounts(offered: UInt64(offered), admitted: UInt64(offered), completed: UInt64(offered),
            outcomes: outcomes, deadlineMisses: outcomes[.timedOut, default: 0])
        try counts.validate()
        return VoiceLifecycleTimingMeasurement(scenario: scenario.rawValue, profileVersion: 1,
            configuredRequests: requests, concurrency: concurrency, maximumHarnessTasks: min(requests, concurrency),
            clockDomain: statistics.clockDomain, counts: counts, metrics: statistics.metrics(),
            durationNanoseconds: try BenchmarkTime.nanoseconds(duration: began.duration(to: ended)),
            cleanup: .init(completed: true, remainingOwners: cleanup.remainingOwners), ownership: cleanup,
            installedSessions: installed, connectionAttempts: connections, discoveryRequests: discoveries,
            heartbeatACKs: heartbeats, reconnects: reconnects, speakingCommands: speaking, terminalFailures: failures,
            notes: [
                "Actual VoiceManager joins/moves and VoiceSession control owners use injected finite WebSocket/UDP peers and synthetic identity-matched E2EE authorization; this is not DAVE interoperability or live Discord evidence.",
                "voice.lifecycleJoined covers caller entry through awaited manager stop. voice.join ends when join/move installs a session; installation alone does not establish secure readiness.",
                "voice.credentials covers first credential delivery through actual session-factory admission, including both routed halves. voice.handshake covers session run entry through an observed ready control-loop read. voice.secureReady starts at join/move caller entry and ends at that same verified milestone.",
                "voice.heartbeat covers an explicitly released one-second virtual HELLO interval, exact-nonce ACK and subsequent control-loop read/next heartbeat sleep admission. Its measured ContinuousClock interval is local work, not network RTT or virtual elapsed time. Other scripts never release their heartbeat timer.",
                "voice.reconnect covers injected resumable EOF through resumed secure readiness, including explicit release of the configured one-nanosecond virtual retry delay and caller observation. voice.speaking covers true/false sends. voice.termination covers terminal peer close through the joined run result.",
                "voice.shutdown ends after manager stop joins session children; independent cleanup reads follow all terminal timestamps. Primary lifecycle includes its child metrics; distributions cannot be added or subtracted.",
                "A move performs two fresh credential pairs and installs two separate real sessions. A lifecycleJoined script also performs heartbeat, resume and speaking before stop. Termination intentionally records failure; all owned resources still join.",
                "A separate bounded virtual clock drives runtime timers only after observed sleep admission; every returned duration uses ContinuousClock. Finite injected scripts measure local orchestration and scheduling; no device, DNS, actual transport handshake, audio output, cryptographic acceptance or cross-platform performance is qualified."
            ])
    }
}

private struct VoiceLifecycleTimingResult: Sendable {
    let outcome: BenchmarkOutcome
    let valid: Bool
    let cleanup: VoiceLifecycleTimingCleanup
    let installed: Int
    let connections: Int
    let discoveries: Int
    let heartbeats: Int
    let reconnects: Int
    let speaking: Int
    let terminalFailures: Int
}

/// One independent manager, bounded to one synthetic guild and at most two session generations.
private func voiceLifecycleExchange(_ scenario: VoiceLifecycleTimingCase,
                                    statistics: RunStatistics, onReady: (@Sendable () async -> Void)?) async -> VoiceLifecycleTimingResult {
    let clock = ContinuousClock(), harness = VoiceLifecycleHarness(statistics: statistics,
        heartbeat: scenario == .heartbeat || scenario == .lifecycleJoined)
    let began = clock.now
    var outcome = BenchmarkOutcome.success, valid = true, terminalFailures = 0
    var manager: VoiceManager<ContinuousClock>?
    do {
        let owner = try VoiceManager(userID: UserID(rawValue: 2), clock: clock, maximumGuilds: 1,
            sendCommand: { try await harness.send($0) }, makeSession: { try await harness.make($0) })
        manager = owner
        var managed = try await voiceLifecycleJoin(owner, harness: harness, moving: false, statistics: statistics)
        await onReady?()
        try Task.checkCancellation()
        if scenario == .move {
            managed = try await voiceLifecycleJoin(owner, harness: harness, moving: true, statistics: statistics)
        }
        if scenario == .heartbeat || scenario == .lifecycleJoined {
            try await managed.observeHeartbeat(statistics)
        }
        if scenario == .reconnect || scenario == .lifecycleJoined {
            try await managed.resume(statistics)
        }
        if scenario == .speaking || scenario == .lifecycleJoined {
            let started = clock.now
            try await managed.owner.setSpeaking(true)
            try await managed.owner.setSpeaking(false)
            let ended = clock.now
            statistics.record(started.duration(to: ended), workload: .voiceSpeaking, outcome: .success)
            guard await managed.currentSocket().speakingCount() >= 2 else { throw LoadFailure.unexpectedResponse }
        }
        if scenario == .termination {
            let started = clock.now
            await managed.first.disconnect(4014)
            let failure = try await managed.waitForTerminal()
            let ended = clock.now
            guard failure == .peerClosed(4014) else { throw LoadFailure.unexpectedResponse }
            statistics.record(started.duration(to: ended), workload: .voiceTermination, outcome: .failure)
            terminalFailures = 1; outcome = .failure
        }
    } catch {
        if error is CancellationError || Task.isCancelled { outcome = .cancelled }
        else if (error as? TransportFailure) == .deadlineExceeded { outcome = .timedOut }
        else { outcome = .failure; valid = false }
    }
    let shutdown = clock.now
    await manager?.stop()
    let ended = clock.now
    statistics.record(shutdown.duration(to: ended), workload: .voiceShutdown, outcome: outcome == .cancelled ? .cancelled : .success)
    statistics.record(began.duration(to: ended), workload: .voiceLifecycle, outcome: outcome)
    let snapshot = await manager?.snapshot()
    let receipt = await harness.receipt()
    let cleanup = VoiceLifecycleTimingCleanup(retainedGuilds: snapshot?.retainedGuildCount ?? 0,
        retainedOperations: snapshot?.retainedOperationCount ?? 0, runningSessions: receipt.running,
        sockets: receipt.sockets, datagrams: receipt.datagrams, backends: receipt.backends, waiters: receipt.waiters)
    return VoiceLifecycleTimingResult(outcome: outcome, valid: valid, cleanup: cleanup,
        installed: receipt.installed, connections: receipt.connections, discoveries: receipt.discoveries,
        heartbeats: receipt.heartbeats, reconnects: receipt.reconnects, speaking: receipt.speaking,
        terminalFailures: terminalFailures)
}

/// Delivers a fresh fenced pair in opposite event orders for initial join and move.
private func voiceLifecycleJoin(_ owner: VoiceManager<ContinuousClock>, harness: VoiceLifecycleHarness,
                                moving: Bool, statistics: RunStatistics) async throws -> VoiceLifecycleManaged {
    let clock = ContinuousClock(), started = clock.now
    let ordinal = moving ? 2 : 1
    let join = Task {
        if moving { return try await owner.move(guildID: GuildID(rawValue: 1), channelID: ChannelID(rawValue: 4)) }
        return try await owner.join(guildID: GuildID(rawValue: 1), channelID: ChannelID(rawValue: 3))
    }
    do {
        return try await withTaskCancellationHandler {
            try await harness.waitForCommand(ordinal)
            guard let generation = await owner.generation(guildID: GuildID(rawValue: 1)) else { throw LoadFailure.unexpectedResponse }
            let credentialsStart = clock.now
            await harness.beginCredentials(credentialsStart)
            let state = try VoiceState(data: JSONValue.object([
                "guild_id": .string("1"), "user_id": .string("2"),
                "channel_id": .string(moving ? "4" : "3"), "session_id": .string("synthetic-session"),
                "deaf": .bool(false), "mute": .bool(false), "self_deaf": .bool(false), "self_mute": .bool(false),
                "self_video": .bool(false), "suppress": .bool(false), "request_to_speak_timestamp": .null]).serialized())
            let server = try GatewayVoiceServerUpdate(data: JSONValue.object([
                "guild_id": .string("1"), "token": .string("synthetic-token"), "endpoint": .string("voice.invalid")]).serialized())
            if moving {
                try await owner.route(server: server, generation: generation)
                try await owner.route(state: state, generation: generation)
            } else {
                try await owner.route(state: state, generation: generation)
                try await owner.route(server: server, generation: generation)
            }
            guard let managed = try await join.value as? VoiceLifecycleManaged else { throw LoadFailure.unexpectedResponse }
            let installed = clock.now
            statistics.record(started.duration(to: installed), workload: .voiceJoin, outcome: .success)
            let ready = try await managed.waitForReady()
            statistics.record(started.duration(to: ready), workload: .voiceSecureReady, outcome: .success)
            return managed
        } onCancel: { join.cancel() }
    } catch {
        join.cancel()
        _ = try? await join.value
        throw error
    }
}

/// Cancellation-aware finite gates; retained continuations are counted independently at cleanup.
private actor VoiceLifecycleGate {
    private var opened = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    /// Resolves every current waiter exactly once and retains an open state for future callers.
    func open() {
        opened = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending.values { waiter.resume() }
    }
    /// Suspends cancellation-cooperatively until open; cancellation removes its exact continuation.
    func wait() async throws {
        try Task.checkCancellation()
        if opened { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[id] = continuation }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    /// Removes and cancels only the waiter identified by this registration token.
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    /// Reports retained continuation count without changing gate state.
    func count() -> Int { waiters.count }
}

private actor VoiceLifecycleHarness {
    let statistics: RunStatistics
    let heartbeat: Bool
    private var commands = 0
    private var commandGates: [Int: VoiceLifecycleGate] = [:]
    private var sessions: [VoiceLifecycleManaged] = []
    private var credentialsStart: ContinuousClock.Instant?
    /// Retains the shared statistics owner and finite heartbeat policy without starting work.
    init(statistics: RunStatistics, heartbeat: Bool) { self.statistics = statistics; self.heartbeat = heartbeat }
    /// Stores the direct timestamp immediately before routing the first credential half.
    func beginCredentials(_ instant: ContinuousClock.Instant) { credentialsStart = instant }
    /// Records non-leave manager commands and opens their exact admission-count gates.
    func send(_ command: VoiceManagerCommand) async throws {
        try Task.checkCancellation()
        if command.channelID != nil {
            commands += 1
            await commandGates.removeValue(forKey: commands)?.open()
        }
    }
    /// Waits for a known join or move command before routing fenced synthetic events.
    func waitForCommand(_ count: Int) async throws {
        if commands >= count { return }
        let gate = commandGates[count] ?? VoiceLifecycleGate(); commandGates[count] = gate
        try await gate.wait()
    }
    /// Measures actual factory admission and transfers one fresh real session to the manager.
    func make(_ credentials: VoiceConnectionCredentials) async throws -> any VoiceManagedSession {
        let admitted = ContinuousClock().now
        if let credentialsStart { statistics.record(credentialsStart.duration(to: admitted), workload: .voiceCredentialRendezvous, outcome: .success) }
        let managed = try VoiceLifecycleManaged(credentials, heartbeat: heartbeat, statistics: statistics)
        sessions.append(managed)
        return managed
    }
    /// Reads manager-independent runtime, adapter, backend and suspended-waiter counters after stop.
    func receipt() async -> (installed: Int, running: Int, connections: Int, sockets: Int, datagrams: Int,
                             backends: Int, waiters: Int, discoveries: Int, heartbeats: Int, reconnects: Int, speaking: Int) {
        var running = 0, connections = 0, sockets = 0, datagrams = 0, backends = 0, waiters = 0
        var discoveries = 0, heartbeats = 0, reconnects = 0, speaking = 0
        for session in sessions {
            let snapshot = await session.owner.snapshot()
            running += snapshot.isRunning ? 1 : 0
            connections += await session.connector.count()
            let first = await session.first.receipt(), second = await session.second.receipt()
            sockets += first.owners + second.owners
            waiters += first.waiters + second.waiters
            heartbeats += first.acks + second.acks
            speaking += first.speaking + second.speaking
            reconnects += snapshot.reconnectAttempts
            let udp = await session.udp.receipt()
            datagrams += udp.owners; waiters += udp.waiters; discoveries += udp.sent
            backends += await session.backend.isClosed() ? 0 : 1
            waiters += await session.observationWaiters()
            waiters += session.runtimeClock.pendingSleepCount
        }
        for gate in commandGates.values { waiters += await gate.count() }
        return (sessions.count, running, connections, sockets, datagrams, backends, waiters, discoveries, heartbeats, reconnects, speaking)
    }
}

/// The manager owns this wrapper's run task; it joins the actual VoiceSession on every path.
private actor VoiceLifecycleManaged: VoiceManagedSession {
    nonisolated let owner: VoiceSession<VoiceLifecycleClock>
    nonisolated let runtimeClock: VoiceLifecycleClock
    nonisolated let first: VoiceLifecycleSocket
    nonisolated let second: VoiceLifecycleSocket
    nonisolated let connector: VoiceLifecycleConnector
    nonisolated let udp: VoiceLifecycleDatagram
    nonisolated let backend: VoiceLifecycleE2EE
    nonisolated let finished = VoiceLifecycleGate()
    private let started = VoiceLifecycleGate()
    private let statistics: RunStatistics
    private var runStart: ContinuousClock.Instant?
    private var terminalFailure: VoiceSessionFailure?
    private var resumed = false
    /// Creates one inert real session and two finite socket generations without opening network resources.
    init(_ credentials: VoiceConnectionCredentials, heartbeat: Bool, statistics: RunStatistics) throws {
        first = VoiceLifecycleSocket(try voiceLifecycleFrames(heartbeat: heartbeat))
        second = VoiceLifecycleSocket([try voiceLifecycleFrame(8, .object(["heartbeat_interval": voiceLifecycleNumber(60_000)])),
                                      try voiceLifecycleFrame(9, .null)])
        connector = VoiceLifecycleConnector(first, second)
        udp = VoiceLifecycleDatagram()
        backend = VoiceLifecycleE2EE(credentials.identity)
        let udp = self.udp
        runtimeClock = VoiceLifecycleClock()
        owner = try VoiceSession(credentials: credentials, webSocket: connector, makeDatagram: { _ in await udp.open(); return udp },
            e2ee: backend, clock: runtimeClock,
            configuration: VoiceSessionConfiguration(retryDelay: .nanoseconds(1), maximumReconnectAttempts: 1))
        self.statistics = statistics
    }
    /// Executes the real session under manager ownership and publishes its already-joined terminal result.
    func run() async throws {
        runStart = ContinuousClock().now
        await started.open()
        do {
            try await owner.run()
            await finished.open()
        } catch {
            terminalFailure = error as? VoiceSessionFailure
            await finished.open()
            throw error
        }
    }
    /// Awaits idempotent real-session disposal; the manager separately joins its run task.
    func stop() async { await owner.stop() }
    /// Fences the control read after Description and verifies both ready phase and media availability.
    func waitForReady() async throws -> ContinuousClock.Instant {
        try await started.wait()
        try await first.waitForRead(4)
        let ready = ContinuousClock().now
        guard await owner.snapshot().phase == .ready, await owner.mediaPipeline() != nil, let runStart else {
            throw LoadFailure.unexpectedResponse
        }
        statistics.record(runStart.duration(to: ready), workload: .voiceHandshake, outcome: .success)
        return ready
    }
    /// Releases one admitted virtual heartbeat, observes exact-nonce ACK processing and parks its next timer.
    func observeHeartbeat(_ statistics: RunStatistics) async throws {
        try await runtimeClock.firstHeartbeat.wait()
        let acknowledgement = await first.nextACKGate()
        let began = ContinuousClock().now
        await runtimeClock.advance(by: .seconds(1))
        try await acknowledgement.wait()
        try await runtimeClock.secondHeartbeat.wait()
        let ended = ContinuousClock().now
        guard await owner.snapshot().phase == .ready else { throw LoadFailure.unexpectedResponse }
        statistics.record(began.duration(to: ended), workload: .voiceHeartbeat, outcome: .success)
    }
    /// Injects resumable EOF, releases an admitted retry timer and verifies resumed secure readiness.
    func resume(_ statistics: RunStatistics) async throws {
        let began = ContinuousClock().now
        await first.disconnect(4015)
        try await runtimeClock.retry.wait()
        await runtimeClock.advance(by: .nanoseconds(1))
        try await second.waitForRead(3)
        let ended = ContinuousClock().now
        guard await owner.snapshot().phase == .ready, await owner.snapshot().reconnectAttempts == 1,
              await connector.count() == 2, await udp.receipt().owners == 1 else { throw LoadFailure.unexpectedResponse }
        resumed = true
        statistics.record(began.duration(to: ended), workload: .voiceReconnect, outcome: .success)
    }
    /// Returns the fixture generation currently used by the real session.
    func currentSocket() -> VoiceLifecycleSocket { resumed ? second : first }
    /// Counts readiness, terminal and runtime-timer observation waiters after owned task joins.
    func observationWaiters() async -> Int {
        let ready = await started.count(), terminal = await finished.count()
        return ready + terminal + (await runtimeClock.pendingObservationCount())
    }
    /// Observes the actual VoiceSession run result after its children and adapters have joined.
    func waitForTerminal() async throws -> VoiceSessionFailure? { try await finished.wait(); return terminalFailure }
}

/// In-memory complete-message peer with an explicit next-read fence after reducer processing.
private actor VoiceLifecycleSocket: WebSocketSessionConnection {
    private var incoming: [WebSocketMessage]
    private var waiter: CheckedContinuation<WebSocketMessage?, any Error>?
    private var reads = 0
    private var readGates: [Int: VoiceLifecycleGate] = [:]
    private var ackDelivered = false
    private var processedACKs = 0
    private var ackGates: [Int: VoiceLifecycleGate] = [:]
    private var heartbeatACKs = 0
    private var speaking = 0
    private var opened = false
    private var closed = false
    private var code: Int?
    /// Retains a finite sequence of complete synthetic server frames without starting reads.
    init(_ incoming: [WebSocketMessage]) { self.incoming = incoming }
    /// Records explicit connector acquisition; unused scripted generations do not count as owners.
    func open() { opened = true }
    /// Validates one client control, counts Speaking and echoes exact heartbeat nonces locally.
    func send<C: Clock>(_ message: WebSocketMessage, context: TransportContext<C>) async throws where C.Duration == Duration {
        try context.check(); guard !closed else { throw TransportFailure.closed }
        let frame = try VoiceGatewayFrame(message, direction: .clientToServer)
        if frame.opcode == 5 { speaking += 1 }
        if frame.opcode == 3, case .json(.object(let body)) = frame.payload, let nonce = body["t"] {
            heartbeatACKs += 1
            let ack = try voiceLifecycleFrame(6, .object(["t": nonce]))
            if let waiter { self.waiter = nil; ackDelivered = true; waiter.resume(returning: ack) }
            else { incoming.append(ack) }
        }
    }
    /// Runs a single cancellation-aware message pull under the real session's injected context.
    func receive<C: Clock>(context: TransportContext<C>) async throws -> WebSocketMessage? where C.Duration == Duration {
        try await context.run { try await self.read() }
    }
    /// Delivers a finite control or suspends one reader, opening next-read reducer fences.
    private func read() async throws -> WebSocketMessage? {
        try Task.checkCancellation()
        reads += 1
        await readGates.removeValue(forKey: reads)?.open()
        if ackDelivered {
            ackDelivered = false; processedACKs += 1
            await ackGates.removeValue(forKey: processedACKs)?.open()
        }
        if !incoming.isEmpty {
            let message = incoming.removeFirst()
            if (try? VoiceGatewayFrame(message, direction: .serverToClient).opcode) == 6 { ackDelivered = true }
            return message
        }
        if closed { return nil }
        guard waiter == nil else { throw TransportFailure.concurrentRead }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiter = continuation }
            }
        } onCancel: { Task { await self.cancelRead() } }
    }
    /// Removes and cancels the currently suspended socket reader exactly once.
    private func cancelRead() { let pending = waiter; waiter = nil; pending?.resume(throwing: CancellationError()) }
    /// Records a synthetic peer close code and releases a pending reader with EOF.
    func disconnect(_ code: Int) { self.code = code; closed = true; let pending = waiter; waiter = nil; pending?.resume(returning: nil) }
    /// Closes the acquired fixture idempotently and releases a pending reader with EOF.
    func close() { closed = true; let pending = waiter; waiter = nil; pending?.resume(returning: nil) }
    /// Performs resumable-generation cleanup using the same idempotent socket close.
    func closeForReconnect() async { close() }
    /// Returns only the finite synthetic close code used by the production retry policy.
    func peerCloseCode() -> Int? { code }
    /// Waits for a known receive-call count, proving preceding controls completed reduction.
    func waitForRead(_ count: Int) async throws {
        if reads >= count { return }
        let gate = readGates[count] ?? VoiceLifecycleGate(); readGates[count] = gate
        try await gate.wait()
    }
    /// Reserves an observation gate for the next ACK processed after this caller boundary.
    func nextACKGate() -> VoiceLifecycleGate {
        let target = processedACKs + 1
        let gate = ackGates[target] ?? VoiceLifecycleGate(); ackGates[target] = gate
        return gate
    }
    /// Returns the actual number of complete outgoing Speaking controls.
    func speakingCount() -> Int { speaking }
    /// Reads acquired-resource, continuation, acknowledged-heartbeat and Speaking counters.
    func receipt() async -> (owners: Int, waiters: Int, acks: Int, speaking: Int) {
        var count = waiter == nil ? 0 : 1
        for gate in readGates.values { count += await gate.count() }
        for gate in ackGates.values { count += await gate.count() }
        return (opened && !closed ? 1 : 0, count, heartbeatACKs, speaking)
    }
}

private actor VoiceLifecycleConnector: WebSocketTransport {
    private let sockets: [VoiceLifecycleSocket]
    private var attempts = 0
    /// Retains exactly two inert scripted socket generations for the allowed single resume.
    init(_ first: VoiceLifecycleSocket, _ second: VoiceLifecycleSocket) { sockets = [first, second] }
    /// Checks the production secure-upgrade request and acquires the next local scripted peer.
    func connectWebSocket<C: Clock>(_ request: HTTPRequest, context: TransportContext<C>) async throws -> any WebSocketConnection where C.Duration == Duration {
        try context.check()
        guard attempts < sockets.count, request.url.scheme == "wss", request.url.host == "voice.invalid" else {
            throw TransportFailure.scriptExhausted
        }
        let socket = sockets[attempts]; attempts += 1; await socket.open()
        return socket
    }
    /// Returns actual connector acquisitions, including the optional resumed generation.
    func count() -> Int { attempts }
}

/// Exact discovery response followed by one cancellation-aware media read; never binds a socket.
private actor VoiceLifecycleDatagram: DatagramTransport {
    private var discovered = false
    private var opened = false
    private var closed = false
    private var sent = 0
    private var waiter: CheckedContinuation<Datagram?, any Error>?
    /// Records the real session acquiring the inert UDP fixture after Ready.
    func open() { opened = true }
    /// Validates and counts the exact production discovery packet without creating a socket.
    func sendDatagram<C: Clock>(_ datagram: Datagram, context: TransportContext<C>) async throws where C.Duration == Duration {
        try context.check(); guard !closed, datagram.bytes == VoiceDiscovery.request(ssrc: 42) else { throw TransportFailure.invalidLimit }
        sent += 1
    }
    /// Runs one cancellation-aware datagram pull under the supplied discovery or media context.
    func receiveDatagram<C: Clock>(context: TransportContext<C>) async throws -> Datagram? where C.Duration == Duration {
        try await context.run { try await self.read() }
    }
    /// Delivers one fixed-width discovery response, then suspends the lifetime media reader.
    private func read() async throws -> Datagram? {
        try Task.checkCancellation()
        if !discovered {
            discovered = true
            var bytes = [UInt8](VoiceDiscovery.request(ssrc: 42)); bytes[1] = 2
            for (index, byte) in "127.0.0.1".utf8.enumerated() { bytes[8 + index] = byte }
            bytes[72] = 0xc3; bytes[73] = 0x50
            return Datagram(bytes: Data(bytes), peer: DatagramAddress(host: "127.0.0.1", port: 50_000))
        }
        if closed { return nil }
        guard waiter == nil else { throw TransportFailure.concurrentRead }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiter = continuation }
            }
        } onCancel: { Task { await self.cancelRead() } }
    }
    /// Closes the synthetic native-style UDP resource and cancels its suspended reader.
    private func cancelRead() { closed = true; let pending = waiter; waiter = nil; pending?.resume(throwing: CancellationError()) }
    /// Closes idempotently and releases a pending lifetime media read with EOF.
    func close() { closed = true; let pending = waiter; waiter = nil; pending?.resume(returning: nil) }
    /// Returns acquired-resource, suspended-reader and exact discovery-send counts.
    func receipt() -> (owners: Int, waiters: Int, sent: Int) { (opened && !closed ? 1 : 0, waiter == nil ? 0 : 1, sent) }
}

private struct VoiceLifecycleReadiness: VoiceE2EEReadiness {
    let identity: VoiceConnectionIdentity
    /// Accepts only the exact synthetic connection identity and negotiated nonzero version one.
    func validateSession(protocolVersion: UInt16, identity: VoiceConnectionIdentity) throws {
        guard protocolVersion == 1, identity == self.identity else { throw VoiceControlFailure.e2eeUnavailable }
    }
}

/// Synthetic identity gate deliberately performs no real MLS or media cryptography.
private actor VoiceLifecycleE2EE: VoiceSessionE2EE {
    let identity: VoiceConnectionIdentity
    private var closed = false
    /// Retains the entire expected synthetic identity without creating keys or work.
    init(_ identity: VoiceConnectionIdentity) { self.identity = identity }
    /// Checks the nonzero fixture protocol version; no MLS negotiation is fabricated.
    func start(protocolVersion: UInt16) throws -> [VoiceGatewayFrame] {
        guard !closed, protocolVersion == 1 else { throw VoiceControlFailure.e2eeUnavailable }; return []
    }
    /// Returns no synthetic responses; this control-only fixture performs no cryptographic processing.
    func receive(_ frame: VoiceGatewayFrame, now: TimeInterval) throws -> [VoiceGatewayFrame] { [] }
    /// Uses the production identity-checking readiness API to authorize the copied fixture reducer.
    func authorizeGateway(_ state: VoiceGatewaySessionState) throws -> VoiceGatewaySessionState {
        guard !closed else { throw VoiceControlFailure.closed }
        var result = state; try result.authorizeMedia(using: VoiceLifecycleReadiness(identity: identity)); return result
    }
    /// Accepts control-only binding; no media path uses this synthetic backend.
    func bindSSRC(_ ssrc: UInt32, userID: UserID) throws {}
    /// Performs no work because this control-only fixture retains no participant bindings.
    func removeParticipant(_ userID: UserID) {}
    /// Rejects every media-encryption request so the fixture cannot be mistaken for real DAVE.
    func seal(_ opus: Data, ssrc: UInt32) throws -> Data { throw VoiceControlFailure.e2eeUnavailable }
    /// Rejects every media-decryption request so synthetic readiness cannot authenticate media.
    func open(_ frame: Data, ssrc: UInt32) throws -> Data { throw VoiceControlFailure.e2eeUnavailable }
    /// Permanently closes the synthetic readiness owner without retaining keys or child tasks.
    func close() { closed = true }
    /// Reports backend closure independently from session and adapter snapshots.
    func isClosed() -> Bool { closed }
}

/// Serializes one bounded synthetic server control through the real lossless JSON path.
private func voiceLifecycleFrame(_ opcode: UInt8, _ data: JSONValue) throws -> WebSocketMessage {
    .text(String(decoding: try JSONValue.object(["op": voiceLifecycleNumber(opcode), "d": data]).serialized(), as: UTF8.self))
}

/// Builds finite Hello, Ready and Description controls with the current transport cipher and DAVE version.
private func voiceLifecycleFrames(heartbeat: Bool) throws -> [WebSocketMessage] {
    [try voiceLifecycleFrame(8, .object(["heartbeat_interval": voiceLifecycleNumber(heartbeat ? 1_000 : 60_000)])),
     try voiceLifecycleFrame(2, .object(["ssrc": voiceLifecycleNumber(42), "ip": .string("127.0.0.1"),
        "port": voiceLifecycleNumber(50_000), "modes": .array([.string("aead_xchacha20_poly1305_rtpsize")])])),
     try voiceLifecycleFrame(4, .object(["mode": .string("aead_xchacha20_poly1305_rtpsize"),
        "secret_key": .array((0..<32).map { voiceLifecycleNumber($0) }), "dave_protocol_version": voiceLifecycleNumber(1)]))]
}

/// Converts only a finite fixture integer to exact JSON, with no floating-point path.
private func voiceLifecycleNumber<T: BinaryInteger>(_ value: T) -> JSONValue {
    .number(try! JSONNumber(rawValue: String(value)))
}

/// Bounded virtual runtime time; observation gates drive timers without wall-clock scheduling races.
/// Measurement never uses this clock, and ordinary sleeps never advance its time automatically.
private final class VoiceLifecycleClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        let offset: Duration
        /// Returns the checked virtual-time offset after adding a duration.
        func advanced(by duration: Duration) -> Self { .init(offset: offset + duration) }
        /// Returns signed virtual elapsed time to another instant from this clock.
        func duration(to other: Self) -> Duration { other.offset - offset }
        /// Orders virtual instants by their clock-local offsets.
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.offset < rhs.offset }
    }
    private struct Sleep {
        let deadline: Instant
        let gate: VoiceLifecycleGate
    }
    private let lock = NSLock()
    private var instant = Instant(offset: .zero)
    private var sleepers: [UUID: Sleep] = [:]
    private var heartbeatSleeps = 0
    let firstHeartbeat = VoiceLifecycleGate()
    let secondHeartbeat = VoiceLifecycleGate()
    let retry = VoiceLifecycleGate()
    /// Reads the explicitly advanced virtual instant under the clock lock.
    var now: Instant { lock.withLock { instant } }
    /// Declares one-nanosecond virtual resolution without implying measurement precision.
    var minimumResolution: Duration { .nanoseconds(1) }
    /// Counts retained runtime timer registrations after owned tasks have joined.
    var pendingSleepCount: Int { lock.withLock { sleepers.count } }
    /// Registers at most 32 cancellation-aware timers and signals exact heartbeat or retry admission.
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        let id = UUID(), gate = VoiceLifecycleGate()
        let admission: (Bool, VoiceLifecycleGate?) = try lock.withLock {
            guard deadline > instant else { return (false, nil) }
            guard sleepers.count < 32 else { throw TransportFailure.invalidLimit }
            let duration = instant.duration(to: deadline)
            sleepers[id] = Sleep(deadline: deadline, gate: gate)
            var signal: VoiceLifecycleGate?
            if duration == .seconds(1) {
                heartbeatSleeps += 1
                if heartbeatSleeps == 1 { signal = firstHeartbeat }
                else if heartbeatSleeps == 2 { signal = secondHeartbeat }
            }
            if duration == .nanoseconds(1) { signal = retry }
            return (true, signal)
        }
        guard admission.0 else { return }
        defer { _ = lock.withLock { sleepers.removeValue(forKey: id) } }
        await admission.1?.open()
        try await gate.wait()
    }
    /// Counts suspended script observers of actual runtime timer admission.
    func pendingObservationCount() async -> Int {
        let first = await firstHeartbeat.count(), second = await secondHeartbeat.count(), retries = await retry.count()
        return first + second + retries
    }
    /// Moves virtual time forward and resolves every due timer once; measurement time remains independent.
    func advance(by duration: Duration) async {
        let due: [VoiceLifecycleGate] = lock.withLock {
            instant = instant.advanced(by: duration)
            let due = sleepers.filter { $0.value.deadline <= instant }
            for id in due.keys { sleepers.removeValue(forKey: id) }
            return due.values.map(\.gate)
        }
        for gate in due { await gate.open() }
    }
}
