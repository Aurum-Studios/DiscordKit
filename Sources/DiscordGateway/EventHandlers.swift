// File: Sources/DiscordGateway/EventHandlers.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordLogging
import DiscordTransport
import Foundation

/// Validated scheduling bounds for one supervised handler run.
public struct GatewayEventHandlerConfiguration: Sendable {
    public let maximumConcurrentHandlers: Int
    public let maximumRetainedEvents: Int
    public let maximumRetainedBytes: Int

    /// Validates finite task and retained event bounds before callbacks can run.
    /// - Parameters:
    ///   - maximumConcurrentHandlers: Positive maximum callback/admission tasks, default four.
    ///   - maximumRetainedEvents: Positive sum of active and locally pending events, default 128.
    ///   - maximumRetainedBytes: Positive sum of active and pending envelope bytes, default 4 MiB.
    /// - Throws: `GatewayEventDeliveryFailure.invalidConfiguration` for nonpositive limits.
    public init(maximumConcurrentHandlers: Int = 4, maximumRetainedEvents: Int = 128,
                maximumRetainedBytes: Int = 4_194_304) throws {
        guard maximumConcurrentHandlers > 0, maximumRetainedEvents > 0, maximumRetainedBytes > 0 else {
            throw GatewayEventDeliveryFailure.invalidConfiguration
        }
        self.maximumConcurrentHandlers = maximumConcurrentHandlers
        self.maximumRetainedEvents = maximumRetainedEvents
        self.maximumRetainedBytes = maximumRetainedBytes
    }
}

/// Nonsecret aggregate callback/admission usage for a shared handler authority.
public struct GatewayHandlerAuthoritySnapshot: Sendable {
    public let activeHandlers: Int
    public let waitingHandlers: Int
}

/// FIFO process-local callback authority shared across independently supervised clients.
///
/// Both active callbacks and queued permit requests are bounded. Cancelling a queued request
/// removes its continuation; a callback that already acquired a permit releases it after returning
/// or throwing. This authority does not execute user code or impose callback deadlines.
public actor GatewayHandlerAuthority {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let maximumActiveHandlers: Int
    private let maximumWaitingHandlers: Int
    private var activeHandlers = 0
    private var waiters: [Waiter] = []

    /// Validates aggregate callback and queued-admission limits without starting tasks.
    /// - Parameters:
    ///   - maximumActiveHandlers: Positive simultaneous callbacks across all adopting dispatchers.
    ///   - maximumWaitingHandlers: Nonnegative FIFO permit-waiter cap; zero rejects excess immediately.
    /// - Throws: `GatewayEventDeliveryFailure.invalidConfiguration` for invalid limits.
    public init(maximumActiveHandlers: Int, maximumWaitingHandlers: Int = 128) throws {
        guard maximumActiveHandlers > 0, maximumWaitingHandlers >= 0 else {
            throw GatewayEventDeliveryFailure.invalidConfiguration
        }
        self.maximumActiveHandlers = maximumActiveHandlers
        self.maximumWaitingHandlers = maximumWaitingHandlers
    }

    /// Reports active callback permits and bounded admission waiters atomically.
    /// - Returns: Counters shared across all dispatchers using this authority.
    public func snapshot() -> GatewayHandlerAuthoritySnapshot {
        GatewayHandlerAuthoritySnapshot(activeHandlers: activeHandlers, waitingHandlers: waiters.count)
    }

    /// Acquires one aggregate callback permit with cancellation-safe FIFO waiting.
    /// - Parameter id: Fresh invocation identity used to remove only its own cancelled waiter.
    /// - Throws: Cancellation or `handlerCapacityExceeded` when the bounded waiting list is full.
    fileprivate func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        if activeHandlers < maximumActiveHandlers {
            activeHandlers += 1
            return
        }
        guard waiters.count < maximumWaitingHandlers else { throw GatewayEventDeliveryFailure.handlerCapacityExceeded }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(id: id, continuation: continuation))
        }
    }

    /// Releases one owned permit, transferring it to the oldest live admission waiter if present.
    /// The dispatcher calls this exactly once after every successful acquire, even on user failure.
    fileprivate func release() {
        if !waiters.isEmpty { waiters.removeFirst().continuation.resume() }
        else { activeHandlers -= 1 }
    }

    /// Removes a cancelled admission waiter without recalling a callback's already granted permit.
    /// - Parameter id: Invocation identity; stale or already granted identifiers are harmless.
    fileprivate func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// Structured bounded scheduling with optional serialization per complete shard identity.
