// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/Phase6TimingCommand.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation

/// Native owner details retain each family's distinct ingress and completion semantics.
enum Phase6Measurement: Codable, Sendable {
    case gateway(GatewayTimingReport)
    case interaction(InteractionTimingReport)
    case synthetic(SyntheticCommandTimingReport)
}

/// Complete native receipts and a shared catalog-six distribution envelope.
struct Phase6TimingReport: Codable, Sendable {
    var format = "DiscordKitLoadTests.command-timing"
    var schemaVersion: UInt32 = 1
    let configuration: Phase6TimingConfiguration
    let measurement: Phase6Measurement
    let common: DiscordBenchmarkReport
}

enum Phase6TimingCommand {
    /// Finite names can be inspected without creating peers, keys, owners or output files.
    static var cases: [String] {
        /// Lists registered Gateway, signed HTTP and synthetic invocation families.
        get { GatewayTimingScenario.allCases.map(\.rawValue) +
            InteractionTimingScenario.allCases.map { "interaction." + $0.rawValue } +
            SyntheticCommandTimingScenario.allCases.map(\.rawValue) }
    }

    /// Runs separate warmup and measured owners with cooperative finite wall caps and joined teardown.
    static func measure(_ configuration: Phase6TimingConfiguration) async throws -> Phase6TimingReport {
        try configuration.validate()
        let before = ProcessSample.capture()
        let clock = ContinuousClock()
        var warmup: UInt64 = 0
        if configuration.warmupRequests > 0 && configuration.warmupSeconds > 0 {
            let start = clock.now
            let (value, _) = try await Phase5TimingCommand.bounded(seconds: configuration.warmupSeconds) {
                try await population(configuration, requests: configuration.warmupRequests)
            }
            guard remainingOwners(value) == 0 else { throw Phase6TimingError.integrityFailure("Warmup ownership remains") }
            warmup = try BenchmarkTime.nanoseconds(duration: start.duration(to: clock.now))
        }
        let (measurement, capped) = try await Phase5TimingCommand.bounded(seconds: configuration.durationSeconds) {
            try await population(configuration, requests: configuration.requests)
        }
        let after = ProcessSample.capture()
        let common = try commonReport(configuration, measurement: measurement, warmup: warmup,
            capped: capped, before: before, after: after)
        return Phase6TimingReport(configuration: configuration, measurement: measurement, common: common)
    }

    /// Warmup and measured populations must independently join every fixture owner.
    private static func remainingOwners(_ measurement: Phase6Measurement) -> Int {
        switch measurement {
        case .gateway(let value): value.cleanup.remainingOwners
        case .interaction(let value): value.cleanup.remainingOwners
        case .synthetic(let value): value.cleanup.remainingOwners
        }
    }

    /// Delegates one bounded population to its actual workflow owner, preserving ingress provenance.
    private static func population(_ configuration: Phase6TimingConfiguration, requests: Int) async throws -> Phase6Measurement {
        let concurrency = min(configuration.concurrency, requests)
        let delay = Duration.microseconds(configuration.delayMicroseconds)
        if let scenario = GatewayTimingScenario(rawValue: configuration.scenario) {
            return .gateway(try await GatewayTimingRunner().run(scenario: scenario, requests: requests,
                concurrency: concurrency, delay: delay, rate: configuration.rate))
        }
        if configuration.scenario.hasPrefix("interaction."),
            let scenario = InteractionTimingScenario(rawValue: String(configuration.scenario.dropFirst("interaction.".count))) {
            return .interaction(try await InteractionTimingRunner().run(scenario: scenario, requests: requests,
                concurrency: concurrency, delay: delay))
        }
        guard let scenario = SyntheticCommandTimingScenario(rawValue: configuration.scenario) else {
            throw Phase6TimingError.invalidConfiguration("Unknown synthetic case")
        }
        return .synthetic(try await SyntheticCommandTimingRunner().run(scenario: scenario, requests: requests,
            concurrency: concurrency, delay: delay))
    }

