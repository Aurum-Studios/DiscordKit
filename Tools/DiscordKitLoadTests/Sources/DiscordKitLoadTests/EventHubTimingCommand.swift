// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/EventHubTimingCommand.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation

/// Versioned native owner receipts plus directly measured common publication/residence populations.
struct EventHubTimingReport: Codable, Sendable {
    var format = "DiscordKitLoadTests.gateway-hub-timing"
    var schemaVersion: UInt32 = 2
    let configuration: EventHubTimingConfiguration
    let measurement: EventHubTimingMeasurement
    let common: DiscordBenchmarkReport
}

/// Native accounting changed incompatibly; do not reinterpret historical schema-1 reports.
extension EventHubTimingReport {
    /// Decodes the current owner-accounting format and rejects incompatible report schemas.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decode(String.self, forKey: .format)
        schemaVersion = try values.decode(UInt32.self, forKey: .schemaVersion)
        guard format == "DiscordKitLoadTests.gateway-hub-timing", schemaVersion == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: values,
                debugDescription: "Expected event-hub owner accounting schema 2")
        }
        configuration = try values.decode(EventHubTimingConfiguration.self, forKey: .configuration)
        measurement = try values.decode(EventHubTimingMeasurement.self, forKey: .measurement)
        common = try values.decode(DiscordBenchmarkReport.self, forKey: .common)
    }
}

enum EventHubTimingCommand {
    /// Lists only the four versioned public-hub experiments, excluding scripted socket scenarios.
    static var cases: [String] { EventHubTimingScenario.allCases.map(\.rawValue) }
    static let scheduler = "sequential-publication-fixed-backlog-v2"

