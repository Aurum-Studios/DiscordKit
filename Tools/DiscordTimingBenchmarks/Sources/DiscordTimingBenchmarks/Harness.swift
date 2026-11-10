// File: Tools/DiscordTimingBenchmarks/Sources/DiscordTimingBenchmarks/Harness.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordLogging
import DiscordLogHandlers
import Dispatch
import Foundation

/// A joined worker's whole-population distribution and observable deterministic result.
struct TimingWorkerResult: Sendable {
    let worker: Int
    let count: UInt64
    let checksum: UInt64
    let histogram: BoundedHistogram
}

/// Native v1 evidence preserves per-mode adapter counters in addition to the common envelope.
struct TimingBenchmarkResult: Codable, Sendable {
    var format = "DiscordTimingBenchmarks"
    var schemaVersion: UInt32 = 1
    let configuration: TimingConfiguration
    let completedOperations: UInt64
    let checksum: UInt64
    let expectedChecksum: UInt64
    let warmupOperations: UInt64
    let warmupNanoseconds: UInt64
    let measuredNanoseconds: UInt64
    let flushNanoseconds: UInt64
    let outputCounters: [String: UInt64]
    let common: DiscordBenchmarkReport
}

/// Finite, whole-population instrumentation workload with explicit warmup and joined output ownership.
enum TimingHarness {
    static let fixtureHash = "8d7524e535557da2a0cd19b35883a70b9383e48446f9d48216b6b15faf7cd66b"

    /// Executes reproducible observable integer work outside pure runtime kernels.
    /// - Parameter seed: Run seed mixed with worker/iteration indices; all UInt64 values are valid.
    /// - Returns: Wrapping rotate/multiply checksum over exactly 64 fixed lanes.
    ///   Inlining is disabled so an optimizing caller cannot precompute an entire repeated loop.
    @inline(never) static func fixture(_ seed: UInt64) -> UInt64 {
        var value = seed
        for lane in UInt64(0)..<64 {
            value ^= lane
            value = (value << 13) | (value >> 51)
            value = value &* 6_364_136_223_846_793_005
        }
        return value
    }

    /// Derives an operation input without allocating strings, collections or persistent identities.
    /// - Parameters:
    ///   - configuration: Recorded run seed and fixed mode.
    ///   - worker: Bounded worker index in `0..<concurrency`.
    ///   - index: Operation index in `0..<iterations` for that worker.
    /// - Returns: Stable deterministic input shared by measurement and post-measurement verification.
    static func input(_ configuration: TimingConfiguration, worker: Int, index: UInt64) -> UInt64 {
        configuration.seed ^ (UInt64(worker) << 32) ^ index
    }

    /// Executes one real optional lifecycle around the CPU fixture or a separate filtered diagnostic scope.
    /// - Parameters:
    ///   - configuration: Fixed mode selected before measurement.
    ///   - outputs: Application-owned sinks; nil interval mode performs no hook clock/callback work.
    ///   - seed: Observable fixture input.
    /// - Returns: Deterministic work result; empty-harness control returns its unchanged input.
    static func operation(_ configuration: TimingConfiguration, outputs: TimingOutputs, seed: UInt64) -> UInt64 {
        if configuration.mode == .emptyHarness { return seed }
        if configuration.mode == .clockRead {
            let observed = DispatchTime.now().uptimeNanoseconds
            precondition(observed > 0, "Monotonic clock unavailable")
            return fixture(seed)
        }
        if configuration.mode == .filtered {
            return DiscordLog.withOperation("timing.benchmark", event: "fixture", operation: { fixture(seed) })
        }
        let interval = outputs.timing?.begin(.rest, stage: .operation, parent: nil)
        let result = fixture(seed)
        interval?.end()
        return result
    }

