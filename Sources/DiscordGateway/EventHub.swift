// File: Sources/DiscordGateway/EventHub.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordLogging
import Foundation

/// Closed subscription/admission failures that never contain event payloads or credentials.
public enum GatewayEventDeliveryFailure: Error, Equatable, Sendable {
    case invalidConfiguration
    case subscriptionCapacityExceeded
    case resynchronizationRequired
    case concurrentIteration
    case handlerCapacityExceeded
    case finished
}

/// Explicit choices for a slow subscriber; the default reports lost continuity.
public enum GatewayEventOverflowPolicy: Sendable {
    case resynchronize
    case dropNewest
    case dropOldest
}

/// Validated queue and metadata limits for a hub or its shared process authority.
public struct GatewayEventHubConfiguration: Sendable {
    public let maximumSubscriptions: Int
    public let maximumBufferedEvents: Int
    public let maximumBufferedBytes: Int
    public let maximumEventsPerSubscription: Int
    public let maximumBytesPerSubscription: Int

    /// Validates limits without launching tasks or retaining events.
    /// - Parameters:
    ///   - maximumSubscriptions: Positive subscription metadata cap, including unobserved terminal failures; default 64.
    ///   - maximumBufferedEvents: Positive sum of queued event copies across subscribers; default 4,096.
    ///   - maximumBufferedBytes: Positive sum of retained envelope bytes across subscribers; default 16 MiB.
    ///   - maximumEventsPerSubscription: Positive default individual queue count; default 128.
    ///   - maximumBytesPerSubscription: Positive default individual queue byte limit; default 1 MiB.
    /// - Throws: `GatewayEventDeliveryFailure.invalidConfiguration` for nonpositive limits.
    public init(maximumSubscriptions: Int = 64, maximumBufferedEvents: Int = 4_096,
                maximumBufferedBytes: Int = 16_777_216, maximumEventsPerSubscription: Int = 128,
                maximumBytesPerSubscription: Int = 1_048_576) throws {
        guard maximumSubscriptions > 0, maximumBufferedEvents > 0, maximumBufferedBytes > 0,
              maximumEventsPerSubscription > 0, maximumBytesPerSubscription > 0 else {
            throw GatewayEventDeliveryFailure.invalidConfiguration
        }
        self.maximumSubscriptions = maximumSubscriptions
        self.maximumBufferedEvents = maximumBufferedEvents
        self.maximumBufferedBytes = maximumBufferedBytes
        self.maximumEventsPerSubscription = maximumEventsPerSubscription
        self.maximumBytesPerSubscription = maximumBytesPerSubscription
    }
}

/// Bounded nonsecret queue accounting; event copies are counted once per subscriber.
public struct GatewayEventHubSnapshot: Sendable {
    public let subscriptions: Int
    public let bufferedEvents: Int
    public let bufferedBytes: Int
    public let waitingConsumers: Int
}

/// One publication's admission outcome, with no consumer callbacks executed by publication.
public struct GatewayEventPublication: Sendable {
    public let delivered: Int
    public let dropped: Int
    public let terminated: Int
}

/// Independent single-consumer broadcast queue with explicit cancellation ownership.
///
/// Create a separate subscription for each consumer. Multiple iterators share this one queue;
/// overlapping `next` calls fail rather than creating an unbounded waiter list. Call `cancel`
/// when abandoning a subscription without a suspended iteration. An unobserved overflow retains
/// one bounded metadata slot until iteration observes the failure, explicit cancellation, or hub finish.
public struct GatewayEventSubscription: AsyncSequence, Sendable {
    public typealias Element = GatewayEvent
    fileprivate let authority: GatewayEventHubAuthority
    fileprivate let id: UUID

    /// An iterator into exactly one independently bounded subscription.
    public struct AsyncIterator: AsyncIteratorProtocol, Sendable {
        fileprivate let subscription: GatewayEventSubscription

