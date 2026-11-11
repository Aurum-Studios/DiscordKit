// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/RPCActivitiesTimingRunner.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordActivities
import DiscordBenchmarkSupport
import DiscordCore
import DiscordRPC
import DiscordTransport
import Foundation

/// Finite credential-free scripts exercising real public clients through exclusively injected peers.
enum RPCActivitiesTimingScenario: String, CaseIterable, Codable, Sendable {
    case rpcFragmented = "rpc.fragmented"
    case rpcHandshake = "rpc.handshake"
    case rpcRequests = "rpc.requests"
    case rpcPendingPressure = "rpc.pendingPressure"
    case rpcEvents = "rpc.events"
    case rpcCancelled = "rpc.cancelled"
    case rpcCorrelationFailure = "rpc.correlationFailure"
    case activitiesHandshake = "activities.handshake"
    case activitiesRequests = "activities.requests"
    case activitiesPendingPressure = "activities.pendingPressure"
    case activitiesEvents = "activities.events"
    case activitiesSubscriptions = "activities.subscriptions"
    case activitiesSubscriptionGroupsV1 = "activities.subscriptionGroupsV1"
    case rpcQueuedRepliesV1 = "rpc.queuedRepliesV1"
    case activitiesCancelled = "activities.cancelled"
    case activitiesCorrelationFailure = "activities.correlationFailure"

    /// Selects the explicit local protocol family without creating an unbounded label.
    var isRPC: Bool { rawValue.hasPrefix("rpc.") }
    /// Identifies the finite concurrent-correlation script.
    var isConcurrent: Bool { self == .rpcRequests || self == .activitiesRequests }
    /// Identifies deterministic capacity rejection while one support request owns the only slot.
    var isPressure: Bool { self == .rpcPendingPressure || self == .activitiesPendingPressure }
    /// Identifies cancellation after actual adapter admission.
    var isCancelled: Bool { self == .rpcCancelled || self == .activitiesCancelled }
    /// Identifies the protocol command/nonce mismatch script.
    var isMismatch: Bool { self == .rpcCorrelationFailure || self == .activitiesCorrelationFailure }
    /// Identifies finite slow-consumer dispatch retention and explicit drain.
    var isEvents: Bool { self == .rpcEvents || self == .activitiesEvents }
}

/// Whole primary-call distributions and independently sampled, joined local protocol ownership receipts.
struct RPCActivitiesTimingReport: Codable, Sendable {
    let scenario: String
    let clockDomain: String
    let counts: BenchmarkCounts
    let metrics: [BenchmarkMetric]
    let durationNanoseconds: UInt64
    let cleanup: BenchmarkCleanup
    let peakPendingRequests: Int
    let retainedEvents: Int
    let acquiredSubscriptions: Int
    let upstreamSubscriptions: Int
    let upstreamUnsubscriptions: Int
    let protocolWrites: Int
    let inputFragments: Int
    let closedPeers: Int
    let notes: [String]
    /// Exact successful duplicate-admission sum/population for subscriptionGroupsV1 only.
    var subscriptionAdmissionNanoseconds: UInt64? = nil
    var subscriptionAdmissions: UInt64? = nil
    /// Exact total for complete fixed-size reply cohorts, before histogram recording or cleanup.
    var queuedReplyCohortNanoseconds: UInt64? = nil
    /// Number of complete reply cohorts contributing to the exact total.
    var queuedReplyCohorts: UInt64? = nil
}

/// Measures real RPC framing and Activity client orchestration with no desktop or browser access.
struct RPCActivitiesTimingRunner: Sendable {
    private let onReplyDelivery: (@Sendable () async -> Void)?

    /// Optionally parks the first released reply at its actual adapter read for cancellation tests.
    /// - Parameter onReplyDelivery: Test-owned gate; nil leaves ordinary adapter delivery unchanged.
    init(onReplyDelivery: (@Sendable () async -> Void)? = nil) { self.onReplyDelivery = onReplyDelivery }

