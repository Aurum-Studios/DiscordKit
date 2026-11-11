// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/Phase6TimingConfiguration.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Foundation

/// Invalid policies fail before opening any peer, response sink, task or output.
enum Phase6TimingError: Error, Equatable {
    case invalidConfiguration(String), integrityFailure(String)
}

/// Finite, independent warmup and measured populations for local command workflows.
struct Phase6TimingConfiguration: Codable, Equatable, Sendable {
    var scenario = "interaction.immediate"
    var profile = "smoke"
    var seed: UInt64 = 1
    var requests = 64
    var concurrency = 4
    var warmupRequests = 8
    var rate = 1_000
    var delayMicroseconds = 2_000
    var durationSeconds: UInt64 = 10
    var warmupSeconds: UInt64 = 1
    var output: String?
    var commonReport: String?

    /// Rejects unknown scenarios, unsafe limits and destinations sharing the same file.
    func validate() throws {
        guard Phase6TimingCommand.cases.contains(scenario), ["smoke", "standard", "stress", "soak"].contains(profile),
            (1...100_000).contains(requests), (1...(profile == "smoke" ? 64 : 256)).contains(concurrency),
            (0...10_000).contains(warmupRequests), (1...1_000_000).contains(rate),
            (0...1_000_000).contains(delayMicroseconds), durationSeconds > 0,
            durationSeconds <= (profile == "soak" ? 3_600 : profile == "smoke" ? 10 : 300),
            warmupSeconds <= 60, output != "", commonReport != "",
            scenario != "interaction.replayNearCapacityV1" || (requests <= 256 && warmupRequests <= 256) else {
            throw Phase6TimingError.invalidConfiguration("Unsupported case or finite workload limits")
        }
        if let output, let commonReport {
            guard URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath() !=
                URL(fileURLWithPath: commonReport).standardizedFileURL.resolvingSymlinksInPath() else {
                throw Phase6TimingError.invalidConfiguration("Output destinations alias")
            }
        }
    }

    /// Parses unique value options; explicit values override the shared subprocess driver.
    static func parse(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        guard arguments.count.isMultiple(of: 2) else { throw Phase6TimingError.invalidConfiguration("Options require values") }
        var options: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard options.updateValue(arguments[index + 1], forKey: arguments[index]) == nil else {
                throw Phase6TimingError.invalidConfiguration("Duplicate option")
            }
        }
        let known: Set<String> = ["--case", "--profile", "--seed", "--requests", "--concurrency", "--warmup-requests",
            "--rate", "--delay-microseconds", "--duration-seconds", "--warmup-seconds", "--output", "--common-report"]
        guard Set(options.keys).isSubset(of: known) else { throw Phase6TimingError.invalidConfiguration("Unknown option") }
        var result = Self()
        result.scenario = options["--case"] ?? result.scenario
        result.profile = options["--profile"] ?? environment["DK_BENCHMARK_PROFILE"] ?? result.profile
        for (key, value) in [("--requests", options["--requests"]),
            ("--concurrency", options["--concurrency"] ?? environment["DK_BENCHMARK_CONCURRENCY"]),
            ("--warmup-requests", options["--warmup-requests"]), ("--rate", options["--rate"]),
            ("--delay-microseconds", options["--delay-microseconds"])] {
            guard let value else { continue }
            guard let number = Int(value) else { throw Phase6TimingError.invalidConfiguration("Invalid integer") }
            switch key {
            case "--requests": result.requests = number
            case "--concurrency": result.concurrency = number
            case "--warmup-requests": result.warmupRequests = number
            case "--rate": result.rate = number
            default: result.delayMicroseconds = number
            }
        }
        for (key, variable) in [("--seed", "DK_BENCHMARK_SEED"), ("--duration-seconds", "DK_BENCHMARK_DURATION_SECONDS"),
            ("--warmup-seconds", "DK_BENCHMARK_WARMUP_SECONDS")] {
            guard let value = options[key] ?? environment[variable] else { continue }
            guard let number = UInt64(value) else { throw Phase6TimingError.invalidConfiguration("Invalid unsigned integer") }
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
