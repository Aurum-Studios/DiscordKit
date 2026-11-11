// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/ArrivalTimingRunner.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation

/// A monotonic clock shared by the scheduler and service fixture; tests advance it explicitly.
struct ArrivalTimingClock: Sendable {
    let nowNanoseconds: @Sendable () -> UInt64
    let sleepUntil: @Sendable (UInt64) async throws -> Void

    /// Uses absolute process uptime, with cancellation-aware suspension outside measured service.
    static let continuous = Self(nowNanoseconds: { DispatchTime.now().uptimeNanoseconds }, sleepUntil: { deadline in
        let now = DispatchTime.now().uptimeNanoseconds
        if deadline > now { try await Task.sleep(for: .nanoseconds(deadline - now)) }
        try Task.checkCancellation()
    })
}

/// Finite independent arrivals, with a fixed worker cohort and a separately bounded waiting queue.
struct ArrivalTimingProfile: Codable, Equatable, Sendable {
    let arrivals: Int
    let intervalNanoseconds: UInt64
    let maximumActive: Int
    let maximumPending: Int
    let measureGenerator: Bool

    /// Validates limits before the scheduler, workers or aggregate cells are created.
    init(arrivals: Int, intervalNanoseconds: UInt64, maximumActive: Int, maximumPending: Int,
        measureGenerator: Bool = false) throws {
        guard (1...100_000).contains(arrivals), intervalNanoseconds > 0,
            (1...256).contains(maximumActive), (0...1_024).contains(maximumPending),
            maximumActive + maximumPending <= 1_024,
            !UInt64(arrivals - 1).multipliedReportingOverflow(by: intervalNanoseconds).overflow else {
            throw LoadFailure.invalidArguments
        }
        self.arrivals = arrivals
        self.intervalNanoseconds = intervalNanoseconds
        self.maximumActive = maximumActive
        self.maximumPending = maximumPending
        self.measureGenerator = measureGenerator
    }

    private enum CodingKeys: String, CodingKey {
        case arrivals, intervalNanoseconds, maximumActive, maximumPending, measureGenerator
    }

    /// Reads historical profiles with generator observation disabled and validates all finite bounds.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(arrivals: container.decode(Int.self, forKey: .arrivals),
            intervalNanoseconds: container.decode(UInt64.self, forKey: .intervalNanoseconds),
            maximumActive: container.decode(Int.self, forKey: .maximumActive),
            maximumPending: container.decode(Int.self, forKey: .maximumPending),
            measureGenerator: container.decodeIfPresent(Bool.self, forKey: .measureGenerator) ?? false)
    }

    /// Revalidates decoded numeric fields before any work is started.
    func validate() throws {
        _ = try Self(arrivals: arrivals, intervalNanoseconds: intervalNanoseconds,
            maximumActive: maximumActive, maximumPending: maximumPending, measureGenerator: measureGenerator)
    }
}

/// Transient request identity and honest pre-owner submission boundary; never retained per arrival.
struct ArrivalSubmission: Sendable {
    let ordinal: Int
    let scheduledNanoseconds: UInt64
    let submittedNanoseconds: UInt64
}

/// Terminal service classification, with optional timestamps supplied by an observable service owner.
struct ArrivalOperationResult: Sendable {
    let outcome: BenchmarkOutcome
    let admittedNanoseconds: UInt64?
    let serviceStartedNanoseconds: UInt64?
    let serviceCompletedNanoseconds: UInt64?

    /// Missing admission is unavailable; the driver never substitutes submission for service admission.
    init(outcome: BenchmarkOutcome, admittedNanoseconds: UInt64? = nil,
        serviceStartedNanoseconds: UInt64? = nil, serviceCompletedNanoseconds: UInt64? = nil) {
        self.outcome = outcome
        self.admittedNanoseconds = admittedNanoseconds
        self.serviceStartedNanoseconds = serviceStartedNanoseconds
        self.serviceCompletedNanoseconds = serviceCompletedNanoseconds
    }
}

/// Constant-space timestamp evidence: individual operation records are deliberately not retained.
struct ArrivalTimestampRange: Codable, Equatable, Sendable {
    private(set) var firstNanoseconds: UInt64?
    private(set) var lastNanoseconds: UInt64?
    private(set) var count: Int = 0