    /// Runs finite independent sessions, retaining one measured primary command per session.
    /// - Parameters:
    ///   - scenario: Fixed framing, correlation, capacity, event, subscription or cancellation script.
    ///   - requests: Independent primary attempts, in 1...100,000.
    ///   - concurrency: Concurrent session owners, in 1...64 and no greater than requests.
    ///   - fanOut: Concurrent supporting requests, events or shared subscription owners, in 1...64.
    ///   - delay: Injected peer delivery delay per complete protocol frame, zero through one second.
    ///   - subscriptionGroups: Independent active groups for subscriptionGroupsV1; one for legacy cases.
    ///   - ownersPerGroup: Measured duplicate owners after each seeded group; one for legacy cases.
    /// - Returns: Every started primary call, bounded child populations and actual post-close receipts.
    /// - Throws: Invalid bounds, allocation failure or an independently detected protocol/cleanup mismatch.
    /// External cancellation stops new waves; interrupted in-flight callers, startup and fixture failures
    /// throw only after all public caller tasks, native fixture reads and cleanup have joined.
    func run(scenario: RPCActivitiesTimingScenario, requests: Int = 8, concurrency: Int = 1,
             fanOut: Int = 4, delay: Duration = .zero, subscriptionGroups: Int = 1,
             ownersPerGroup: Int = 1) async throws -> RPCActivitiesTimingReport {
        guard (1...100_000).contains(requests), (1...64).contains(concurrency), concurrency <= requests,
              (1...64).contains(fanOut), delay >= .zero, delay <= .seconds(1),
              (1...4_096).contains(subscriptionGroups), (1...4_096).contains(ownersPerGroup),
              subscriptionGroups * (ownersPerGroup + 1) <= 65_536,
              scenario == .activitiesSubscriptionGroupsV1 || (subscriptionGroups == 1 && ownersPerGroup == 1),
              scenario != .rpcQueuedRepliesV1 else { throw LoadFailure.invalidArguments }
        let statistics = try RunStatistics(workloads: scenario.isRPC
            ? [.rpcRequest, .rpcHandshake, .rpcWrite, .rpcPeerWait, .rpcEventDispatch, .rpcClose]
            : [.activitiesRequest, .activitiesHandshake, .activitiesWrite, .activitiesPeerWait,
               .activitiesEventDispatch, .activitiesClose, .activitiesSubscription])
        let origin = ContinuousClock.now
        var results: [ProtocolTimingReceipt] = []
        // Only bounded numeric receipts are retained across waves, never per-operation payloads.
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        var completed = 0, peak = 0, events = 0, subscriptions = 0, upstream = 0, removed = 0
        var writes = 0, fragments = 0, closed = 0, remaining = 0, invalid = false
        var admissionNanoseconds: UInt64 = 0, admissions: UInt64 = 0
        for wave in stride(from: 0, to: requests, by: concurrency) {
            if Task.isCancelled { break }
            results.removeAll(keepingCapacity: true)
            try await withThrowingTaskGroup(of: ProtocolTimingReceipt.self) { group in
                for _ in wave..<min(requests, wave + concurrency) {
                    group.addTask { try await runProtocolFixture(scenario, fanOut: fanOut, delay: delay,
                        subscriptionGroups: subscriptionGroups, ownersPerGroup: ownersPerGroup,
                        onReplyDelivery: onReplyDelivery, statistics: statistics) }
                }
                for try await result in group { results.append(result) }
            }
            for result in results {
                completed += 1; outcomes[result.outcome, default: 0] += 1
                peak = max(peak, result.peakPending); events += result.events; subscriptions += result.subscriptions
                upstream += result.peer.subscriptions; removed += result.peer.unsubscriptions
                writes += result.peer.writes; fragments += result.peer.fragments; closed += result.peer.closes
                remaining += result.remaining; invalid = invalid || !result.valid
                let sum = admissionNanoseconds.addingReportingOverflow(result.admissionNanoseconds)
                guard !sum.overflow else { throw ProtocolTimingFailure.integrity }
                admissionNanoseconds = sum.partialValue; admissions += UInt64(result.admissions)
            }
        }
        guard !invalid, remaining == 0 else { throw ProtocolTimingFailure.integrity }
        var report = RPCActivitiesTimingReport(scenario: scenario.rawValue, clockDomain: statistics.clockDomain,
            counts: .init(offered: UInt64(completed), admitted: UInt64(completed) - outcomes[.rejected, default: 0],
                completed: UInt64(completed), outcomes: outcomes, deadlineMisses: 0), metrics: statistics.metrics(),
            durationNanoseconds: try BenchmarkTime.nanoseconds(duration: origin.duration(to: .now)),
            cleanup: .init(completed: true, remainingOwners: UInt64(remaining)), peakPendingRequests: peak,
            retainedEvents: events, acquiredSubscriptions: subscriptions, upstreamSubscriptions: upstream,
            upstreamUnsubscriptions: removed, protocolWrites: writes, inputFragments: fragments, closedPeers: closed,
            notes: [
                "Injected byte-stream/Activity peers only; no real desktop, browser, credential, authorization or purchase is used.",
                "Counts cover exactly one primary public request per independent session. Supporting pressure/correlation requests and subscription commands are excluded from that population and explicitly counted as adapter writes.",
                "Request clocks start immediately before the public client call and stop at its result/error, before resource snapshots, event drains or close. Handshake has its independent caller boundary; close includes the public owner call and an explicit join of actual fixture adapter reads.",
                "Write measures the injected adapter method, including framing/fixture response preparation. Peer wait measures only the explicitly configured delivery sleep once per complete frame, before fragment delivery; neither metric claims internal actor admission or nonce-match CPU time.",
                "Event dispatch is a batch from injected dispatch submission through the sentinel request reply and public drain, including protocol read/queue residence. Concurrent support replies are delivered in reverse order and each caller's distinct response is checked.",
                "All RPC scripts use the production RPCIPCConnection and RPCFrameDecoder; fragmented uses single-byte input, other RPC scripts use seven-byte input. Activities use complete authenticated-adapter tuples; origin authentication belongs to the separate Node bridge checks.",
                "Activity subscription metrics time acquisition through each returned token or rejection. Duplicate owners share one actual SUBSCRIBE; one extra owner proves bounded capacity rejection without another wire subscription. Final release emits one UNSUBSCRIBE and is verified through receipts, without a release histogram. A support command holds pending capacity for rejected primary calls.",
                "subscriptionGroupsV1 seeds one acknowledged owner per distinct group outside subscription timing, then measures duplicate acquisitions while every seeded group remains active. Upstream delay is excluded from these measured duplicates; seed and final release provider work remains in overall duration. Capacity rejection and exact full release are checked independently.",
                "For subscriptionGroupsV1 compare activities.subscription and the exact successful duplicate-admission native sum/count. Its later generic activities.request primary and common throughput are control observations and do not measure subscription admission.",
                "Peak pending is the maximum observed per independent session; retained-event and subscription receipts sum actual per-session counts. Nested intervals overlap and are not additive. Overall duration includes fixture allocation, orchestration and diagnostics; local timing is not live host qualification."
            ])
        if scenario == .activitiesSubscriptionGroupsV1 {
            report.subscriptionAdmissionNanoseconds = admissionNanoseconds
            report.subscriptionAdmissions = admissions
        }
        return report
    }
}

