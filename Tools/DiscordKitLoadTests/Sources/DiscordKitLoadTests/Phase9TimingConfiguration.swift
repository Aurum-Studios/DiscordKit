// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/Phase9TimingConfiguration.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Foundation

/// Finite scripted voice populations; validation precedes sockets, keys and owners.
struct Phase9TimingConfiguration: Codable, Equatable, Sendable {
    var scenario = "voice.join"
    var profile = "smoke"
    var seed: UInt64 = 1
    var requests = 16
    var concurrency = 1
    var warmupRequests = 2
    var durationSeconds: UInt64 = 10
    var warmupSeconds: UInt64 = 1
    var output: String?
    var commonReport: String?

    /// Rejects unknown cases, unbounded work and aliased output destinations.
    func validate() throws {
        guard Phase9TimingCommand.cases.contains(scenario), ["smoke", "standard", "stress", "soak"].contains(profile),
            (1...10_000).contains(requests), (1...8).contains(concurrency),
            (0...1_000).contains(warmupRequests), durationSeconds > 0,
            durationSeconds <= (profile == "soak" ? 3_600 : profile == "smoke" ? 10 : 300),
            warmupSeconds <= 60, output != "", commonReport != "" else {
            throw Phase8TimingError.invalidConfiguration("Unsupported voice case or finite workload limits")
        }
        if let output, let commonReport {
            guard URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath() !=
                URL(fileURLWithPath: commonReport).standardizedFileURL.resolvingSymlinksInPath() else {
                throw Phase8TimingError.invalidConfiguration("Output destinations alias")
            }
        }
    }

    /// Parses unique explicit values, falling back to shared process-driver policy.
    static func parse(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        guard arguments.count.isMultiple(of: 2) else { throw Phase8TimingError.invalidConfiguration("Options require values") }
        var options: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard options.updateValue(arguments[index + 1], forKey: arguments[index]) == nil else {
                throw Phase8TimingError.invalidConfiguration("Duplicate option")
            }
        }
        let known: Set<String> = ["--case", "--profile", "--seed", "--requests", "--concurrency", "--warmup-requests",
            "--duration-seconds", "--warmup-seconds", "--output", "--common-report"]
        guard Set(options.keys).isSubset(of: known) else { throw Phase8TimingError.invalidConfiguration("Unknown option") }
        var result = Self()
        result.scenario = options["--case"] ?? result.scenario
        result.profile = options["--profile"] ?? environment["DK_BENCHMARK_PROFILE"] ?? result.profile
        for (key, value) in [("requests", options["--requests"]),
            ("concurrency", options["--concurrency"] ?? environment["DK_BENCHMARK_CONCURRENCY"]),
            ("warmup", options["--warmup-requests"])] {
            guard let value else { continue }
            guard let number = Int(value) else { throw Phase8TimingError.invalidConfiguration("Invalid integer") }
            switch key {
            case "requests": result.requests = number
            case "concurrency": result.concurrency = number
            default: result.warmupRequests = number
            }
        }
        for (key, variable) in [("--seed", "DK_BENCHMARK_SEED"), ("--duration-seconds", "DK_BENCHMARK_DURATION_SECONDS"),
            ("--warmup-seconds", "DK_BENCHMARK_WARMUP_SECONDS")] {
            guard let value = options[key] ?? environment[variable] else { continue }
            guard let number = UInt64(value) else { throw Phase8TimingError.invalidConfiguration("Invalid unsigned integer") }
            switch key {
            case "--seed": result.seed = number
            case "--duration-seconds": result.durationSeconds = number
            default: result.warmupSeconds = number
            }
        }
        result.output = options["--output"]
        result.commonReport = options["--common-report"] ?? environment["DK_BENCHMARK_ENVELOPE"]
        try result.validate()
        return result
    }
}
