// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/ArrivalTimingRunnerTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

@testable import DiscordKitLoadTests
import DiscordBenchmarkSupport
import Foundation
import Testing

/// Independent scheduled arrivals, deterministic overload and joined cancellation without timing sleeps.
@Suite("Bounded arrival timing")
struct ArrivalTimingRunnerTests {
    /// Saturation cannot create more workers/backlog, and later arrivals recover after the queue drains.
    @Test func independentScheduleSaturationAndRecovery() async throws {
        let time = ManualArrivalTime()
        let service = ArrivalServiceGate()
        let profile = try ArrivalTimingProfile(arrivals: 7, intervalNanoseconds: 1_000_000,
            maximumActive: 1, maximumPending: 1)
        let task = Task { try await ArrivalTimingRunner().run(profile: profile, clock: time.clock) {
            await service.perform($0)
        } }
        var ticks = time.requests.makeAsyncIterator()
        var entries = service.entries.makeAsyncIterator()
        #expect(await ticks.next() == 0)
        #expect(await ticks.next() == 1_000_000)
        #expect(await entries.next() == 0)
        // One queued arrival then four missed slots while the first operation remains suspended.
        for tick in 1...5 {
            time.advance(to: UInt64(tick) * 1_000_000)
            #expect(await ticks.next() == UInt64(tick + 1) * 1_000_000)
        }
        await service.release(0)
        #expect(await entries.next() == 1)
        await service.release(1)
        // The scheduler is still awaiting the final independently scheduled slot.
        time.advance(to: 6_000_000)
        #expect(await entries.next() == 6)
        time.advance(to: 7_000_000)
        await service.release(6)
        let result = try await task.value
        #expect(result.offeredArrivals == 7)
        #expect(result.submittedArrivals == 3)
        #expect(result.submittedCompletions == 3)
        // The final slot may briefly queue while the already released second operation joins.
        #expect((1...2).contains(result.deferredArrivals))
        #expect(result.missedArrivals == 4)
        #expect(result.counts.outcomes[.rejected] == 4)
        #expect(result.counts.outcomes[.success] == 3)
        #expect(result.peakActive == 1)
        #expect(result.peakPending == 1)
        #expect(result.maximumHarnessTasks == 2)
        #expect(result.remainingActive == 0)
        #expect(result.remainingPending == 0)
        #expect(await service.liveCount() == 0)
        #expect(result.recoveryNanoseconds == 1_000_000)
        #expect(result.scheduledTimestamps.count == 7)
        #expect(result.submittedTimestamps.count == 3)
        #expect(result.admittedTimestamps.count == 0)
        #expect(result.responseTimestamps.count == 3)
        #expect(result.offeredPerSecond == 7.0 * 1_000_000_000 / 6_000_000)
        #expect(result.completedPerSecond == 3.0 * 1_000_000_000 / 7_000_000)
        #expect(metric(result, "arrival.scheduledResponse")?.distribution.observedCount == 3)
        #expect(metric(result, "arrival.scheduledResponse")?.distribution.maxInRangeNanoseconds == 5_000_000)
        #expect(metric(result, "arrival.submittedResponse")?.distribution.maxInRangeNanoseconds == 5_000_000)
        #expect(metric(result, "arrival.lateness")?.distribution.maxInRangeNanoseconds == 4_000_000)
        #expect(metric(result, "arrival.service")?.distribution.observedCount == 3)
        try result.counts.validate()
        _ = try JSONDecoder().decode(ArrivalTimingMeasurement.self, from: JSONEncoder().encode(result))
    }

    /// Cancellation while scheduling releases queued ownership and returns terminal partial counts.
    @Test func cancellationDuringSchedule() async throws {
        let time = ManualArrivalTime()
        let service = ArrivalServiceGate()
        let profile = try ArrivalTimingProfile(arrivals: 4, intervalNanoseconds: 1_000,
            maximumActive: 1, maximumPending: 1)
        let task = Task { try await ArrivalTimingRunner().run(profile: profile, clock: time.clock) {
            await service.perform($0)
        } }
        var ticks = time.requests.makeAsyncIterator()
        var entries = service.entries.makeAsyncIterator()
        _ = await ticks.next()
        #expect(await ticks.next() == 1_000)
        #expect(await entries.next() == 0)
        time.advance(to: 1_000)
        #expect(await ticks.next() == 2_000)
        task.cancel()
        let result = try await task.value
        #expect(result.cancelled)
        #expect(result.offeredArrivals == 2)
        #expect(result.unofferedArrivals == 2)
        #expect(result.submittedArrivals == 1)
        #expect(result.cancelledBeforeSubmission == 1)
        #expect(result.counts.outcomes[.cancelled] == 2)
        #expect(result.remainingActive == 0)
        #expect(result.remainingPending == 0)
        #expect(await service.liveCount() == 0)
        #expect(metric(result, "arrival.scheduledResponse", outcome: .cancelled)?.distribution.observedCount == 1)
        try result.counts.validate()
    }

