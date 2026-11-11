// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/Phase8TimingCommand.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation

/// Native owner details retain each family's distinct ingress and completion semantics.
enum Phase8Measurement: Codable, Sendable {
    case oauth(OAuthTimingReport)
    case rpcActivities(RPCActivitiesTimingReport)
    case service(ServiceTimingReport)
}

/// Complete native receipts and a shared catalog-eight distribution envelope.
struct Phase8TimingReport: Codable, Sendable {
    var format = "DiscordKitLoadTests.service-timing"
    var schemaVersion: UInt32 = 1
    let configuration: Phase8TimingConfiguration
    let measurement: Phase8Measurement
    let common: DiscordBenchmarkReport
}

enum Phase8TimingCommand {
    /// Finite names can be inspected without creating peers, keys, owners or output files.
    static var cases: [String] {
        /// Lists registered credential-free optional service families.
        get { OAuthTimingScenario.allCases.map(\.rawValue) + RPCActivitiesTimingScenario.allCases.map(\.rawValue) + ServiceTimingScenario.allCases.map(\.rawValue) }
    }

    /// Runs separate warmup and measured owners with cooperative finite wall caps and joined teardown.
    @available(macOS 15, *)
    static func measure(_ configuration: Phase8TimingConfiguration) async throws -> Phase8TimingReport {
        try configuration.validate()
        let before = ProcessSample.capture()
        let clock = ContinuousClock()
        var warmup: UInt64 = 0
        if configuration.warmupRequests > 0 && configuration.warmupSeconds > 0 {
            let start = clock.now
            let (value, _) = try await Phase5TimingCommand.bounded(seconds: configuration.warmupSeconds) {
                try await population(configuration, requests: configuration.warmupRequests)
            }
            guard remainingOwners(value) == 0 else { throw Phase8TimingError.integrityFailure("Warmup ownership remains") }
            warmup = try BenchmarkTime.nanoseconds(duration: start.duration(to: clock.now))
        }
        let (measurement, capped) = try await Phase5TimingCommand.bounded(seconds: configuration.durationSeconds) {
            try await population(configuration, requests: configuration.requests)
        }
        let after = ProcessSample.capture()
        let common = try commonReport(configuration, measurement: measurement, warmup: warmup,
            capped: capped, before: before, after: after)
        return Phase8TimingReport(configuration: configuration, measurement: measurement, common: common)
    }

    /// Warmup and measured populations must independently join every fixture owner.
    private static func remainingOwners(_ measurement: Phase8Measurement) -> UInt64? {
        switch measurement {
        case .oauth(let value): value.cleanup.remainingOwners
        case .rpcActivities(let value): value.cleanup.remainingOwners
        case .service(let value): value.cleanup.remainingOwners
        }
    }

    /// Delegates one bounded population to its actual workflow owner, preserving ingress provenance.
    @available(macOS 15, *)
    private static func population(_ configuration: Phase8TimingConfiguration, requests: Int) async throws -> Phase8Measurement {
        let concurrency = min(configuration.concurrency, requests)
        let delay = Duration.microseconds(configuration.delayMicroseconds)
        if let scenario = OAuthTimingScenario(rawValue: configuration.scenario) {
            return .oauth(try await OAuthTimingRunner().run(scenario: scenario, requests: requests,
                concurrency: concurrency, delay: delay, storageDelay: .microseconds(configuration.storageDelayMicroseconds),
                backendDelay: .microseconds(configuration.backendDelayMicroseconds)))
        }
        if configuration.scenario == "rpc.queuedRepliesV1" {
            return .rpcActivities(try await RPCQueueTimingRunner().run(requests: requests, concurrency: concurrency,
                queueDepth: configuration.queueDepth, delay: delay))
        }
        if let scenario = RPCActivitiesTimingScenario(rawValue: configuration.scenario) {
            return .rpcActivities(try await RPCActivitiesTimingRunner().run(scenario: scenario, requests: requests,
                concurrency: concurrency, fanOut: configuration.fanOut, delay: delay,
                subscriptionGroups: configuration.subscriptionGroups, ownersPerGroup: configuration.ownersPerGroup))
        }
        guard let scenario = ServiceTimingScenario(rawValue: configuration.scenario) else {
            throw Phase8TimingError.invalidConfiguration("Unknown service case")
        }
        return .service(try await ServiceTimingRunner().run(scenario: scenario, requests: requests,
            concurrency: concurrency, delay: delay))
    }