    /// Retains extrema and population count without allocating one record per operation.
    mutating func include(_ value: UInt64) {
        firstNanoseconds = min(firstNanoseconds ?? value, value)
        lastNanoseconds = max(lastNanoseconds ?? value, value)
        count += 1
    }
}

/// Optional versioned generator control, measuring its own offer boundary for every scheduled slot.
struct ArrivalGeneratorMeasurement: Codable, Sendable {
    let offeredTimestamps: ArrivalTimestampRange
    let schedulerLateness: HistogramSnapshot
    let nextSlotHeadroom: HistogramSnapshot
    let lateArrivals: Int
    let noHeadroomArrivals: Int
}

/// Whole-run arrival evidence, separate from the historical closed-loop cohort format.
struct ArrivalTimingMeasurement: Codable, Sendable {
    let profile: ArrivalTimingProfile
    let clockDomain: String
    let counts: BenchmarkCounts
    let offeredArrivals: Int
    let submittedArrivals: Int
    let submittedCompletions: Int
    let unofferedArrivals: Int
    let deferredArrivals: Int
    let missedArrivals: Int
    let rejectedRequests: Int
    let cancelledBeforeSubmission: Int
    let peakActive: Int
    let peakPending: Int
    let remainingActive: Int
    let remainingPending: Int
    let maximumHarnessTasks: Int
    let invalidOperationTimestamps: Int
    let clockRegressed: Bool
    let cancelled: Bool
    let offeredWindowNanoseconds: UInt64
    let elapsedNanoseconds: UInt64
    let driverElapsedNanoseconds: UInt64
    let recoveryNanoseconds: UInt64
    let offeredPerSecond: Double
    let completedPerSecond: Double
    let successfulPerSecond: Double
    let scheduledTimestamps: ArrivalTimestampRange
    let submittedTimestamps: ArrivalTimestampRange
    let admittedTimestamps: ArrivalTimestampRange
    let serviceStartedTimestamps: ArrivalTimestampRange
    let serviceCompletedTimestamps: ArrivalTimestampRange
    let responseTimestamps: ArrivalTimestampRange
    let metrics: [BenchmarkMetric]
    let generator: ArrivalGeneratorMeasurement?
}

/// Schedules independently of completions; overload creates counts rather than more tasks or storage.
struct ArrivalTimingRunner: Sendable {
    /// Runs one scheduler and at most `maximumActive` persistent workers, then joins all ownership.
    ///
    /// The offered interval begins at the first scheduled arrival and ends at the final scheduled
    /// slot (one slot for a single arrival). Completion throughput includes post-offer drain time.
    /// Missed arrivals are rejected terminal counts without invented submission/latency observations.
    /// Queue cancellation is likewise counted without inventing a submission. A cancelled owner returns
    /// partial evidence after every worker has joined; operations must honor cooperative cancellation.
    func run(profile: ArrivalTimingProfile, clock: ArrivalTimingClock = .continuous,
        operation: @escaping @Sendable (ArrivalSubmission) async -> ArrivalOperationResult) async throws -> ArrivalTimingMeasurement {
        try profile.validate()
        let owner = try ArrivalTimingOwner(profile: profile, clockDomain: UUID().uuidString, clock: clock)
        let start = clock.nowNanoseconds()
        let span = UInt64(profile.arrivals - 1) * profile.intervalNanoseconds
        guard !start.addingReportingOverflow(span).overflow else { throw LoadFailure.invalidArguments }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<min(profile.maximumActive, profile.arrivals) {
                group.addTask {
                    var next = await owner.next()
                    while let job = next {
                        // Capture before entering the service owner or its admission/scheduling hop.
                        let submitted = clock.nowNanoseconds()
                        let submission = ArrivalSubmission(ordinal: job.ordinal,
                            scheduledNanoseconds: job.scheduled, submittedNanoseconds: submitted)
                        let serviceStart = clock.nowNanoseconds()
                        let result = await operation(submission)
                        let response = clock.nowNanoseconds()
                        next = await owner.complete(submission: submission, serviceStart: serviceStart,
                            response: response, result: result, workerCancelled: Task.isCancelled)
                    }
                }
            }
            await owner.waitForWorkers(min(profile.maximumActive, profile.arrivals))
            var interrupted = Task.isCancelled
            if !interrupted {
                for ordinal in 0..<profile.arrivals {
                    let scheduled = start + UInt64(ordinal) * profile.intervalNanoseconds
                    do {
                        try await clock.sleepUntil(scheduled)
                        try Task.checkCancellation()
                    } catch {
                        interrupted = true
                        break
                    }
                    await owner.offer(ordinal: ordinal, scheduled: scheduled)
                }
            }
            if interrupted { group.cancelAll() }
            await owner.finish(cancelled: interrupted)
            await group.waitForAll()
            if Task.isCancelled { await owner.finish(cancelled: true) }
        }
        return await owner.measurement(start: start, end: clock.nowNanoseconds())
    }
}

