// File: Tools/DiscordMediaBenchmarks/Sources/DiscordMediaBenchmarks/Harness.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Crypto
import DiscordBenchmarkSupport
import Dispatch
import Foundation

struct MediaPopulation {
    var batches: UInt64 = 0
    var calls: UInt64 = 0
    var timedNanoseconds: UInt64 = 0
    var maximumBatchNanoseconds: UInt64 = 0
    var elapsedNanoseconds: UInt64 = 0
    var histogram: BoundedHistogram
}

struct MediaBenchmarkResult: Codable {
    var format = "DiscordMediaBenchmarks"
    var schemaVersion: UInt32 = 1
    let configuration: MediaConfiguration
    let completedBatches: UInt64
    let completedCalls: UInt64
    let warmupBatches: UInt64
    let warmupCalls: UInt64
    let timedNanoseconds: UInt64
    let maximumBatchNanoseconds: UInt64
    let normalizedMeanNanoseconds: Double
    let common: DiscordBenchmarkReport
}

enum MediaHarness {
    /// Fixtures, complete result oracles and awaited owner closure bracket each batch outside its timer.
    /// Cancellation and time caps are checked between bounded batches; started native calls finish.
    static func population(_ configuration: MediaConfiguration, workload: MediaCase, warmup: Bool,
        now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) async throws -> MediaPopulation {
        let histogram = try HistogramConfiguration(lowerBoundNanoseconds: 0,
            upperBoundNanoseconds: 5_000_000_000, bucketWidthNanoseconds: 10_000)
        try AggregateStatisticsBudget.validate(histograms: [histogram, histogram], additionalBytes: 131_072)
        var result = MediaPopulation(histogram: BoundedHistogram(configuration: histogram))
        let start = now()
        let seconds = warmup ? configuration.warmupSeconds : configuration.durationSeconds
        let cap = warmup ? (seconds == 0 ? 0 : configuration.warmupBatches) : configuration.batches
        let deadline = start.addingReportingOverflow(seconds * 1_000_000_000)
        guard !deadline.overflow else { throw MediaBenchmarkError.integrityFailure("Deadline overflow") }
        let sessionSeed = configuration.seed &+ (warmup ? 1 << 63 : 0)
        let session: MediaSession?
        if let factory = workload.preparePopulation, cap > 0, now() < deadline.partialValue {
            try Task.checkCancellation()
            session = try await factory(sessionSeed)
        } else { session = nil }
        do {
            for batchIndex in 0..<cap {
                try Task.checkCancellation()
                if now() >= deadline.partialValue { break }
                let seed = configuration.seed &+ UInt64(batchIndex) &+ (warmup ? 1 << 63 : 0)
                let batch: MediaBatch
                if let session { batch = try await session.prepare(configuration.batchSize, seed) }
                else { batch = try await workload.prepare(configuration.batchSize, seed) }
                do {
                    // Preparation may consume the remaining wall budget; close its owners without timing it.
                    if now() >= deadline.partialValue { await batch.close(); break }
                    let batchStart = now()
                    let completed = try await batch.run()
                    let batchEnd = now()
                    guard batchEnd >= batchStart else { throw MediaBenchmarkError.integrityFailure("Regressing batch clock") }
                    let elapsed = batchEnd - batchStart
                    try await batch.verify()
                    guard completed == UInt64(configuration.batchSize) else {
                        throw MediaBenchmarkError.integrityFailure("Completed call accounting mismatch")
                    }
                    await batch.close()
                    let sum = result.timedNanoseconds.addingReportingOverflow(elapsed)
                    guard !sum.overflow else { throw MediaBenchmarkError.integrityFailure("Timing sum overflow") }
                    result.timedNanoseconds = sum.partialValue
                    result.maximumBatchNanoseconds = max(result.maximumBatchNanoseconds, elapsed)
                    result.histogram.record(elapsed)
                    result.batches += 1; result.calls += completed
                } catch { await batch.close(); throw error }
            }
            try Task.checkCancellation()
            try await session?.verify()
            await session?.close()
        } catch { await session?.close(); throw error }
        let end = now()
        guard end >= start else { throw MediaBenchmarkError.integrityFailure("Regressing population clock") }
        result.elapsedNanoseconds = end - start
        try requirePopulation(result, configuration: configuration)
        return result
    }

    /// Reconciles exact native call totals and complete histogram batch counts after producer shutdown.
    static func requirePopulation(_ population: MediaPopulation, configuration: MediaConfiguration) throws {
        guard population.calls == population.batches * UInt64(configuration.batchSize),
            population.histogram.snapshot().observedCount == population.batches else {
            throw MediaBenchmarkError.integrityFailure("Batch/histogram population mismatch")
        }
    }

