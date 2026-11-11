// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/OrderingHandoffTimingRunner.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordHTTP
import Foundation

/// Exact calls into the injected clock, rather than inferred executor wakeups or allocations.
struct OrderingClockReceipt: Codable, Equatable, Sendable {
    var sleepInvocations = 0
    var completedSleeps = 0
    var cancelledSleeps = 0
    var activeSleeps = 0
    var peakActiveSleeps = 0
}

/// A bounded causal sample. Return-to-entry keeps its sign when the successor wins scheduling.
struct OrderingHandoffSample: Codable, Sendable {
    let queuedCallers: Int
    let heldPartitions: Int
    let releaseOffsetFromFirstSleepNanoseconds: Int64?
    let signalToFirstSuccessorNanoseconds: UInt64
    let ownerExitToFirstSuccessorNanoseconds: UInt64
    let ownerReturnToFirstSuccessorNanoseconds: Int64
}

/// Public-API ordering evidence; no transport, rate reservation or remote authority is involved.
struct OrderingHandoffTimingReport: Codable, Sendable {
    let counts: BenchmarkCounts
    let metrics: [BenchmarkMetric]
    let clockDomain: String
    let durationNanoseconds: UInt64
    let successfulThroughputPerSecond: Double
    let releaseToSuccessor: HistogramSnapshot
    let samples: [OrderingHandoffSample]
    let omittedSamples: Int
    let completedWaves: Int
    let maximumCallerTasks: Int
    let maximumHolderTasks: Int
    let clock: OrderingClockReceipt
    let remainingOwners: Int
    let scheduling: RESTSchedulingReceipt
    let notes: [String]
}