    /// Runs independent finite warmup and measured hubs with cooperative caps and joined teardown.
    /// - Parameter configuration: Validated workload dimensions and distinct warmup/measured caps.
    /// - Returns: Native receipts and the shared envelope. A cooperative cap retains an interrupted
    ///   partial population; process gauges include setup/warmup/cleanup, unlike publication timing.
    /// - Throws: Invalid configuration, owner-integrity failures, histogram loss or invalid report data.
    static func measure(_ configuration: EventHubTimingConfiguration) async throws -> EventHubTimingReport {
        try configuration.validate()
        let before = ProcessSample.capture(), clock = ContinuousClock()
        var warmup: UInt64 = 0
        if configuration.warmupRequests > 0 && configuration.warmupSeconds > 0 {
            let start = clock.now
            let (value, _) = try await Phase5TimingCommand.bounded(seconds: configuration.warmupSeconds) {
                try await EventHubTimingRunner().run(configuration, requests: configuration.warmupRequests)
            }
            guard value.cleanup.isEmpty else { throw EventHubTimingError.integrityFailure("Warmup ownership remains") }
            warmup = try BenchmarkTime.nanoseconds(duration: start.duration(to: clock.now))
        }
        let (measurement, capped) = try await Phase5TimingCommand.bounded(seconds: configuration.durationSeconds) {
            try await EventHubTimingRunner().run(configuration)
        }
        let after = ProcessSample.capture()
        guard measurement.cleanup.isEmpty, measurement.publicationCalls > 0,
              measurement.counts.offered == measurement.counts.completed,
              measurement.metrics.allSatisfy({ $0.distribution.droppedCount == 0 && !$0.distribution.counterOverflow }),
              measurement.pullCall.droppedCount == 0, !measurement.pullCall.counterOverflow else {
            throw EventHubTimingError.integrityFailure("Incomplete terminal population, timing loss or cleanup")
        }
        let publicationObservations = measurement.metrics.filter { $0.id == BenchmarkWorkload.gatewayPublication.rawValue }
            .reduce(UInt64(0)) { $0 + $1.distribution.observedCount }
        guard publicationObservations == UInt64(measurement.publicationCalls) else {
            throw EventHubTimingError.integrityFailure("Incomplete publication distribution")
        }
        let elapsed = measurement.durationNanoseconds
        let cpu = try BenchmarkTime.nanoseconds(seconds: max(0, after.cpuSeconds - before.cpuSeconds))
        var identity = ReportIdentity(scenario: configuration.scenario, profile: configuration.profile, seed: configuration.seed,
            inputSizes: ["requestsPerHub": UInt64(configuration.requests), "warmupRequestsPerHub": UInt64(configuration.warmupRequests),
                "subscriptionsPerHub": UInt64(configuration.subscriptions), "hubs": UInt64(configuration.hubs),
                "queuedDepth": UInt64(configuration.queuedDepth), "payloadBytes": UInt64(configuration.payloadBytes),
                "overflowPolicy": UInt64(EventHubTimingPolicy.allCases.firstIndex(of: configuration.policy)!),
                "delayMicroseconds": UInt64(configuration.delayMicroseconds), "durationCapSeconds": configuration.durationSeconds],
            instrumentation: "owner-accounting-v2-1us-publication-100us-residence", scheduler: scheduler,
            concurrency: 1, warmupNanoseconds: warmup, requestedWarmupNanoseconds: configuration.warmupSeconds * 1_000_000_000,
            measuredNanoseconds: elapsed, repetitions: 1)
        identity.catalogVersion = 6
        let offered = UInt64(configuration.requests * configuration.subscriptions * configuration.hubs)
        let common = DiscordBenchmarkReport(identity: identity, provenance: .capture(), adapter: "public-event-hub",
            clockDomain: measurement.clockDomain,
            status: capped || Task.isCancelled || measurement.counts.offered != offered ? .interrupted : .completed,
            counts: measurement.counts, metrics: measurement.metrics,
            gauges: [
                "processCPU": .init(value: cpu, unit: "nanoseconds", method: "getrusage user+system delta",
                    scope: "fixture setup, warmup, measurement and joined shutdown"),
                "processPeakResidentBytes": .init(value: after.peakRSSBytes, unit: "bytes", method: "getrusage",
                    scope: "process lifetime including setup and warmup"),
                "processResidentBytes": .init(value: after.residentBytes, unit: "bytes", method: "native process probe",
                    scope: "after shutdown", unavailableReason: after.residentBytes == nil ? "Current RSS probe unavailable on this host." : nil),
            ], cleanup: .init(completed: true, remainingOwners: 0),
            throughputPerSecond: Double(measurement.counts.outcomes[.success, default: 0]) * 1_000_000_000 / Double(max(1, elapsed)),
            qualificationLimitations: [
                "Local informational timing; reserved-host no-change floor, profiler evidence and numerical qualification remain separate requirements.",
                "One sequential publisher; concurrency is 1. Subscriber/hub fan-out, queued depth, payload bytes, overflow policy and injected consumer hold are independent input dimensions.",
                "Native schema 2 retains setup and measured dispositions separately; owner accounting adds bounded bookkeeping, so compare only matching scheduler and instrumentation identities.",
                "Counts partition measured subscriber copies; publication metrics count actual publication calls. Successful throughput includes eventual measured-copy consumption and gross setup/drain time.",
                "Residence includes setup backlog and all retained terminal copies. Direct handoffs have no retained residence; publication, residence and pull percentiles cannot be added or subtracted.",
                "Warmup uses separate owners. CPU includes setup and warmup; peak RSS is process lifetime. Envelope byte charges do not establish metadata allocations or unique payload memory.",
            ])
        try common.validate()
        return EventHubTimingReport(configuration: configuration, measurement: measurement, common: common)
    }

    /// Writes bounded validated JSON only after the full finite population and every owner joins.
    static func run(arguments: [String]) async throws {
        if arguments == ["--list-cases"] { print(cases.joined(separator: "\n")); return }
        let configuration = try EventHubTimingConfiguration.parse(arguments)
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