/// Serializes only finite driver state and statistics; there is no task or continuation per arrival.
private actor ArrivalTimingOwner {
    struct Job: Sendable { let ordinal: Int; let scheduled: UInt64 }
    private let profile: ArrivalTimingProfile
    private let clockDomain: String
    private let clock: ArrivalTimingClock
    private var generatorLateness: BoundedHistogram?
    private var generatorHeadroom: BoundedHistogram?
    private var offeredRange = ArrivalTimestampRange()
    private var lateArrivals = 0
    private var noHeadroomArrivals = 0
    private var pending: [Job] = []
    private var idle: [CheckedContinuation<Job?, Never>] = []
    private var workerReadiness: (count: Int, continuation: CheckedContinuation<Void, Never>)?
    private var populations: [String: [BenchmarkOutcome: BoundedHistogram]] = [:]
    private var outcomeCounts = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
    private var finished = false
    private var cancelled = false
    private var active = 0
    private var peakActive = 0
    private var peakPending = 0
    private var offered = 0
    private var submitted = 0
    private var deferred = 0
    private var missed = 0
    private var rejected = 0
    private var cancelledPending = 0
    private var invalidTimestamps = 0
    private var clockRegressed = false
    private var scheduledRange = ArrivalTimestampRange()
    private var submittedRange = ArrivalTimestampRange()
    private var admissionRange = ArrivalTimestampRange()
    private var serviceStartRange = ArrivalTimestampRange()
    private var serviceEndRange = ArrivalTimestampRange()
    private var responseRange = ArrivalTimestampRange()
    private static let metricIDs = ["arrival.scheduledResponse", "arrival.submittedResponse",
        "arrival.lateness", "arrival.admissionWait", "arrival.service"]

    /// Preallocates every outcome cell and checks the combined budget before measured arrivals.
    init(profile: ArrivalTimingProfile, clockDomain: String, clock: ArrivalTimingClock) throws {
        let configuration = try HistogramConfiguration(lowerBoundNanoseconds: 0,
            upperBoundNanoseconds: 1_000_000_000, bucketWidthNanoseconds: 100_000)
        try AggregateStatisticsBudget.validate(histograms: Array(repeating: configuration,
            count: Self.metricIDs.count * BenchmarkOutcome.allCases.count + (profile.measureGenerator ? 2 : 0)), additionalBytes: 131_072)
        self.profile = profile
        self.clockDomain = clockDomain
        self.clock = clock
        if profile.measureGenerator {
            generatorLateness = BoundedHistogram(configuration: configuration)
            generatorHeadroom = BoundedHistogram(configuration: configuration)
        }
        pending.reserveCapacity(profile.maximumPending)
        idle.reserveCapacity(profile.maximumActive)
        for id in Self.metricIDs {
            populations[id] = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map {
                ($0, BoundedHistogram(configuration: configuration))
            })
        }
    }

    /// Returns bounded queued work or one waiter per persistent worker.
    func next() async -> Job? {
        if !pending.isEmpty {
            let job = pending.removeFirst()
            active += 1
            peakActive = max(peakActive, active)
            return job
        }
        if finished { return nil }
        return await withCheckedContinuation {
            idle.append($0)
            if let readiness = workerReadiness, idle.count == readiness.count {
                workerReadiness = nil
                readiness.continuation.resume()
            }
        }
    }

    /// Prevents task-start scheduling from being mistaken for a full zero-capacity waiting queue.
    func waitForWorkers(_ count: Int) async {
        if idle.count == count { return }
        await withCheckedContinuation { workerReadiness = (count, $0) }
    }

    /// Counts each scheduled slot immediately, independently of service completion.
    func offer(ordinal: Int, scheduled: UInt64) {
        let observed = profile.measureGenerator ? clock.nowNanoseconds() : nil
        defer { if let observed { recordGenerator(ordinal: ordinal, scheduled: scheduled, observed: observed) } }
        offered += 1
        scheduledRange.include(scheduled)
        if finished {
            cancelledPending += 1
            outcomeCounts[.cancelled]! += 1
            return
        }
        let job = Job(ordinal: ordinal, scheduled: scheduled)
        if !idle.isEmpty {
            active += 1
            peakActive = max(peakActive, active)
            idle.removeFirst().resume(returning: job)
        } else if pending.count < profile.maximumPending {
            pending.append(job)
            deferred += 1
            peakPending = max(peakPending, pending.count)
        } else {
            missed += 1
            outcomeCounts[.rejected]! += 1
        }
    }

    /// Captures generator lateness and remaining time to the next configured slot independently of service.
    /// Headroom ends after bounded offer bookkeeping. A missed next deadline contributes zero headroom
    /// and an explicit count; unavailable negative chronology contributes histogram loss instead.
    private func recordGenerator(ordinal: Int, scheduled: UInt64, observed: UInt64) {
        offeredRange.include(observed)
        if observed >= scheduled {
            generatorLateness!.record(observed - scheduled)
            if observed > scheduled { lateArrivals += 1 }
        } else {
            clockRegressed = true
            generatorLateness!.recordLoss()
        }
        guard ordinal + 1 < profile.arrivals else { return }
        let completed = clock.nowNanoseconds()
        guard completed >= observed else {
            clockRegressed = true
            generatorHeadroom!.recordLoss()
            return
        }
        let next = scheduled + profile.intervalNanoseconds
        if completed >= next {
            noHeadroomArrivals += 1
            generatorHeadroom!.record(0)
        } else { generatorHeadroom!.record(next - completed) }
    }

    /// Captures terminal populations after the operation body has returned and released its resources.
    func complete(submission: ArrivalSubmission, serviceStart: UInt64,
        response: UInt64, result: ArrivalOperationResult, workerCancelled: Bool) async -> Job? {
        active -= 1
        submitted += 1
        outcomeCounts[result.outcome]! += 1
        if result.outcome == .rejected { rejected += 1 }
        submittedRange.include(submission.submittedNanoseconds)
        responseRange.include(response)
        record("arrival.scheduledResponse", from: submission.scheduledNanoseconds, to: response, outcome: result.outcome)
        record("arrival.submittedResponse", from: submission.submittedNanoseconds, to: response, outcome: result.outcome)
        record("arrival.lateness", from: submission.scheduledNanoseconds, to: submission.submittedNanoseconds, outcome: result.outcome)
        if let admitted = result.admittedNanoseconds {
            if admitted >= submission.submittedNanoseconds && admitted <= response {
                admissionRange.include(admitted)
                record("arrival.admissionWait", from: submission.submittedNanoseconds, to: admitted, outcome: result.outcome)
            } else {
                invalidTimestamps += 1
                populations["arrival.admissionWait"]![result.outcome]!.recordLoss()
            }
        }
        let serviceBegin = result.serviceStartedNanoseconds ?? serviceStart
        let serviceEnd = result.serviceCompletedNanoseconds ?? response
        // This frozen metric always measures the driver-invoked operation body. Optional finer
        // service-owner boundaries are retained separately and never narrow its population semantics.
        record("arrival.service", from: serviceStart, to: response, outcome: result.outcome)
        if serviceBegin >= submission.submittedNanoseconds && serviceEnd >= serviceBegin && serviceEnd <= response {
            serviceStartRange.include(serviceBegin)
            serviceEndRange.include(serviceEnd)
        } else {
            invalidTimestamps += 1
        }
        if workerCancelled { finish(cancelled: true) }
        return await next()
    }

    /// Stops replenishment and releases every idle worker; cancellation drains pending work as counts.
    func finish(cancelled: Bool) {
        finished = true
        self.cancelled = self.cancelled || cancelled
        if cancelled {
            cancelledPending += pending.count
            outcomeCounts[.cancelled]! += UInt64(pending.count)
            pending.removeAll(keepingCapacity: true)
        }
        let waiters = idle
        idle.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume(returning: nil) }
    }

    /// Builds immutable summaries after all worker tasks have been joined.
    func measurement(start: UInt64, end: UInt64) -> ArrivalTimingMeasurement {
        // Histograms and throughput share terminal service boundaries. Joining worker tasks can
        // take longer, so retain that driver interval separately; snapshots follow both endpoints.
        let finalScheduled = scheduledRange.lastNanoseconds ?? start
        let finalTerminal = max(responseRange.lastNanoseconds ?? start, finalScheduled)
        let elapsed = offered == 0 ? 0 : (finalTerminal >= start ? finalTerminal - start : 0)
        let driverElapsed = end >= start ? end - start : 0
        let offeredWindow = max(profile.intervalNanoseconds,
            scheduledRange.lastNanoseconds.map { $0 - start } ?? 0)
        let recovery = finalTerminal >= finalScheduled ? finalTerminal - finalScheduled : 0
        let metrics = Self.metricIDs.sorted().flatMap { id in
            BenchmarkOutcome.allCases.compactMap { outcome -> BenchmarkMetric? in
                let snapshot = populations[id]![outcome]!.snapshot()
                guard snapshot.observedCount > 0 || snapshot.droppedCount > 0 || snapshot.counterOverflow else { return nil }
                return BenchmarkMetric(id: id, outcome: outcome, clockDomain: clockDomain, distribution: snapshot)
            }
        }
        let counts = BenchmarkCounts(offered: UInt64(offered), admitted: UInt64(submitted),
            completed: UInt64(offered), outcomes: outcomeCounts, deadlineMisses: 0)
        return ArrivalTimingMeasurement(profile: profile, clockDomain: clockDomain, counts: counts,
            offeredArrivals: offered, submittedArrivals: submitted, submittedCompletions: submitted,
            unofferedArrivals: profile.arrivals - offered, deferredArrivals: deferred,
            missedArrivals: missed, rejectedRequests: rejected, cancelledBeforeSubmission: cancelledPending,
            peakActive: peakActive, peakPending: peakPending, remainingActive: active,
            remainingPending: pending.count, maximumHarnessTasks: min(profile.maximumActive, profile.arrivals) + 1,
            invalidOperationTimestamps: invalidTimestamps,
            clockRegressed: clockRegressed || end < start || end < finalTerminal, cancelled: cancelled,
            offeredWindowNanoseconds: offeredWindow, elapsedNanoseconds: elapsed,
            driverElapsedNanoseconds: driverElapsed, recoveryNanoseconds: recovery,
            offeredPerSecond: Double(offered) * 1_000_000_000 / Double(max(1, offeredWindow)),
            completedPerSecond: Double(submitted) * 1_000_000_000 / Double(max(1, elapsed)),
            successfulPerSecond: Double(outcomeCounts[.success]!) * 1_000_000_000 / Double(max(1, elapsed)),
            scheduledTimestamps: scheduledRange, submittedTimestamps: submittedRange,
            admittedTimestamps: admissionRange, serviceStartedTimestamps: serviceStartRange,
            serviceCompletedTimestamps: serviceEndRange, responseTimestamps: responseRange, metrics: metrics,
            generator: generatorLateness.map { lateness in ArrivalGeneratorMeasurement(offeredTimestamps: offeredRange,
                schedulerLateness: lateness.snapshot(), nextSlotHeadroom: generatorHeadroom!.snapshot(),
                lateArrivals: lateArrivals, noHeadroomArrivals: noHeadroomArrivals) })
    }

    /// Records unknown negative chronology as loss, preserving the operation's original result.
    private func record(_ id: String, from start: UInt64, to end: UInt64, outcome: BenchmarkOutcome) {
        if end >= start { populations[id]![outcome]!.record(end - start) }
        else {
            clockRegressed = true
            populations[id]![outcome]!.recordLoss()
        }
    }
}
