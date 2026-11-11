// File: Tools/DiscordDSLBenchmarks/Sources/DiscordDSLBenchmarks/CompilerTiming.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation

/// Raw integer subprocess observations from the separate compiler driver, never runtime invocations.
struct CompilerProcessMeasurement: Decodable, Sendable {
    let wallNanoseconds: UInt64
    let peakRSSBytes: UInt64
}

/// One consumer clean/edit pair, with exact binary identity after catalog construction qualification.
struct CompilerBuildPair: Decodable, Sendable {
    let clean: CompilerProcessMeasurement
    let incremental: CompilerProcessMeasurement
    let binarySHA256: String
}

/// Only a single selected manual/macro and handler-count population may enter one common envelope.
struct CompilerWorkload: Decodable, Sendable {
    let mode: String
    let handlerCount: Int
    let functionalGatesPassed: Bool
    let samples: [CompilerBuildPair]
}

/// The compiler native artifact remains v1; catalog7 integer observations are an additive opt-in receipt.
struct CompilerTimingInput: Decodable, Sendable {
    struct Configuration: Decodable, Sendable {
        let modules: Int
        let jobs: Int
        let samples: Int
        let configuration: String
        let buildSystem: String
        let timingBoundary: String
        let dependencyColdBuildIncluded: Bool
    }
    let schemaVersion: Int
    let reportKind: String
    let metricCatalogVersion: Int
    let configuration: Configuration
    let environment: BenchmarkEnvironment
    let revision: String
    let sourceHash: String
    let fixtureHash: String
    let resolutionHash: String
    let manifestHash: String
    let buildCommand: [String]
    let workloads: [CompilerWorkload]
}

