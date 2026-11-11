// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/Phase5TimingCommand.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation

/// Native families remain independent shapes within the versioned Phase 5 report.
enum Phase5Measurement: Codable, Sendable {
    case transport(TransportTimingMeasurement)
    case rest(RESTTimingReport)
    case arrival(ArrivalTimingMeasurement, RESTTimingCleanup)
}

/// Full native evidence plus a common, strictly validated distribution envelope.
struct Phase5TimingReport: Codable, Sendable {
    var format = "DiscordKitLoadTests.timing"
    var schemaVersion: UInt32 = 1
    let configuration: Phase5TimingConfiguration
    let measurement: Phase5Measurement
    let common: DiscordBenchmarkReport
}

/// Two bounded children race the complete operation and its admission/cancellation cap.
private enum Phase5Race<Value: Sendable>: Sendable { case result(Value), deadline, timerCancelled }

enum Phase5TimingCommand {
    /// Finite workload names are inspectable without starting any fixture or opening outputs.
    static var cases: [String] {
        /// Lists independent transport, REST and arrival policies; arbitrary labels are rejected.
        get { TransportTimingCase.allCases.map(\.rawValue) + RESTTimingScenario.allCases.map { "rest." + $0.rawValue } + ["arrival.rest"] }
    }

    /// Caps asynchronous work, cancels the losing child and awaits the entire task group.
    /// - Parameters:
    ///   - seconds: Positive wall cap; admitted operations must honor cooperative cancellation.
    ///   - operation: Owner returning exact partial evidence after joining its children.
    /// - Returns: The joined result and whether its wall cap fired first.
    /// - Throws: Owner setup/integrity errors; the timer never fabricates observations.
    static func bounded<Value: Sendable>(seconds: UInt64,
        operation: @escaping @Sendable () async throws -> Value) async throws -> (Value, Bool) {
        try await withThrowingTaskGroup(of: Phase5Race<Value>.self) { group in
            group.addTask { .result(try await operation()) }
            group.addTask {
                do { try await Task.sleep(for: .seconds(seconds)) }
                catch { return .timerCancelled }
                return .deadline
            }
            var capped = false
            while let next = try await group.next() {
                switch next {
                case .deadline: capped = true; group.cancelAll()
                case .timerCancelled: group.cancelAll()
                case .result(let value):
                    group.cancelAll()
                    try await group.waitForAll()
                    return (value, capped)
                }
            }
            throw CancellationError()
        }
    }

    /// Runs one explicit case with separate warmup, exact terminal populations and owned teardown.
    /// - Parameters:
    ///   - configuration: Validated finite settings; results are not written by this method.
    /// - Returns: Native details and common catalog-five evidence; local smoke is informational.
    /// - Throws: Fixture/configuration/schema errors rather than emitting a successful empty run.
    static func measure(_ configuration: Phase5TimingConfiguration) async throws -> Phase5TimingReport {
        try configuration.validate()
        let before = ProcessSample.capture()
        let clock = ContinuousClock()
        var warmupNanoseconds: UInt64 = 0
        let measured: Phase5Measurement
        var capped = false
        if let scenario = TransportTimingCase(rawValue: configuration.scenario) {
            let transport = try await TransportTimingNativeSuite().run(
                adapter: TransportTimingAdapter(rawValue: configuration.adapter)!, scenario: scenario,
                requests: configuration.requests, concurrency: configuration.concurrency,
                warmupRequests: configuration.warmupSeconds == 0 ? 0 : configuration.warmupRequests,
                connectionMode: TransportConnectionMode(rawValue: configuration.connectionMode)!, tls: configuration.tls,
                maxWarmupDuration: .seconds(configuration.warmupSeconds), maxMeasuredDuration: .seconds(configuration.durationSeconds))
            warmupNanoseconds = transport.warmupNanoseconds
            capped = transport.counts.offered < UInt64(configuration.requests)
            measured = .transport(transport)
        } else if configuration.scenario == "arrival.rest" {
            if configuration.warmupRequests > 0 && configuration.warmupSeconds > 0 {
                let start = clock.now
                _ = try await bounded(seconds: configuration.warmupSeconds) {
                    try await arrival(configuration, requests: configuration.warmupRequests)
                }
                warmupNanoseconds = try BenchmarkTime.nanoseconds(duration: start.duration(to: clock.now))
            }
            let result = try await bounded(seconds: configuration.durationSeconds) {
                try await arrival(configuration, requests: configuration.requests)
            }
            measured = result.0; capped = result.1
        } else {
            guard let scenario = RESTTimingScenario(rawValue: String(configuration.scenario.dropFirst(5))) else {
                throw Phase5TimingError.invalidConfiguration("Unknown REST case")
            }
            if configuration.warmupRequests > 0 && configuration.warmupSeconds > 0 {
                let start = clock.now
                _ = try await bounded(seconds: configuration.warmupSeconds) {
                    try await RESTTimingRunner().run(scenario: scenario, requests: configuration.warmupRequests,
                        concurrency: min(configuration.concurrency, configuration.warmupRequests), delay: .microseconds(configuration.delayMicroseconds))
                }
                warmupNanoseconds = try BenchmarkTime.nanoseconds(duration: start.duration(to: clock.now))
            }
            let result = try await bounded(seconds: configuration.durationSeconds) {
                try await RESTTimingRunner().run(scenario: scenario, requests: configuration.requests,
                    concurrency: min(configuration.concurrency, configuration.requests), delay: .microseconds(configuration.delayMicroseconds))
            }
            measured = .rest(result.0); capped = result.1
        }
        let after = ProcessSample.capture()
        let common = try commonReport(configuration, measurement: measured, warmup: warmupNanoseconds,
            capped: capped, before: before, after: after)
        return Phase5TimingReport(configuration: configuration, measurement: measured, common: common)
    }