    /// A cancellation during post-offer draining remains marked after the complete cohort joins.
    @Test func cancellationDuringDrain() async throws {
        let time = ManualArrivalTime()
        let service = ArrivalServiceGate()
        let profile = try ArrivalTimingProfile(arrivals: 1, intervalNanoseconds: 1,
            maximumActive: 1, maximumPending: 0)
        let task = Task { try await ArrivalTimingRunner().run(profile: profile, clock: time.clock) {
            await service.perform($0)
        } }
        var entries = service.entries.makeAsyncIterator()
        #expect(await entries.next() == 0)
        task.cancel()
        let result = try await task.value
        #expect(result.cancelled)
        #expect(result.counts.outcomes[.cancelled] == 1)
        #expect(result.remainingActive == 0)
        #expect(result.remainingPending == 0)
        #expect(await service.liveCount() == 0)
    }

    /// Already-cancelled owners offer no arrivals and still release their fixed worker continuations.
    @Test func cancellationBeforeScheduling() async throws {
        let time = ManualArrivalTime()
        let profile = try ArrivalTimingProfile(arrivals: 4, intervalNanoseconds: 1,
            maximumActive: 2, maximumPending: 2)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ArrivalTimingRunner().run(profile: profile, clock: time.clock) { _ in
                Issue.record("Pre-cancelled driver invoked service")
                return ArrivalOperationResult(outcome: .failure)
            }
        }
        let result = try await task.value
        #expect(result.cancelled)
        #expect(result.offeredArrivals == 0)
        #expect(result.unofferedArrivals == 4)
        #expect(result.counts.completed == 0)
        #expect(result.remainingActive == 0)
        #expect(result.remainingPending == 0)
        #expect(result.metrics.isEmpty)
        try result.counts.validate()
    }

    /// A broken injected clock records loss and an explicit regression flag, never a qualified zero.
    @Test func clockRegressionIsExplicit() async throws {
        let time = RegressingArrivalTime()
        let profile = try ArrivalTimingProfile(arrivals: 1, intervalNanoseconds: 1,
            maximumActive: 1, maximumPending: 0)
        let result = try await ArrivalTimingRunner().run(profile: profile,
            clock: ArrivalTimingClock(nowNanoseconds: { time.now() }, sleepUntil: { _ in })) { _ in
                time.regress()
                return ArrivalOperationResult(outcome: .success)
            }
        #expect(result.clockRegressed)
        #expect(result.counts.outcomes[.success] == 1)
        #expect(metric(result, "arrival.scheduledResponse")?.distribution.droppedCount == 1)
        #expect(metric(result, "arrival.submittedResponse")?.distribution.droppedCount == 1)
        #expect(metric(result, "arrival.service")?.distribution.droppedCount == 1)
    }

    /// Throughput and recovery stop at the last observed terminal, before post-response driver joins.
    @Test func throughputEndsAtObservedResponse() async throws {
        let time = ArrivalBoundaryClock(timestamps: [0, 0, 0, 100, 1_000])
        let profile = try ArrivalTimingProfile(arrivals: 1, intervalNanoseconds: 10,
            maximumActive: 1, maximumPending: 0)
        let result = try await ArrivalTimingRunner().run(profile: profile,
            clock: ArrivalTimingClock(nowNanoseconds: { time.now() }, sleepUntil: { _ in })) { _ in
                ArrivalOperationResult(outcome: .success)
            }
        #expect(result.elapsedNanoseconds == 100)
        #expect(result.driverElapsedNanoseconds == 1_000)
        #expect(result.recoveryNanoseconds == 100)
        #expect(result.completedPerSecond == 10_000_000)
        #expect(result.successfulPerSecond == 10_000_000)
        #expect(!result.clockRegressed)
        #expect(metric(result, "arrival.scheduledResponse")?.distribution.maxInRangeNanoseconds == 100)
    }

    /// Every service terminal category contributes to all required full-population histograms.
    @Test func outcomePopulationsAndObservableAdmission() async throws {
        let time = ManualArrivalTime(automaticallyAdvance: true)
        let profile = try ArrivalTimingProfile(arrivals: 12, intervalNanoseconds: 10_000,
            maximumActive: 2, maximumPending: 12)
        let result = try await ArrivalTimingRunner().run(profile: profile, clock: time.clock) { submission in
            let now = time.now()
            return ArrivalOperationResult(outcome: BenchmarkOutcome.allCases[submission.ordinal % 6],
                admittedNanoseconds: now, serviceStartedNanoseconds: now, serviceCompletedNanoseconds: now)
        }
        #expect(result.missedArrivals == 0)
        #expect(result.counts.completed == 12)
        #expect(result.admittedTimestamps.count == 12)
        #expect(result.serviceStartedTimestamps.count == 12)
        #expect(result.invalidOperationTimestamps == 0)
        for outcome in BenchmarkOutcome.allCases {
            #expect(result.counts.outcomes[outcome] == 2)
            for id in ["arrival.scheduledResponse", "arrival.submittedResponse", "arrival.lateness",
                "arrival.admissionWait", "arrival.service"] {
                #expect(metric(result, id, outcome: outcome)?.distribution.observedCount == 2)
            }
        }
        #expect(result.rejectedRequests == 2)
        #expect(result.peakActive <= 2)
        #expect(result.peakPending <= 12)
        try result.counts.validate()
    }

    /// Invalid optional boundaries degrade evidence while preserving the fixture's actual outcome.
    @Test func invalidBoundariesAndLimits() async throws {
        let time = ManualArrivalTime(automaticallyAdvance: true)
        let profile = try ArrivalTimingProfile(arrivals: 1, intervalNanoseconds: 1,
            maximumActive: 1, maximumPending: 0)
        let result = try await ArrivalTimingRunner().run(profile: profile, clock: time.clock) { _ in
            ArrivalOperationResult(outcome: .uncertain, admittedNanoseconds: .max,
                serviceStartedNanoseconds: .max, serviceCompletedNanoseconds: 0)
        }
        #expect(result.invalidOperationTimestamps == 2)
        #expect(result.counts.outcomes[.uncertain] == 1)
        #expect(result.admittedTimestamps.count == 0)
        #expect(metric(result, "arrival.service", outcome: .uncertain)?.distribution.observedCount == 1)
        #expect(metric(result, "arrival.service", outcome: .uncertain)?.distribution.droppedCount == 0)
        #expect(metric(result, "arrival.admissionWait", outcome: .uncertain)?.distribution.droppedCount == 1)
        for values in [(0, UInt64(1), 1, 0), (1, 0, 1, 0), (1, 1, 257, 0),
            (1, 1, 256, 769), (1, 1, 1, -1), (3, UInt64.max, 1, 0)] {
            #expect(throws: LoadFailure.invalidArguments) {
                try ArrivalTimingProfile(arrivals: values.0, intervalNanoseconds: values.1,
                    maximumActive: values.2, maximumPending: values.3)
            }
        }
    }

    /// Historical profile JSON retains the original disabled generator observation policy.
    @Test func legacyProfileDecode() throws {
        let data = Data("{\"arrivals\":3,\"intervalNanoseconds\":100,\"maximumActive\":1,\"maximumPending\":2}".utf8)
        let profile = try JSONDecoder().decode(ArrivalTimingProfile.self, from: data)
        #expect(!profile.measureGenerator)
        #expect(profile.arrivals == 3)
    }

    /// A late driver clock exposes generator deadline pressure separately from service/queue lateness.
    @Test func noOpGeneratorControlRetainsLatenessAndHeadroom() async throws {
        let time = ManualArrivalTime()
        let profile = try ArrivalTimingProfile(arrivals: 3, intervalNanoseconds: 100,
            maximumActive: 1, maximumPending: 2, measureGenerator: true)
        let task = Task { try await ArrivalTimingRunner().run(profile: profile, clock: time.clock) { _ in
            let now = time.now()
            return ArrivalOperationResult(outcome: .success, admittedNanoseconds: now,
                serviceStartedNanoseconds: now, serviceCompletedNanoseconds: now)
        } }
        var ticks = time.requests.makeAsyncIterator()
        #expect(await ticks.next() == 0)
        #expect(await ticks.next() == 100)
        time.advance(to: 250)
        #expect(await ticks.next() == 200)
        let result = try await task.value
        let generator = try #require(result.generator)
        #expect(generator.offeredTimestamps.count == 3)
        #expect(generator.schedulerLateness.observedCount == 3)
        #expect(generator.schedulerLateness.maxInRangeNanoseconds == 150)
        #expect(generator.nextSlotHeadroom.observedCount == 2)
        #expect(generator.nextSlotHeadroom.maxInRangeNanoseconds == 100)
        #expect(generator.lateArrivals == 2)
        #expect(generator.noHeadroomArrivals == 1)
        #expect(result.offeredArrivals == 3 && result.submittedArrivals == 3)
        #expect(result.missedArrivals == 0 && result.rejectedRequests == 0)
        #expect(result.admittedTimestamps.count == 3)
        #expect(result.remainingActive == 0 && result.remainingPending == 0)
        #expect(!result.clockRegressed)
        _ = try JSONDecoder().decode(ArrivalTimingMeasurement.self, from: JSONEncoder().encode(result))
    }

    /// Finds one finite identity/outcome without merging populations or averaging their quantiles.
    private func metric(_ result: ArrivalTimingMeasurement, _ id: String,
        outcome: BenchmarkOutcome = .success) -> BenchmarkMetric? {
        result.metrics.first { $0.id == id && $0.outcome == outcome }
    }
}

