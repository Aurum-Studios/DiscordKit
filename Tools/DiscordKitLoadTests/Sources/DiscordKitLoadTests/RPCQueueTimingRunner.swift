// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/RPCQueueTimingRunner.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordCore
import DiscordRPC
import DiscordTransport
import Foundation

/// Controlled sent-reply cohorts with an independently varied, unsent writer backlog.
struct RPCQueueTimingRunner: Sendable {
    private let onCohortSubmitted: (@Sendable () -> Void)?

    /// Installs an optional test-only submission barrier; production captures leave it absent.
    /// - Parameter onCohortSubmitted: Synchronous notification after reply submission, before result joining.
    init(onCohortSubmitted: (@Sendable () -> Void)? = nil) {
        self.onCohortSubmitted = onCohortSubmitted
    }

    /// Completes fixed cohorts of 64 public requests while one actual send holds the queued depth constant.
    /// - Parameters:
    ///   - requests: Independent fixture/cohort count in 1...100,000.
    ///   - concurrency: Simultaneous fixtures in 1...64, no greater than requests.
    ///   - queueDepth: Unsent support requests behind the parked writer, in 0...4,096.
    ///   - delay: Injected receive delay per complete reply, zero through one second.
    /// - Returns: Whole-cohort and whole-call distributions with independently checked cleanup receipts.
    /// - Throws: Invalid dimensions, cancellation or protocol/ownership integrity failure after joined cleanup.
    func run(requests: Int, concurrency: Int, queueDepth: Int, delay: Duration) async throws -> RPCActivitiesTimingReport {
        guard (1...100_000).contains(requests), (1...64).contains(concurrency), concurrency <= requests,
              (0...4_096).contains(queueDepth), delay >= .zero, delay <= .seconds(1) else {
            throw LoadFailure.invalidArguments
        }
        let statistics = try RunStatistics(workloads: [.rpcQueuedReplyCohortV1, .rpcRequest, .rpcHandshake, .rpcClose])
        let origin = ContinuousClock.now
        var completed = 0, writes = 0, fragments = 0, closed = 0, peak = 0
        var cohortNanoseconds: UInt64 = 0
        for wave in stride(from: 0, to: requests, by: concurrency) {
            if Task.isCancelled { break }
            try await withThrowingTaskGroup(of: RPCQueueReceipt.self) { group in
                for _ in wave..<min(requests, wave + concurrency) {
                    group.addTask { try await runRPCQueueFixture(depth: queueDepth, delay: delay, statistics: statistics,
                        onCohortSubmitted: onCohortSubmitted) }
                }
                for try await receipt in group {
                    completed += 1; writes += receipt.writes; fragments += receipt.fragments
                    closed += receipt.closes; peak = max(peak, receipt.peak)
                    let sum = cohortNanoseconds.addingReportingOverflow(receipt.nanoseconds)
                    guard !sum.overflow else { throw RPCQueueFailure.integrity }
                    cohortNanoseconds = sum.partialValue
                }
            }
        }
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        outcomes[.success] = UInt64(completed)
        return RPCActivitiesTimingReport(scenario: "rpc.queuedRepliesV1", clockDomain: statistics.clockDomain,
            counts: .init(offered: UInt64(completed), admitted: UInt64(completed), completed: UInt64(completed),
                          outcomes: outcomes, deadlineMisses: 0), metrics: statistics.metrics(),
            durationNanoseconds: try BenchmarkTime.nanoseconds(duration: origin.duration(to: .now)),
            cleanup: .init(completed: true, remainingOwners: 0), peakPendingRequests: peak,
            retainedEvents: 0, acquiredSubscriptions: 0, upstreamSubscriptions: 0, upstreamUnsubscriptions: 0,
            protocolWrites: writes, inputFragments: fragments, closedPeers: closed,
            notes: [
                "Each primary observation is one fixed cohort of 64 already-sent public RPC requests, from submission of pre-serialized reverse replies through all 64 public results. Counts count cohorts, never individual calls or inferred call percentiles.",
                "The independently controlled unsent queue depth is \(queueDepth). A 65th actual send remains parked throughout the target. Actual public pending counts prove every support admission before the timer starts; no setup polling or logging hook executes in the target.",
                "rpc.request separately records all 64 original caller-to-result durations, including prefill and queue setup. Exact cohort nanoseconds/count supplement the 100-microsecond histogram. Recording, resource snapshots, cancellation, close and integrity checks follow the target stop.",
                "All queued support callers are cancelled and joined before releasing the parked writer; exact write counts prove their bytes never send. The parked support caller is cancelled independently. Awaited close checks client bytes/counts and actual peer reader/writer ownership.",
                "The injected complete-frame RPCConnection isolates production RPCClient correlation. It does not run RPCIPCConnection, native IPC, browser, desktop or Discord. Input fragments count complete delivered frames. Delay is an explicit per-reply receive control included in the cohort endpoint."
            ], queuedReplyCohortNanoseconds: cohortNanoseconds, queuedReplyCohorts: UInt64(completed))
    }
}