    /// Projects native distributions without recombining overlapping child percentiles or outcome counts.
    private static func commonReport(_ configuration: Phase6TimingConfiguration, measurement: Phase6Measurement,
        warmup: UInt64, capped: Bool, before: ProcessSample, after: ProcessSample) throws -> DiscordBenchmarkReport {
        let metrics: [BenchmarkMetric], domain: String, counts: BenchmarkCounts, elapsed: UInt64
        let owners: Int, adapter: String, scheduler: String
        switch measurement {
        case .gateway(let value):
            metrics = value.metrics; domain = value.clockDomain; counts = value.counts
            guard let duration = value.durationNanoseconds else { throw BenchmarkReportError.invalidTime }
            elapsed = duration; owners = value.cleanup.remainingOwners
            adapter = "scripted-json-websocket"; scheduler = "bounded-gateway-dispatch"
        case .interaction(let value):
            metrics = value.metrics; domain = value.clockDomain; counts = value.counts
            elapsed = value.durationNanoseconds; owners = value.cleanup.remainingOwners
            adapter = "signed-local-http-adapter"; scheduler = "closed-loop-interaction-cohort"
        case .synthetic(let value):
            metrics = value.metrics; domain = value.clockDomain; counts = value.counts
            elapsed = value.durationNanoseconds; owners = value.cleanup.remainingOwners
            adapter = "synthetic-command-router"; scheduler = "closed-loop-command-cohort"
        }
        guard owners == 0, !metrics.isEmpty, counts.offered > 0, counts.completed == counts.offered else {
            throw Phase6TimingError.integrityFailure("Incomplete terminal population or runtime cleanup")
        }
        guard metrics.allSatisfy({ $0.distribution.droppedCount == 0 && !$0.distribution.counterOverflow }) else {
            throw Phase6TimingError.integrityFailure("Aggregate timing loss")
        }
        let cpu = try BenchmarkTime.nanoseconds(seconds: max(0, after.cpuSeconds - before.cpuSeconds))
        let gauges: [String: BenchmarkGauge] = [
            "processCPU": .init(value: cpu, unit: "nanoseconds", method: "getrusage user+system delta",
                scope: "fixture setup, warmup, measurement and joined shutdown"),
            "processPeakResidentBytes": .init(value: after.peakRSSBytes, unit: "bytes", method: "getrusage",
                scope: "process-lifetime including setup and warmup"),
            "processResidentBytes": .init(value: after.residentBytes, unit: "bytes", method: "native process probe",
                scope: "after shutdown", unavailableReason: after.residentBytes == nil ? "Current RSS probe unavailable on this host." : nil),
        ]
        var identity = ReportIdentity(scenario: configuration.scenario, profile: configuration.profile, seed: configuration.seed,
            inputSizes: ["requests": UInt64(configuration.requests), "warmupRequests": UInt64(configuration.warmupRequests),
                "configuredConcurrency": UInt64(configuration.concurrency), "configuredGatewayArrivalRate": UInt64(configuration.rate),
                "delayMicroseconds": UInt64(configuration.delayMicroseconds), "durationCapSeconds": configuration.durationSeconds],
            instrumentation: "whole-population-aggregate", scheduler: scheduler,
            concurrency: UInt32(min(configuration.concurrency, configuration.requests)), warmupNanoseconds: warmup,
            requestedWarmupNanoseconds: configuration.warmupSeconds * 1_000_000_000, measuredNanoseconds: elapsed, repetitions: 1)
        identity.catalogVersion = 6
        let report = DiscordBenchmarkReport(identity: identity, provenance: .capture(), adapter: adapter, clockDomain: domain,
            status: capped || Task.isCancelled || counts.offered != UInt64(configuration.requests) ? .interrupted : .completed,
            counts: counts, metrics: metrics, gauges: gauges, cleanup: .init(completed: true, remainingOwners: 0),
            throughputPerSecond: Double(counts.completed) * 1_000_000_000 / Double(max(1, elapsed)), qualificationLimitations: [
                "Local informational timing; no controlled-host numerical baseline, other-platform or live Discord qualification.",
                "Gateway uses a credential-free scripted uncompressed JSON WebSocket transport. Synthetic command cases bypass trusted Gateway receipt and signed ingress.",
                "Response completion means the declared local sink completed; it does not establish Discord delivery or client rendering.",
                "Warmup uses separate owners and populations. Histograms cover measured terminal outcomes; diagnostics and report writes follow terminal timestamps.",
                "Whole workflow and child intervals overlap; their percentiles cannot be added or subtracted.",
                "Process gauges include fixture setup, warmup and teardown; process maximum RSS is not per-row resident memory.",
            ])
        try report.validate()
        return report
    }

    /// Serializes only validated evidence after every fixture and workflow owner has joined.
    static func run(arguments: [String]) async throws {
        if arguments == ["--list-cases"] { print(cases.joined(separator: "\n")); return }
        let configuration = try Phase6TimingConfiguration.parse(arguments)
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
