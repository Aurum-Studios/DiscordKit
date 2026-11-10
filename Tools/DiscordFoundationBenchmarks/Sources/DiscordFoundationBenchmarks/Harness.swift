// File: Tools/DiscordFoundationBenchmarks/Sources/DiscordFoundationBenchmarks/Harness.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Crypto
import DiscordBenchmarkSupport
import Dispatch
import Foundation

struct FoundationPopulation {
    var batches: UInt64 = 0
    var calls: UInt64 = 0
    var checksum: UInt64 = 0
    var rejections: UInt64 = 0
    var successfulBatches: UInt64 = 0
    var rejectedBatches: UInt64 = 0
    var timedNanoseconds: UInt64 = 0
    var elapsedNanoseconds: UInt64 = 0
    var histogram: BoundedHistogram
}

/// Native evidence distinguishes call counts and normalized mean from batch-distribution percentiles.
struct FoundationBenchmarkResult: Codable {
    var format = "DiscordFoundationBenchmarks"
    var schemaVersion: UInt32 = 1
    let configuration: FoundationConfiguration
    let completedBatches: UInt64
    let completedCalls: UInt64
    let rejectedCalls: UInt64
    let checksum: UInt64
    let expectedChecksum: UInt64
    let warmupBatches: UInt64
    let warmupCalls: UInt64
    let normalizedMeanNanoseconds: Double
    let common: DiscordBenchmarkReport
}

enum FoundationHarness {
    /// Times fixed batches through minimal result consumption; no mid-call cancellation is promised.
    /// Injected monotonic reads permit exact boundary tests without performance assertions.
    /// - Parameters:
    ///   - configuration: Validated finite batch/time/seed settings; all calls within a batch have one outcome class.
    ///   - workload: Prepared synchronous operation; checksum/rejection consumption is included in the batch timer.
    ///   - warmup: Selects the independent warmup population; zero warmup seconds admits no batches.
    ///   - now: Monotonic nanosecond clock, defaulting to Dispatch uptime; tests inject exact observations.
    /// - Returns: Whole-population batch histogram and exact call totals, before full semantic verification.
    /// - Throws: Cancellation between batches, fixture errors, invalid clocks/counts or statistics budget errors.
    /// Runs serially without creating tasks. A started batch completes before another cancellation/deadline check.
    static func population(_ configuration: FoundationConfiguration, workload: FoundationWorkload, warmup: Bool,
        now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) throws -> FoundationPopulation {
        let histogram = try HistogramConfiguration(lowerBoundNanoseconds: 0,
            upperBoundNanoseconds: 100_000_000, bucketWidthNanoseconds: 1_000)
        _ = try AggregateStatisticsBudget.validate(histograms: [histogram], additionalBytes: 16_384)
        var result = FoundationPopulation(histogram: BoundedHistogram(configuration: histogram))
        let start = now()
        let seconds = warmup ? configuration.warmupSeconds : configuration.durationSeconds
        let cap = warmup ? (seconds == 0 ? 0 : configuration.warmupBatches) : configuration.batches
        let (deadline, overflow) = start.addingReportingOverflow(seconds * 1_000_000_000)
        guard !overflow else { throw FoundationBenchmarkError.integrityFailure("Monotonic deadline overflow") }
        for _ in 0..<cap {
            try Task.checkCancellation()
            if now() >= deadline { break }
            var checksum: UInt64 = 0, rejections: UInt64 = 0
            let batchStart = now()
            for offset in 0..<configuration.batchSize {
                let observation = try workload.operation(configuration.seed &+ result.calls &+ UInt64(offset))
                guard observation.rejections <= 1 else {
                    throw FoundationBenchmarkError.integrityFailure("Invalid per-call rejection count")
                }
                checksum &+= observation.checksum
                rejections += observation.rejections
            }
            let batchEnd = now()
            guard batchEnd >= batchStart, rejections == 0 || rejections == UInt64(configuration.batchSize) else {
                throw FoundationBenchmarkError.integrityFailure("Invalid clock or mixed batch population")
            }
            let elapsed = batchEnd - batchStart
            let (total, totalOverflow) = result.timedNanoseconds.addingReportingOverflow(elapsed)
            guard !totalOverflow else { throw FoundationBenchmarkError.integrityFailure("Timing sum overflow") }
            result.timedNanoseconds = total
            result.histogram.record(elapsed)
            result.batches += 1; result.calls += UInt64(configuration.batchSize)
            result.checksum &+= checksum; result.rejections += rejections
            if rejections == 0 { result.successfulBatches += 1 } else { result.rejectedBatches += 1 }
        }
        let end = now()
        guard end >= start else { throw FoundationBenchmarkError.integrityFailure("Regressing cohort clock") }
        result.elapsedNanoseconds = end - start
        return result
    }