        /// Waits for one event, preserving publication order within this subscription.
        /// - Returns: The oldest queued event, or nil after explicit cancellation or hub finish.
        /// - Throws: Cancellation, an overflow's `resynchronizationRequired`, or `concurrentIteration`.
        ///   Cancelling a suspended call releases the entire subscription and all retained events.
        public mutating func next() async throws -> GatewayEvent? {
            let authority = subscription.authority
            let id = subscription.id
            do {
                let event = try await withTaskCancellationHandler {
                    try await authority.next(id)
                } onCancel: {
                    // The cancellation callback cannot await. This short actor hop owns no user work;
                    // the suspended next resumes only after the authority has released its resources.
                    Task { await authority.cancel(id, cancelled: true) }
                }
                try Task.checkCancellation()
                return event
            } catch {
                if Task.isCancelled { await authority.cancel(id, cancelled: true) }
                throw error
            }
        }
    }

    /// Creates an iterator without allocating another queue or starting a task.
    /// - Returns: An iterator sharing this subscription's single-consumer state.
    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(subscription: self) }

    /// Discards queued events and wakes a suspended consumer with normal end-of-sequence.
    /// Repeated calls are harmless and do not affect any other subscription.
    public func cancel() async { await authority.cancel(id, cancelled: false) }
}