    /// Runs one bounded cohort; worker task count equals concurrency and never follows operation count.
    /// - Parameters:
    ///   - configuration: Validated finite workload.
    ///   - outputs: Ready-to-use outputs, separately owned by this population.
    ///   - warmup: Selects warmup iteration/time caps; false selects measured work.
    /// - Returns: Joined per-worker exact counts, distributions, wall time and process gauges.
    /// - Throws: REST fixture, cancellation, histogram budget or integrity failures; existing child tasks are joined.
    private static func population(_ configuration: TimingConfiguration, outputs: TimingOutputs, warmup: Bool) async throws
        -> (workers: [TimingWorkerResult], elapsed: UInt64, gauges: [String: BenchmarkGauge]) {
        let histogramConfiguration = try HistogramConfiguration(lowerBoundNanoseconds: 0,
            upperBoundNanoseconds: 2_000_000, bucketWidthNanoseconds: 100)
        _ = try AggregateStatisticsBudget.validate(
            histograms: Array(repeating: histogramConfiguration, count: configuration.concurrency + 1), additionalBytes: 65_536)
        let histograms = (0..<configuration.concurrency).map { _ in BoundedHistogram(configuration: histogramConfiguration) }
        let rest = try configuration.mode.usesREST ? (0..<configuration.concurrency).map { _ in
            try TimingRESTFixture(timing: outputs.scalar)
        } : []
        let iterations = warmup ? (configuration.warmupSeconds == 0 ? 0 : configuration.warmupIterations) : configuration.iterations
        let duration = warmup ? configuration.warmupSeconds : configuration.durationSeconds
        let before = TimingProcessSample.capture()
        let clock = ContinuousClock(), started = ContinuousClock.now
        let deadline = started.advanced(by: .seconds(Int64(duration)))
        var workers: [TimingWorkerResult] = []
        do {
            workers = try await DiscordLog.$loggerFactory.withValue({ _ in outputs.logger }) {
                try await withThrowingTaskGroup(of: TimingWorkerResult.self) { group in
                    for worker in 0..<configuration.concurrency {
                        group.addTask {
                            var histogram = histograms[worker]
                            var checksum: UInt64 = 0, count: UInt64 = 0
                            for index in 0..<iterations {
                                try Task.checkCancellation()
                                if clock.now >= deadline { break }
                                let seed = input(configuration, worker: worker, index: UInt64(index))
                                let start = DispatchTime.now().uptimeNanoseconds
                                let value: UInt64
                                if configuration.mode.usesREST {
                                    let status = try await rest[worker].client.execute(rest[worker].endpoint)
                                    guard status == 204 else { throw TimingBenchmarkError.integrityFailure("Invalid REST result") }
                                    value = fixture(seed)
                                } else { value = operation(configuration, outputs: outputs, seed: seed) }
                                let end = DispatchTime.now().uptimeNanoseconds
                                guard end >= start else { throw TimingBenchmarkError.integrityFailure("Regressing measurement clock") }
                                histogram.record(end - start)
                                checksum &+= value
                                count += 1
                            }
                            return TimingWorkerResult(worker: worker, count: count, checksum: checksum, histogram: histogram)
                        }
                    }
                    var result: [TimingWorkerResult] = []
                    for try await worker in group { result.append(worker) }
                    return result
                }
            }
        } catch {
            for fixture in rest { _ = await fixture.close() }
            throw error
        }
        let elapsed = try BenchmarkTime.nanoseconds(duration: started.duration(to: clock.now))
        let gauges = TimingProcessSample.capture().gauges(since: before)
        for worker in workers where configuration.mode.usesREST {
            guard rest[worker.worker].transport.snapshot() == worker.count else {
                for fixture in rest { _ = await fixture.close() }
                throw TimingBenchmarkError.integrityFailure("Unexpected transport request count")
            }
        }
        var remaining: UInt64 = 0
        for fixture in rest { remaining += await fixture.close() }
        guard remaining == 0 else { throw TimingBenchmarkError.integrityFailure("REST owners remain active") }
        return (workers, elapsed, gauges)
    }