/// Holds each selected partition before submitting a finite successor cohort.
struct OrderingHandoffTimingRunner: Sendable {
    /// Runs actual default scheduling at configurable identity/resource cardinalities.
    /// - Parameters:
    ///   - requests: Measured successors; held setup operations are excluded from counts.
    ///   - concurrency: Maximum queued successor cohort, including the one-caller control.
    ///   - partitions: Major-resource partitions per identity, bounded by default held-owner limits.
    ///   - identities: Independently ordered opaque identities.
    ///   - releaseOffsetMicroseconds: Delay after confirming the full queued cohort; actual phase is retained.
    /// - Returns: Joined full-population acquire/handoff histograms and bounded causal samples.
    /// - Throws: Invalid limits or failed public ownership-barrier checks.
    func run(requests: Int, concurrency: Int, partitions: Int, identities: Int,
             releaseOffsetMicroseconds: Int) async throws -> OrderingHandoffTimingReport {
        guard (1...100_000).contains(requests), (1...64).contains(concurrency),
            (1...8).contains(partitions), (1...64).contains(identities), partitions * identities <= 64,
            (0...10_000).contains(releaseOffsetMicroseconds) else { throw LoadFailure.invalidArguments }
        let statistics = try RunStatistics(workloads: [.restOrderWait])
        let histogramConfiguration = try HistogramConfiguration(lowerBoundNanoseconds: 0,
            upperBoundNanoseconds: 1_000_000_000, bucketWidthNanoseconds: 10_000)
        _ = try AggregateStatisticsBudget.validate(histograms: [histogramConfiguration], additionalBytes: 65_536)
        var handoff = BoundedHistogram(configuration: histogramConfiguration)
        let clockDiagnostics = OrderingClockDiagnostics()
        let clock = OrderingProbeClock(diagnostics: clockDiagnostics)
        let scopes = (0..<identities).map { _ in RateLimitIdentity() }
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        var firstSubmission: UInt64?, lastTerminal: UInt64?
        var samples: [OrderingHandoffSample] = []
        var sampleCount = 0, waves = 0, maximumCallers = 0, maximumHolders = 0, remainingOwners = 0
        for first in stride(from: 0, to: requests, by: concurrency) {
            if Task.isCancelled { break }
            let count = min(concurrency, requests - first)
            let holderCount = min(count, partitions * identities)
            let descriptors = (0..<holderCount).map { index in
                RateLimitRequest(identity: scopes[index / partitions], route: "POST /held-owner-probe",
                    majorResource: "local-\(index % partitions)")
            }
            let wave = try await runWave(descriptors: descriptors, count: count, clock: clock,
                statistics: statistics, releaseOffsetMicroseconds: releaseOffsetMicroseconds)
            maximumCallers = max(maximumCallers, count); maximumHolders = max(maximumHolders, holderCount)
            remainingOwners += wave.remainingOwners
            for result in wave.results {
                outcomes[result.outcome, default: 0] += 1
                firstSubmission = firstSubmission.map { min($0, result.submitted) } ?? result.submitted
                lastTerminal = lastTerminal.map { max($0, result.terminal) } ?? result.terminal
                if let entered = result.entered, let release = wave.releaseSignal {
                    guard entered >= release else { throw Phase5TimingError.integrityFailure("Successor preceded held-owner release") }
                    handoff.record(entered - release)
                }
            }
            sampleCount += wave.samples.count
            if samples.count < 64 { samples.append(contentsOf: wave.samples.prefix(64 - samples.count)) }
            waves += 1
        }
        let completed = outcomes.values.reduce(0, +)
        let elapsed = firstSubmission.flatMap { first in lastTerminal.map { $0 - first } } ?? 0
        let receipt = clockDiagnostics.snapshot().receipt
        guard receipt.activeSleeps == 0, remainingOwners == 0 else {
            throw Phase5TimingError.integrityFailure("Ordering probe retained runtime ownership")
        }
        return OrderingHandoffTimingReport(counts: .init(offered: completed, admitted: completed,
            completed: completed, outcomes: outcomes, deadlineMisses: outcomes[.timedOut, default: 0]),
            metrics: statistics.metrics(), clockDomain: statistics.clockDomain,
            durationNanoseconds: elapsed,
            successfulThroughputPerSecond: Double(outcomes[.success, default: 0]) * 1_000_000_000 / Double(max(1, elapsed)),
            releaseToSuccessor: handoff.snapshot(), samples: samples, omittedSamples: sampleCount - samples.count,
            completedWaves: waves, maximumCallerTasks: maximumCallers, maximumHolderTasks: maximumHolders,
            clock: receipt, remainingOwners: remainingOwners,
            scheduling: .init(policy: SchedulingPolicy(), usesDefaults: true), notes: [
                "Actual SchedulingPolicy(); public withOrdering and snapshot only. Held setup owners consume no rate quota and are excluded from measured successor counts.",
                "rest.orderWait measures immediately before withOrdering through operation entry, or the acquire error; releaseToSuccessor measures release signal through every successful successor entry, including same-partition predecessors.",
                "Each wave confirms all holders and queued successors, then delays release by the requested offset. Actual first-sleep phase is retained when a sleep exists; invocation does not prove suspension.",
                "Native handoff histogram uses 10 microsecond buckets over 0...1 second with explicit censor/loss. First 64 partition samples are diagnostic and are not a percentile population.",
                "Clock counters count actual injected sleep calls and their joined terminal results. They do not count scheduler wakeups, allocations, or all runtime tasks. Driver/timeout sleeps use a separate clock.",
                "Throughput spans first measured submission through final measured terminal, including barriers, release offsets and inter-wave setup. Process CPU includes setup, warmup and teardown.",
                "Remote authority delay/failure and real rate/reset deadlines require separate admission tests: withOrdering does not invoke RateLimitStore. No reserved-host numerical or profiler qualification is claimed."
            ])
    }

