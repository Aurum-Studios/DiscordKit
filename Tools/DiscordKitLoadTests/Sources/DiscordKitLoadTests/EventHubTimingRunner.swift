// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/EventHubTimingRunner.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordCore
import DiscordGateway
import DiscordLogging
import DiscordModels
import DiscordTransport
import Foundation

/// Public counter receipts; envelope bytes exclude queue and subscription metadata allocations.
struct EventHubTimingSnapshot: Codable, Equatable, Sendable {
    let subscriptions: Int
    let bufferedEvents: Int
    let bufferedBytes: Int
    let waitingConsumers: Int

    /// Copies atomic public counters without retaining the authority or any event envelope.
    init(_ value: GatewayEventHubSnapshot) {
        subscriptions = value.subscriptions; bufferedEvents = value.bufferedEvents
        bufferedBytes = value.bufferedBytes; waitingConsumers = value.waitingConsumers
    }
    /// Confirms that metadata, queued envelopes and suspended consumer owners have all been released.
    var isEmpty: Bool { subscriptions == 0 && bufferedEvents == 0 && bufferedBytes == 0 && waitingConsumers == 0 }
}

/// Fixed per-consumer order and count evidence, without retaining any event or timestamp.
struct EventHubTimingConsumer: Codable, Equatable, Sendable {
    var measuredEvents = 0
    var setupEvents = 0
    var firstSequence: Int64?
    var lastSequence: Int64?

    /// Rejects gaps or reorder within each observed retained sequence and releases the payload immediately.
    mutating func receive(_ event: GatewayEvent, measuredStart: Int64) throws {
        guard let sequence = event.sequence, lastSequence.map({ sequence == $0 + 1 }) ?? true else {
            throw EventHubTimingError.integrityFailure("Consumer order changed")
        }
        firstSequence = firstSequence ?? sequence; lastSequence = sequence
        if sequence >= measuredStart { measuredEvents += 1 } else { setupEvents += 1 }
    }
}

struct EventHubTimingMeasurement: Codable, Sendable {
    let counts: BenchmarkCounts
    let metrics: [BenchmarkMetric]
    let clockDomain: String
    let durationNanoseconds: UInt64
    let publicationCalls: Int
    let admittedCopies: Int
    let publicationDrops: Int
    let terminatedSubscriptions: Int
    let resynchronizationErrors: Int
    let discardedAdmittedCopies: Int
    let cancelledRetainedCopies: Int
    let setupCopies: Int
    let measuredCopies: EventHubTimingPopulationCounts
    let setupOutcomes: EventHubTimingPopulationCounts
    let retainedBeforeDrain: EventHubTimingSnapshot
    let cleanup: EventHubTimingSnapshot
    let consumers: [EventHubTimingConsumer]
    let pullCall: HistogramSnapshot
    let notes: [String]
}

/// Default-disabled fault boundaries owned by the benchmark, never awaited inside the hub authority.
enum EventHubTimingCheckpoint: Equatable, Sendable {
    case setupComplete
    case beforeQueuedPull(Int)
    case afterAcceptance(Int)
    case waitingReady
    case waitingReturned(Int)
    case beforeWaitingAggregation
}

