// File: Tools/DiscordFoundationBenchmarks/Sources/DiscordFoundationBenchmarks/Configuration.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Foundation

/// One case per process; finite batches and warmup have independent operation populations.
struct FoundationConfiguration: Codable {
    var workload = "json.parse.1024.depth1.ascii"
    var profile = "smoke"
    var seed: UInt64 = 1
    var batches = 100
    var batchSize = 16
    var warmupBatches = 8
    var durationSeconds: UInt64 = 10
    var warmupSeconds: UInt64 = 1
    var output: String?
    var commonReport: String?

    /// Checks finite profile, batch, time and distinct report destinations before fixture allocation.
    /// - Throws: Invalid configuration for unsupported profiles, bounds or aliased standardized/symlink paths.
    /// Performs no writes; a valid destination need not already exist.
    func validate() throws {
        guard ["smoke", "standard", "stress", "soak"].contains(profile), !workload.isEmpty,
            (1...100_000).contains(batches), (1...1_024).contains(batchSize),
            (0...10_000).contains(warmupBatches), warmupSeconds <= 60,
            durationSeconds > 0, durationSeconds <= (profile == "soak" ? 3_600 : profile == "smoke" ? 10 : 300),
            output != "", commonReport != "" else {
            throw FoundationBenchmarkError.invalidConfiguration("Invalid finite workload or output limits")
        }
        if let output, let commonReport,
            URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath()
                == URL(fileURLWithPath: commonReport).standardizedFileURL.resolvingSymlinksInPath() {
            throw FoundationBenchmarkError.invalidConfiguration("Native and common reports require distinct destinations")
        }
    }

    /// Explicit options override shared supervisor settings; serial CPU cases require concurrency one.
    /// - Parameters:
    ///   - arguments: Key/value options after the executable; duplicates and unknown keys are errors.
    ///   - environment: Shared supervisor requests, injectable in tests; absent settings retain finite defaults.
    /// - Returns: A validated configuration. Case existence is checked separately by the catalog.
    /// - Throws: Invalid configuration for malformed integers/options, nonserial execution, bounds or output aliasing.
    static func parse(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        guard arguments.count.isMultiple(of: 2) else {
            throw FoundationBenchmarkError.invalidConfiguration("Options require values")
        }
        var options: [String: String] = [:]
        let known: Set<String> = ["--case", "--profile", "--seed", "--batches", "--batch-size", "--warmup-batches",
            "--duration-seconds", "--warmup-seconds", "--output", "--common-report", "--concurrency"]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard known.contains(arguments[index]), options.updateValue(arguments[index + 1], forKey: arguments[index]) == nil else {
                throw FoundationBenchmarkError.invalidConfiguration("Unknown or duplicate option")
            }
        }
        guard (options["--concurrency"] ?? environment["DK_BENCHMARK_CONCURRENCY"] ?? "1") == "1" else {
            throw FoundationBenchmarkError.invalidConfiguration("Pure CPU cases run serially")
        }
        var value = Self()
        value.workload = options["--case"] ?? value.workload
        value.profile = options["--profile"] ?? environment["DK_BENCHMARK_PROFILE"] ?? value.profile
        for (key, fallback) in [("--seed", "DK_BENCHMARK_SEED"), ("--duration-seconds", "DK_BENCHMARK_DURATION_SECONDS"),
            ("--warmup-seconds", "DK_BENCHMARK_WARMUP_SECONDS")] {
            if let text = options[key] ?? environment[fallback] {
                guard let number = UInt64(text) else { throw FoundationBenchmarkError.invalidConfiguration("Invalid unsigned integer") }
                switch key {
                case "--seed": value.seed = number
                case "--duration-seconds": value.durationSeconds = number
                default: value.warmupSeconds = number
                }
            }
        }
        for key in ["--batches", "--batch-size", "--warmup-batches"] {
            if let text = options[key] {
                guard let number = Int(text) else { throw FoundationBenchmarkError.invalidConfiguration("Invalid integer") }
                switch key {
                case "--batches": value.batches = number
                case "--batch-size": value.batchSize = number
                default: value.warmupBatches = number
                }
            }
        }
        value.output = options["--output"]
        value.commonReport = options["--common-report"] ?? environment["DK_BENCHMARK_ENVELOPE"]
        try value.validate()
        return value
    }
}