    /// Runs disjoint warmup/measurement fixtures and emits validated catalog-nine evidence after joined cleanup.
    /// The injected monotonic clock supports exact boundary tests; resource probes retain native process scope.
    static func run(_ configuration: MediaConfiguration, workload: MediaCase,
        now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) async throws -> MediaBenchmarkResult {
        try configuration.validate()
        guard workload.id == configuration.workload else { throw MediaBenchmarkError.invalidConfiguration("Case mismatch") }
        let warmup = try await population(configuration, workload: workload, warmup: true, now: now)
        let before = MediaProcessSample.capture()
        let measured = try await population(configuration, workload: workload, warmup: false, now: now)
        let gauges = MediaProcessSample.capture().gauges(since: before)
        guard measured.batches > 0, measured.elapsedNanoseconds > 0 else {
            throw MediaBenchmarkError.integrityFailure("Empty measured population")
        }
        let descriptor = Data("PUBLIC-MEDIA-FIXTURES-v1|\(workload.id)|\(configuration.seed)|\(configuration.batchSize)".utf8)
        let fixtureHash = SHA256.hash(data: descriptor).map { String(format: "%02x", $0) }.joined()
        var dimensions = workload.dimensions
        dimensions["batchSize"] = UInt64(configuration.batchSize)
        dimensions["batchesCap"] = UInt64(configuration.batches)
        dimensions["warmupBatchesCap"] = UInt64(configuration.warmupBatches)
        dimensions["durationCapSeconds"] = configuration.durationSeconds
        let scheduler = workload.dimensions["concurrentJobsPerCall"] == 2 ? "joined-concurrent-transition-media-batches-v4"
            : workload.id == "dave.transition.queue" ? "joined-concurrent-signaling-batches"
            : workload.preparePopulation == nil ? "serial-wrapper-batches"
            : workload.dimensions["fixtureVersion"] == 4 ? "serial-population-stream-v4"
            : workload.dimensions["fixtureVersion"] == 3 ? "serial-population-stream-v3" : "serial-population-stream-v2"
        var identity = ReportIdentity(scenario: workload.id, profile: configuration.profile, seed: configuration.seed,
            fixtureHashes: ["public-fixture-descriptor-v1": fixtureHash], inputSizes: dimensions,
            instrumentation: "external-prepared-batch", scheduler: scheduler,
            concurrency: workload.id == "dave.transition.queue" ? UInt32(configuration.batchSize)
                : workload.dimensions["concurrentJobsPerCall"] == 2 ? 2 : 1,
            warmupNanoseconds: warmup.elapsedNanoseconds,
            requestedWarmupNanoseconds: configuration.warmupSeconds * 1_000_000_000,
            measuredNanoseconds: measured.elapsedNanoseconds, repetitions: 1)
        identity.catalogVersion = 9
        var provenance = BenchmarkProvenance.capture(); provenance.fixtureHashes = identity.fixtureHashes
        let domain = "media-monotonic"
        let common = DiscordBenchmarkReport(identity: identity, provenance: provenance,
            adapter: "DiscordMediaBenchmarks.v1", clockDomain: domain, status: .completed,
            counts: .init(offered: measured.batches, admitted: measured.batches, completed: measured.batches,
                outcomes: Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, $0 == .success ? measured.batches : 0) }),
                deadlineMisses: 0), metrics: [.init(id: workload.transition ? BenchmarkWorkload.mlsTransition.rawValue : BenchmarkWorkload.mediaBatch.rawValue,
                    clockDomain: domain, distribution: measured.histogram.snapshot())], gauges: gauges,
            cleanup: .init(completed: true, remainingOwners: 0),
            throughputPerSecond: Double(measured.calls) * 1_000_000_000 / Double(measured.elapsedNanoseconds),
            qualificationLimitations: [
                "Local external wrapper/batch evidence; no live Discord, devices, network or realtime guarantee.",
                "Histogram/count populations are batches. Native call totals and normalized means do not establish individual-call percentiles.",
                "Batch timers include wrapper invocation, actor hops, bounded result retention and loop overhead; no clock overhead is subtracted.",
                "Fixture preparation, complete semantic verification and joined closure are excluded from batch timers; population elapsed time and throughput include them.",
                "Fixed public signing/symmetric inputs have no confidentiality value. MLS uses real native random HPKE/epoch entropy; the fixture hash identifies inputs, not random key bytes.",
                "Cryptographic timings establish no security property or independent implementation qualification.",
                "DAVE queue cases include bounded concurrent caller scheduling and signaling admission; this does not isolate queue residence or guarantee a particular observed depth.",
                "CELT recover selects documented PLC fallback. SILK/hybrid request in-band FEC; timing does not establish provider interoperability or recovered signal quality.",
                "Version-two continuous cases keep one prefilled owner across each population; warmup and measurement use independent owners. Legacy cases retain per-batch/call reset semantics.",
                "Version-three resampler endpoints separate constructor, continuous process and finish costs. PCM queue occupancy cases rotate a full FIFO with two public actor hops per call; neither workload is paced.",
                "Version-four DAVE populations prefill the selected complete replay window. Reorder/duplicate and authentication-failure policies include their documented multiple opens per wrapper; generation-expiry endpoints use independently prefilled owners and include one expiry plus authentication per call.",
                "Version-four MLS wrappers time commit preparation and all-peer acceptance on bounded dense/sparse trees with real entropy. Cached proposal admission and full exporter/authenticator/revocation checks are untimed. Mixed cases join independent DAVE media/control service and do not isolate queue residence, secure-ready or manager installation.",
                "Time caps and cancellation apply between started bounded batches. Microbenchmarks have no scheduled playout deadlines; deadlineMisses zero describes this unscheduled population."
            ])
        try common.validate()
        return MediaBenchmarkResult(configuration: configuration, completedBatches: measured.batches,
            completedCalls: measured.calls, warmupBatches: warmup.batches, warmupCalls: warmup.calls,
            timedNanoseconds: measured.timedNanoseconds, maximumBatchNanoseconds: measured.maximumBatchNanoseconds,
            normalizedMeanNanoseconds: Double(measured.timedNanoseconds) / Double(measured.calls), common: common)
    }
}