/// A public-API fixed-backlog experiment, separated from socket, decoder, handler and provider work.
struct EventHubTimingRunner: Sendable {
    /// Synchronous fault observation; test callbacks never await or reenter the authority.
    var onResidence: (@Sendable (DiscordIntervalEvent) -> Void)? = nil
    /// Bounded driver fault barriers; nil in command execution.
    var onCheckpoint: (@Sendable (EventHubTimingCheckpoint) async throws -> Void)? = nil
    /// Every task and subscription is joined or cancelled before returning, including interrupted runs.
    /// - Parameters:
    ///   - configuration: Validated independent subscriber, hub, backlog, payload and consumer-policy
    ///     dimensions. Owners are private to this invocation; no network or trusted receipt is created.
    ///   - requests: Optional finite publication count per hub, overriding the configured count for
    ///     independent warmup. The same 100,000-call and ten-million-copy bounds still apply.
    /// - Returns: Direct publication/pull distributions, production residence intervals, exact copy
    ///   classifications and independently sampled empty cleanup. Cancellation returns the actual partial
    ///   population after joining; retained cancellation can include setup copies outside logical work.
    /// - Throws: Invalid dimensions, construction errors or integrity failures after owned cleanup.
    func run(_ configuration: EventHubTimingConfiguration, requests: Int? = nil) async throws -> EventHubTimingMeasurement {
        try configuration.validate()
        let requests = requests ?? configuration.requests
        guard (1...100_000).contains(requests), requests * configuration.subscriptions * configuration.hubs <= 10_000_000,
              let scenario = EventHubTimingScenario(rawValue: configuration.scenario) else {
            throw EventHubTimingError.invalidConfiguration
        }
        let statistics = try EventHubTimingStatistics()
        let accounting = EventHubTimingAccounting()
        let clock = ContinuousClock(), origin = clock.now
        let intervals = DiscordIntervalTiming(clockDomain: 603, sink: { event in
            accounting.observe(event)
            guard event.kind == .ended, event.operation == .gatewayPublication,
                  event.stage == .hubResidence, let outcome = event.outcome else { return }
            statistics.residence(event.elapsedNanoseconds, valid: event.validity == .valid, outcome: outcome)
            onResidence?(event)
        }, now: { origin.duration(to: clock.now) })
        let queueCapacity = scenario == .queued ? configuration.queuedDepth + 1 : max(1, configuration.queuedDepth)
        let perHubCopies = queueCapacity * configuration.subscriptions
        let bytesPerCopy = configuration.payloadBytes + 1_024
        let sharedConfiguration = try GatewayEventHubConfiguration(maximumSubscriptions: configuration.subscriptions * configuration.hubs,
            maximumBufferedEvents: perHubCopies * configuration.hubs,
            maximumBufferedBytes: perHubCopies * configuration.hubs * bytesPerCopy,
            maximumEventsPerSubscription: queueCapacity, maximumBytesPerSubscription: queueCapacity * bytesPerCopy)
        let localConfiguration = try GatewayEventHubConfiguration(maximumSubscriptions: configuration.subscriptions,
            maximumBufferedEvents: perHubCopies, maximumBufferedBytes: perHubCopies * bytesPerCopy,
            maximumEventsPerSubscription: queueCapacity, maximumBytesPerSubscription: queueCapacity * bytesPerCopy)
        let authority = GatewayEventHubAuthority(configuration: sharedConfiguration)
        let hubs = (0..<configuration.hubs).map { _ in GatewayEventHub(configuration: localConfiguration, authority: authority, intervals: intervals) }
        var subscriptions: [GatewayEventSubscription] = []
        let policy: GatewayEventOverflowPolicy
        switch configuration.policy { case .resynchronize: policy = .resynchronize; case .dropNewest: policy = .dropNewest; case .dropOldest: policy = .dropOldest }
        do {
            for hub in hubs {
                for _ in 0..<configuration.subscriptions { subscriptions.append(try await hub.subscribe(policy: policy)) }
            }
        } catch {
            for hub in hubs { await hub.finish() }
            throw error
        }
        var iterators = subscriptions.map { $0.makeAsyncIterator() }
        var consumers = subscriptions.map { _ in EventHubTimingConsumer() }
        let shard = try ShardIdentity(botID: UserID(rawValue: 1), topologyGeneration: 0, index: 0, count: 1)
        let payload = JSONValue.string(String(repeating: "x", count: configuration.payloadBytes))
        let measuredStart = Int64(scenario == .queued ? configuration.queuedDepth : 0)
        var publicationCalls = 0, admitted = 0, drops = 0, terminated = 0, resynchronizations = 0
        var setupCopies = 0, unadmitted = 0
        var pendingAggregated = 0, pendingAdmitted: [Bool] = []
        var pending: [Task<GatewayEvent?, any Error>] = []
        var failure: (any Error)?
        var interrupted = false
        var beforeDrain = EventHubTimingSnapshot(await authority.snapshot())
        let started = clock.now
        do {
            accounting.setPopulation(.setup)
            if scenario == .queued {
                for ordinal in 0..<configuration.queuedDepth {
                    try Task.checkCancellation()
                    let event = try GatewayEvent(shard: shard, name: "HUB_TIMING", sequence: Int64(ordinal), data: payload)
                    for hub in hubs {
                        let result = await hub.publish(event)
                        guard result.delivered == configuration.subscriptions, result.dropped == 0, result.terminated == 0 else {
                            throw EventHubTimingError.integrityFailure("Backlog setup refused")
                        }
                        setupCopies += result.delivered
                    }
                }
            }
            try await onCheckpoint?(.setupComplete)
            accounting.setPopulation(.measured)
            for ordinal in 0..<requests {
                try Task.checkCancellation()
                let event = try GatewayEvent(shard: shard, name: "HUB_TIMING", sequence: measuredStart + Int64(ordinal), data: payload)
                if scenario == .waiting {
                    pendingAggregated = 0
                    pendingAdmitted = subscriptions.map { _ in false }
                    pending = subscriptions.enumerated().map { index, subscription in
                        Task {
                            var iterator = subscription.makeAsyncIterator()
                            let start = clock.now
                            let event = try await iterator.next()
                            statistics.pull(start.duration(to: clock.now))
                            try await onCheckpoint?(.waitingReturned(index))
                            return event
                        }
                    }
                    while await authority.snapshot().waitingConsumers != subscriptions.count {
                        try Task.checkCancellation(); await Task.yield()
                    }
                }
                if scenario == .waiting { try await onCheckpoint?(.waitingReady) }
                for (hubIndex, hub) in hubs.enumerated() {
                    let start = clock.now
                    let result = await hub.publish(event)
                    let elapsed = start.duration(to: clock.now)
                    statistics.publication(elapsed, rejected: result.dropped > 0 || result.terminated > 0)
                    guard (0...configuration.subscriptions).contains(result.delivered) else {
                        throw EventHubTimingError.integrityFailure("Invalid publication admission")
                    }
                    publicationCalls += 1; admitted += result.delivered; drops += result.dropped; terminated += result.terminated
                    unadmitted += configuration.subscriptions - result.delivered
                    if scenario == .waiting {
                        guard result.delivered == configuration.subscriptions else {
                            throw EventHubTimingError.integrityFailure("Confirmed waiting cohort was not handed off")
                        }
                        for index in (hubIndex * configuration.subscriptions)..<((hubIndex + 1) * configuration.subscriptions) {
                            pendingAdmitted[index] = true
                        }
                    }
                }
                if scenario == .queued {
                    if configuration.delayMicroseconds > 0 { try await clock.sleep(for: .microseconds(configuration.delayMicroseconds)) }
                    for index in iterators.indices {
                        try await onCheckpoint?(.beforeQueuedPull(index))
                        try await Self.pull(&iterators[index], consumer: &consumers[index], measuredStart: measuredStart,
                            statistics: statistics, accounting: accounting)
                        try await onCheckpoint?(.afterAcceptance(index))
                    }
                } else if scenario == .waiting {
                    try await onCheckpoint?(.beforeWaitingAggregation)
                    for index in pending.indices {
                        let result = await pending[index].result
                        pendingAggregated = index + 1
                        try Self.acceptWaiting(result, admitted: pendingAdmitted[index], consumer: &consumers[index],
                            measuredStart: measuredStart, accounting: accounting)
                        try await onCheckpoint?(.afterAcceptance(index))
                    }
                    pending.removeAll(keepingCapacity: true)
                }
            }
            beforeDrain = EventHubTimingSnapshot(await authority.snapshot())
            if scenario == .overflow || scenario == .cancelled, configuration.delayMicroseconds > 0 {
                try await clock.sleep(for: .microseconds(configuration.delayMicroseconds))
            }
            if scenario == .cancelled {
                for subscription in subscriptions { await subscription.cancel() }
            } else if scenario != .waiting {
                guard beforeDrain.bufferedEvents.isMultiple(of: subscriptions.count) else {
                    throw EventHubTimingError.integrityFailure("Unequal retained population")
                }
                let retainedPerSubscription = beforeDrain.bufferedEvents / subscriptions.count
                for index in iterators.indices {
                    if scenario == .overflow, configuration.policy == .resynchronize, terminated > 0 {
                        do {
                            _ = try await iterators[index].next()
                            throw EventHubTimingError.integrityFailure("Missing resynchronization failure")
                        } catch GatewayEventDeliveryFailure.resynchronizationRequired { resynchronizations += 1 }
                    } else {
                        for _ in 0..<retainedPerSubscription {
                            try Task.checkCancellation()
                            try await Self.pull(&iterators[index], consumer: &consumers[index], measuredStart: measuredStart,
                                statistics: statistics, accounting: accounting)
                            try await onCheckpoint?(.afterAcceptance(index))
                        }
                    }
                }
            }
        } catch {
            interrupted = error is CancellationError || Task.isCancelled
            if !(error is CancellationError) { failure = error }
            beforeDrain = EventHubTimingSnapshot(await authority.snapshot())
        }
        for task in pending { task.cancel() }
        for hub in hubs { await hub.finish() }
        for index in pending.indices where index >= pendingAggregated {
            let result = await pending[index].result
            do {
                try Self.acceptWaiting(result, admitted: pendingAdmitted[index], consumer: &consumers[index],
                    measuredStart: measuredStart, accounting: accounting)
            } catch is CancellationError {
                interrupted = true
            } catch {
                failure = failure ?? error
            }
        }
        let terminal = clock.now
        let cleanup = EventHubTimingSnapshot(await authority.snapshot())
        guard cleanup.isEmpty else { throw EventHubTimingError.integrityFailure("Hub ownership remains") }
        if let failure { throw failure }
        let partition = try accounting.snapshot()
        let measured = partition.measured, setup = partition.setup
        let offered = publicationCalls * configuration.subscriptions
        let consumed = consumers.reduce(0) { $0 + $1.measuredEvents }
        let setupConsumed = consumers.reduce(0) { $0 + $1.setupEvents }
        guard measured.total == admitted, setup.total == setupCopies,
              measured.consumed == consumed, setup.consumed == setupConsumed,
              admitted + unadmitted == offered else {
            throw EventHubTimingError.integrityFailure("Unexplained or duplicate admitted copies")
        }
        let discarded = measured.discarded + setup.discarded
        let cancelledCopies = measured.cancelledRetained + setup.cancelledRetained
        let cancelled = measured.cancelledRetained + measured.cancelledHandoff
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        outcomes[.success] = UInt64(consumed); outcomes[.cancelled] = UInt64(cancelled)
        outcomes[.rejected] = UInt64(unadmitted + measured.discarded)
        let counts = BenchmarkCounts(offered: UInt64(offered), admitted: UInt64(admitted), completed: UInt64(offered), outcomes: outcomes, deadlineMisses: 0)
        try counts.validate()
        if !interrupted, scenario == .queued || scenario == .waiting {
            guard consumed == offered else { throw EventHubTimingError.integrityFailure("Lossless cohort incomplete") }
        }
        return EventHubTimingMeasurement(counts: counts, metrics: statistics.metrics(), clockDomain: statistics.clockDomain,
            durationNanoseconds: try BenchmarkTime.nanoseconds(duration: started.duration(to: terminal)),
            publicationCalls: publicationCalls, admittedCopies: admitted, publicationDrops: drops,
            terminatedSubscriptions: terminated, resynchronizationErrors: resynchronizations,
            discardedAdmittedCopies: discarded, cancelledRetainedCopies: cancelledCopies, setupCopies: setupCopies,
            measuredCopies: measured, setupOutcomes: setup,
            retainedBeforeDrain: beforeDrain, cleanup: cleanup, consumers: consumers, pullCall: statistics.pullSnapshot(), notes: [
                "Public replay events and in-process hubs only; no socket, lease validation, cache, dispatcher, provider or trusted interaction receipt is represented.",
                "gateway.publication measures caller immediately before publish through its actual return, excluding event construction, setup, consumer work and final FIFO drain. Precision is 1 microsecond over 0...100 milliseconds; censor and loss remain explicit.",
                "Queued mode prefills queuedDepth events per subscriber, then publishes and pulls one event per subscriber, maintaining independent fixed backlog. Setup copies and final FIFO drain are excluded from logical offered work.",
                "gateway.hubResidence uses the production interval for every retained copy, including setup backlog, failed eviction and cancelled teardown. Its precision is 100 microseconds over 0...10 seconds; waiting direct handoffs have no residence interval.",
                "pullCall measures actual next invocations, including setup-copy returns and final FIFO drain; waiting mode includes suspension and the driver barrier. It is not hub residence or a handler endpoint.",
                "Waiting mode creates and confirms one finite parked consumer task per subscription before each publication; task creation and barriers remain in gross duration, outside publication timing.",
                "Overflow mode holds all consumers until publication completes. Every policy retains separate publication drops, failed subscriptions, rejected copies and admitted copies discarded before consumption. dropOldest eviction is not reported as publication.dropped by the public API.",
                "Schema 2 classifies setup and measured copies separately from actual residence ends and joined pull results; cancellation after queue removal is a handoff outcome, never a discard. Unexplained copies are integrity failures.",
                "Counts partition measured subscriber copies, not publication calls; successful throughput counts eventual measured consumption. Queue byte receipts count retained envelope charges, not metadata, unique payload allocations or process memory.",
                "Gross duration includes prefill, optional injected consumer hold, driver barriers, final drain and joined shutdown. Independent hubs share one authority; per-subscription order is verified without retaining payloads."
            ])
    }