/// Converts new exact compiler subprocess observations using shared histograms and schema validation.
enum CompilerTimingCommand {
    /// Checks SHA-256 receipt spelling without accepting whitespace, partial digests or arbitrary strings.
    /// - Parameter value: Exact lower/uppercase hexadecimal native digest.
    /// - Returns: True only for 64 ASCII hexadecimal bytes; this checks shape, not receipt authenticity.
    private static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    /// Produces one explicit manual/macro working-set envelope, retaining clean and incremental populations.
    /// - Parameters:
    ///   - input: New additive native compiler receipts; old summary-only v1 files cannot supply these fields.
    ///   - mode: Exact manual or macro selection, never mixed into the other path's histogram.
    ///   - handlers: Selected fixed declaration population, exactly 10, 100 or 1,000.
    /// - Returns: Catalog7 informational evidence; bootstrap and fixture edits remain excluded from timings.
    /// - Throws: Invalid configuration, missing/duplicate populations, malformed hashes, overflow or schema errors.
    static func convert(_ input: CompilerTimingInput, mode: String, handlers: Int) throws -> DiscordBenchmarkReport {
        guard input.schemaVersion == 1, input.metricCatalogVersion == 7, input.reportKind == "dsl-compiler-cost",
              ["manual", "macro"].contains(mode), [10, 100, 1_000].contains(handlers),
              (1...5).contains(input.configuration.samples), (1...32).contains(input.configuration.jobs),
              (1...handlers / 10).contains(input.configuration.modules), !input.configuration.dependencyColdBuildIncluded,
              input.configuration.configuration == "debug", input.configuration.buildSystem == "native",
              input.configuration.timingBoundary == "supervised-process-lifetime-v1",
              !input.buildCommand.isEmpty,
              [input.fixtureHash, input.manifestHash, input.resolutionHash, input.sourceHash].allSatisfy(validHash)
        else { throw BenchmarkError.invalidConfiguration }
        let rows = input.workloads.filter { $0.mode == mode && $0.handlerCount == handlers }
        guard rows.count == 1, let row = rows.first, row.functionalGatesPassed,
              row.samples.count == input.configuration.samples else { throw BenchmarkError.functionalGate }
        let configuration = try HistogramConfiguration(lowerBoundNanoseconds: 0,
            upperBoundNanoseconds: 3_600_000_000_000, bucketWidthNanoseconds: 1_000_000_000)
        var clean = BoundedHistogram(configuration: configuration), incremental = BoundedHistogram(configuration: configuration)
        var total: UInt64 = 0, peak: UInt64 = 0
        for sample in row.samples {
            guard validHash(sample.binarySHA256) else { throw BenchmarkError.functionalGate }
            for observation in [sample.clean, sample.incremental] {
                guard observation.peakRSSBytes > 0 else { throw BenchmarkReportError.invalidGauge }
                let (sum, overflow) = total.addingReportingOverflow(observation.wallNanoseconds)
                guard !overflow, observation.wallNanoseconds <= UInt64(Int64.max) else { throw BenchmarkReportError.invalidTime }
                total = sum; peak = max(peak, observation.peakRSSBytes)
            }
            clean.record(sample.clean.wallNanoseconds); incremental.record(sample.incremental.wallNanoseconds)
        }
        let domain = UUID().uuidString
        let fixtures = ["consumerSources": input.fixtureHash, "consumerManifest": input.manifestHash]
        var identity = ReportIdentity(scenario: "compiler." + mode, profile: "consumer-debug", fixtureHashes: fixtures,
            inputSizes: ["handlers": UInt64(handlers), "modules": UInt64(input.configuration.modules),
                "samples": UInt64(row.samples.count), "jobs": UInt64(input.configuration.jobs)],
            instrumentation: "integer-monotonic-subprocess-wall", scheduler: "serial-clean-then-declared-edit",
            concurrency: 1, warmupNanoseconds: 0, requestedWarmupNanoseconds: 0, measuredNanoseconds: total, repetitions: 1)
        identity.catalogVersion = 7
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        let completed = UInt64(row.samples.count * 2)
        outcomes[.success] = completed
        let provenance = BenchmarkProvenance(machineIdentity: input.environment.hardwareModel,
            architecture: input.environment.architecture, memoryBytes: input.environment.physicalMemoryBytes,
            compiler: input.environment.compiler, optimization: "debug consumer; prepared dependencies and macro plugin",
            operatingSystem: input.environment.operatingSystem, sourceRevision: input.revision,
            dependencyHashes: ["consumerResolution": input.resolutionHash], fixtureHashes: fixtures, buildFlags: input.buildCommand,
            unavailabilityReasons: ["dirtyFingerprint": "Native sourceHash covers Swift sources but does not prove a complete dirty-tree fingerprint.",
                "executableHash": "Per-sample output binaries are recorded in the native compiler artifact; compiler driver executable identity is unavailable."])
        let report = DiscordBenchmarkReport(identity: identity, provenance: provenance, adapter: "swiftpm-consumer-compiler",
            clockDomain: domain, status: .completed,
            counts: .init(offered: completed, admitted: completed, completed: completed, outcomes: outcomes, deadlineMisses: 0),
            metrics: [BenchmarkMetric(id: BenchmarkWorkload.compilerClean.rawValue, clockDomain: domain, distribution: clean.snapshot()),
                BenchmarkMetric(id: BenchmarkWorkload.compilerIncremental.rawValue, clockDomain: domain, distribution: incremental.snapshot())],
            gauges: ["compilerPeakResidentBytes": .init(value: peak, unit: "bytes", method: "/usr/bin/time child maximum resident set size",
                scope: "maximum per-build process RSS across selected clean/edit pairs; not concurrent compiler-family RSS")],
            cleanup: .init(completed: true, remainingOwners: 0), throughputPerSecond: Double(completed) * 1e9 / Double(max(1, total)),
            qualificationLimitations: [
                "Offline informational debug consumer build costs; no runtime, live Discord, other-platform or controlled-host numerical qualification.",
                "Clean removes only consumer outputs. Prepared dependency/plugin bootstrap is excluded and retained separately in the native artifact.",
                "Incremental mutates one response literal before its timer and restores original bytes afterward. Gross supervised duration includes bounded output collection, RSS probes, process-group teardown and reap; receipt serialization follows the timer.",
                "One-second histogram cells retain whole build populations up to one hour; out-of-range values remain censored. One to five samples cannot qualify p99 tails.",
                "Current conversion trusts the supplied local native receipt; full raw source, target, binary and command evidence remains in that artifact.",
                "Process wall clocks are monotonic run-local durations. No timestamps from different subprocesses are correlated or combined into a timeline.",
            ])
        try report.validate()
        return report
    }

    /// Reads bounded new compiler receipts and atomically exports a selected validated common envelope.
    /// - Parameter arguments: Exactly input, mode, handlers and output key/value options.
    /// - Throws: Invalid CLI, oversized/old summary-only native input, decode/schema or filesystem errors.
    static func run(_ arguments: [String]) throws {
        guard arguments.count == 8 else { throw BenchmarkError.invalidConfiguration }
        var options: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard options.updateValue(arguments[index + 1], forKey: arguments[index]) == nil else { throw BenchmarkError.invalidConfiguration }
        }
        guard Set(options.keys) == ["--input", "--mode", "--handlers", "--output"],
              let path = options["--input"], let mode = options["--mode"], let count = options["--handlers"],
              let handlers = Int(count), let output = options["--output"], !output.isEmpty else { throw BenchmarkError.invalidConfiguration }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: DiscordBenchmarkReport.maximumSerializedBytes + 1) ?? Data()
        guard data.count <= DiscordBenchmarkReport.maximumSerializedBytes else { throw BenchmarkReportError.reportTooLarge }
        let input = try JSONDecoder().decode(CompilerTimingInput.self, from: data)
        try convert(input, mode: mode, handlers: handlers).validatedData().write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