///
/// By default, different shards may execute concurrently while callbacks for one complete shard
/// identity finish in subscription order. Explicitly disabling serialization admits independent
/// same-shard callbacks concurrently under the same task, retention and aggregate authority limits.
/// This opt-in provides no callback completion order; ordinary event consumers should retain ordering.
/// A finite pending queue permits other shards to progress while one callback suspends; once
/// retained bounds are reached, input pauses and the subscription's explicit overflow policy applies.
/// Callback errors propagate unchanged and cancel sibling work. Callbacks must cooperate with
/// cancellation; a callback that never returns necessarily prevents structured cleanup from finishing.
/// No callbacks, subscriptions, or tasks are created by construction.
public struct GatewayEventHandlerDispatcher: Sendable {
    private enum Completion: Sendable {
        case input(GatewayEvent?)
        case handled(ShardIdentity, Int)
    }

    private let configuration: GatewayEventHandlerConfiguration
    private let authority: GatewayHandlerAuthority?
    /// Explicit observer; nil bypasses all timing reads and invocation-local timing scope.
    private let timing: OperationTiming?
    /// True preserves subscription order within each complete shard identity.
    private let serializesPerShard: Bool

    /// Preserves complete-shard callback ordering with explicit scheduling bounds and shared admission.
    /// - Parameters:
    ///   - configuration: Validated local task, retained count and retained byte limits.
    ///   - authority: Optional shared process callback limit.
    ///   - timing: Optional prompt content-free observer; nil performs no timing work.
    public init(configuration: GatewayEventHandlerConfiguration, authority: GatewayHandlerAuthority? = nil,
                timing: OperationTiming? = nil) {
        self.init(configuration: configuration, authority: authority, serializesPerShard: true, timing: timing)
    }

    /// Stores explicit scheduling bounds and an optional shared aggregate callback authority.
    /// - Parameters:
    ///   - configuration: Validated local task, retained count, and retained byte limits.
    ///   - authority: Optional shared process limit; nil applies only the local concurrency cap.
    ///   - serializesPerShard: True by default; false permits independent same-shard callbacks to overlap
    ///     without changing task, retained-event, retained-byte or shared authority limits.
    ///   - timing: Optional synchronous observer; enabled callbacks retain only numeric clock offsets.
    public init(configuration: GatewayEventHandlerConfiguration, authority: GatewayHandlerAuthority? = nil,
                serializesPerShard: Bool, timing: OperationTiming? = nil) {
        self.configuration = configuration
        self.authority = authority
        self.serializesPerShard = serializesPerShard
        self.timing = timing
    }

    /// Consumes one owned subscription until completion, cancellation, admission failure, or user error.
    ///
    /// The operation owns and awaits every input/callback child task, then explicitly cancels its
    /// subscription on every exit. Reentrant callbacks may publish or use services; input processing
    /// and hub publication never await a callback. An event larger than retained byte capacity fails
    /// closed rather than running a callback beyond the configured bound.
    /// - Parameters:
    ///   - subscription: Dedicated single-consumer sequence; do not iterate it from another task.
    ///   - handler: Sendable async callback; no actor/executor affinity is assumed. Call an actor-isolated
    ///     service explicitly when needed. A handler may throw its own observable application error.
    /// - Throws: Cancellation, subscription overflow/iteration errors, bounded handler admission failure,
    ///   or the original callback error. After an error, concurrently completed side effects are not undone.
    public func run(subscription: GatewayEventSubscription,
                    handler: @escaping @Sendable (GatewayEvent) async throws -> Void) async throws {
        let runStarted = timing?.instant()
        DiscordLog.makeLogger("gateway.handlers").info("Gateway handler dispatcher started", metadata: ["dk.event": "gateway.handlers.started"])
        do {
            try Task.checkCancellation()
            try await withThrowingTaskGroup(of: Completion.self) { group in
                var pending: [GatewayEvent] = []
                // Allocate offsets only for explicitly enabled observation, under the same event bound.
                var pendingTiming: [Duration]? = timing.map { _ in [] }
                var active: [ShardIdentity: Int] = [:]
                var activeCount = 0
                var retainedEvents = 0
                var retainedBytes = 0
                var inputScheduled = false
                var inputFinished = false
                defer { group.cancelAll() }
                while true {
                    try Task.checkCancellation()
                    while activeCount < configuration.maximumConcurrentHandlers,
                          let index = pending.firstIndex(where: { !serializesPerShard || active[$0.shard] == nil }) {
                        let event = pending.remove(at: index)
                        if let timing, let enqueuedAt = pendingTiming?.remove(at: index) {
                            timing.record(.gatewayLocalQueue, since: enqueuedAt)
                        }
                        active[event.shard, default: 0] += 1
                        activeCount += 1
                        group.addTask {
                            try await invoke(event, handler: handler)
                            return .handled(event.shard, event.retainedByteCount)
                        }
                    }
                    if !inputFinished, !inputScheduled, retainedEvents < configuration.maximumRetainedEvents,
                       retainedBytes < configuration.maximumRetainedBytes {
                        inputScheduled = true
                        group.addTask {
                            var iterator = subscription.makeAsyncIterator()
                            return .input(try await iterator.next())
                        }
                    }
                    guard let completion = try await group.next() else { break }
                    switch completion {
                    case .input(let event):
                        inputScheduled = false
                        guard let event else { inputFinished = true; continue }
                        guard event.retainedByteCount <= configuration.maximumRetainedBytes - retainedBytes else {
                            DiscordLog.makeLogger("gateway.handlers").error("Gateway handler retained capacity exhausted", metadata: ["dk.event": "gateway.handlers.overflow", "dk.retained": .stringConvertible(retainedEvents)])
                            throw GatewayEventDeliveryFailure.handlerCapacityExceeded
                        }
                        retainedEvents += 1
                        retainedBytes += event.retainedByteCount
                        pending.append(event)
                        if let timing { pendingTiming?.append(timing.instant()) }
                    case .handled(let shard, let bytes):
                        let remaining = active[shard, default: 1] - 1
                        if remaining == 0 { active.removeValue(forKey: shard) }
                        else { active[shard] = remaining }
                        activeCount -= 1
                        retainedEvents -= 1
                        retainedBytes -= bytes
                    }
                }
            }
        } catch {
            await subscription.cancel()
            if let timing, let runStarted {
                timing.record(.gatewayRunJoined, since: runStarted, outcome: OperationTiming.outcome(for: error))
            }
            if error is CancellationError {
                DiscordLog.makeLogger("gateway.handlers").debug("Gateway handler dispatcher cancelled", metadata: ["dk.event": "gateway.handlers.cancelled"])
            } else {
                DiscordLog.makeLogger("gateway.handlers").error("Gateway handler dispatcher failed", metadata: ["dk.event": "gateway.handlers.failed"])
            }
            throw error
        }
        await subscription.cancel()
        if let timing, let runStarted { timing.record(.gatewayRunJoined, since: runStarted) }
        DiscordLog.makeLogger("gateway.handlers").info("Gateway handler dispatcher stopped", metadata: ["dk.event": "gateway.handlers.stopped"])
    }