/// A protocol integrity discrepancy is distinct from a deliberately measured runtime error.
private enum ProtocolTimingFailure: Error { case integrity }

/// Joined primary-call result and scalar diagnostics from one exclusively owned fixture.
private struct ProtocolTimingReceipt: Sendable {
    let outcome: BenchmarkOutcome
    let valid: Bool
    let peakPending: Int
    let events: Int
    let subscriptions: Int
    let remaining: Int
    let peer: ProtocolPeerReceipt
    var admissionNanoseconds: UInt64 = 0
    var admissions: Int = 0
}

/// Numeric peer ownership and observed protocol receipts, independent of client snapshots.
private struct ProtocolPeerReceipt: Sendable {
    let writes: Int
    let fragments: Int
    let subscriptions: Int
    let unsubscriptions: Int
    let closes: Int
    let remaining: Int
}

/// One measured public request, including unchanged expected failure/cancellation propagation.
private struct ProtocolCallResult: Sendable {
    let outcome: BenchmarkOutcome
    let valid: Bool
}

/// Couples family-specific public operations while preserving their actual owner methods.
private enum ProtocolTimingClient: Sendable {
    case rpc(RPCClient<ContinuousClock>)
    case activities(ActivityClient<ContinuousClock>)

    /// Starts an owned local session and validates production READY handling.
    func start() async throws {
        switch self {
        case .rpc(let client): try await client.connect(context: protocolTimingContext())
        case .activities(let client): try await client.start(timeout: .seconds(10))
        }
    }

    /// Executes one documented read command and preserves the raw correlated response for fixture checks.
    func request() async throws -> JSONValue {
        switch self {
        case .rpc(let client): return try await client.request(.getGuilds(), context: protocolTimingContext())
        case .activities(let client): return try await client.execute(ActivityRequest(command: .getChannel,
            arguments: ["channel_id": .string("1")], decode: { $0 }), timeout: .seconds(10))
        }
    }

    /// Reads actual owner counters, preserving both count and byte ownership after termination.
    func snapshot() async -> (pending: Int, remaining: Int, events: Int, subscriptions: Int) {
        switch self {
        case .rpc(let client):
            let value = await client.resourceCounts()
            return (value.pending, value.pending + value.pendingBytes + value.events + value.eventBytes, value.events, 0)
        case .activities(let client):
            let value = await client.snapshot()
            return (value.pending, value.pending + value.pendingBytes + value.events + value.eventBytes + value.subscriptions,
                value.events, value.subscriptions)
        }
    }