    /// Composes independent arrivals with a single shared, bounded REST owner.
    /// - Parameters:
    ///   - configuration: Finite rate/active/pending policy and scripted service delay.
    ///   - requests: Separate warmup or measured arrival count.
    /// - Returns: Joined driver population and policy shutdown receipt.
    /// - Throws: Invalid bounds or setup errors; setup failures create no fabricated operations.
    private static func arrival(_ configuration: Phase5TimingConfiguration, requests: Int) async throws -> Phase5Measurement {
        let fixture = try RESTArrivalFixture(concurrency: configuration.concurrency,
            delay: .microseconds(configuration.delayMicroseconds))
        do {
            let value = try await ArrivalTimingRunner().run(profile: try .init(arrivals: requests,
                intervalNanoseconds: UInt64(1_000_000_000 / configuration.rate),
                maximumActive: configuration.concurrency, maximumPending: configuration.pending)) { submission in
                ArrivalOperationResult(outcome: await fixture.execute(ordinal: submission.ordinal))
            }
            return .arrival(value, await fixture.shutdown())
        } catch {
            _ = await fixture.shutdown()
            throw error
        }
    }

    /// Projects each native family into a common schema without recombining percentiles or outcomes.
    /// - Parameters:
    ///   - configuration: Original immutable workload settings.
    ///   - measurement: Joined complete/partial native evidence.
    ///   - warmup: Actual separate warmup lifecycle duration, excluded from measured histograms.
    ///   - capped: Whether admission/time caps stopped the requested population.
    ///   - before: Process probe before fixture construction and warmup.
    ///   - after: Process probe after joined fixture/adapter teardown.
    /// - Returns: Validated catalog-five common report.
    /// - Throws: Inconsistent clocks, ownership, metric evidence or report schema.
    private static func commonReport(_ configuration: Phase5TimingConfiguration, measurement: Phase5Measurement,
        warmup: UInt64, capped: Bool, before: ProcessSample, after: ProcessSample) throws -> DiscordBenchmarkReport {
        let metrics: [BenchmarkMetric], domain: String, counts: BenchmarkCounts, elapsed: UInt64
        let owners: UInt64?, adapter: String, scheduler: String
        var gauges: [String: BenchmarkGauge] = [:]
        switch measurement {
        case .transport(let value):
            metrics = value.metrics; domain = value.clockDomain; counts = value.counts
            guard let duration = value.durationNanoseconds else { throw BenchmarkReportError.invalidTime }
            elapsed = duration; adapter = value.adapter; scheduler = "closed-loop-" + value.connectionMode
            guard value.cleanup.ownedAdaptersClosed else { throw Phase5TimingError.integrityFailure("Adapter cleanup incomplete") }
            if let active = value.cleanup.poolActiveAfterShutdown, let idle = value.cleanup.poolIdleAfterShutdown {
                owners = UInt64(active + idle)
            } else { owners = value.adapter == "scripted" ? 0 : nil }
        case .rest(let value):
            metrics = value.metrics; domain = value.clockDomain; counts = value.counts
            elapsed = value.durationNanoseconds; adapter = "scripted-rest"; scheduler = "closed-loop-policy"
            owners = UInt64(value.cleanup.remainingOwners)
        case .arrival(let value, let cleanup):
            guard !value.clockRegressed, value.invalidOperationTimestamps == 0 else {
                throw Phase5TimingError.integrityFailure("Invalid arrival clock or owner timestamps")
            }
            metrics = value.metrics; domain = value.clockDomain; counts = value.counts
            elapsed = value.elapsedNanoseconds; adapter = "scripted-rest"; scheduler = "bounded-independent-arrivals"
            owners = UInt64(value.remainingActive + value.remainingPending + cleanup.remainingOwners)
            gauges["offeredArrivalsPerSecond"] = .init(value: UInt64(value.offeredPerSecond), unit: "arrivals/second",
                method: "offered / scheduled-window", scope: "scheduled-window")
            for (key, count) in [("peakActive", value.peakActive), ("peakPending", value.peakPending),
                ("missedArrivals", value.missedArrivals), ("deferredArrivals", value.deferredArrivals),
                ("submittedCompletions", value.submittedCompletions)] {
                gauges[key] = .init(value: UInt64(count), unit: "count", method: "exact driver owner counter", scope: "measured-population")
            }
        }
        guard owners == nil || owners == 0 else { throw Phase5TimingError.integrityFailure("Remaining runtime ownership") }
        let cpu = try BenchmarkTime.nanoseconds(seconds: max(0, after.cpuSeconds - before.cpuSeconds))
        gauges["processCPU"] = .init(value: cpu, unit: "nanoseconds", method: "getrusage user+system delta",
            scope: "fixture setup, warmup, measurement and joined shutdown")
        gauges["processPeakResidentBytes"] = .init(value: after.peakRSSBytes, unit: "bytes", method: "getrusage",
            scope: "process-lifetime including setup and warmup")
        gauges["processResidentBytes"] = .init(value: after.residentBytes, unit: "bytes", method: "native process probe",
            scope: "after shutdown", unavailableReason: after.residentBytes == nil ? "Current RSS probe unavailable on this host." : nil)
        var identity = ReportIdentity(scenario: configuration.scenario, profile: configuration.profile, seed: configuration.seed,
            inputSizes: ["requests": UInt64(configuration.requests), "warmupRequests": UInt64(configuration.warmupRequests),
                "configuredConcurrency": UInt64(configuration.concurrency),
                "maximumPending": UInt64(configuration.pending), "arrivalRate": UInt64(configuration.rate),
                "delayMicroseconds": UInt64(configuration.delayMicroseconds), "tls": configuration.tls ? 1 : 0,
                "durationCapSeconds": configuration.durationSeconds], instrumentation: "whole-population-aggregate",
            scheduler: scheduler, concurrency: UInt32(min(configuration.concurrency, configuration.requests)), warmupNanoseconds: warmup,
            requestedWarmupNanoseconds: configuration.warmupSeconds * 1_000_000_000,
            measuredNanoseconds: elapsed, repetitions: 1)
        identity.catalogVersion = 5
        if case .transport(let value) = measurement { identity.profileVersion = value.profileVersion }
        let report = DiscordBenchmarkReport(identity: identity, provenance: .capture(), adapter: adapter,
            clockDomain: domain, status: capped || Task.isCancelled ? .interrupted : .completed, counts: counts,
            metrics: metrics, gauges: gauges, cleanup: .init(completed: true, remainingOwners: owners,
                reason: owners == nil ? "Adapter close awaited; private Foundation pool counts are unavailable." : nil),
            throughputPerSecond: Double(counts.completed) * 1_000_000_000 / Double(max(1, elapsed)),
            qualificationLimitations: ["Local informational timing; no controlled-host numerical baseline, other-platform or live Discord qualification.",
                "Warmup uses a separate population. Diagnostic snapshots and report writes follow terminal timestamps; transport byte validation is inside its body/request boundary.",
                "Whole workflow and child percentiles overlap; they must not be added or subtracted.",
                "Unavailable native DNS/TLS/pool/upload internals and REST owner admission timestamps are not inferred from aggregate timings.",
                "Process gauges include fixture setup/warmup/teardown; workflow histograms and throughput use their declared measured boundaries."])
        try report.validate()
        return report
    }

    /// Parses and executes one case, then serializes only after teardown and schema validation.
    /// - Parameter arguments: Arguments following `timing`; `--list-cases` starts no workers.
    /// - Throws: Invalid policy, runtime integrity, output alias or filesystem errors.
    static func run(arguments: [String]) async throws {
        if arguments == ["--list-cases"] {
            print(cases.joined(separator: "\n"))
            return
        }
        let configuration = try Phase5TimingConfiguration.parse(arguments)
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