    /// Executes one callback under optional aggregate admission, releasing ownership on every path.
    /// - Parameters:
    ///   - event: Already counted local event retained until this method completes.
    ///   - handler: Caller-owned callback, invoked once after cancellation/admission checks.
    /// - Throws: Original user error, cancellation, or aggregate waiting-capacity failure.
    private func invoke(_ event: GatewayEvent,
                        handler: @Sendable (GatewayEvent) async throws -> Void) async throws {
        DiscordLog.makeLogger("gateway.handlers").trace("Gateway event handler requesting admission", metadata: ["dk.event": "gateway.handler.admission", "dk.shared_authority": .stringConvertible(authority != nil)])
        if let authority {
            let id = UUID()
            let admissionStarted = timing?.instant()
            do {
                try await withTaskCancellationHandler {
                    try await authority.acquire(id)
                } onCancel: {
                    // A cancellation callback cannot await; the short actor hop resolves its parked
                    // continuation. Successful admission remains owned here and is always released below.
                    Task { await authority.cancel(id) }
                }
            } catch {
                if let timing, let admissionStarted {
                    timing.record(.gatewaySharedAdmission, since: admissionStarted, outcome: OperationTiming.outcome(for: error))
                }
                throw error
            }
            if let timing, let admissionStarted { timing.record(.gatewaySharedAdmission, since: admissionStarted) }
            do {
                try Task.checkCancellation()
                DiscordLog.makeLogger("gateway.handlers").trace("Gateway event handler invoked", metadata: ["dk.event": "gateway.handler.invoked"])
                try await admittedHandler(event, handler: handler)
            } catch {
                await authority.release()
                DiscordLog.makeLogger("gateway.handlers").trace("Gateway event handler failed after releasing admission", metadata: ["dk.event": "gateway.handler.failed"])
                throw error
            }
            await authority.release()
            DiscordLog.makeLogger("gateway.handlers").trace("Gateway event handler completed after releasing admission", metadata: ["dk.event": "gateway.handler.completed"])
        } else {
            try Task.checkCancellation()
            DiscordLog.makeLogger("gateway.handlers").trace("Gateway event handler invoked", metadata: ["dk.event": "gateway.handler.invoked"])
            try await admittedHandler(event, handler: handler)
            DiscordLog.makeLogger("gateway.handlers").trace("Gateway event handler completed", metadata: ["dk.event": "gateway.handler.completed"])
        }
    }

    /// Installs the numeric admission origin only for enabled callbacks; disabled callbacks run directly.
    /// - Parameters:
    ///   - event: Existing retained event, without any change to its receipt provenance.
    ///   - handler: Exactly-once callback after local and shared admission.
    /// - Throws: Original callback error or cancellation, unchanged.
    private func admittedHandler(_ event: GatewayEvent,
                                 handler: @Sendable (GatewayEvent) async throws -> Void) async throws {
        if let timing {
            try await OperationTimingScope.$gatewayAdmission.withValue(timing.instant()) {
                try await handler(event)
            }
        } else { try await handler(event) }
    }
}