    /// Owns, cancels and joins every holder/successor even if a synchronization barrier fails.
    private func runWave(descriptors: [RateLimitRequest], count: Int, clock: OrderingProbeClock,
        statistics: RunStatistics, releaseOffsetMicroseconds: Int) async throws -> OrderingWave {
        let coordinator = RateLimitCoordinator(clock: clock, policy: SchedulingPolicy())
        let markers = OrderingWaveMarkers(count: descriptors.count)
        let releases = descriptors.map { _ in OrderingReleaseSignal() }
        let holders = descriptors.enumerated().map { index, descriptor in
            Task {
                try await coordinator.withOrdering(request: descriptor) {
                    try await releases[index].wait()
                    markers.ownerExited(index)
                }
                markers.ownerReturned(index)
            }
        }
        var callers: [Task<OrderingCallerResult, Never>] = []
        var releaseSignal: UInt64?
        clock.diagnostics.startWave()
        let initialSleepCount = clock.diagnostics.snapshot().receipt.sleepInvocations
        do {
            try await waitForOwnership(coordinator, queued: 0, held: descriptors.count)
            callers = (0..<count).map { index in
                let descriptor = descriptors[index % descriptors.count]
                return Task {
                    let submitted = DispatchTime.now().uptimeNanoseconds
                    let start = clock.now
                    var entered: UInt64?
                    let outcome: BenchmarkOutcome
                    do {
                        let admitted = try await coordinator.withOrdering(request: descriptor) {
                            let timestamp = DispatchTime.now().uptimeNanoseconds
                            let acquireDuration = start.duration(to: clock.now)
                            statistics.record(acquireDuration, workload: .restOrderWait, outcome: .success)
                            return timestamp
                        }
                        entered = admitted; outcome = .success
                    } catch {
                        let duration = start.duration(to: clock.now)
                        outcome = orderingOutcome(error)
                        statistics.record(duration, workload: .restOrderWait, outcome: outcome)
                    }
                    return OrderingCallerResult(outcome: outcome, submitted: submitted,
                        terminal: DispatchTime.now().uptimeNanoseconds, entered: entered,
                        partition: index % descriptors.count)
                }
            }
            try await waitForOwnership(coordinator, queued: count, held: descriptors.count)
            if releaseOffsetMicroseconds > 0 { try await Task.sleep(for: .microseconds(releaseOffsetMicroseconds)) }
            releaseSignal = DispatchTime.now().uptimeNanoseconds
            releases.forEach { $0.release() }
        } catch {
            holders.forEach { $0.cancel() }; callers.forEach { $0.cancel() }
            releases.forEach { $0.release() }
            await coordinator.close()
            for holder in holders { _ = await holder.result }
            for caller in callers { _ = await caller.value }
            if !(error is CancellationError) { throw error }
        }
        // On cancellation, explicitly cancel unstructured children before joining them.
        if Task.isCancelled {
            holders.forEach { $0.cancel() }; callers.forEach { $0.cancel() }
            releases.forEach { $0.release() }; await coordinator.close()
        }
        for holder in holders { _ = await holder.result }
        var results: [OrderingCallerResult] = []
        for caller in callers { results.append(await caller.value) }
        await coordinator.close()
        try await waitForClockQuiescence(clock)
        let after = await coordinator.snapshot()
        let values = markers.snapshot()
        let diagnostics = clock.diagnostics.snapshot()
        let firstSleep = diagnostics.receipt.sleepInvocations > initialSleepCount ? diagnostics.firstSleep : nil
        let samples: [OrderingHandoffSample] = descriptors.indices.compactMap { partition in
            guard let releaseSignal,
                let entered = results.filter({ $0.partition == partition }).compactMap(\.entered).min(),
                let exited = values.exits[partition], let returned = values.returns[partition] else { return nil }
            return OrderingHandoffSample(queuedCallers: count, heldPartitions: descriptors.count,
                releaseOffsetFromFirstSleepNanoseconds: firstSleep.map { Int64(releaseSignal) - Int64($0) },
                signalToFirstSuccessorNanoseconds: entered - releaseSignal,
                ownerExitToFirstSuccessorNanoseconds: entered - exited,
                ownerReturnToFirstSuccessorNanoseconds: Int64(entered) - Int64(returned))
        }
        return OrderingWave(results: results, releaseSignal: releaseSignal, samples: samples,
            remainingOwners: after.queuedCount + after.orderedOperationsCount + after.activeCount)
    }

    /// Checks a finite public ownership barrier without relying on polling implementation details.
    private func waitForOwnership(_ coordinator: RateLimitCoordinator<OrderingProbeClock>, queued: Int, held: Int) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while true {
            try Task.checkCancellation()
            let snapshot = await coordinator.snapshot()
            if snapshot.queuedCount == queued && snapshot.orderedOperationsCount == held { return }
            guard ContinuousClock().now < deadline else {
                throw Phase5TimingError.integrityFailure("Ordering ownership barrier timed out")
            }
            await Task.yield()
        }
    }

    /// Allows cancellation of the coordinator's shared clock sleep to finish after close.
    /// This bounded diagnostic barrier is outside every caller and handoff interval.
    private func waitForClockQuiescence(_ clock: OrderingProbeClock) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        await Task.yield()
        while clock.diagnostics.snapshot().receipt.activeSleeps > 0 {
            guard ContinuousClock().now < deadline else {
                throw Phase5TimingError.integrityFailure("Ordering clock remained active after close")
            }
            await Task.yield()
        }
    }
}