    /// Projects native distributions without recombining overlapping child percentiles or outcome counts.
    private static func commonReport(_ configuration: Phase8TimingConfiguration, measurement: Phase8Measurement,
        warmup: UInt64, capped: Bool, before: ProcessSample, after: ProcessSample) throws -> DiscordBenchmarkReport {
        let metrics: [BenchmarkMetric], domain: String, counts: BenchmarkCounts, elapsed: UInt64
        let cleanup: BenchmarkCleanup
        let adapter: String
        let scheduler = configuration.scenario == "rpc.queuedRepliesV1" ? "bounded-rpc-reply-cohort" : "bounded-service-cohort"
        switch measurement {
        case .oauth(let value):
            metrics = value.metrics; domain = value.clockDomain; counts = value.counts
            elapsed = value.durationNanoseconds; cleanup = value.cleanup
            adapter = "injected-oauth-storage-backend"
        case .rpcActivities(let value):
            metrics = value.metrics; domain = value.clockDomain; counts = value.counts
            elapsed = value.durationNanoseconds; cleanup = value.cleanup
            adapter = configuration.scenario == "rpc.queuedRepliesV1" ? "injected-rpc-correlation" :
                configuration.scenario.hasPrefix("rpc.") ? "injected-rpc-peer" : "injected-activity-bridge"
        case .service(let value):
            metrics = value.metrics; domain = value.clockDomain; counts = value.counts
            elapsed = value.durationNanoseconds; cleanup = value.cleanup
            adapter = "injected-service-composition"
        }
        guard cleanup.completed == true, cleanup.remainingOwners == 0, !metrics.isEmpty, counts.offered > 0, counts.completed == counts.offered else {
            throw Phase8TimingError.integrityFailure("Incomplete terminal population or runtime cleanup")
        }
        guard metrics.allSatisfy({ $0.distribution.droppedCount == 0 && !$0.distribution.counterOverflow }) else {
            throw Phase8TimingError.integrityFailure("Aggregate timing loss")
        }
        try validatePrimary(metrics: metrics, counts: counts, scenario: configuration.scenario)
        let cpu = try BenchmarkTime.nanoseconds(seconds: max(0, after.cpuSeconds - before.cpuSeconds))
        let gauges: [String: BenchmarkGauge] = [
            "processCPU": .init(value: cpu, unit: "nanoseconds", method: "getrusage user+system delta",
                scope: "fixture setup, warmup, measurement and joined shutdown"),
            "processPeakResidentBytes": .init(value: after.peakRSSBytes, unit: "bytes", method: "getrusage",
                scope: "process-lifetime including setup and warmup"),
            "processResidentBytes": .init(value: after.residentBytes, unit: "bytes", method: "native process probe",
                scope: "after shutdown", unavailableReason: after.residentBytes == nil ? "Current RSS probe unavailable on this host." : nil),
        ]
        var inputSizes: [String: UInt64] = ["requests": UInt64(configuration.requests), "warmupRequests": UInt64(configuration.warmupRequests),
                "configuredConcurrency": UInt64(configuration.concurrency), "fanOut": UInt64(configuration.fanOut),
                "delayMicroseconds": UInt64(configuration.delayMicroseconds), "durationCapSeconds": configuration.durationSeconds]
        if OAuthTimingScenario(rawValue: configuration.scenario)?.isScaling == true {
            inputSizes["storageDelayMicroseconds"] = UInt64(configuration.storageDelayMicroseconds)
            inputSizes["backendDelayMicroseconds"] = UInt64(configuration.backendDelayMicroseconds)
        }
        if configuration.scenario == "activities.subscriptionGroupsV1" {
            inputSizes["subscriptionGroups"] = UInt64(configuration.subscriptionGroups)
            inputSizes["ownersPerGroup"] = UInt64(configuration.ownersPerGroup)
        }
        if configuration.scenario == "rpc.queuedRepliesV1" {
            inputSizes["queueDepth"] = UInt64(configuration.queueDepth)
            inputSizes["replyCohort"] = 64
        }
        var identity = ReportIdentity(scenario: configuration.scenario, profile: configuration.profile, seed: configuration.seed,
            inputSizes: inputSizes,
            instrumentation: "whole-population-aggregate", scheduler: scheduler,
            concurrency: UInt32(min(configuration.concurrency, configuration.requests)), warmupNanoseconds: warmup,
            requestedWarmupNanoseconds: configuration.warmupSeconds * 1_000_000_000, measuredNanoseconds: elapsed, repetitions: 1)
        identity.catalogVersion = 8
        let report = DiscordBenchmarkReport(identity: identity, provenance: .capture(), adapter: adapter, clockDomain: domain,
            status: capped || Task.isCancelled || counts.offered != UInt64(configuration.requests) ? .interrupted : .completed,
            counts: counts, metrics: metrics, gauges: gauges, cleanup: .init(completed: true, remainingOwners: 0),
            throughputPerSecond: Double(counts.completed) * 1_000_000_000 / Double(max(1, elapsed)), qualificationLimitations: [
                "Local informational timing; no controlled-host numerical baseline, other-platform or live Discord qualification.",
                "Only credential-free injected storage, RPC peers, Activity bridges and service backends are used; no browser, desktop-host, purchase or authorization operation occurs.",
                "Caller, storage, refresh I/O, peer wait, validation and cleanup observations are separate populations; actor residence is never inferred by subtracting histograms.",
                "Warmup uses separate owners and populations. Histograms cover measured terminal outcomes; diagnostics and report writes follow terminal timestamps.",
                "Whole workflow and child intervals overlap; their percentiles cannot be added or subtracted.",
                "Process gauges include fixture setup, warmup and teardown; process maximum RSS is not per-row resident memory.",
            ])
        try report.validate()
        return report
    }