/// Process-local aggregate authority shareable by hubs for independent bot identities.
///
/// All accounting and queue mutations are atomic actor operations with no suspension, user
/// callbacks, payload decoding, or network work. First-created subscribers have admission priority
/// for shared capacity; lossy eviction can discard only the affected subscriber's own events.
/// This is an in-process budget, not a distributed broadcast or persistence contract.
public actor GatewayEventHubAuthority {
    private struct QueuedEvent: Sendable {
        let event: GatewayEvent
        let interval: DiscordInterval?
        var retainedByteCount: Int {
            /// Returns the existing raw-envelope accounting bound for this subscriber copy.
            get { event.retainedByteCount }
        }
    }

    /// Lazily allocated circular storage whose consumed slots immediately release envelope payloads.
    /// Capacity never exceeds the queue's effective event limit; empty queues release their allocation.
    private struct EventQueue {
        private var storage: [QueuedEvent?] = []
        private var head = 0
        private(set) var count = 0
        let maximumCount: Int

        /// Appends one already admitted event in amortized constant time, copying only during bounded growth.
        /// - Parameter event: Envelope copy whose accounting was admitted against every applicable limit.
        /// - Precondition: Fewer than `maximumCount` events are retained before this call.
        mutating func append(_ event: QueuedEvent) {
            precondition(count < maximumCount)
            if count == storage.count {
                let capacity = storage.isEmpty ? 1 : storage.count + min(storage.count, maximumCount - storage.count)
                var expanded = [QueuedEvent?](repeating: nil, count: capacity)
                for offset in 0..<count {
                    let index = offset < storage.count - head ? head + offset : offset - (storage.count - head)
                    expanded[offset] = storage[index]
                }
                storage = expanded
                head = 0
            }
            let tail = count < storage.count - head ? head + count : count - (storage.count - head)
            storage[tail] = event
            count += 1
        }

        /// Removes the oldest envelope without shifting live entries and clears its retained payload reference.
        /// Slot cleanup when the queue empties is amortized over the preceding admitted events.
        /// - Returns: The oldest queued copy, or nil when empty; draining also releases slot metadata.
        mutating func popFirst() -> QueuedEvent? {
            guard count > 0 else { return nil }
            let event = storage[head]
            storage[head] = nil
            count -= 1
            if count == 0 {
                storage = []
                head = 0
            } else {
                head = head == storage.count - 1 ? 0 : head + 1
            }
            return event
        }
    }

    /// Admission order and exact retained usage for one hub, including unobserved terminal metadata.
    private final class HubState {
        var subscriptions: [UUID] = []
        var bufferedEvents = 0
        var bufferedBytes = 0
        var waitingConsumers = 0
    }

    /// Actor-owned mutable queue state; reference ownership avoids copying circular storage on lookup.
    private final class Subscriber {
        let hub: UUID
        let hubState: HubState
        let configuration: GatewayEventHubConfiguration
        let maximumEvents: Int
        let maximumBytes: Int
        let policy: GatewayEventOverflowPolicy
        var events: EventQueue
        var bytes = 0
        var waiter: CheckedContinuation<GatewayEvent?, any Error>?
        var failed = false

        /// Creates empty actor-confined queue storage without allocating event slots.
        /// - Parameters:
        ///   - hub: Owning hub identity used only for metadata removal.
        ///   - hubState: Shared exact counters and admission order for that hub.
        ///   - configuration: Validated hub event and byte limits.
        ///   - maximumEvents: Positive individual event limit selected at admission.
        ///   - maximumBytes: Positive individual envelope byte limit selected at admission.
        ///   - policy: Overflow behavior for this independent queue.
        ///   - sharedMaximumEvents: Positive authority event cap, bounding lazily allocated slot metadata.
        init(hub: UUID, hubState: HubState, configuration: GatewayEventHubConfiguration,
             maximumEvents: Int, maximumBytes: Int, policy: GatewayEventOverflowPolicy,
             sharedMaximumEvents: Int) {
            self.hub = hub
            self.hubState = hubState
            self.configuration = configuration
            self.maximumEvents = maximumEvents
            self.maximumBytes = maximumBytes
            self.policy = policy
            events = EventQueue(maximumCount: min(maximumEvents, configuration.maximumBufferedEvents, sharedMaximumEvents))
        }
    }

    private let configuration: GatewayEventHubConfiguration
    private var subscribers: [UUID: Subscriber] = [:]
    private var hubs: [UUID: HubState] = [:]
    private var bufferedEvents = 0
    private var bufferedBytes = 0
    private var waitingConsumers = 0

    /// Stores validated aggregate limits; no background task or external resources are created.
    /// - Parameter configuration: Process-wide subscriptions/count/bytes limits. Per-subscription defaults
    ///   are selected by each hub's configuration, not this authority's defaults.
    public init(configuration: GatewayEventHubConfiguration) { self.configuration = configuration }

    /// Reports aggregate metadata and queue usage across every hub sharing this authority.
    /// - Returns: An atomic bounded snapshot, excluding events already handed to consumer code.
    public func snapshot() -> GatewayEventHubSnapshot { snapshot(hub: nil) }

    /// Registers one independent queue after checking hub and shared metadata budgets.
    /// - Parameters:
    ///   - hub: Opaque hub identity, never a credential or user diagnostic label.
    ///   - configuration: Validated hub aggregate and default individual bounds.
    ///   - policy: Explicit action when queue or shared byte/count capacity is exhausted.
    ///   - maximumEvents: Positive individual event count override, or nil for the hub default.
    ///   - maximumBytes: Positive individual retained byte override, or nil for the hub default.
    /// - Returns: A new subscription that receives only subsequent publications to this hub.
    /// - Throws: `CancellationError` when the caller is already cancelled, invalid overrides,
    ///   or exhausted local/shared subscription metadata capacity.
    fileprivate func subscribe(hub: UUID, configuration: GatewayEventHubConfiguration,
                               policy: GatewayEventOverflowPolicy, maximumEvents: Int?, maximumBytes: Int?) throws -> GatewayEventSubscription {
        try Task.checkCancellation()
        let events = maximumEvents ?? configuration.maximumEventsPerSubscription
        let bytes = maximumBytes ?? configuration.maximumBytesPerSubscription
        guard events > 0, bytes > 0 else { throw GatewayEventDeliveryFailure.invalidConfiguration }
        let hubState = hubs[hub] ?? HubState()
        guard subscribers.count < self.configuration.maximumSubscriptions,
              hubState.subscriptions.count < configuration.maximumSubscriptions else {
            throw GatewayEventDeliveryFailure.subscriptionCapacityExceeded
        }
        let id = UUID()
        subscribers[id] = Subscriber(hub: hub, hubState: hubState, configuration: configuration,
            maximumEvents: events, maximumBytes: bytes, policy: policy,
            sharedMaximumEvents: self.configuration.maximumBufferedEvents)
        hubState.subscriptions.append(id)
        hubs[hub] = hubState
        DiscordLog.makeLogger("gateway.events").debug("Gateway subscription created", metadata: ["dk.event": "gateway.subscription.created", "dk.subscriptions": .stringConvertible(subscribers.count)])
        return GatewayEventSubscription(authority: self, id: id)
    }

    /// Publishes atomically to a bounded set of independent queues, without awaiting consumers.
    /// - Parameters:
    ///   - event: Already bounded raw envelope whose byte count is trusted from Gateway ingestion.
    ///   - hub: Opaque source hub; subscribers of other hubs never receive this event.
    ///   - intervals: Optional observer used only for copies actually retained in a subscription queue.
    ///   - parent: Numeric publication context; it confers no trusted interaction receipt.
    /// - Returns: Counts of admitted, dropped, and newly failed subscribers.
    fileprivate func publish(_ event: GatewayEvent, hub: UUID, intervals: DiscordIntervalTiming?, parent: DiscordIntervalContext?) -> GatewayEventPublication {
        var delivered = 0
        var dropped = 0
        var terminated = 0
        let ids = hubs[hub]?.subscriptions ?? []
        for id in ids {
            guard let subscriber = subscribers[id], !subscriber.failed else { continue }
            if let waiter = subscriber.waiter {
                subscriber.waiter = nil
                subscriber.hubState.waitingConsumers -= 1
                waitingConsumers -= 1
                waiter.resume(returning: event)
                delivered += 1
                continue
            }
            if subscriber.policy == .dropOldest,
               event.retainedByteCount <= subscriber.maximumBytes,
               event.retainedByteCount <= subscriber.configuration.maximumBufferedBytes,
               event.retainedByteCount <= configuration.maximumBufferedBytes {
                while !fits(event, subscriber: subscriber), let removed = subscriber.events.popFirst() {
                    removed.interval?.end(.failed)
                    release(removed, subscriber: subscriber)
                }
            }
            if fits(event, subscriber: subscriber) {
                subscriber.events.append(QueuedEvent(event: event,
                    interval: intervals?.begin(.gatewayPublication, stage: .hubResidence, parent: parent)))
                subscriber.bytes += event.retainedByteCount
                subscriber.hubState.bufferedEvents += 1
                subscriber.hubState.bufferedBytes += event.retainedByteCount
                bufferedEvents += 1
                bufferedBytes += event.retainedByteCount
                delivered += 1
            } else if subscriber.policy == .resynchronize {
                while let entry = subscriber.events.popFirst() {
                    entry.interval?.end(.failed)
                    release(entry, subscriber: subscriber)
                }
                subscriber.failed = true
                terminated += 1
            } else { dropped += 1 }
        }
        if terminated > 0 || dropped > 0 {
            DiscordLog.makeLogger("gateway.events").warning("Gateway subscriber capacity exhausted", metadata: ["dk.event": "gateway.subscription.overflow", "dk.dropped": .stringConvertible(dropped), "dk.terminated": .stringConvertible(terminated)])
        }
        DiscordLog.makeLogger("gateway.events").trace("Gateway event publication completed", metadata: ["dk.event": "gateway.publication.completed", "dk.delivered": .stringConvertible(delivered), "dk.dropped": .stringConvertible(dropped), "dk.terminated": .stringConvertible(terminated), "dk.queued": .stringConvertible(bufferedEvents), "dk.bytes": .stringConvertible(bufferedBytes)])
        return GatewayEventPublication(delivered: delivered, dropped: dropped, terminated: terminated)
    }

    /// Determines admission using subtraction to avoid overflow even for extreme configured limits.
    /// - Parameters:
    ///   - event: Candidate event, counted once for this queue.
    ///   - subscriber: Current local queue state, already reflected in shared accounting.
    /// - Returns: Whether all subscriber, hub, and shared event/byte bounds permit one more copy.
    private func fits(_ event: GatewayEvent, subscriber: Subscriber) -> Bool {
        return subscriber.events.count < subscriber.maximumEvents
            && event.retainedByteCount <= subscriber.maximumBytes - subscriber.bytes
            && subscriber.hubState.bufferedEvents < subscriber.configuration.maximumBufferedEvents
            && event.retainedByteCount <= subscriber.configuration.maximumBufferedBytes - subscriber.hubState.bufferedBytes
            && bufferedEvents < configuration.maximumBufferedEvents
            && event.retainedByteCount <= configuration.maximumBufferedBytes - bufferedBytes
    }

    /// Reads or parks exactly one consumer continuation and releases accounting before delivery.
    /// - Parameter id: Subscription admission identity, never reused after cancellation.
    /// - Returns: Oldest admitted event, or nil for an unknown/finished subscription.
    /// - Throws: Cancellation, a terminal resynchronization error, or overlapping consumer iteration.
    fileprivate func next(_ id: UUID) async throws -> GatewayEvent? {
        if Task.isCancelled {
            cancel(id, cancelled: true)
            throw CancellationError()
        }
        guard let subscriber = subscribers[id] else { return nil }
        if subscriber.failed {
            removeMetadata(id, subscriber: subscriber)
            throw GatewayEventDeliveryFailure.resynchronizationRequired
        }
        guard subscriber.waiter == nil else { throw GatewayEventDeliveryFailure.concurrentIteration }
        if let event = subscriber.events.popFirst() {
            release(event, subscriber: subscriber)
            event.interval?.end()
            DiscordLog.makeLogger("gateway.events").trace("Gateway subscription dequeued an event", metadata: ["dk.event": "gateway.subscription.dequeued", "dk.queued": .stringConvertible(bufferedEvents), "dk.bytes": .stringConvertible(bufferedBytes)])
            return event.event
        }
        DiscordLog.makeLogger("gateway.events").trace("Gateway subscription waiting for publication", metadata: ["dk.event": "gateway.subscription.wait"])
        return try await withCheckedThrowingContinuation { continuation in
            subscriber.waiter = continuation
            subscriber.hubState.waitingConsumers += 1
            waitingConsumers += 1
        }
    }

    /// Removes one queue and resolves its continuation exactly once, including cancellation races.
    /// - Parameters:
    ///   - id: Subscription to release; unknown IDs are harmless.
    ///   - cancelled: Whether a suspended consumer receives cancellation rather than normal completion.
    fileprivate func cancel(_ id: UUID, cancelled: Bool) {
        guard let subscriber = subscribers[id] else { return }
        while let entry = subscriber.events.popFirst() {
            entry.interval?.end(.cancelled)
            release(entry, subscriber: subscriber)
        }
        if subscriber.waiter != nil {
            subscriber.hubState.waitingConsumers -= 1
            waitingConsumers -= 1
        }
        removeMetadata(id, subscriber: subscriber)
        DiscordLog.makeLogger("gateway.events").trace("Gateway subscription released", metadata: ["dk.event": "gateway.subscription.released", "dk.cancelled": .stringConvertible(cancelled), "dk.subscriptions": .stringConvertible(subscribers.count), "dk.queued": .stringConvertible(bufferedEvents), "dk.bytes": .stringConvertible(bufferedBytes)])
        if cancelled { subscriber.waiter?.resume(throwing: CancellationError()) }
        else { subscriber.waiter?.resume(returning: nil) }
    }

    /// Discards every queue owned by one hub, leaving unrelated identities operational.
    /// - Parameter hub: Opaque hub whose subscribers should receive normal completion.
    fileprivate func finish(hub: UUID) {
        let ids = hubs[hub]?.subscriptions ?? []
        for id in ids { cancel(id, cancelled: false) }
    }

    /// Reads exact metadata/queue counters for a hub or the full authority without scanning queues.
    /// - Parameter hub: Nil selects all hubs; otherwise only matching subscriptions count.
    /// - Returns: Atomic usage, including terminal failure metadata until observed or cancelled.
    fileprivate func snapshot(hub: UUID?) -> GatewayEventHubSnapshot {
        guard let hub else {
            return GatewayEventHubSnapshot(subscriptions: subscribers.count, bufferedEvents: bufferedEvents,
                bufferedBytes: bufferedBytes, waitingConsumers: waitingConsumers)
        }
        guard let state = hubs[hub] else {
            return GatewayEventHubSnapshot(subscriptions: 0, bufferedEvents: 0, bufferedBytes: 0, waitingConsumers: 0)
        }
        return GatewayEventHubSnapshot(subscriptions: state.subscriptions.count,
            bufferedEvents: state.bufferedEvents, bufferedBytes: state.bufferedBytes,
            waitingConsumers: state.waitingConsumers)
    }

    /// Releases the exact subscriber, hub and authority charge for one dequeued or discarded copy.
    /// - Parameters:
    ///   - event: Copy already removed from its FIFO; its interval is resolved by the caller.
    ///   - subscriber: Owning queue whose retained byte charge still includes this event.
    private func release(_ event: QueuedEvent, subscriber: Subscriber) {
        subscriber.bytes -= event.retainedByteCount
        subscriber.hubState.bufferedEvents -= 1
        subscriber.hubState.bufferedBytes -= event.retainedByteCount
        bufferedEvents -= 1
        bufferedBytes -= event.retainedByteCount
    }

    /// Releases admission order metadata after queued and waiting-consumer accounting is drained.
    /// This bounded metadata mutation is paid at removal, leaving publication and snapshots scan-free.
    /// - Parameters:
    ///   - id: Registered queue identity to remove exactly once.
    ///   - subscriber: Actor-owned queue already empty or terminal with no retained consumer charge.
    private func removeMetadata(_ id: UUID, subscriber: Subscriber) {
        subscribers.removeValue(forKey: id)
        subscriber.hubState.subscriptions.removeAll { $0 == id }
        if subscriber.hubState.subscriptions.isEmpty { hubs.removeValue(forKey: subscriber.hub) }
    }
}