/// A finite fixture discrepancy is distinct from the expected cancellation of support requests.
private enum RPCQueueFailure: Error { case integrity }

/// Bounded scalar receipt from one fully joined fixture.
private struct RPCQueueReceipt: Sendable {
    let writes: Int
    let fragments: Int
    let closes: Int
    let peak: Int
    let nanoseconds: UInt64
}

/// Complete public-call outcome retained only until its cohort stops and statistics can be recorded.
private struct RPCQueueCall: Sendable {
    let value: JSONValue?
    let ordinal: Int
    let duration: Duration

    /// Validates the distinct fixture response only after the complete cohort target has stopped.
    var valid: Bool { value == .string(String(ordinal)) }
}

/// Measures the original public request boundary without histogram contention in the reply-cohort target.
/// - Parameters:
///   - client: One exclusively owned public client.
///   - ordinal: Exact synthetic response identity for this caller.
///   - context: Finite fixture cancellation/deadline domain.
/// - Returns: Raw response and caller-to-result duration, including setup residence; validation follows the target.
private func rpcQueueCall(_ client: RPCClient<ContinuousClock>, ordinal: Int,
                          context: TransportContext<ContinuousClock>) async -> RPCQueueCall {
    let start = ContinuousClock.now
    do {
        let value = try await client.request(.getGuilds(), context: context)
        let end = ContinuousClock.now
        return .init(value: value, ordinal: ordinal, duration: start.duration(to: end))
    } catch {
        return .init(value: nil, ordinal: ordinal, duration: start.duration(to: .now))
    }
}