    /// Runs independent warmup then measurement; full semantic checks and expected totals are untimed.
    /// - Parameters:
    ///   - configuration: Finite policy whose case ID must match the prepared workload.
    ///   - workload: Prepared local case; its full oracle runs before warmup and after measurement.
    /// - Returns: Native call accounting and validated common batch evidence, including resource scopes and fixture hash.
    /// - Throws: Configuration, cancellation, operation, semantic integrity or report errors; performs no file writes.
    /// Resource probes bracket the measured population. Verification, encoding and fixture preparation are excluded.
    static func run(_ configuration: FoundationConfiguration, workload: FoundationWorkload) throws -> FoundationBenchmarkResult {
        try configuration.validate()
        guard configuration.workload == workload.id else { throw FoundationBenchmarkError.invalidConfiguration("Case mismatch") }
        try workload.verify()
        let warmup = try population(configuration, workload: workload, warmup: true)
        _ = try verify(warmup, configuration: configuration, workload: workload)
        let before = FoundationProcessSample.capture()
        let measured = try population(configuration, workload: workload, warmup: false)
        let gauges = FoundationProcessSample.capture().gauges(since: before)
        let expected = try verify(measured, configuration: configuration, workload: workload)
        try workload.verify()
        guard measured.batches > 0, measured.elapsedNanoseconds > 0 else {
            throw FoundationBenchmarkError.integrityFailure("Empty measured population")
        }
        let fixtureHash = SHA256.hash(data: workload.fixture).map { String(format: "%02x", $0) }.joined()
        var dimensions = workload.dimensions
        dimensions["batchSize"] = UInt64(configuration.batchSize)
        dimensions["batchesCap"] = UInt64(configuration.batches)
        dimensions["warmupBatchesCap"] = UInt64(configuration.warmupBatches)
        dimensions["durationCapSeconds"] = configuration.durationSeconds
        var identity = ReportIdentity(scenario: workload.id, profile: configuration.profile, seed: configuration.seed,
            fixtureHashes: ["prepared-variants-v1": fixtureHash], inputSizes: dimensions,
            instrumentation: "external-batch", scheduler: "serial-synchronous-batches", concurrency: 1,
            warmupNanoseconds: warmup.elapsedNanoseconds, requestedWarmupNanoseconds: configuration.warmupSeconds * 1_000_000_000,
            measuredNanoseconds: measured.elapsedNanoseconds, repetitions: 1)
        identity.catalogVersion = 4
        var provenance = BenchmarkProvenance.capture()
        provenance.fixtureHashes = identity.fixtureHashes
        let domain = "foundation-monotonic"
        let outcome: BenchmarkOutcome = measured.rejectedBatches > 0 ? .rejected : .success
        let report = DiscordBenchmarkReport(identity: identity, provenance: provenance,
            adapter: "DiscordFoundationBenchmarks.v1", clockDomain: domain, status: .completed,
            counts: .init(offered: measured.batches, admitted: measured.batches, completed: measured.batches,
                outcomes: Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map {
                    ($0, $0 == .success ? measured.successfulBatches : $0 == .rejected ? measured.rejectedBatches : 0)
                }), deadlineMisses: 0),
            metrics: [.init(id: BenchmarkWorkload.pureBatch.rawValue, outcome: outcome,
                clockDomain: domain, distribution: measured.histogram.snapshot())], gauges: gauges,
            cleanup: .init(completed: true, remainingOwners: 0),
            throughputPerSecond: Double(measured.calls) * 1_000_000_000 / Double(measured.elapsedNanoseconds),
            qualificationLimitations: ["Local CPU evidence; no controlled-host noise study, numerical gate or platform qualification.",
                "Common counts and histograms represent batches; native call/rejection counts are separate. Throughput is calls per second.",
                "Normalized batch mean includes loop/checksum work and is not an individual-call percentile. No clock overhead is subtracted.",
                "Time caps and cancellation are checked between synchronous batches; a started batch finishes before its next check."])
        try report.validate()
        return FoundationBenchmarkResult(configuration: configuration, completedBatches: measured.batches,
            completedCalls: measured.calls, rejectedCalls: measured.rejections, checksum: measured.checksum,
            expectedChecksum: expected, warmupBatches: warmup.batches, warmupCalls: warmup.calls,
            normalizedMeanNanoseconds: Double(measured.timedNanoseconds) / Double(measured.calls), common: report)
    }

    /// Requires exact checksum, rejection and whole-population histogram accounting after a population stops.
    /// - Parameters:
    ///   - population: Completed warmup or measured counters; no live producer may mutate these value snapshots.
    ///   - configuration: Original seed and batch size, replayed without calling the measured operation.
    ///   - workload: Independent expected-observation oracle for every completed call index.
    /// - Returns: Expected wrapping checksum, only after all counts and histogram totals reconcile.
    /// - Throws: Integrity failure for altered/lost results, rejections or batch counts. Performs no timing or I/O.
    static func verify(_ population: FoundationPopulation, configuration: FoundationConfiguration,
        workload: FoundationWorkload) throws -> UInt64 {
        var checksum: UInt64 = 0, rejections: UInt64 = 0
        for index in 0..<population.calls {
            let value = workload.expected(configuration.seed &+ index)
            checksum &+= value.checksum; rejections += value.rejections
        }
        guard checksum == population.checksum, rejections == population.rejections,
            population.histogram.snapshot().observedCount == population.batches,
            population.successfulBatches + population.rejectedBatches == population.batches,
            population.calls == population.batches * UInt64(configuration.batchSize) else {
            throw FoundationBenchmarkError.integrityFailure("Checksum, rejection or population accounting failed")
        }
        return checksum
    }
}