/// A broadcast endpoint with separately bounded queues, optionally sharing aggregate budgets.
///
/// Publication order is preserved per subscription and therefore per sequentially published shard.
/// Concurrent publishers have actor admission order, not an invented cross-shard order. Delivery
/// is neither durable nor exactly once. No constructor launches tasks or performs network I/O.
public actor GatewayEventHub {
    private let id = UUID()
    private let configuration: GatewayEventHubConfiguration
    private let authority: GatewayEventHubAuthority
    private let intervals: DiscordIntervalTiming?
    private var finished = false
    private var inFlightSubscriptions = 0
    private var admissionsDrained: CheckedContinuation<Void, Never>?
    private var finishTask: Task<Void, Never>?

    /// Creates an idle hub with explicit local bounds and an optional shared process authority.
    /// - Parameters:
    ///   - configuration: Validated local metadata/count/byte limits and subscriber defaults.
    ///   - authority: Shared aggregate budget; nil creates a private authority with the same limits.
    ///   - intervals: Optional publication and per-subscription residence hooks. Nil reads no interval clock.
    public init(configuration: GatewayEventHubConfiguration, authority: GatewayEventHubAuthority? = nil,
                intervals: DiscordIntervalTiming? = nil) {
        self.configuration = configuration
        self.authority = authority ?? GatewayEventHubAuthority(configuration: configuration)
        self.intervals = intervals
    }

    /// Registers a new consumer before publication; existing queued events are not replayed.
    /// - Parameters:
    ///   - policy: Default `.resynchronize` ends only this subscription when admission fails.
    ///   - maximumEvents: Positive individual queue count override; nil uses configuration.
    ///   - maximumBytes: Positive individual byte override; nil uses configuration.
    /// - Returns: An independently owned sequence that must be consumed or explicitly cancelled.
    /// - Throws: Invalid overrides, cancellation, exhausted local/shared metadata admission,
    ///   or `finished` after permanent hub shutdown, including subscription/shutdown races.
    public func subscribe(policy: GatewayEventOverflowPolicy = .resynchronize,
                          maximumEvents: Int? = nil, maximumBytes: Int? = nil) async throws -> GatewayEventSubscription {
        try Task.checkCancellation()
        guard !finished else { throw GatewayEventDeliveryFailure.finished }
        inFlightSubscriptions += 1
        defer { completeSubscriptionAdmission() }
        let subscription = try await authority.subscribe(hub: id, configuration: configuration, policy: policy,
            maximumEvents: maximumEvents, maximumBytes: maximumBytes)
        if finished || Task.isCancelled {
            await subscription.cancel()
            if Task.isCancelled { throw CancellationError() }
            throw GatewayEventDeliveryFailure.finished
        }
        return subscription
    }

    /// Offers one event to all current subscribers without running or awaiting user callbacks.
    /// - Parameter event: Already bounded raw Gateway observation, including future/unknown events.
    /// - Returns: Explicit subscriber delivery/drop/failure counts. A slow queue never blocks publication.
    @discardableResult public func publish(_ event: GatewayEvent) async -> GatewayEventPublication {
        guard !finished else { return GatewayEventPublication(delivered: 0, dropped: 0, terminated: 0) }
        let publication = intervals?.begin(.gatewayPublication, stage: .operation)
        let result = await authority.publish(event, hub: id, intervals: intervals, parent: publication?.context)
        publication?.end(result.dropped > 0 || result.terminated > 0 ? .failed : .succeeded)
        return result
    }

    /// Permanently closes admission, completes current subscriptions, and discards queues.
    /// Preexisting subscription admissions are cancelled and awaited before cleanup returns.
    /// Repeated calls await the same owned cleanup task and are harmless. Construct another hub for another run.
    public func finish() async {
        finished = true
        if let finishTask { await finishTask.value; return }
        // Explicit shutdown owns this one task and every caller awaits it. Keeping a single
        // completion task avoids accumulating a continuation per concurrent finish caller.
        let task = Task { await completeFinish() }
        finishTask = task
        await task.value
    }

    /// Reports this hub's atomic metadata/queue usage without exposing identity or event payloads.
    /// - Returns: Usage for only this hub, excluding consumer-owned events after delivery.
    public func snapshot() async -> GatewayEventHubSnapshot { await authority.snapshot(hub: id) }

    /// Releases one pending admission and wakes the single owned cleanup operation after the last settles.
    /// This executes without suspension so shutdown never observes a partially completed admission.
    private func completeSubscriptionAdmission() {
        inFlightSubscriptions -= 1
        if inFlightSubscriptions == 0 {
            admissionsDrained?.resume()
            admissionsDrained = nil
        }
    }

    /// Completes queues before and after awaiting all admissions that raced permanent shutdown.
    /// This operation belongs to `finishTask`; it performs no user work and cannot be cancelled midway.
    private func completeFinish() async {
        await authority.finish(hub: id)
        if inFlightSubscriptions > 0 {
            await withCheckedContinuation { admissionsDrained = $0 }
        }
        await authority.finish(hub: id)
    }
}