    /// Transfers finite public events in their original order; READY is consumed separately at startup.
    func drain(_ count: Int) async throws -> Bool {
        switch self {
        case .rpc(let client):
            for _ in 0..<count {
                guard try await client.nextEvent(context: protocolTimingContext())?.name == "TIMING_EVENT" else { return false }
            }
            return true
        case .activities(let client): return await client.drainEvents().map(\.name.rawValue) == Array(repeating: "TIMING_EVENT", count: count)
        }
    }

    /// Awaits the public owner's terminal transport cleanup without skipping cancellation cleanup.
    func close() async {
        switch self {
        case .rpc(let client): await client.close()
        case .activities(let client): await client.close()
        }
    }
}

/// Uses a finite real deadline so a broken fixture cannot leave request or event waiters indefinite.
private func protocolTimingContext() -> TransportContext<ContinuousClock> {
    .init(clock: ContinuousClock(), deadline: ContinuousClock.now.advanced(by: .seconds(10)))
}

/// Preserves the finite harness outcome contract without exposing arbitrary runtime error descriptions.
private func protocolTimingOutcome(_ error: any Error) -> BenchmarkOutcome {
    if error is CancellationError { return .cancelled }
    if error as? RPCFailure == .overloaded || error as? ActivityFailure == .overloaded { return .rejected }
    if error as? TransportFailure == .deadlineExceeded { return .timedOut }
    return .failure
}

/// Measures exactly one primary public request and validates its distinct synthetic correlated result.
private func protocolTimingCall(_ client: ProtocolTimingClient, expected: Int, statistics: RunStatistics,
                                workload: BenchmarkWorkload) async -> ProtocolCallResult {
    let start = ContinuousClock.now
    do {
        let value = try await client.request()
        let end = ContinuousClock.now
        statistics.record(start.duration(to: end), workload: workload, outcome: .success)
        return .init(outcome: .success, valid: value == .string(String(expected)))
    } catch {
        let end = ContinuousClock.now, outcome = protocolTimingOutcome(error)
        statistics.record(start.duration(to: end), workload: workload, outcome: outcome)
        return .init(outcome: outcome, valid: true)
    }
}