    /// Binds one queued removal to its actual iterator return or cancellation boundary.
    private static func pull(_ iterator: inout GatewayEventSubscription.AsyncIterator,
                             consumer: inout EventHubTimingConsumer, measuredStart: Int64,
                             statistics: EventHubTimingStatistics, accounting: EventHubTimingAccounting) async throws {
        accounting.beginPull()
        let clock = ContinuousClock(), start = clock.now
        let value: GatewayEvent?
        do { value = try await iterator.next() }
        catch {
            try accounting.finishPull(accepted: false, cancelled: error is CancellationError)
            throw error
        }
        guard let value else {
            try accounting.finishPull(accepted: false, cancelled: false)
            throw EventHubTimingError.integrityFailure("Queued consumer ended")
        }
        statistics.pull(start.duration(to: clock.now))
        try consumer.receive(value, measuredStart: measuredStart)
        try accounting.finishPull(accepted: true, cancelled: false)
    }

    /// Every waiting task is joined; successful values survive an interrupted driver aggregation.
    private static func acceptWaiting(_ result: Result<GatewayEvent?, any Error>, admitted: Bool,
                                      consumer: inout EventHubTimingConsumer, measuredStart: Int64,
                                      accounting: EventHubTimingAccounting) throws {
        switch result {
        case .success(let event):
            if let event {
                guard admitted else { throw EventHubTimingError.integrityFailure("Unadmitted waiting value") }
                try consumer.receive(event, measuredStart: measuredStart)
                accounting.record(.consumed, population: .measured)
            } else if admitted { throw EventHubTimingError.integrityFailure("Admitted waiting consumer ended") }
        case .failure(let error):
            if error is CancellationError, admitted { accounting.record(.cancelledHandoff, population: .measured) }
            throw error
        }
    }

}

