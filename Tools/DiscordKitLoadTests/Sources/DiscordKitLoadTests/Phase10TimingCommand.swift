// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/Phase10TimingCommand.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation

struct Phase10TimingReport: Codable, Sendable {
    var format = "DiscordKitLoadTests.integration-timing"
    var schemaVersion: UInt32 = 1
    let configuration: Phase10TimingConfiguration
    let measurement: Phase10TimingMeasurement
    let common: DiscordBenchmarkReport
}

enum Phase10TimingCommand {
    /// Serializes constant-space populations and bounded cycle receipts after every fixture owner joins.
    @available(macOS 15, *)
    static func measure(_ configuration: Phase10TimingConfiguration) async throws -> Phase10TimingReport {
        try configuration.validate()
        let measurement = try await Phase10TimingRunner().run(configuration)
        let targetCycles = Int(configuration.durationSeconds / configuration.cycleSeconds)
        let complete = !measurement.cancelled && !measurement.controlFailure && !measurement.resources.capExceeded &&
            measurement.completedCycles > 0 && measurement.completedCycles <= targetCycles &&
            measurement.durationNanoseconds >= configuration.durationSeconds * 1_000_000_000
        var identity = ReportIdentity(scenario: "integration.mixed-v1", profile: configuration.profile, seed: configuration.seed,
            inputSizes: ["durationSeconds": configuration.durationSeconds, "cycleSeconds": configuration.cycleSeconds,
                "maximumActive": 8, "maximumPending": 8, "workingSet": 64,
                "maximumRSSBytes": configuration.maximumRSSBytes, "maximumCPUSeconds": configuration.maximumCPUSeconds],
            instrumentation: "driver-aggregate+operation-\(configuration.observerMode)", scheduler: "independent-scheduled-four-band-v1", concurrency: 8,
            warmupNanoseconds: 0, requestedWarmupNanoseconds: 0, measuredNanoseconds: measurement.durationNanoseconds, repetitions: 1)
        identity.catalogVersion = 9
        let common = DiscordBenchmarkReport(identity: identity, provenance: .capture(), adapter: "injected-rest-cache-gateway",
            clockDomain: measurement.clockDomain,
            status: measurement.resources.capExceeded || measurement.controlFailure ? .failed : complete ? .completed : .interrupted,
            counts: measurement.counts, metrics: measurement.metrics, gauges: [
                "processCPU": .init(value: try BenchmarkTime.nanoseconds(seconds: measurement.resources.cpuSeconds), unit: "nanoseconds",
                    method: "getrusage user+system delta", scope: "measured mixed workload and joined shutdown"),
                "processMaximumResidentBytes": .init(value: measurement.resources.maximumRSSBytes, unit: "bytes",
                    method: "native process probe sampled every100ms; peak RSS fallback", scope: "mixed workload"),
                "successfulCompletions": .init(value: measurement.counts.outcomes[.success, default: 0], unit: "operations",
                    method: "exact terminal outcome count", scope: "whole offered population"),
            ], cleanup: measurement.cleanup,
            throughputPerSecond: Double(measurement.counts.completed) * 1_000_000_000 / Double(max(1, measurement.durationNanoseconds)),
            qualificationLimitations: [
                "Informational offline integration: real REST admission/ordering, fixed-key entity cache and shared-authority Gateway hubs; zero sockets and credentials.",
                "Load names refer to the injected25ms single-partition provider control at20/40/160/20 arrivals/s, not a qualified platform saturation knee.",
                "Primary latency populations include submitted work only; independently offered driver rejections remain exact counts without invented response latency.",
                "Each band drains its bounded8-worker/8-pending arrival queue. Cache/hubs persist across every cycle; held slow subscriber retains at most32 events.",
                "Cancellation, injected provider delay, payload bursts, CPU arithmetic and cache expiry overlap. Crypto rekey/media, real network, product application workflows and platform qualification retain separate receipts.",
                "Control progress counts actual publication and pull on a separate hub sharing the data hub authority. It is not a Discord heartbeat or socket milestone.",
                "CLI runtime SwiftLog uses a fixed critical-level filter to bound soak diagnostics; runner API callers retain their host logging policy. Operation observer mode controls wrapper histograms; mandatory arrival driver accounting remains enabled in both modes. Aggregate histograms retain whole populations; cycle summaries retain only scalars. No p99 qualification, controlled-host improvement or numerical regression gate is claimed.",
            ])
        try common.validate()
        return .init(configuration: configuration, measurement: measurement, common: common)
    }

    /// Parses finite policy and writes validated native/common receipts only after joined cleanup.
    static func run(arguments: [String]) async throws {
        guard #available(macOS 15, *) else { throw LoadFailure.unsupportedHost }
        let configuration = try Phase10TimingConfiguration.parse(arguments)
        let result = try await measure(configuration)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let native = try encoder.encode(result)
        guard native.count <= DiscordBenchmarkReport.maximumSerializedBytes else { throw BenchmarkReportError.reportTooLarge }
        if let path = configuration.commonReport { try result.common.validatedData().write(to: URL(fileURLWithPath: path), options: .atomic) }
        if let path = configuration.output { try native.write(to: URL(fileURLWithPath: path), options: .atomic) }
        else { try FileHandle.standardOutput.write(contentsOf: native + Data([10])) }
    }
}