/// Drives one primary and its finite support owners, then checks both client and peer cleanup independently.
/// - Parameters:
///   - scenario: Fixed protocol family and finite fixture policy.
///   - fanOut: Legacy supporting requests, events or shared owners.
///   - delay: Injected peer receive wait per complete frame.
///   - subscriptionGroups: Independently seeded upstream group count for the versioned control.
///   - ownersPerGroup: Duplicate admissions measured for every seeded group.
///   - onReplyDelivery: Optional test-owned first released-reply read gate.
///   - statistics: Full-population collector used after each terminal timestamp.
/// - Returns: Joined primary outcome and exact protocol, subscription and cleanup receipts.
/// - Throws: Fixture, protocol, cancellation or independently detected population/ownership failures.
private func runProtocolFixture(_ scenario: RPCActivitiesTimingScenario, fanOut: Int, delay: Duration,
                                subscriptionGroups: Int, ownersPerGroup: Int,
                                onReplyDelivery: (@Sendable () async -> Void)?,
                                statistics: RunStatistics) async throws -> ProtocolTimingReceipt {
    let peer = try ProtocolTimingPeer(rpc: scenario.isRPC, fragmentSize: scenario == .rpcFragmented ? 1 : 7,
        delay: delay, onReplyDelivery: onReplyDelivery, statistics: statistics)
    let client: ProtocolTimingClient
    if scenario.isRPC {
        let connection = try RPCIPCConnection(transport: peer, maximumPayloadBytes: 4096)
        client = .rpc(try RPCClient(applicationID: .init(rawValue: 1), clock: ContinuousClock(),
            connector: ProtocolTimingConnector(connection: connection), maximumPendingRequests: scenario.isPressure ? 1 : 64,
            maximumEvents: 66, maximumPayloadBytes: 4096))
    } else {
        let host = try ActivityHostParameters(url: URL(string: "https://1.discordsays.com/?frame_id=fixture&instance_id=fixture&platform=desktop")!)
        client = .activities(try ActivityClient(applicationID: .init(rawValue: 1), host: host, transport: peer,
            clock: ContinuousClock(), limits: .init(maximumFrameBytes: 4096, maximumPending: scenario.isPressure ? 1 : 64,
                maximumEvents: 66, maximumSubscriptions: scenario == .activitiesSubscriptions ? fanOut :
                    scenario == .activitiesSubscriptionGroupsV1 ? subscriptionGroups * (ownersPerGroup + 1) : 64)))
    }
    let handshake = ContinuousClock.now
    do {
        try await client.start()
        let end = ContinuousClock.now
        statistics.record(handshake.duration(to: end), workload: scenario.isRPC ? .rpcHandshake : .activitiesHandshake, outcome: .success)
    } catch {
        let end = ContinuousClock.now
        statistics.record(handshake.duration(to: end), workload: scenario.isRPC ? .rpcHandshake : .activitiesHandshake,
            outcome: protocolTimingOutcome(error))
        await client.close(); await peer.joinReads(); throw error
    }
    if case .activities(let activity) = client { _ = await activity.drainEvents() }
    var helpers: [Task<Bool, Never>] = []
    var ownedPrimary: Task<ProtocolCallResult, Never>?
    do {
    var valid = true, acquired = 0, peak = 0, events = 0
    var subscriptions: [ActivitySubscription] = []
    var admissionNanoseconds: UInt64 = 0, admissions = 0
    if scenario == .activitiesSubscriptions, case .activities(let activity) = client {
        // The first owner establishes the upstream group. Equal later tokens prove sharing independently.
        do {
            for _ in 0..<fanOut {
                let start = ContinuousClock.now
                let token = try await activity.subscribe(.init(rawValue: "TIMING_EVENT"), timeout: .seconds(10))
                let end = ContinuousClock.now
                statistics.record(start.duration(to: end), workload: .activitiesSubscription, outcome: .success)
                subscriptions.append(token)
            }
            acquired = await activity.snapshot().subscriptions
            let rejectedStart = ContinuousClock.now
            do {
                let extra = try await activity.subscribe(.init(rawValue: "TIMING_EVENT"), timeout: .seconds(10))
                let end = ContinuousClock.now
                statistics.record(rejectedStart.duration(to: end), workload: .activitiesSubscription, outcome: .success)
                subscriptions.append(extra); valid = false
            } catch {
                let end = ContinuousClock.now, outcome = protocolTimingOutcome(error)
                statistics.record(rejectedStart.duration(to: end), workload: .activitiesSubscription, outcome: outcome)
                valid = valid && outcome == .rejected
            }
            for token in subscriptions { try await activity.unsubscribe(token, timeout: .seconds(10)) }
        } catch { await client.close(); await peer.joinReads(); throw error }
    }
    if scenario == .activitiesSubscriptionGroupsV1, case .activities(let activity) = client {
        // Populate independent groups first so timed duplicate admissions see a fixed group count.
        for group in 0..<subscriptionGroups {
            subscriptions.append(try await activity.subscribe(.init(rawValue: "TIMING_EVENT"),
                arguments: ["channel_id": .string(String(group + 1))], timeout: .seconds(10)))
        }
        for _ in 0..<ownersPerGroup {
            for group in 0..<subscriptionGroups {
                let start = ContinuousClock.now
                let token = try await activity.subscribe(.init(rawValue: "TIMING_EVENT"),
                    arguments: ["channel_id": .string(String(group + 1))], timeout: .seconds(10))
                let end = ContinuousClock.now
                statistics.record(start.duration(to: end), workload: .activitiesSubscription, outcome: .success)
                subscriptions.append(token)
                let duration = try BenchmarkTime.nanoseconds(duration: start.duration(to: end))
                let sum = admissionNanoseconds.addingReportingOverflow(duration)
                guard !sum.overflow else { throw ProtocolTimingFailure.integrity }
                admissionNanoseconds = sum.partialValue; admissions += 1
            }
        }
        acquired = await activity.snapshot().subscriptions
        let start = ContinuousClock.now
        do {
            let extra = try await activity.subscribe(.init(rawValue: "TIMING_EVENT"),
                arguments: ["channel_id": .string("1")], timeout: .seconds(10))
            let end = ContinuousClock.now
            statistics.record(start.duration(to: end), workload: .activitiesSubscription, outcome: .success)
            subscriptions.append(extra); valid = false
        } catch {
            let end = ContinuousClock.now, outcome = protocolTimingOutcome(error)
            statistics.record(start.duration(to: end), workload: .activitiesSubscription, outcome: outcome)
            valid = valid && outcome == .rejected
        }
        for token in subscriptions { try await activity.unsubscribe(token, timeout: .seconds(10)) }
        let released = await activity.snapshot()
        valid = valid && released.subscriptions == 0
    }
    let eventStart = ContinuousClock.now
    if scenario.isEvents { try await peer.pushEvents(fanOut) }
    await peer.holdReplies(true)
    let base = await peer.commandCount
    if scenario.isPressure {
        helpers.append(Task {
            do { return try await client.request() == .string(String(base + 1)) }
            catch { return false }
        })
        try await peer.waitForCommands(base + 1)
        peak = await client.snapshot().pending
    }
    let expected = base + (scenario.isPressure ? 2 : 1)
    let primary = Task { await protocolTimingCall(client, expected: expected, statistics: statistics,
        workload: scenario.isRPC ? .rpcRequest : .activitiesRequest) }
    ownedPrimary = primary
    if !scenario.isPressure {
        try await peer.waitForCommands(base + 1)
        if scenario.isConcurrent {
            for index in 1..<fanOut {
                helpers.append(Task {
                    do { return try await client.request() == .string(String(base + index + 1)) }
                    catch { return false }
                })
                try await peer.waitForCommands(base + index + 1)
            }
        }
        peak = await client.snapshot().pending
    }
    let currentHelpers = helpers
    let joined = try await withTaskCancellationHandler {
        let result: ProtocolCallResult
        if scenario.isPressure {
            result = await primary.value
            try await peer.releaseReplies(mismatch: false)
        } else if scenario.isCancelled || Task.isCancelled {
            primary.cancel(); result = await primary.value
            // Late responses are intentionally delivered after the primary continuation has been released.
            try await peer.releaseReplies(mismatch: false)
        } else {
            try await peer.releaseReplies(mismatch: scenario.isMismatch)
            result = await primary.value
        }
        var helpersValid = true
        for helper in currentHelpers { helpersValid = await helper.value && helpersValid }
        // Parent cancellation is observed only after every unstructured public caller has joined.
        try Task.checkCancellation()
        return (result, helpersValid)
    } onCancel: {
        primary.cancel()
        for helper in currentHelpers { helper.cancel() }
    }
    let result = joined.0
    valid = valid && joined.1
    let expectedOutcome: BenchmarkOutcome = scenario.isPressure ? .rejected : scenario.isCancelled || Task.isCancelled ? .cancelled : scenario.isMismatch ? .failure : .success
    valid = valid && result.valid && result.outcome == expectedOutcome
    if scenario.isEvents {
        events = await client.snapshot().events
        valid = try await client.drain(fanOut) && valid && events == fanOut
        let end = ContinuousClock.now
        statistics.record(eventStart.duration(to: end), workload: scenario.isRPC ? .rpcEventDispatch : .activitiesEventDispatch, outcome: .success)
    }
    let close = ContinuousClock.now
    await client.close()
    await peer.joinReads()
    let closed = ContinuousClock.now
    statistics.record(close.duration(to: closed), workload: scenario.isRPC ? .rpcClose : .activitiesClose, outcome: .success)
    await client.close()
    let snapshot = await client.snapshot(), receipt = await peer.receipt()
    valid = valid && receipt.closes == 1
    if scenario == .activitiesSubscriptions { valid = valid && acquired == fanOut && receipt.subscriptions == 1 && receipt.unsubscriptions == 1 }
    if scenario == .activitiesSubscriptionGroupsV1 {
        valid = valid && acquired == subscriptionGroups * (ownersPerGroup + 1)
            && receipt.subscriptions == subscriptionGroups && receipt.unsubscriptions == subscriptionGroups
    }
    return .init(outcome: result.outcome, valid: valid, peakPending: peak, events: events, subscriptions: acquired,
        remaining: snapshot.remaining + receipt.remaining, peer: receipt,
        admissionNanoseconds: admissionNanoseconds, admissions: admissions)
    } catch {
        ownedPrimary?.cancel()
        for helper in helpers { helper.cancel() }
        await client.close()
        await peer.joinReads()
        _ = await ownedPrimary?.value
        for helper in helpers { _ = await helper.value }
        let state = await client.snapshot(), receipt = await peer.receipt()
        guard state.remaining + receipt.remaining == 0 else { throw ProtocolTimingFailure.integrity }
        throw error
    }
}

