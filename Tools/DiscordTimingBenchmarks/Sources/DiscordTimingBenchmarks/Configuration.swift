// File: Tools/DiscordTimingBenchmarks/Sources/DiscordTimingBenchmarks/Configuration.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Foundation

/// Fixed development modes; scalar REST cases have a different workload from CPU fixture cases.
enum TimingMode: String, Codable, CaseIterable, Sendable {
    case disabled, noop, aggregate, sampled, filtered, callback, callbackContention
    case console, rotatingFile, sinkFailure, saturation, unifiedLog, signposts, combined
    case clockRead, emptyHarness, scalarDisabled, scalarNoop, scalarAggregate

    /// Whether this mode exercises real scalar hooks through a local REST owner.
    var usesREST: Bool {
        /// Selects the three local REST populations without conflating them with CPU observations.
        get { self == .scalarDisabled || self == .scalarNoop || self == .scalarAggregate }
    }
}

/// Explicit CLI/input failures stop before opening outputs or starting workers.
enum TimingBenchmarkError: Error, Equatable {
    case invalidConfiguration(String), integrityFailure(String), unsupportedPlatform(String)
}

/// Development collector ownership; the default retains the original shared-observer workload.
enum TimingCollectorScope: String, Codable, CaseIterable, Sendable {
    case shared, perWorker
}

/// Finite workload and output ownership policy, passed by value to every bounded worker.
struct TimingConfiguration: Codable, Sendable {
    var mode: TimingMode = .disabled
    var profile = "smoke"
    var seed: UInt64 = 1
    var iterations = 1_000
    var warmupIterations = 128
    var concurrency = 1
    var collectorScope: TimingCollectorScope = .shared
    var durationSeconds: UInt64 = 10
    var warmupSeconds: UInt64 = 1
    var output: String?
    var commonReport: String?
    var artifactDirectory: String?

    /// Validates limits before allocating histograms, opening sinks or creating the finite cohort.
    /// - Throws: Configuration errors for unknown profiles, invalid cohorts, bounds or contention policy.
    func validate() throws {
        let cap: Int
        switch profile {
        case "smoke": cap = 64
        case "standard", "stress", "soak": cap = 64
        default: throw TimingBenchmarkError.invalidConfiguration("Unknown profile")
        }
        guard (1...cap).contains(concurrency), (1...1_000_000).contains(iterations),
            (0...1_000_000).contains(warmupIterations), warmupSeconds <= 60,
            durationSeconds > 0, durationSeconds <= (profile == "soak" ? 3_600 : profile == "smoke" ? 10 : 300),
            mode != .callbackContention || concurrency >= 2 else {
            throw TimingBenchmarkError.invalidConfiguration("Invalid finite workload limits")
        }
        guard output != "", commonReport != "", artifactDirectory != "" else {
            throw TimingBenchmarkError.invalidConfiguration("Empty output destination")
        }
    }

    /// Parses key/value CLI arguments and shared-driver environment without implicit performance claims.
    /// - Parameters:
    ///   - arguments: Arguments after the executable; every option needs one value.
    ///   - environment: Driver settings, with explicit CLI options taking precedence.
    /// - Returns: A validated finite configuration. Iteration caps can finish before the time cap.
    /// - Throws: Unknown, duplicated or malformed options and invalid finite limits.
    static func parse(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        var result = Self()
        var options: [String: String] = [:]
        guard arguments.count.isMultiple(of: 2) else {
            throw TimingBenchmarkError.invalidConfiguration("Options require values")
        }
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard options.updateValue(arguments[index + 1], forKey: arguments[index]) == nil else {
                throw TimingBenchmarkError.invalidConfiguration("Duplicate option")
            }
        }
        let known: Set<String> = ["--mode", "--profile", "--seed", "--iterations", "--warmup-iterations",
            "--concurrency", "--collector-scope", "--duration-seconds", "--warmup-seconds", "--output", "--common-report", "--artifact-directory"]
        guard Set(options.keys).isSubset(of: known) else { throw TimingBenchmarkError.invalidConfiguration("Unknown option") }
        if let value = options["--mode"] {
            guard let mode = TimingMode(rawValue: value) else { throw TimingBenchmarkError.invalidConfiguration("Unknown mode") }
            result.mode = mode
        }
        if let value = options["--collector-scope"] {
            guard let scope = TimingCollectorScope(rawValue: value) else {
                throw TimingBenchmarkError.invalidConfiguration("Unknown collector scope")
            }
            result.collectorScope = scope
        }
        result.profile = options["--profile"] ?? environment["DK_BENCHMARK_PROFILE"] ?? result.profile
        for (key, fallback) in [("--seed", "DK_BENCHMARK_SEED"), ("--duration-seconds", "DK_BENCHMARK_DURATION_SECONDS"),
            ("--warmup-seconds", "DK_BENCHMARK_WARMUP_SECONDS")] {
            if let text = options[key] ?? environment[fallback] {
                guard let value = UInt64(text) else { throw TimingBenchmarkError.invalidConfiguration("Invalid unsigned integer") }
                switch key {
                case "--seed": result.seed = value
                case "--duration-seconds": result.durationSeconds = value
                default: result.warmupSeconds = value
                }
            }
        }
        for (key, text) in [("--iterations", options["--iterations"]), ("--warmup-iterations", options["--warmup-iterations"]),
            ("--concurrency", options["--concurrency"] ?? environment["DK_BENCHMARK_CONCURRENCY"])] {
            if let text {
                guard let value = Int(text) else { throw TimingBenchmarkError.invalidConfiguration("Invalid integer") }
                switch key {
                case "--iterations": result.iterations = value
                case "--warmup-iterations": result.warmupIterations = value
                default: result.concurrency = value
                }
            }
        }
        result.output = options["--output"]
        result.commonReport = options["--common-report"] ?? environment["DK_BENCHMARK_ENVELOPE"]
        result.artifactDirectory = options["--artifact-directory"]
        try result.validate()
        return result
    }
}