/// Bounded independent precisions for fast publication/pull and intentionally held residence.
private final class EventHubTimingStatistics: @unchecked Sendable {
    let clockDomain = UUID().uuidString
    private let lock = NSLock()
    private var publications: [BenchmarkOutcome: BoundedHistogram]
    private var residences: [BenchmarkOutcome: BoundedHistogram]
    private var pulls: BoundedHistogram

    /// Bounds histogram storage; copy-owner evidence has its separate finite queue-slot limit.
    init() throws {
        let fast = try HistogramConfiguration(lowerBoundNanoseconds: 0, upperBoundNanoseconds: 100_000_000, bucketWidthNanoseconds: 1_000)
        let held = try HistogramConfiguration(lowerBoundNanoseconds: 0, upperBoundNanoseconds: 10_000_000_000, bucketWidthNanoseconds: 100_000)
        _ = try AggregateStatisticsBudget.validate(histograms: Array(repeating: fast, count: BenchmarkOutcome.allCases.count + 1)
            + Array(repeating: held, count: BenchmarkOutcome.allCases.count), additionalBytes: 65_536)
        publications = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, BoundedHistogram(configuration: fast)) })
        residences = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, BoundedHistogram(configuration: held)) })
        pulls = BoundedHistogram(configuration: fast)
    }
    /// Records one actual publish call, separating calls reporting a drop or terminated subscription.
    func publication(_ duration: Duration, rejected: Bool) {
        lock.lock(); defer { lock.unlock() }
        let outcome: BenchmarkOutcome = rejected ? .rejected : .success
        if let elapsed = try? BenchmarkTime.nanoseconds(duration: duration) { publications[outcome]!.record(elapsed) }
        else { publications[outcome]!.recordLoss() }
    }
    /// Preserves production interval outcomes and records invalid clock evidence as explicit loss.
    func residence(_ elapsed: Int64?, valid: Bool, outcome: DiscordIntervalOutcome) {
        lock.lock(); defer { lock.unlock() }
        let result: BenchmarkOutcome
        switch outcome { case .succeeded: result = .success; case .cancelled: result = .cancelled; case .failed: result = .failure; case .uncertain: result = .uncertain }
        if valid, let elapsed, let value = UInt64(exactly: elapsed) { residences[result]!.record(value) }
        else { residences[result]!.recordLoss() }
    }
    /// Records one completed next call, including suspension, without retaining per-call timestamps.
    func pull(_ duration: Duration) {
        lock.lock(); defer { lock.unlock() }
        if let elapsed = try? BenchmarkTime.nanoseconds(duration: duration) { pulls.record(elapsed) } else { pulls.recordLoss() }
    }
    /// Returns an atomic bounded pull distribution after the finite consumers have joined.
    func pullSnapshot() -> HistogramSnapshot { lock.lock(); defer { lock.unlock() }; return pulls.snapshot() }

    /// Exports nonempty outcome populations with one report clock identity and their original precision.
    func metrics() -> [BenchmarkMetric] {
        lock.lock(); defer { lock.unlock() }
        return [(BenchmarkWorkload.gatewayPublication, publications), (.gatewayHubResidence, residences)].flatMap { workload, populations in
            BenchmarkOutcome.allCases.compactMap { outcome in
                let snapshot = populations[outcome]!.snapshot()
                guard snapshot.observedCount > 0 || snapshot.droppedCount > 0 else { return nil }
                return BenchmarkMetric(id: workload.rawValue, outcome: outcome, clockDomain: clockDomain, distribution: snapshot)
            }
        }
    }
}