private struct OrderingCallerResult: Sendable {
    let outcome: BenchmarkOutcome
    let submitted: UInt64
    let terminal: UInt64
    let entered: UInt64?
    let partition: Int
}

private struct OrderingWave: Sendable {
    let results: [OrderingCallerResult]
    let releaseSignal: UInt64?
    let samples: [OrderingHandoffSample]
    let remainingOwners: Int
}

private struct OrderingReleaseSignal: Sendable {
    let stream: AsyncStream<Void>
    let continuation: AsyncStream<Void>.Continuation
    /// Creates one buffered release signal for one held setup owner.
    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream; continuation = pair.continuation
    }
    /// Suspends the owner until release, preserving cancellation as an operation failure.
    func wait() async throws {
        var iterator = stream.makeAsyncIterator()
        guard await iterator.next() != nil else { throw CancellationError() }
        try Task.checkCancellation()
    }
    /// Releases the single owner and finishes its stream; repeated release is harmless.
    func release() { continuation.yield(()); continuation.finish() }
}

private final class OrderingWaveMarkers: @unchecked Sendable {
    private let lock = NSLock()
    private var exits: [UInt64?]
    private var returns: [UInt64?]
    /// Allocates fixed marker slots for the finite held-partition cohort.
    init(count: Int) { exits = .init(repeating: nil, count: count); returns = .init(repeating: nil, count: count) }
    /// Marks the holder operation's last statement before ordering ownership is released.
    func ownerExited(_ index: Int) { lock.withLock { exits[index] = DispatchTime.now().uptimeNanoseconds } }
    /// Marks the holder caller's return after the coordinator has released ordering ownership.
    func ownerReturned(_ index: Int) { lock.withLock { returns[index] = DispatchTime.now().uptimeNanoseconds } }
    /// Copies the bounded marker arrays after every holder and successor has joined.
    func snapshot() -> (exits: [UInt64?], returns: [UInt64?]) { lock.withLock { (exits, returns) } }
}

private final class OrderingClockDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var receipt = OrderingClockReceipt()
    private var firstSleep: UInt64?
    /// Resets the wave-local sleep phase marker while preserving whole-run counters.
    func startWave() { lock.withLock { firstSleep = nil } }
    /// Counts a real clock-sleep invocation and captures the first invocation's uptime.
    func begin() {
        lock.withLock {
            receipt.sleepInvocations += 1; receipt.activeSleeps += 1
            receipt.peakActiveSleeps = max(receipt.peakActiveSleeps, receipt.activeSleeps)
            if firstSleep == nil { firstSleep = DispatchTime.now().uptimeNanoseconds }
        }
    }
    /// Records the sleep's terminal result and relinquishes its active counter.
    func end(cancelled: Bool) {
        lock.withLock {
            receipt.activeSleeps -= 1
            if cancelled { receipt.cancelledSleeps += 1 } else { receipt.completedSleeps += 1 }
        }
    }
    /// Reads all sleep counters and the current wave's first invocation under one lock.
    func snapshot() -> (receipt: OrderingClockReceipt, firstSleep: UInt64?) { lock.withLock { (receipt, firstSleep) } }
}

private struct OrderingProbeClock: Clock {
    typealias Instant = ContinuousClock.Instant
    typealias Duration = Swift.Duration
    let base = ContinuousClock()
    let diagnostics: OrderingClockDiagnostics
    /// Forwards the production monotonic clock without introducing a virtual-time policy.
    var now: Instant { base.now }
    /// Preserves the base clock's advertised minimum resolution.
    var minimumResolution: Duration { base.minimumResolution }
    /// Observes an actual sleep invocation and its joined result while forwarding its deadline.
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        diagnostics.begin()
        do { try await base.sleep(until: deadline, tolerance: tolerance); diagnostics.end(cancelled: false) }
        catch { diagnostics.end(cancelled: true); throw error }
    }
}

/// Preserves cancellation and deadline outcomes; other acquire failures remain explicit failures.
private func orderingOutcome(_ error: any Error) -> BenchmarkOutcome {
    if error is CancellationError { return .cancelled }
    if let failure = error as? RateLimitFailure, failure == .deadlineExceeded { return .timedOut }
    return .failure
}
