// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/Phase10TimingConfiguration.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Foundation

/// Bounded mixed-workflow policy; a soak target is elapsed time, never a timeout cap.
struct Phase10TimingConfiguration: Codable, Equatable, Sendable {
    var profile = "smoke"
    var observerMode = "aggregate"
    var seed: UInt64 = 1
    var durationSeconds: UInt64 = 8
    var cycleSeconds: UInt64 = 8
    var maximumRSSBytes: UInt64 = 1_073_741_824
    var maximumCPUSeconds: UInt64 = 30
    var output: String?
    var commonReport: String?

    /// Rejects partial cycles, unbounded retained receipts and aliased destinations before ownership.
    func validate() throws {
        guard ["smoke", "standard", "soak"].contains(profile), ["disabled", "aggregate"].contains(observerMode), (4...3_600).contains(durationSeconds),
              (4...60).contains(cycleSeconds), cycleSeconds.isMultiple(of: 4),
              durationSeconds.isMultiple(of: cycleSeconds), durationSeconds / cycleSeconds <= 256,
              (16_777_216...8_589_934_592).contains(maximumRSSBytes),
              (1...28_800).contains(maximumCPUSeconds), output != "", commonReport != "" else {
            throw Phase8TimingError.invalidConfiguration("Invalid integration duration, cycle, resource or report bounds")
        }
        if let output, let commonReport {
            guard URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath() !=
                URL(fileURLWithPath: commonReport).standardizedFileURL.resolvingSymlinksInPath() else {
                throw Phase8TimingError.invalidConfiguration("Output destinations alias")
            }
        }
    }

    /// Explicit flags override driver environment; all profiles retain identical workload semantics.
    static func parse(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        guard arguments.count.isMultiple(of: 2) else { throw LoadFailure.invalidArguments }
        var options: [String: String] = [:]
        for i in stride(from: 0, to: arguments.count, by: 2) {
            guard options.updateValue(arguments[i + 1], forKey: arguments[i]) == nil else { throw LoadFailure.invalidArguments }
        }
        let known: Set<String> = ["--profile", "--seed", "--duration-seconds", "--cycle-seconds", "--maximum-rss-bytes",
            "--maximum-cpu-seconds", "--observer-mode", "--output", "--common-report"]
        guard Set(options.keys).isSubset(of: known) else { throw LoadFailure.invalidArguments }
        var result = Self()
        result.observerMode = options["--observer-mode"] ?? "aggregate"
        result.profile = options["--profile"] ?? environment["DK_BENCHMARK_PROFILE"] ?? "smoke"
        result.durationSeconds = result.profile == "soak" ? 1_800 : result.profile == "standard" ? 32 : 8
        for (flag, variable) in [("--seed", "DK_BENCHMARK_SEED"), ("--duration-seconds", "DK_BENCHMARK_DURATION_SECONDS"),
            ("--cycle-seconds", ""), ("--maximum-rss-bytes", ""), ("--maximum-cpu-seconds", "")] {
            guard let value = options[flag] ?? environment[variable] else { continue }
            guard let number = UInt64(value) else { throw LoadFailure.invalidArguments }
            switch flag {
            case "--seed": result.seed = number
            case "--duration-seconds": result.durationSeconds = number
            case "--cycle-seconds": result.cycleSeconds = number
            case "--maximum-rss-bytes": result.maximumRSSBytes = number
            default: result.maximumCPUSeconds = number
            }
        }
        guard result.durationSeconds <= 3_600 else { throw LoadFailure.invalidArguments }
        if options["--maximum-cpu-seconds"] == nil { result.maximumCPUSeconds = max(30, result.durationSeconds * 2) }
        result.output = options["--output"]
        result.commonReport = options["--common-report"] ?? environment["DK_BENCHMARK_ENVELOPE"]
        try result.validate()
        return result
    }
}