/// A manual monotonic clock with one scheduler waiter and explicit request-event synchronization.
private final class ManualArrivalTime: @unchecked Sendable {
    let requests: AsyncStream<UInt64>
    private let requestEvents: AsyncStream<UInt64>.Continuation
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var waiter: (id: UUID, deadline: UInt64, continuation: CheckedContinuation<Void, any Error>)?
    private var cancelled: Set<UUID> = []
    private let automaticallyAdvance: Bool

    /// Automatic mode advances only at scheduler boundaries; manual mode awaits explicit test advancement.
    init(automaticallyAdvance: Bool = false) {
        let stream = AsyncStream<UInt64>.makeStream()
        requests = stream.stream
        requestEvents = stream.continuation
        self.automaticallyAdvance = automaticallyAdvance
    }

    /// Supplies cancellation-aware test suspension and synchronous monotonic reads in one clock domain.
    var clock: ArrivalTimingClock {
        ArrivalTimingClock(nowNanoseconds: { self.now() }, sleepUntil: { try await self.sleep(until: $0) })
    }

    /// Provides the synchronous timestamp needed before any owner actor hop.
    func now() -> UInt64 { lock.withLock { value } }

    /// Advances time and resumes only a scheduler whose absolute deadline has become due.
    func advance(to instant: UInt64) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            precondition(instant >= value)
            value = instant
            guard let current = waiter, current.deadline <= value else { return nil }
            waiter = nil
            return current.continuation
        }
        continuation?.resume()
    }

    /// Publishes a synchronization event after registering the scheduler's cancellation-aware waiter.
    private func sleep(until deadline: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate = lock.withLock { () -> Bool in
                    if cancelled.remove(id) != nil { return true }
                    if automaticallyAdvance { value = max(value, deadline) }
                    if value >= deadline { return true }
                    precondition(waiter == nil)
                    waiter = (id, deadline, continuation)
                    return false
                }
                requestEvents.yield(deadline)
                if immediate { continuation.resume() }
            }
            try Task.checkCancellation()
        } onCancel: {
            let continuation = self.lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                guard let current = self.waiter, current.id == id else {
                    self.cancelled.insert(id)
                    return nil
                }
                self.waiter = nil
                return current.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

/// A bounded service owner whose resource release is observable and cancellation-aware.
private actor ArrivalServiceGate {
    nonisolated let entries: AsyncStream<Int>
    private let entryEvents: AsyncStream<Int>.Continuation
    private var releases: [Int: AsyncStream<Void>.Continuation] = [:]

    /// Creates synchronization streams without starting any service tasks.
    init() {
        let stream = AsyncStream<Int>.makeStream()
        entries = stream.stream
        entryEvents = stream.continuation
    }

    /// Retains one resource until the test releases it or the owning worker is cancelled.
    func perform(_ submission: ArrivalSubmission) async -> ArrivalOperationResult {
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        releases[submission.ordinal] = signal.continuation
        entryEvents.yield(submission.ordinal)
        await withTaskCancellationHandler {
            var iterator = signal.stream.makeAsyncIterator()
            _ = await iterator.next()
        } onCancel: { signal.continuation.finish() }
        releases.removeValue(forKey: submission.ordinal)
        signal.continuation.finish()
        return ArrivalOperationResult(outcome: Task.isCancelled ? .cancelled : .success)
    }

    /// Releases exactly the named resource; a missing ordinal is a test sequencing error.
    func release(_ ordinal: Int) { releases.removeValue(forKey: ordinal)!.yield(()) }

    /// Returns post-join ownership to prove cleanup rather than infer it from completion counts.
    func liveCount() -> Int { releases.count }
}

/// Deliberately violates the clock contract to exercise evidence degradation without a timer sleep.
private final class RegressingArrivalTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 100

    /// Reads the timestamp synchronously at the same pre-owner boundary as the real clock.
    func now() -> UInt64 { lock.withLock { value } }

    /// Injects a backwards clock after submission, preserving the operation's successful result.
    func regress() { lock.withLock { value = 0 } }
}

/// Supplies exact start/submission/service/response/driver-end reads to distinguish terminal and join boundaries.
private final class ArrivalBoundaryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var timestamps: [UInt64]

    /// Stores a tiny fixed read script, independent of any real scheduler timing.
    init(timestamps: [UInt64]) { self.timestamps = timestamps }

    /// Returns the next declared boundary; extra reads indicate changed endpoint semantics.
    func now() -> UInt64 {
        lock.withLock {
            precondition(!timestamps.isEmpty)
            return timestamps.removeFirst()
        }
    }
}
