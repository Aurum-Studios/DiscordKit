// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/CacheScalingTimingCommand.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation

/// Native finite fixture evidence and validated common timing envelope for one versioned experiment.
struct CacheScalingTimingReport: Codable, Sendable {
    var format = "DiscordKitLoadTests.cache-scaling-timing"
    var schemaVersion: UInt32 = 1
    let configuration: CacheScalingTimingConfiguration
    let measurement: CacheScalingTimingMeasurement
    let common: DiscordBenchmarkReport
}

enum CacheScalingTimingCommand {
    /// Lists the six versioned cases without creating owners; owner selection is independent.
    static var cases: [String] { CacheScalingTimingScenario.allCases.map(\.rawValue) }

    /// Runs separate bounded warmup and measured owners, preserving exact whole-call populations.
    /// - Parameter configuration: Independent owner, aggregate working-set, identity, payload and churn controls.
    /// - Returns: Local informational native/common receipts only after every owner has joined.
    /// - Throws: Invalid dimensions, cooperative-cap cancellation, fixture errors or invalid evidence.
    ///   A cap aborts evidence export after joined cleanup; it never publishes a successful partial run.
    @available(macOS 15, *)
    static func measure(_ configuration: CacheScalingTimingConfiguration) async throws -> CacheScalingTimingReport {
        try configuration.validate()
        let before = ProcessSample.capture(), clock = ContinuousClock()
        var warmup: UInt64 = 0
        if configuration.warmupRequests > 0 && configuration.warmupSeconds > 0 {
            let start = clock.now
            let (value, capped) = try await Phase5TimingCommand.bounded(seconds: configuration.warmupSeconds) {
                try await CacheScalingTimingRunner().run(configuration, requests: configuration.warmupRequests)
            }
            guard !capped, value.cleanup.isEmpty else { throw CacheScalingTimingError.integrityFailure("Incomplete warmup") }
            warmup = try BenchmarkTime.nanoseconds(duration: start.duration(to: clock.now))
        }
        let (measurement, capped) = try await Phase5TimingCommand.bounded(seconds: configuration.durationSeconds) {
            try await CacheScalingTimingRunner().run(configuration)
        }
        let after = ProcessSample.capture()
        let callers = measurement.metrics.filter { $0.id == BenchmarkWorkload.cacheCall.rawValue }
            .reduce(UInt64(0)) { $0 + $1.distribution.observedCount }
        let owners = measurement.metrics.filter { $0.id == BenchmarkWorkload.cacheOwner.rawValue }
            .reduce(UInt64(0)) { $0 + $1.distribution.observedCount }
        guard !capped, measurement.cleanup.isEmpty, callers == UInt64(configuration.requests),
              owners == (configuration.owner == .entity ? callers : 0),
              measurement.counts.outcomes[.success] == callers,
              measurement.metrics.allSatisfy({ $0.distribution.droppedCount == 0 && !$0.distribution.counterOverflow }) else {
            throw CacheScalingTimingError.integrityFailure("Incomplete operation population, timing loss or cleanup")
        }
        var identity = ReportIdentity(scenario: configuration.scenario + "." + configuration.owner.rawValue,
            profile: configuration.profile, seed: configuration.seed,
            inputSizes: ["requests": UInt64(configuration.requests), "warmupRequests": UInt64(configuration.warmupRequests),
                "workingSet": UInt64(configuration.workingSet), "identities": UInt64(configuration.identities),
                "payloadBytes": UInt64(configuration.payloadBytes), "churnUpdates": UInt64(configuration.churnUpdates),
                "durationCapSeconds": configuration.durationSeconds],
            instrumentation: configuration.owner == .entity ? "whole-population-call-and-owner" : "whole-population-call",
            scheduler: "sequential-cache-fixed-aggregate-working-set-v1", concurrency: 1,
            warmupNanoseconds: warmup, requestedWarmupNanoseconds: configuration.warmupSeconds * 1_000_000_000,
            measuredNanoseconds: measurement.durationNanoseconds, repetitions: 1)
        identity.catalogVersion = 7
        let elapsed = measurement.durationNanoseconds
        let common = DiscordBenchmarkReport(identity: identity, provenance: .capture(), adapter: "public-\(configuration.owner.rawValue)-cache",
            clockDomain: measurement.clockDomain, status: .completed, counts: measurement.counts, metrics: measurement.metrics,
            gauges: [
                "processCPU": .init(value: try BenchmarkTime.nanoseconds(seconds: max(0, after.cpuSeconds - before.cpuSeconds)),
                    unit: "nanoseconds", method: "getrusage user+system delta", scope: "fixture setup, warmup, measurement and joined shutdown"),
                "processPeakResidentBytes": .init(value: after.peakRSSBytes, unit: "bytes", method: "getrusage", scope: "process lifetime including setup and warmup"),
                "processResidentBytes": .init(value: after.residentBytes, unit: "bytes", method: "native process probe", scope: "after shutdown",
                    unavailableReason: after.residentBytes == nil ? "Current RSS probe unavailable on this host." : nil),
            ], cleanup: .init(completed: true, remainingOwners: 0),
            throughputPerSecond: Double(callers) * 1_000_000_000 / Double(max(1, elapsed)), qualificationLimitations: [
                "Local informational timing; reserved-host no-change pairs, alternating candidate pairs, profiles and numerical qualification remain separate requirements.",
                "Working set is aggregate across identities; payload length and untimed replacement churn are independent. Every selected call uses one sequential caller.",
                "Payload/key preparation, population, replacement churn, diagnostics and recovery are outside call and owner timers. Gross throughput and CPU include setup and cleanup.",
                "Entity writes include actual JSON serialization and conservative byte charging. HTTP writes retain prepared Data; these owners have distinct byte-accounting semantics.",
                "Entity owner timing begins after actor admission. Read cache has only direct caller timing; no actor residence is inferred by subtracting distributions.",
                "Expiry advances a separate deterministic freshness clock and times the public lookup that prunes the whole retained working set. Recovery calls are untimed.",
                "The 16 MiB retained-charge guard is a fixture bound. Key/index/task metadata, allocator overhead and two prepared payload variants require separate process memory evidence.",
                "Warmup has separate owners. Peak RSS is process lifetime. P99 sample requirements and all existing cache-client single-flight/fencing identities are unchanged.",
            ])
        try common.validate()
        return .init(configuration: configuration, measurement: measurement, common: common)
    }

    /// Writes bounded validated evidence after all finite fixture owners have been released.
    /// - Parameter arguments: Unique CLI value flags or the standalone `--list-cases` request.
    /// - Throws: Unsupported host, configuration, fixture, encoding or output errors.
    static func run(arguments: [String]) async throws {
        if arguments == ["--list-cases"] { print(cases.joined(separator: "\n")); return }
        guard #available(macOS 15, *) else { throw LoadFailure.unsupportedHost }
        let configuration = try CacheScalingTimingConfiguration.parse(arguments)
        let result = try await measure(configuration)
        let common = try result.common.validatedData()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let native = try encoder.encode(result)
        guard native.count <= DiscordBenchmarkReport.maximumSerializedBytes else { throw BenchmarkReportError.reportTooLarge }
        if let path = configuration.commonReport { try common.write(to: URL(fileURLWithPath: path), options: .atomic) }
        if let path = configuration.output { try native.write(to: URL(fileURLWithPath: path), options: .atomic) }
        else { try FileHandle.standardOutput.write(contentsOf: native + Data([10])) }
    }
}