    /// Rejects missing, duplicated, overflowing or mislabeled terminal primary populations.
    /// - Parameters:
    ///   - metrics: Joined caller and overlapping child distributions.
    ///   - counts: Actual terminal outcome accounting, validated independently.
    ///   - scenario: Finite selected public workflow; determines its primary metric identity.
    /// - Throws: Invalid counts or an integrity failure for any per-outcome population mismatch.
    static func validatePrimary(metrics: [BenchmarkMetric], counts: BenchmarkCounts, scenario: String) throws {
        try counts.validate()
        let required = primaryWorkload(scenario).rawValue
        for outcome in BenchmarkOutcome.allCases {
            var represented: UInt64 = 0
            for metric in metrics where metric.id == required && metric.outcome == outcome {
                let (sum, overflow) = represented.addingReportingOverflow(metric.distribution.observedCount)
                guard !overflow else { throw Phase8TimingError.integrityFailure("Primary population overflow") }
                represented = sum
            }
            guard represented == counts.outcomes[outcome, default: 0] else {
                throw Phase8TimingError.integrityFailure("Incomplete primary outcome distribution")
            }
        }
    }

    /// Selects the primary completed-call population; overlapping child observations never multiply counts.
    static func primaryWorkload(_ scenario: String) -> BenchmarkWorkload {
        if scenario == "rpc.queuedRepliesV1" { return .rpcQueuedReplyCohortV1 }
        if scenario == "oauth.storage" { return .oauthInstall }
        if scenario == "oauth.revoke" { return .oauthRevoke }
        if scenario.hasPrefix("oauth.") { return .oauthLookup }
        if scenario.hasPrefix("rpc.") { return .rpcRequest }
        if scenario.hasPrefix("activities.") { return .activitiesRequest }
        return .serviceOperation
    }

    /// Serializes only validated evidence after every fixture and workflow owner has joined.
    static func run(arguments: [String]) async throws {
        if arguments == ["--list-cases"] { print(cases.joined(separator: "\n")); return }
        guard #available(macOS 15, *) else { throw LoadFailure.unsupportedHost }
        let configuration = try Phase8TimingConfiguration.parse(arguments)
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