    /// Verifies all measured work and adapter accounting, then writes no files except explicitly owned output artifacts.
    /// - Parameter configuration: Validated finite mode and optional artifact directory; warmup outputs never share measured state.
    /// - Returns: Native and common evidence with gross full-population operation latency and independent flush time.
    /// - Throws: Invalid configuration, incomplete result accounting, adapter flush/export or bounded statistics errors.
    static func run(_ configuration: TimingConfiguration) async throws -> TimingBenchmarkResult {
        try configuration.validate()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let warmDirectory = directory.appendingPathComponent("warmup")
        try FileManager.default.createDirectory(at: warmDirectory, withIntermediateDirectories: true)
        let warmOutputs = try TimingOutputs(configuration: configuration, directory: warmDirectory)
        let warmup: (workers: [TimingWorkerResult], elapsed: UInt64, gauges: [String: BenchmarkGauge])
        do {
            warmup = try await population(configuration, outputs: warmOutputs, warmup: true)
            _ = try warmOutputs.close(exportDirectory: nil)
        } catch {
            _ = try? warmOutputs.close(exportDirectory: nil)
            throw error
        }
        let measuredDirectory = configuration.artifactDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? directory.appendingPathComponent("measured")
        // Caller destinations must be new: repeated runs cannot append to or replace another run's output.
        guard !FileManager.default.fileExists(atPath: measuredDirectory.path) else {
            throw TimingBenchmarkError.invalidConfiguration("Artifact directory already exists")
        }
        try FileManager.default.createDirectory(at: measuredDirectory, withIntermediateDirectories: true)
        let outputs = try TimingOutputs(configuration: configuration, directory: measuredDirectory)
        let measured: (workers: [TimingWorkerResult], elapsed: UInt64, gauges: [String: BenchmarkGauge])
        do { measured = try await population(configuration, outputs: outputs, warmup: false) }
        catch {
            _ = try? outputs.close(exportDirectory: nil)
            throw error
        }
        let flushStart = DispatchTime.now().uptimeNanoseconds
        let counters = try outputs.close(exportDirectory: configuration.artifactDirectory == nil ? nil : measuredDirectory)
        let flush = DispatchTime.now().uptimeNanoseconds - flushStart
        guard let first = measured.workers.first else { throw TimingBenchmarkError.integrityFailure("Missing worker results") }
        var histogram = first.histogram
        for worker in measured.workers.dropFirst() { try histogram.merge(worker.histogram) }
        let count = measured.workers.reduce(UInt64(0)) { $0 + $1.count }
        let checksum = measured.workers.reduce(UInt64(0)) { $0 &+ $1.checksum }
        var expected: UInt64 = 0
        for worker in measured.workers {
            for index in 0..<worker.count {
                let seed = input(configuration, worker: worker.worker, index: index)
                expected &+= configuration.mode == .emptyHarness ? seed : fixture(seed)
            }
        }
        guard count > 0, checksum == expected, histogram.snapshot().observedCount == count else {
            throw TimingBenchmarkError.integrityFailure("Whole-population fixture accounting failed")
        }
        try verifyOutputs(configuration.mode, count: count, counters: counters)
        let domain = "instrumentation-monotonic"
        let metric = BenchmarkMetric(id: BenchmarkWorkload.instrumentation.rawValue, clockDomain: domain, distribution: histogram.snapshot())
        var identity = ReportIdentity(scenario: configuration.mode.usesREST ? "instrumentation.local-rest" : "instrumentation.cpu-fixture",
            profile: configuration.profile, seed: configuration.seed, fixtureHashes: ["fixture-v1": fixtureHash],
            inputSizes: ["lanes": 64, "iterationsPerWorkerCap": UInt64(configuration.iterations),
                "warmupIterationsPerWorkerCap": UInt64(configuration.warmupIterations), "durationCapSeconds": configuration.durationSeconds],
            instrumentation: configuration.mode.rawValue, scheduler: "finite-structured-worker-cohort",
            concurrency: UInt32(configuration.concurrency), warmupNanoseconds: warmup.elapsed,
            requestedWarmupNanoseconds: configuration.warmupSeconds * 1_000_000_000,
            measuredNanoseconds: measured.elapsed, repetitions: 1)
        identity.catalogVersion = 3
        var provenance = BenchmarkProvenance.capture()
        provenance.fixtureHashes = identity.fixtureHashes
        let report = DiscordBenchmarkReport(identity: identity, provenance: provenance,
            adapter: "DiscordTimingBenchmarks.v1", clockDomain: domain, status: .completed,
            counts: .init(offered: count, admitted: count, completed: count,
                outcomes: Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, $0 == .success ? count : 0) }), deadlineMisses: 0),
            metrics: [metric], gauges: measured.gauges, cleanup: .init(completed: true, remainingOwners: 0),
            throughputPerSecond: Double(count) * 1_000_000_000 / Double(measured.elapsed),
            qualificationLimitations: ["Informational overhead evidence; no controlled-host noise study or numerical qualification.",
                "Per-call timers report gross cost; wall throughput also includes cohort scheduling and histogram/checksum bookkeeping.",
                "Process peak RSS covers warmup and output setup; allocation gauges are live footprint, not allocation-event counts."])
        try report.validate()
        return TimingBenchmarkResult(configuration: configuration, completedOperations: count, checksum: checksum,
            expectedChecksum: expected, warmupOperations: warmup.workers.reduce(0) { $0 + $1.count },
            warmupNanoseconds: warmup.elapsed, measuredNanoseconds: measured.elapsed, flushNanoseconds: flush,
            outputCounters: counters, common: report)
    }

    /// Requires exact known record populations and explicit saturation/failure loss conservation.
    /// - Parameters:
    ///   - mode: Fixed output mode determining expected endpoint and scalar counts.
    ///   - count: Successfully completed fixture operations; every enabled lifecycle has two endpoints.
    ///   - counters: Closed adapter snapshots taken after all workers joined.
    /// - Throws: Integrity error on missing, duplicated or silently dropped observations.
    static func verifyOutputs(_ mode: TimingMode, count: UInt64, counters: [String: UInt64]) throws {
        if mode == .aggregate || mode == .combined || mode == .scalarAggregate {
            guard counters["aggregateAccepted"] == count * (mode.usesREST ? 4 : 1),
                counters["aggregateDropped"] == 0, counters["aggregateInvalid"] == 0 else {
                throw TimingBenchmarkError.integrityFailure("Aggregate population mismatch")
            }
        }
        if [.callback, .callbackContention, .combined].contains(mode), counters["callbackRecords"] != count * 2 {
            throw TimingBenchmarkError.integrityFailure("Callback population mismatch")
        }
        if mode == .filtered, counters["callbackRecords"] != 0 {
            throw TimingBenchmarkError.integrityFailure("Filtered diagnostic output escaped")
        }
        if mode == .sampled || mode == .combined || mode == .saturation {
            guard counters["captureRetained", default: 0] + counters["captureDropped", default: 0]
                    + counters["captureSampledOut", default: 0] == count * 2,
                counters["captureActiveAfterClose"] == 0 else {
                throw TimingBenchmarkError.integrityFailure("Capture endpoint accounting mismatch")
            }
            if mode == .saturation, counters["captureDropped"] != count * 2 - min(3, count * 2) {
                throw TimingBenchmarkError.integrityFailure("Capture saturation mismatch")
            }
        }
        if mode == .rotatingFile {
            guard counters["fileWritten"] == count * 2, counters["fileDropped"] == 0, counters["fileClosed"] == 1 else {
                throw TimingBenchmarkError.integrityFailure("Rotating file accounting mismatch")
            }
        }
        if mode == .signposts {
            guard counters["signpostBegun"] == count, counters["signpostEnded"] == count,
                counters["signpostDropped"] == 0, counters["signpostIncomplete"] == 0,
                counters["signpostUnmatched"] == 0, counters["signpostActiveAfterClose"] == 0 else {
                throw TimingBenchmarkError.integrityFailure("Signpost lifecycle accounting mismatch")
            }
        }
        if mode == .sinkFailure {
            guard counters["fileWritten"] == 0, counters["fileDropped"] == count * 2,
                counters["fileFailures"] == count * 2, counters["fileClosed"] == 1 else {
                throw TimingBenchmarkError.integrityFailure("Closed-sink failure accounting mismatch")
            }
        }
    }
}