/// Owns prefill, a constant blocked backlog, the reply cohort and independently verified cancellation/close.
/// - Parameters:
///   - depth: Exact support backlog independently varied while the reply population remains 64.
///   - delay: Explicit injected reply delay, absent from fixture admission and handshake.
///   - statistics: Bounded shared collector; target timestamps precede recording.
///   - onCohortSubmitted: Optional deterministic test notification, absent during captures.
/// - Returns: Numeric receipts only after every task and transport owner is joined.
/// - Throws: Invalid fixture state, cancellation or deadline after complete cleanup.
private func runRPCQueueFixture(depth: Int, delay: Duration, statistics: RunStatistics,
    onCohortSubmitted: (@Sendable () -> Void)?) async throws -> RPCQueueReceipt {
    let peer = RPCQueuePeer(delay: delay)
    let client = try RPCClient(applicationID: .init(rawValue: 1), clock: ContinuousClock(),
        connector: RPCQueueConnector(peer: peer), maximumPendingRequests: depth + 65,
        maximumPendingBytes: 8_388_608, maximumPayloadBytes: 4_096)
    let context = TransportContext(clock: ContinuousClock(), deadline: ContinuousClock.now.advanced(by: .seconds(120)))
    var calls: [Task<RPCQueueCall, Never>] = []
    var support: [Task<JSONValue, any Error>] = []
    let cancellation = RPCQueueCancellation(client: client)
    let result: Result<RPCQueueReceipt, any Error>
    do {
        result = .success(try await withTaskCancellationHandler {
            do {
                let handshake = ContinuousClock.now
                try await client.connect(context: context)
                statistics.record(handshake.duration(to: .now), workload: .rpcHandshake, outcome: .success)
                for ordinal in 1...64 {
                    calls.append(Task { await rpcQueueCall(client, ordinal: ordinal, context: context) })
                    try await context.run { try await peer.waitForCommands(ordinal) }
                }
                await peer.holdNextWrite()
                support.append(Task { try await client.request(.getVoiceSettings(), context: context) })
                try await context.run { try await peer.waitForCommands(65) }
                for _ in 0..<depth { support.append(Task { try await client.request(.getGuilds(), context: context) }) }
                // With 64 observed sent correlations and the sole writer parked on command65,
                // these public pending counts establish exact unsent backlog without a runtime hook.
                while await client.resourceCounts().pending < depth + 65 {
                    try context.check(); await Task.yield()
                }
                let before = await client.resourceCounts()
                guard before.pending == depth + 65 else { throw RPCQueueFailure.integrity }
                try await peer.prepareReplies()
                var results: [RPCQueueCall] = []
                results.reserveCapacity(64)
                try Task.checkCancellation()
                let start = ContinuousClock.now
                try await peer.releaseReplies()
                onCohortSubmitted?()
                for call in calls { results.append(await call.value) }
                let end = ContinuousClock.now
                try Task.checkCancellation()
                let duration = start.duration(to: end)
                let nanoseconds = try BenchmarkTime.nanoseconds(duration: duration)
                statistics.record(duration, workload: .rpcQueuedReplyCohortV1,
                                  outcome: results.allSatisfy(\.valid) ? .success : .failure)
                for result in results {
                    statistics.record(result.duration, workload: .rpcRequest, outcome: result.valid ? .success : .failure)
                }
                guard results.count == 64, results.allSatisfy(\.valid),
                      await client.resourceCounts().pending == depth + 1 else { throw RPCQueueFailure.integrity }
                for task in support { task.cancel() }
                for task in support {
                    do { _ = try await task.value; throw RPCQueueFailure.integrity }
                    catch is CancellationError {}
                }
                let cancelled = await client.resourceCounts()
                guard cancelled.pending == 0, cancelled.pendingBytes == 0 else { throw RPCQueueFailure.integrity }
                await peer.releaseWrite()
                let close = ContinuousClock.now
                await client.close()
                statistics.record(close.duration(to: .now), workload: .rpcClose, outcome: .success)
                let counts = await client.resourceCounts(), receipt = await peer.receipt()
                guard counts.pending == 0, counts.pendingBytes == 0, counts.events == 0, counts.eventBytes == 0,
                      receipt.writes == 66, receipt.closes == 1, receipt.remaining == 0 else { throw RPCQueueFailure.integrity }
                return .init(writes: receipt.writes, fragments: receipt.fragments, closes: receipt.closes,
                             peak: before.pending, nanoseconds: nanoseconds)
            } catch {
                for task in calls { task.cancel() }; for task in support { task.cancel() }
                await client.close(); await peer.close()
                for task in calls { _ = await task.value }; for task in support { _ = await task.result }
                let counts = await client.resourceCounts(), receipt = await peer.receipt()
                guard counts.pending == 0, counts.pendingBytes == 0, receipt.remaining == 0 else { throw RPCQueueFailure.integrity }
                throw error
            }
        } onCancel: { cancellation.requestClose() })
    } catch { result = .failure(error) }
    // The handler has been removed before this join, so no later cancellation can
    // introduce another unstructured close wrapper after the exact owned task is joined.
    await cancellation.join()
    return try result.get()
}

