// File: Sources/DiscordHTTP/RateLimitCoordinator.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordLogging
import DiscordTransport
import Foundation

/// Cancellable bounded FIFO admission above a shared injectable rate authority.
///
/// The oldest locally eligible partition head receives the next available slot.
/// Local completion resumes only the oldest eligible partition head, so unrelated
/// identities/resources can proceed without polling. Parked waiters share one
/// cancellable clock sleeper for queue deadlines and authority retry instants.
/// FIFO covers one coordinator's identity/route/major
/// resource/class, including holding that partition until completion. Share the
/// coordinator when mutation ordering must span clients; a distributed store alone
/// coordinates rate admission, not cross-process application mutation ordering.
/// An uncertain authority failure permanently closes local admission and emits one
/// critical event. Replace the coordinator after restoring authority; it never resets
/// the safety latch or silently grants local fallback admission.
public actor RateLimitCoordinator<C: Clock> where C.Duration == Duration {
    private struct QueuePartition: Hashable {
        let identity: RateLimitIdentity
        let route: String
        let majorResource: String
        let schedulingClass: SchedulingClass

        /// Derives a FIFO ownership key containing no credential or raw URL.
        /// - Parameter request: Request's explicitly supplied rate scopes.
        init(_ request: RateLimitRequest) {
            identity = request.identity; route = request.route
            majorResource = request.majorResource; schedulingClass = request.schedulingClass
        }
    }
    private struct Waiter {
        let request: RateLimitRequest
        let deadline: C.Instant
        var blockedUntil: C.Instant
        var continuation: CheckedContinuation<Void, Never>?
    }
    private let clock: C
    private let store: any RateLimitStore<C.Instant>
    private let policy: SchedulingPolicy
    private var queue: [UUID] = []
    private var waiters: [UUID: Waiter] = [:]
    private var queuedBytes = 0
    private var orderingQueue: [UUID] = []
    private var orderingWaiters: [UUID: Waiter] = [:]
    private var orderedOperations: [UUID: RateLimitRequest] = [:]
    private var active: [UUID: RateLimitReservation<C.Instant>] = [:]
    private var admitting: Set<QueuePartition> = []
    private var timerDriver: Task<Void, Never>?
    private var timerSleeper: Task<Void, Error>?
    private var timerDeadline: C.Instant?
    private var closed = false
    private var unavailable = false

    /// Creates a scheduler without spawning background work.
    /// - Parameters:
    ///   - clock: Monotonic clock used for queue/deadline/fairness decisions.
    ///   - store: Shared in-process or external authority; nil creates an owned local store.
    ///   - policy: Finite queue, byte, concurrency and age budgets. If supplying a
    ///     store, configure its aggregate limits independently for all clients sharing it.
    public init(clock: C, store: (any RateLimitStore<C.Instant>)? = nil, policy: SchedulingPolicy = .init()) {
        self.clock = clock
        self.policy = policy
        self.store = store ?? InProcessRateLimitStore<C.Instant>(policy: policy)
    }

    /// Waits for ordered admission while respecting every applicable finite budget.
    /// Cancellation removes the waiter and its notification without advancing virtual time.
    /// - Parameters:
    ///   - request: Nonnegative request-byte estimate and opaque authority scopes.
    ///   - deadline: Inclusive clock-local deadline; nil still applies maximumQueueAge.
    /// - Returns: Single-use token whose owner must call complete or release exactly once.
    /// - Throws: Cancellation, closed/unavailable authority, overload, deadline or store failure.
    public func acquire(_ request: RateLimitRequest, deadline: C.Instant? = nil) async throws -> RateLimitReservation<C.Instant> {
        try Task.checkCancellation()
        try ensureOpen()
        guard request.queuedBytes >= 0 else { throw RateLimitFailure.invalidRequest }
        let now = clock.now
        let effectiveDeadline = min(deadline ?? now.advanced(by: policy.maximumQueueAge),
                                    now.advanced(by: policy.maximumQueueAge))
        guard effectiveDeadline > now else { throw RateLimitFailure.deadlineExceeded }
        try validateQueueCapacity(request)
        let id = UUID()
        queue.append(id)
        waiters[id] = Waiter(request: request, deadline: effectiveDeadline, blockedUntil: now)
        queuedBytes += request.queuedBytes
        DiscordLog.makeLogger("http.ratelimit").trace("REST admission queued", metadata: ["dk.event": "http.admission.queued", "dk.queued": .stringConvertible(queue.count)])
        let result: Result<RateLimitReservation<C.Instant>, any Error>
        do {
            result = .success(try await withTaskCancellationHandler {
                while true {
                    try Task.checkCancellation()
                    try ensureOpen()
                    guard var waiter = waiters[id] else { throw CancellationError() }
                    let current = clock.now
                    guard current < waiter.deadline else { throw RateLimitFailure.deadlineExceeded }
                    if eligibleHead(at: current) == id {
                        let partition = QueuePartition(request)
                        admitting.insert(partition)
                        notifyEligibleWaiters()
                        let result: RateLimitAdmission<C.Instant>
                        DiscordLog.makeLogger("http.ratelimit").trace("REST shared authority reservation started", metadata: ["dk.event": "http.admission.reserve", "dk.active": .stringConvertible(active.count)])
                        do { result = try await store.reserve(request, now: current) }
                        catch {
                            admitting.remove(partition)
                            if let failure = error as? RateLimitFailure {
                                if failure == .coordinatorUnavailable || failure == .unknownReservation || failure == .reservationExpired {
                                    failClosed()
                                }
                            } else if !(error is CancellationError) { failClosed() }
                            notifyEligibleWaiters()
                            throw authorityFailure(error)
                        }
                        switch result {
                        case .admitted(let reservation):
                            if closed || unavailable || Task.isCancelled || clock.now >= waiter.deadline {
                                do { try await store.release(reservation, outcome: .notSent, now: clock.now) }
                                catch {
                                    admitting.remove(partition)
                                    failClosed()
                                    throw authorityFailure(error)
                                }
                                admitting.remove(partition)
                                notifyEligibleWaiters()
                                try Task.checkCancellation()
                                try ensureOpen()
                                throw RateLimitFailure.deadlineExceeded
                            }
                            active[reservation.id] = reservation
                            admitting.remove(partition)
                            notifyEligibleWaiters()
                            DiscordLog.makeLogger("http.ratelimit").trace("REST admission granted", metadata: ["dk.event": "http.admission.granted"])
                            return reservation
                        case .retry(let instant):
                            DiscordLog.makeLogger("http.ratelimit").trace("REST shared authority deferred admission", metadata: ["dk.event": "http.admission.deferred"])
                            waiter.blockedUntil = max(instant, current.advanced(by: policy.fairnessInterval))
                            waiters[id]?.blockedUntil = waiter.blockedUntil
                            admitting.remove(partition)
                            notifyEligibleWaiters()
                        }
                    }
                    DiscordLog.makeLogger("http.ratelimit").trace("REST admission waiting for eligibility", metadata: ["dk.event": "http.admission.wait", "dk.queued": .stringConvertible(waiters.count), "dk.active": .stringConvertible(active.count)])
                    await waitForNotification(id, ordering: false)
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            })
        } catch { result = .failure(error) }
        removeWaiter(id)
        await joinIdleTimer()
        return try result.get()
    }

    /// Holds local mutation ordering across a complete operation, including every
    /// rejected-attempt retry and backoff. This lease consumes no Discord quota.
    /// Whole-operation and rate waiters share finite count/byte queue caps, and
    /// held operations have separate finite total/per-identity concurrency limits.
    ///
    /// Callers must consistently use this helper for operations whose ordering must
    /// be preserved and share this coordinator across clients. The operation must
    /// cooperate with cancellation and must not recursively acquire the same key.
    /// External rate stores do not supply cross-process mutation ordering.
    /// - Parameters:
    ///   - request: Identity/route/major-resource/class ordering partition and byte estimate.
    ///   - deadline: Inclusive acquisition deadline; nil still bounds queue age.
    ///   - operation: Structured caller-owned operation, invoked exactly once after
    ///     obtaining FIFO ownership. Its suspension points retain that ownership.
    /// - Returns: The operation result, after releasing local ordering ownership.
    /// - Throws: Queue/deadline/authority/cancellation failures or the operation's error.
    public func withOrdering<Value: Sendable>(request: RateLimitRequest, deadline: C.Instant? = nil,
                                              operation: @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        try ensureOpen()
        guard request.queuedBytes >= 0 else { throw RateLimitFailure.invalidRequest }
        let now = clock.now
        let effectiveDeadline = min(deadline ?? now.advanced(by: policy.maximumQueueAge),
                                    now.advanced(by: policy.maximumQueueAge))
        guard effectiveDeadline > now else { throw RateLimitFailure.deadlineExceeded }
        try validateQueueCapacity(request)
        let id = UUID()
        DiscordLog.makeLogger("http.ordering").trace("REST ordered operation queued", metadata: ["dk.event": "http.ordering.queued", "dk.queued": .stringConvertible(orderingWaiters.count + 1)])
        orderingQueue.append(id)
        orderingWaiters[id] = Waiter(request: request, deadline: effectiveDeadline, blockedUntil: now)
        queuedBytes += request.queuedBytes
        let result: Result<Value, any Error>
        do {
            result = .success(try await withTaskCancellationHandler {
                while true {
                    try Task.checkCancellation()
                    try ensureOpen()
                    guard let waiter = orderingWaiters[id] else { throw CancellationError() }
                    guard clock.now < waiter.deadline else { throw RateLimitFailure.deadlineExceeded }
                    if eligibleOrderingHead(at: clock.now) == id {
                        removeOrderingWaiter(id, notify: false)
                        orderedOperations[id] = request
                        notifyEligibleWaiters()
                        DiscordLog.makeLogger("http.ordering").trace("REST ordered operation admitted", metadata: ["dk.event": "http.ordering.admitted", "dk.active": .stringConvertible(orderedOperations.count)])
                        return try await operation()
                    }
                    await waitForNotification(id, ordering: true)
                }
            } onCancel: {
                Task { await self.removeOrderingWaiter(id) }
            })
        } catch { result = .failure(error) }
        removeOrderingWaiter(id)
        orderedOperations.removeValue(forKey: id)
        notifyEligibleWaiters()
        DiscordLog.makeLogger("http.ordering").trace("REST ordered operation released", metadata: ["dk.event": "http.ordering.released", "dk.active": .stringConvertible(orderedOperations.count)])
        await joinIdleTimer()
        return try result.get()
    }

    /// Learns response rate metadata before releasing the local FIFO partition.
    /// - Parameters:
    ///   - reservation: Token acquired from this coordinator.
    ///   - status: HTTP response status.
    ///   - headers: Bounded response metadata from the transport.
    ///   - retryAfter: Optional decoded 429 body delay; headers also participate.
    ///   - global: Decoded 429 body flag, false when absent.
    /// - Throws: Ownership, metadata or external authority failure; authority errors
    ///   stop new local admissions until the consumer replaces the coordinator.
    public func complete(_ reservation: RateLimitReservation<C.Instant>, status: Int, headers: [HTTPHeader],
                         retryAfter: Duration? = nil, global: Bool = false) async throws {
        guard active[reservation.id] != nil else { throw RateLimitFailure.unknownReservation }
        defer {
            active.removeValue(forKey: reservation.id)
            notifyEligibleWaiters()
        }
        do {
            try await store.complete(reservation, status: status, headers: headers,
                                     retryAfter: retryAfter, global: global, now: clock.now)
            DiscordLog.makeLogger("http.ratelimit").trace("REST response rate observation completed", metadata: ["dk.event": "http.admission.completed", "dk.status": .stringConvertible(status), "dk.global": .stringConvertible(global), "dk.retry_after_present": .stringConvertible(retryAfter != nil)])
        } catch { failClosed(); throw authorityFailure(error) }
    }

    /// Clears owned concurrency after a failed/canceled send while retaining rate debits.
    /// - Parameters:
    ///   - reservation: Token acquired from this coordinator.
    ///   - outcome: Explicit uncertainty; neither value refunds server quota.
    /// - Throws: Unknown/expired ownership or authority failure; failure stops new admissions.
    public func release(_ reservation: RateLimitReservation<C.Instant>, outcome: RateLimitReleaseOutcome) async throws {
        guard active[reservation.id] != nil else { throw RateLimitFailure.unknownReservation }
        defer {
            active.removeValue(forKey: reservation.id)
            notifyEligibleWaiters()
        }
        do {
            try await store.release(reservation, outcome: outcome, now: clock.now)
            DiscordLog.makeLogger("http.ratelimit").trace("REST admission released without response", metadata: ["dk.event": "http.admission.released", "dk.uncertain": .stringConvertible(outcome == .uncertain)])
        }
        catch { failClosed(); throw authorityFailure(error) }
    }

    /// Stops new admission and wakes every queued task immediately without sending.
    /// Already acquired tokens retain caller ownership and must still be completed
    /// or released. This operation joins the owned timer, is idempotent, and does
    /// not close an injected store.
    public func close() async {
        DiscordLog.makeLogger("http.ratelimit").info("REST admission closed", metadata: ["dk.event": "http.admission.closed"])
        closed = true
        notifyEligibleWaiters()
        await timerDriver?.value
    }

    /// Captures queue bytes/count and authority-wide active/metadata ownership.
    /// - Returns: Aggregate counters with no unbounded diagnostic label cardinality.
    public func snapshot() async -> SchedulingSnapshot {
        let authority = await store.snapshot()
        return SchedulingSnapshot(queuedCount: waiters.count + orderingWaiters.count, queuedBytes: queuedBytes,
                                  activeCount: authority.activeCount, metadataCount: authority.metadataCount,
                                  orderedOperationsCount: orderedOperations.count)
    }

    /// Replaces untrusted external authority errors with a closed diagnostic category.
    /// - Parameter error: Injected storage failure, potentially containing credentials in its description.
    /// - Returns: A known safe rate failure, standard cancellation, or coordinatorUnavailable.
    private func authorityFailure(_ error: any Error) -> any Error {
        if let failure = error as? RateLimitFailure { return failure }
        if error is CancellationError { return CancellationError() }
        return RateLimitFailure.coordinatorUnavailable
    }

    /// Rejects new work after shutdown or uncertain authority failure.
    /// - Throws: Closed or coordinatorUnavailable; these never permit local fallback.
    private func ensureOpen() throws {
        if closed { throw RateLimitFailure.closed }
        if unavailable { throw RateLimitFailure.coordinatorUnavailable }
    }

    /// Finds the oldest eligible FIFO partition head, bypassing blocked partitions.
    /// Control and ordinary classes have equal scheduling weight, so neither can
    /// permanently starve the other; a class does not bypass total resource caps.
    /// - Parameter now: Instant used to exclude future-blocked and expired requests.
    /// - Returns: Oldest eligible waiter ID, or nil if all partitions are blocked/full.
    private func eligibleHead(at now: C.Instant) -> UUID? {
        guard active.count + admitting.count < policy.maximumConcurrentRequests else { return nil }
        var seen: Set<QueuePartition> = []
        let activePartitions = Set(active.values.map { QueuePartition($0.request) }).union(admitting)
        for id in queue {
            guard let waiter = waiters[id] else { continue }
            let partition = QueuePartition(waiter.request)
            guard seen.insert(partition).inserted else { continue }
            guard waiter.deadline > now, waiter.blockedUntil <= now, !activePartitions.contains(partition) else { continue }
            let identityActive = active.values.filter { $0.request.identity == waiter.request.identity }.count
                + admitting.filter { $0.identity == waiter.request.identity }.count
            if identityActive < policy.maximumConcurrentRequestsPerIdentity { return id }
        }
        return nil
    }

    /// Checks aggregate/per-identity capacity across both ordering and rate queues.
    /// - Parameter request: Candidate's nonnegative byte estimate and opaque identity.
    /// - Throws: queueFull before changing accounting when any finite cap is exceeded.
    private func validateQueueCapacity(_ request: RateLimitRequest) throws {
        let all = Array(waiters.values) + Array(orderingWaiters.values)
        let sameIdentity = all.filter { $0.request.identity == request.identity }
        let identityBytes = sameIdentity.reduce(0) { $0 + $1.request.queuedBytes }
        guard all.count < policy.maximumQueuedRequests,
              sameIdentity.count < policy.maximumQueuedRequestsPerIdentity,
              request.queuedBytes <= policy.maximumQueuedBytes - queuedBytes,
              request.queuedBytes <= policy.maximumQueuedBytesPerIdentity - identityBytes else {
            DiscordLog.makeLogger("http.ratelimit").debug("REST admission queue exhausted", metadata: ["dk.event": "http.admission.overloaded", "dk.queued": .stringConvertible(all.count)])
            throw RateLimitFailure.queueFull
        }
    }

    /// Selects FIFO heads for whole-operation locks while bypassing unrelated locks.
    /// - Parameter now: Current clock-local instant, excluding expired queue entries.
    /// - Returns: Oldest unlocked, within-budget ordering waiter, or nil.
    private func eligibleOrderingHead(at now: C.Instant) -> UUID? {
        guard orderedOperations.count < policy.maximumConcurrentRequests else { return nil }
        let held = Set(orderedOperations.values.map(QueuePartition.init))
        var seen: Set<QueuePartition> = []
        for id in orderingQueue {
            guard let waiter = orderingWaiters[id] else { continue }
            let key = QueuePartition(waiter.request)
            guard seen.insert(key).inserted, !held.contains(key), waiter.deadline > now else { continue }
            if orderedOperations.values.filter({ $0.identity == waiter.request.identity }).count
                < policy.maximumConcurrentRequestsPerIdentity { return id }
        }
        return nil
    }

    /// Parks one caller without creating a task for subsequent local notifications.
    /// Registration and eligible-head selection occur in the same actor turn, so a
    /// completion cannot be lost between checking eligibility and suspending.
    /// - Parameters:
    ///   - id: Existing pending registration, or an already canceled registration.
    ///   - ordering: Whether the registration belongs to whole-operation ordering.
    private func waitForNotification(_ id: UUID, ordering: Bool) async {
        await withCheckedContinuation { continuation in
            if ordering {
                guard orderingWaiters[id] != nil else { continuation.resume(); return }
                orderingWaiters[id]?.continuation = continuation
            } else {
                guard waiters[id] != nil else { continuation.resume(); return }
                waiters[id]?.continuation = continuation
            }
            notifyEligibleWaiters()
        }
    }

    /// Resumes one parked registration exactly once while retaining its FIFO position.
    /// A resumed head remains selected until its caller consumes eligibility; later
    /// arrivals therefore cannot overtake a notified caller that has not run yet.
    /// - Parameters:
    ///   - id: Candidate registration; nil and already resumed callers are harmless.
    ///   - ordering: Which bounded queue owns the continuation.
    private func signal(_ id: UUID?, ordering: Bool) {
        guard let id else { return }
        let continuation: CheckedContinuation<Void, Never>?
        if ordering {
            continuation = orderingWaiters[id]?.continuation
            orderingWaiters[id]?.continuation = nil
        } else {
            continuation = waiters[id]?.continuation
            waiters[id]?.continuation = nil
        }
        continuation?.resume()
    }

    /// Notifies eligible FIFO heads directly, retaining every authority retry bound.
    /// Expiry and terminal closure wake affected callers only to reject admission.
    /// At most one eligible caller in each queue is resumed per state transition;
    /// consuming its slot continues the bounded handoff chain without a herd.
    private func notifyEligibleWaiters() {
        let now = clock.now
        for id in queue {
            if let waiter = waiters[id], closed || unavailable || waiter.deadline <= now {
                signal(id, ordering: false)
            }
        }
        for id in orderingQueue {
            if let waiter = orderingWaiters[id], closed || unavailable || waiter.deadline <= now {
                signal(id, ordering: true)
            }
        }
        if !closed && !unavailable {
            signal(eligibleHead(at: now), ordering: false)
            signal(eligibleOrderingHead(at: now), ordering: true)
        }
        updateTimer()
    }

    /// Finds the next useful clock wake among parked queue and authority deadlines.
    /// Locally held slots need only completion notifications. An external store's
    /// retry instant remains authoritative even after an unrelated local release.
    /// A retry can become eligible before the timer task first runs. Such a parked
    /// head needs an immediate wake. Locally held capacity still waits for completion.
    /// - Returns: Nearest necessary wake, or nil when no parked caller needs a timer.
    private func nextTimerDeadline() -> C.Instant? {
        guard !closed && !unavailable else { return nil }
        let now = clock.now
        if let head = eligibleHead(at: now), waiters[head]?.continuation != nil { return now }
        var deadline: C.Instant?
        for waiter in waiters.values where waiter.continuation != nil {
            let wake = waiter.blockedUntil > now ? min(waiter.deadline, waiter.blockedUntil) : waiter.deadline
            deadline = min(deadline ?? wake, wake)
        }
        for waiter in orderingWaiters.values where waiter.continuation != nil {
            deadline = min(deadline ?? waiter.deadline, waiter.deadline)
        }
        return deadline
    }

    /// Starts a single timer driver on demand or interrupts its current sleep when
    /// an earlier deadline appears. Completion notifications themselves spawn no
    /// tasks. The driver joins its canceled child before creating another sleeper.
    private func updateTimer() {
        let deadline = nextTimerDeadline()
        if timerDriver == nil, deadline != nil {
            timerDriver = Task { await self.runTimer() }
        } else if let current = timerDeadline {
            if let deadline {
                if deadline < current { timerSleeper?.cancel() }
            } else {
                timerSleeper?.cancel()
            }
        }
    }

    /// Joins obsolete clock registration before the final waiting caller returns.
    /// Only the captured canceled child is joined: a new caller may legitimately
    /// keep the persistent driver alive during this suspension. Other parked
    /// callers retain their shared timer and are never delayed by this cleanup.
    private func joinIdleTimer() async {
        guard nextTimerDeadline() == nil, let sleeper = timerSleeper else { return }
        sleeper.cancel()
        _ = try? await sleeper.value
    }

    /// Owns at most one clock-sleep child for all rate and ordering waiters.
    /// Every interrupted child is joined before replacement, preventing stale timer
    /// callbacks and bounding live tasks even during cancellation/enqueue churn.
    /// The driver exits when queues drain or admission closes; it never polls local
    /// ownership and never grants permission without a fresh authority reservation.
    /// A non-cancellation clock failure latches coordinatorUnavailable for every
    /// queue because deadlines can no longer be enforced; held ownership remains
    /// releasable through the authority and must still be cleaned up by its caller.
    private func runTimer() async {
        while let deadline = nextTimerDeadline() {
            let clock = self.clock
            let sleeper = Task { try await clock.sleep(until: deadline, tolerance: nil) }
            timerDeadline = deadline
            timerSleeper = sleeper
            do { try await sleeper.value }
            catch {
                if !(error is CancellationError) { failClosed() }
            }
            timerSleeper = nil
            timerDeadline = nil
            notifyEligibleWaiters()
        }
        timerDriver = nil
    }

    /// Clears pending ordering accounting and its continuation exactly once.
    /// - Parameters:
    ///   - id: Pending ordering registration; active operation leases are unaffected.
    ///   - notify: False only while atomically transferring this waiter into ownership.
    private func removeOrderingWaiter(_ id: UUID, notify: Bool = true) {
        guard let waiter = orderingWaiters.removeValue(forKey: id) else { return }
        queuedBytes -= waiter.request.queuedBytes
        orderingQueue.removeAll { $0 == id }
        waiter.continuation?.resume()
        if notify { notifyEligibleWaiters() }
    }

    /// Removes queue accounting and its notification exactly once.
    /// - Parameter id: Waiter identifier, possibly already removed after cancellation.
    private func removeWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        queuedBytes -= waiter.request.queuedBytes
        queue.removeAll { $0 == id }
        waiter.continuation?.resume()
        notifyEligibleWaiters()
        DiscordLog.makeLogger("http.ratelimit").trace("REST admission waiter removed", metadata: ["dk.event": "http.admission.waiter.removed", "dk.queued": .stringConvertible(waiters.count), "dk.bytes": .stringConvertible(queuedBytes)])
    }

    /// Runs prompt cancellation cleanup from the cancellation handler's small task.
    /// - Parameter id: Canceled queue registration.
    private func cancelWaiter(_ id: UUID) { removeWaiter(id) }

    /// Permanently latches authority failure and wakes queued tasks without granting admission.
    /// The one critical transition requires application intervention and coordinator replacement.
    private func failClosed() {
        if !unavailable {
            DiscordLog.makeLogger("http.ratelimit").critical("REST authority permanently unavailable; replace coordinator", metadata: ["dk.event": "http.admission.unavailable"])
        }
        unavailable = true
        notifyEligibleWaiters()
    }
}