/// Transfers one already injected IPC connection; no filesystem discovery or host access occurs.
private struct ProtocolTimingConnector: RPCConnector {
    let connection: RPCIPCConnection
    /// Returns the exclusively owned fixture connection after checking cancellation/deadline.
    func connect<C: Clock>(applicationID: ApplicationID, context: TransportContext<C>) async throws -> any RPCConnection where C.Duration == Duration {
        try context.check(); return connection
    }
}

/// Bounded in-memory IPC byte stream or authenticated Activity tuple channel, with deterministic barriers.
private actor ProtocolTimingPeer: IPCTransport, ActivityTransport {
    private let rpc: Bool
    private let fragmentSize: Int
    private let delay: Duration
    private let onReplyDelivery: (@Sendable () async -> Void)?
    private let statistics: RunStatistics
    private var decoder: RPCFrameDecoder
    private var input: [(Data, Bool)] = []
    private var waiter: CheckedContinuation<(Data, Bool)?, Never>?
    private var barrier: (Int, CheckedContinuation<Void, Never>)?
    private var held: [[String: JSONValue]] = []
    private var holding = false
    private var repliesReleased = false
    private var observedReplyDelivery = false
    private var ended = false
    private var activeReads = 0
    private var readJoiner: CheckedContinuation<Void, Never>?
    private var writes = 0, fragments = 0, closes = 0, subscriptions = 0, unsubscriptions = 0
    private(set) var commandCount = 0

    /// Allocates an inert, finite channel; every incoming frame is capped to 4 KiB before fragmenting.
    /// - Parameters:
    ///   - rpc: Selects production IPC framing rather than complete Activity tuples.
    ///   - fragmentSize: Fixed maximum returned IPC fragment size.
    ///   - delay: Cooperative per-complete-frame injected receive wait.
    ///   - onReplyDelivery: Optional deterministic first released-reply read gate for tests.
    ///   - statistics: Bounded adapter and wait populations, recorded after terminal timestamps.
    /// - Throws: Invalid RPC frame-decoder capacity.
    init(rpc: Bool, fragmentSize: Int, delay: Duration,
         onReplyDelivery: (@Sendable () async -> Void)?, statistics: RunStatistics) throws {
        self.rpc = rpc; self.fragmentSize = fragmentSize; self.delay = delay; self.statistics = statistics
        self.onReplyDelivery = onReplyDelivery
        decoder = try RPCFrameDecoder(maximumPayloadBytes: 4096)
    }

    /// Parses actual production IPC wire frames and records only the adapter write boundary.
    func write<C: Clock>(_ bytes: Data, context: TransportContext<C>) async throws where C.Duration == Duration {
        try context.check()
        let start = ContinuousClock.now
        do {
            guard !ended else { throw RPCFailure.closed }
            for frame in try decoder.append(bytes) {
                writes += 1
                if frame.opcode == .handshake { try pushReady() }
                else if frame.opcode == .frame { try accept(frame.payload) }
            }
            let end = ContinuousClock.now
            statistics.record(start.duration(to: end), workload: .rpcWrite, outcome: .success)
        } catch {
            let end = ContinuousClock.now
            statistics.record(start.duration(to: end), workload: .rpcWrite, outcome: protocolTimingOutcome(error)); throw error
        }
    }

    /// Accepts one complete Activity tuple and simulates only documented READY, reply or close handling.
    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        let start = ContinuousClock.now
        do {
            guard !ended, case .array(let tuple) = try JSONValue.parse(data), tuple.count == 2 else { throw ActivityFailure.closed }
            writes += 1
            if tuple[0] == .number(try JSONNumber(rawValue: "0")) { try pushReady() }
            else if tuple[0] == .number(try JSONNumber(rawValue: "1")) { try accept(tuple[1].serialized()) }
            let end = ContinuousClock.now
            statistics.record(start.duration(to: end), workload: .activitiesWrite, outcome: .success)
        } catch {
            let end = ContinuousClock.now
            statistics.record(start.duration(to: end), workload: .activitiesWrite, outcome: protocolTimingOutcome(error)); throw error
        }
    }

    /// Returns the next production-decoder fragment with an explicit finite maximum read bound.
    func read<C: Clock>(maximumBytes: Int, context: TransportContext<C>) async throws -> Data? where C.Duration == Duration {
        try context.check()
        guard maximumBytes >= fragmentSize else { throw ProtocolTimingFailure.integrity }
        return try await take()
    }

    /// Returns a complete authenticated Activity tuple; source/origin filtering is separately tested in Node.
    func receive() async throws -> Data? { try await take() }

    /// Suspends one reader, with close/cancellation releasing its continuation and the configured sleep.
    private func take() async throws -> Data? {
        activeReads += 1
        defer {
            activeReads -= 1
            if activeReads == 0 { readJoiner?.resume(); readJoiner = nil }
        }
        let entry: (Data, Bool)?
        if !input.isEmpty { entry = input.removeFirst() }
        else if ended { return nil }
        else {
            entry = await withTaskCancellationHandler {
                await withCheckedContinuation { waiter = $0 }
            } onCancel: { Task { await self.close() } }
        }
        guard let entry else { return nil }
        if entry.1 && repliesReleased && !observedReplyDelivery, let onReplyDelivery {
            observedReplyDelivery = true
            await onReplyDelivery()
        }
        if entry.1 && delay > .zero {
            let start = ContinuousClock.now
            do {
                try await Task.sleep(for: delay)
                let end = ContinuousClock.now
                statistics.record(start.duration(to: end), workload: rpc ? .rpcPeerWait : .activitiesPeerWait, outcome: .success)
            } catch {
                let end = ContinuousClock.now
                statistics.record(start.duration(to: end), workload: rpc ? .rpcPeerWait : .activitiesPeerWait, outcome: protocolTimingOutcome(error)); throw error
            }
        }
        try Task.checkCancellation()
        return ended ? nil : entry.0
    }

    /// Holds future reply envelopes before any response bytes are delivered.
    func holdReplies(_ value: Bool) { holding = value }

    /// Waits for actual serialized command admission; cancellation disposes the channel and releases the barrier.
    func waitForCommands(_ count: Int) async throws {
        if commandCount < count && !ended {
            await withTaskCancellationHandler {
                await withCheckedContinuation { barrier = (count, $0) }
            } onCancel: { Task { await self.close() } }
        }
        guard commandCount >= count else { throw CancellationError() }
    }

    /// Releases all finite replies in reverse order, with one optional strict command mismatch.
    func releaseReplies(mismatch: Bool) throws {
        holding = false
        repliesReleased = true
        let replies = held.reversed(); held.removeAll()
        for var response in replies {
            if mismatch { response["cmd"] = .string("GET_VOICE_SETTINGS") }
            try push(.object(response))
        }
    }

    /// Adds a finite undrained event batch before the sentinel command's reply in protocol order.
    func pushEvents(_ count: Int) throws {
        for _ in 0..<count {
            try push(.object(["cmd": .string("DISPATCH"), "evt": .string("TIMING_EVENT"), "data": .object([:])]))
        }
    }

    /// Parses one wire request and creates a distinct nonce-preserving reply without exposing payloads in reports.
    private func accept(_ payload: Data) throws {
        guard case .object(let fields) = try JSONValue.parse(payload), let command = fields["cmd"], let nonce = fields["nonce"] else { throw ProtocolTimingFailure.integrity }
        commandCount += 1
        var data: JSONValue = .string(String(commandCount))
        if command == .string("SUBSCRIBE") || command == .string("UNSUBSCRIBE") {
            if command == .string("SUBSCRIBE") { subscriptions += 1 } else { unsubscriptions += 1 }
            data = .object(["evt": fields["evt"] ?? .null])
        }
        let response: [String: JSONValue] = ["cmd": command, "nonce": nonce, "evt": .null, "data": data]
        if holding {
            guard held.count < 64 else { throw ProtocolTimingFailure.integrity }
            held.append(response)
        } else { try push(.object(response)) }
        if let barrier, commandCount >= barrier.0 { self.barrier = nil; barrier.1.resume() }
    }

    /// Supplies schema-valid protocol v1 READY; synthetic application identity grants no permissions.
    private func pushReady() throws {
        let ready = try JSONValue.parse(Data("{\"cmd\":\"DISPATCH\",\"evt\":\"READY\",\"nonce\":null,\"data\":{\"v\":1,\"config\":{\"api_endpoint\":\"//discord.com/api\",\"environment\":\"production\"}}}".utf8))
        try push(ready)
    }

    /// Encodes a bounded real IPC frame or Activity tuple and fragments only the native byte stream.
    private func push(_ value: JSONValue) throws {
        let data = rpc ? try RPCFrame(opcode: .frame, payload: value.serialized()).encoded(maximumPayloadBytes: 4096)
            : try JSONValue.array([.number(JSONNumber(rawValue: "1")), value]).serialized()
        let size = rpc ? fragmentSize : data.count
        guard input.count + (data.count + size - 1) / size <= 32_768 else { throw ProtocolTimingFailure.integrity }
        for offset in stride(from: 0, to: data.count, by: size) {
            let entry = (Data(data[offset..<min(data.count, offset + size)]), offset == 0)
            fragments += 1
            if let waiter { self.waiter = nil; waiter.resume(returning: entry) } else { input.append(entry) }
        }
    }

    /// Closes once, discards bounded fixtures and releases reader/barrier ownership independently of the client.
    func close() async {
        guard !ended else { return }
        ended = true; closes += 1; input.removeAll(); held.removeAll(); decoder.reset()
        waiter?.resume(returning: nil); waiter = nil
        barrier?.1.resume(); barrier = nil
    }

    /// Joins actual adapter read completion after public close has cancelled/released the owned reader.
    func joinReads() async {
        if activeReads > 0 { await withCheckedContinuation { readJoiner = $0 } }
    }

    /// Reads exact remaining peer ownership after the public client's awaited close.
    func receipt() -> ProtocolPeerReceipt {
        .init(writes: writes, fragments: fragments, subscriptions: subscriptions, unsubscriptions: unsubscriptions,
            closes: closes, remaining: activeReads + (readJoiner == nil ? 0 : 1) + input.count + held.count + (waiter == nil ? 0 : 1) + (barrier == nil ? 0 : 1) + (ended ? 0 : 1))
    }
}