/// Owns and joins the one asynchronous close initiated from a synchronous cancellation callback.
/// Every mutable field is protected by the lock; the client itself remains actor isolated.
private final class RPCQueueCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let client: RPCClient<ContinuousClock>
    private var closeTask: Task<Void, Never>?

    /// Retains the exact fixture client without starting another task or I/O owner.
    /// - Parameter client: Public actor whose close releases the held writer and delayed reader.
    init(client: RPCClient<ContinuousClock>) { self.client = client }

    /// Installs at most one close task synchronously, including cancellation before handler admission.
    func requestClose() {
        lock.withLock {
            guard closeTask == nil else { return }
            closeTask = Task { await client.close() }
        }
    }

    /// Awaits the exact callback-created task after the handler has been removed.
    /// No callback can introduce another task after the caller reaches this method.
    func join() async {
        let task = lock.withLock { closeTask }
        await task?.value
    }
}

/// Transfers one injected complete-frame peer without native adapter or discovery work.
private struct RPCQueueConnector: RPCConnector {
    let peer: RPCQueuePeer

    /// Returns the fixture's exclusive connection under the original startup context.
    /// - Parameters:
    ///   - applicationID: Synthetic registered identifier, independent of authorization.
    ///   - context: Caller-owned cancellation/deadline checked before transfer.
    /// - Returns: The one exclusively owned injected peer.
    /// - Throws: Original cancellation or deadline failure.
    func connect<C: Clock>(applicationID: ApplicationID, context: TransportContext<C>) async throws -> any RPCConnection where C.Duration == Duration {
        try context.check(); return peer
    }
}

