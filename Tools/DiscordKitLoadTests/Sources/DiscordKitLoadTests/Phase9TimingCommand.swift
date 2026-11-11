// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/Phase9TimingCommand.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation

/// Native lifecycle receipts and common catalog-nine timing populations.
struct Phase9TimingReport: Codable, Sendable {
    var format = "DiscordKitLoadTests.voice-timing"
    var schemaVersion: UInt32 = 1
    let configuration: Phase9TimingConfiguration
    let measurement: VoiceLifecycleTimingMeasurement
    let common: DiscordBenchmarkReport
}

enum Phase9TimingCommand {
    /// Lists inert finite cases without constructing credentials or session owners.
    static var cases: [String] { VoiceLifecycleTimingCase.allCases.map(\.rawValue) }

    /// Joins independent warmup owners before starting a measured lifecycle population.
    @available(macOS 15, *)
    static func measure(_ configuration: Phase9TimingConfiguration) async throws -> Phase9TimingReport {
        try configuration.validate()
        guard let scenario = VoiceLifecycleTimingCase(rawValue: configuration.scenario) else {
            throw Phase8TimingError.invalidConfiguration("Unknown voice case")
        }
        let before = ProcessSample.capture(), clock = ContinuousClock()
        var warmup: UInt64 = 0
        if configuration.warmupRequests > 0 && configuration.warmupSeconds > 0 {
            let start = clock.now
            let (value, _) = try await Phase5TimingCommand.bounded(seconds: configuration.warmupSeconds) {
                try await VoiceLifecycleTimingRunner().run(scenario: scenario, requests: configuration.warmupRequests,
                    concurrency: min(configuration.concurrency, configuration.warmupRequests))
            }
            guard value.cleanup.completed == true, value.cleanup.remainingOwners == 0 else {
                throw Phase8TimingError.integrityFailure("Warmup ownership remains")
            }
            warmup = try BenchmarkTime.nanoseconds(duration: start.duration(to: clock.now))
        }
        let (measurement, capped) = try await Phase5TimingCommand.bounded(seconds: configuration.durationSeconds) {
            try await VoiceLifecycleTimingRunner().run(scenario: scenario, requests: configuration.requests,
                concurrency: min(configuration.concurrency, configuration.requests))
        }
        let after = ProcessSample.capture()
        try validatePopulation(metrics: measurement.metrics, counts: measurement.counts, cleanup: measurement.cleanup)
        let cpu = try BenchmarkTime.nanoseconds(seconds: max(0, after.cpuSeconds - before.cpuSeconds))
        var identity = ReportIdentity(scenario: configuration.scenario, profile: configuration.profile, seed: configuration.seed,
            inputSizes: ["requests": UInt64(configuration.requests), "warmupRequests": UInt64(configuration.warmupRequests),
                "configuredConcurrency": UInt64(configuration.concurrency), "durationCapSeconds": configuration.durationSeconds],
            instrumentation: "whole-population-aggregate", scheduler: "bounded-scripted-voice-cohort",
            concurrency: UInt32(min(configuration.concurrency, configuration.requests)), warmupNanoseconds: warmup,
            requestedWarmupNanoseconds: configuration.warmupSeconds * 1_000_000_000,
            measuredNanoseconds: measurement.durationNanoseconds, repetitions: 1)
        identity.catalogVersion = 9
        let report = DiscordBenchmarkReport(identity: identity, provenance: .capture(), adapter: "injected-voice-session",
            clockDomain: measurement.clockDomain,
            status: capped || Task.isCancelled || measurement.counts.offered != UInt64(configuration.requests) ? .interrupted : .completed,
            counts: measurement.counts, metrics: measurement.metrics, gauges: [
                "processCPU": .init(value: cpu, unit: "nanoseconds", method: "getrusage user+system delta",
                    scope: "setup, warmup, measured lifecycles and joined shutdown"),
                "processPeakResidentBytes": .init(value: after.peakRSSBytes, unit: "bytes", method: "getrusage", scope: "process-lifetime"),
                "processResidentBytes": .init(value: after.residentBytes, unit: "bytes", method: "native process probe",
                    scope: "after shutdown", unavailableReason: after.residentBytes == nil ? "Current RSS unavailable." : nil),
            ], cleanup: measurement.cleanup,
            throughputPerSecond: Double(measurement.counts.completed) * 1_000_000_000 / Double(max(1, measurement.durationNanoseconds)),
            qualificationLimitations: [
                "Informational scripted local timing; no live Discord, controlled-host baseline, hardware or independent cryptographic qualification.",
                "Manager installation, credential rendezvous, handshake, secure readiness and joined shutdown retain distinct observed boundaries.",
                "Injected signaling, UDP discovery and cryptographic backend establish fixture milestones only; actual duplex crypto/UDP has a separate runner.",
                "Child distributions overlap; percentiles cannot be added or subtracted. Warmup has independent owners and no measured observations.",
                "Process gauges include setup and warmup. Process maximum RSS is not a per-operation gauge.",
            ])
        try report.validate()
        return Phase9TimingReport(configuration: configuration, measurement: measurement, common: report)
    }

    /// Requires a complete primary outcome population and zero retained runtime owners.
    static func validatePopulation(metrics: [BenchmarkMetric], counts: BenchmarkCounts, cleanup: BenchmarkCleanup) throws {
        try counts.validate()
        guard cleanup.completed == true, cleanup.remainingOwners == 0, counts.offered > 0,
            counts.completed == counts.offered, !metrics.isEmpty,
            metrics.allSatisfy({ $0.distribution.droppedCount == 0 && !$0.distribution.counterOverflow }) else {
            throw Phase8TimingError.integrityFailure("Incomplete voice population or runtime cleanup")
        }
        for outcome in BenchmarkOutcome.allCases {
            var represented: UInt64 = 0
            for metric in metrics where metric.id == BenchmarkWorkload.voiceLifecycle.rawValue && metric.outcome == outcome {
                let (next, overflow) = represented.addingReportingOverflow(metric.distribution.observedCount)
                guard !overflow else { throw Phase8TimingError.integrityFailure("Primary population overflow") }
                represented = next
            }
            guard represented == counts.outcomes[outcome, default: 0] else {
                throw Phase8TimingError.integrityFailure("Primary voice outcome mismatch")
            }
        }
    }

    /// Serializes bounded validated evidence only after all sessions and fixture tasks join.
    static func run(arguments: [String]) async throws {
        if arguments == ["--list-cases"] { print(cases.joined(separator: "\n")); return }
        guard #available(macOS 15, *) else { throw LoadFailure.unsupportedHost }
        let configuration = try Phase9TimingConfiguration.parse(arguments)
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