/// Bounded complete-frame peer with independent observed-send and actual held-writer ownership.
private actor RPCQueuePeer: RPCConnection {
    private let delay: Duration
    private var commands: [RPCFrame] = []
    private var replies: [RPCFrame] = []
    private var input: [RPCFrame] = []
    private var reader: CheckedContinuation<RPCFrame?, Never>?
    private var commandWaiter: (Int, CheckedContinuation<Void, Never>)?
    private var heldWrite: CheckedContinuation<Void, Never>?
    private var holdWrite = false
    private var closed = false
    private var activeReads = 0
    private var activeWrites = 0
    private var writes = 0
    private var fragments = 0
    private var closes = 0

    /// Stores the explicit reply delay without starting I/O, readers or tasks.
    /// - Parameter delay: Validated finite injected per-reply receive delay.
    init(delay: Duration) { self.delay = delay }

    /// Publishes one READY frame and counts the explicit handshake write.
    /// - Parameters:
    ///   - applicationID: Synthetic identifier; this peer grants no host authority.
    ///   - context: Original checked startup context.
    /// - Throws: Cancellation, deadline or bounded fixture serialization failure.
    func handshake<C: Clock>(applicationID: ApplicationID, context: TransportContext<C>) async throws where C.Duration == Duration {
        try context.check(); writes += 1
        push(.init(opcode: .frame, payload: try JSONValue.object(["cmd": .string("DISPATCH"), "evt": .string("READY"),
            "data": .object(["v": .number(JSONNumber(rawValue: "1"))])]).serialized()))
    }

    /// Records a bounded command before parking the sole writer on the optional 65th send.
    /// - Parameters:
    ///   - frame: Actual production-client frame; only 65 sends are permitted before cleanup.
    ///   - context: Original ordered-writer context checked before admission.
    /// - Throws: Cancellation, deadline or an unexpected extra/closed fixture write.
    func send<C: Clock>(_ frame: RPCFrame, context: TransportContext<C>) async throws where C.Duration == Duration {
        try context.check()
        guard !closed, commands.count < 65, frame.opcode == .frame else { throw RPCQueueFailure.integrity }
        activeWrites += 1
        defer { activeWrites -= 1 }
        commands.append(frame); writes += 1
        if let waiter = commandWaiter, commands.count >= waiter.0 { commandWaiter = nil; waiter.1.resume() }
        if holdWrite { await withCheckedContinuation { heldWrite = $0 } }
    }

    /// Returns complete frames, including explicit injected delay only for command replies.
    /// - Parameter context: Original reader cancellation/deadline domain.
    /// - Returns: One complete frame, or nil after terminal close.
    /// - Throws: Original cancellation/deadline or injected-delay cancellation.
    func receive<C: Clock>(context: TransportContext<C>) async throws -> RPCFrame? where C.Duration == Duration {
        try context.check(); activeReads += 1
        defer { activeReads -= 1 }
        let frame: RPCFrame?
        if !input.isEmpty { frame = input.removeFirst() }
        else if closed { return nil }
        else {
            frame = await withTaskCancellationHandler {
                await withCheckedContinuation { reader = $0 }
            } onCancel: { Task { await self.close() } }
        }
        if let frame {
            fragments += 1
            if fragments > 1, delay > .zero { try await Task.sleep(for: delay) }
            try context.check()
            return closed ? nil : frame
        }
        return nil
    }

    /// Waits for an actual completed-frame send admission, independently from public pending snapshots.
    /// - Parameter count: Finite command threshold from one through 65.
    /// - Throws: Cancellation or peer closure before the required sends were observed.
    func waitForCommands(_ count: Int) async throws {
        if commands.count < count, !closed {
            await withTaskCancellationHandler {
                await withCheckedContinuation { commandWaiter = (count, $0) }
            } onCancel: { Task { await self.close() } }
        }
        guard commands.count >= count, !closed else { throw CancellationError() }
    }

    /// Parks the next actual send after its command observation barrier has been released.
    func holdNextWrite() { holdWrite = true }

    /// Releases the one active write while preserving terminal and no-replay semantics.
    func releaseWrite() { holdWrite = false; heldWrite?.resume(); heldWrite = nil }

    /// Serializes every reverse reply before the target timer, holding total reply bytes and count fixed.
    /// - Throws: Unexpected command population, malformed correlation or serialization failure.
    func prepareReplies() throws {
        guard commands.count == 65, heldWrite != nil else { throw RPCQueueFailure.integrity }
        for ordinal in (1...64).reversed() {
            guard case .object(let fields) = try JSONValue.parse(commands[ordinal - 1].payload),
                  fields["cmd"] == .string("GET_GUILDS"), let nonce = fields["nonce"] else { throw RPCQueueFailure.integrity }
            replies.append(.init(opcode: .frame, payload: try JSONValue.object([
                "cmd": .string("GET_GUILDS"), "nonce": nonce, "evt": .null,
                "data": .string(String(ordinal))]).serialized()))
        }
    }

    /// Submits the already serialized finite cohort without sleeps, new tasks or diagnostic recording.
    /// - Throws: Missing cohort or loss of the actual held writer before submission.
    func releaseReplies() throws {
        guard replies.count == 64, heldWrite != nil else { throw RPCQueueFailure.integrity }
        for frame in replies { push(frame) }
        replies.removeAll()
    }

    /// Transfers one finite prepared frame to the only reader or bounded input suffix.
    /// - Parameter frame: Complete local fixture frame; input never exceeds the 64-reply cohort.
    private func push(_ frame: RPCFrame) {
        if let reader { self.reader = nil; reader.resume(returning: frame) }
        else { input.append(frame) }
    }

    /// Clears retained fixture bytes and releases both actual I/O continuations exactly once.
    func close() async {
        guard !closed else { return }; closed = true; closes += 1
        reader?.resume(returning: nil); reader = nil
        commandWaiter?.1.resume(); commandWaiter = nil
        releaseWrite(); input.removeAll(); replies.removeAll(); commands.removeAll()
    }

    /// Reports actual I/O ownership after the public client has joined its reader and writer tasks.
    /// - Returns: Protocol write/delivery/close totals and remaining fixture owners or bytes containers.
    func receipt() -> (writes: Int, fragments: Int, closes: Int, remaining: Int) {
        (writes, fragments, closes, activeReads + activeWrites + input.count + commands.count + replies.count
            + (reader == nil ? 0 : 1) + (heldWrite == nil ? 0 : 1) + (commandWaiter == nil ? 0 : 1))
    }
}
