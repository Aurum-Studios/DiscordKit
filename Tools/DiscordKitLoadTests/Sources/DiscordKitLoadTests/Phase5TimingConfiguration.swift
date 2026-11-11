// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/Phase5TimingConfiguration.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Foundation

/// Invalid settings fail before peers, policy owners, outputs or workers are created.
enum Phase5TimingError: Error, Equatable {
    case invalidConfiguration(String), integrityFailure(String)
}

/// Explicit finite policies for corrected transport/REST timers and bounded arrival scheduling.
struct Phase5TimingConfiguration: Codable, Equatable, Sendable {
    var scenario = "rest.noCache"
    var adapter = "scripted"
    var connectionMode = "warm"
    var tls = false
    var profile = "smoke"
    var seed: UInt64 = 1
    var requests = 64
    var concurrency = 4
    var warmupRequests = 8
    var pending = 16
    var rate = 1_000
    var delayMicroseconds = 2_000
    var durationSeconds: UInt64 = 10
    var warmupSeconds: UInt64 = 1
    var output: String?
    var commonReport: String?

    /// Checks the complete finite policy without allocating workload state.
    /// - Throws: Unsupported cases/options, unsafe limits, contradictory transport policy or aliased outputs.
    func validate() throws {
        let cases = Set(Phase5TimingCommand.cases)
        guard cases.contains(scenario), ["smoke", "standard", "stress", "soak"].contains(profile),
            ["nio", "foundation", "scripted"].contains(adapter), ["cold", "warm"].contains(connectionMode),
            (1...100_000).contains(requests), (1...(profile == "smoke" ? 64 : 256)).contains(concurrency),
            (0...10_000).contains(warmupRequests), (0...1_024).contains(pending), concurrency + pending <= 1_024,
            (1...1_000_000).contains(rate), (0...1_000_000).contains(delayMicroseconds),
            durationSeconds > 0, durationSeconds <= (profile == "soak" ? 3_600 : profile == "smoke" ? 10 : 300),
            warmupSeconds <= 60, output != "", commonReport != "" else {
            throw Phase5TimingError.invalidConfiguration("Unsupported case or finite workload limits")
        }
        guard scenario.hasPrefix("transport.") || (adapter == "scripted" && connectionMode == "warm" && !tls),
            !tls || adapter == "nio", connectionMode != "cold" || concurrency == 1 else {
            throw Phase5TimingError.invalidConfiguration("Incompatible adapter, TLS or cold-connection policy")
        }
        if let output, let commonReport {
            let native = URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath()
            let common = URL(fileURLWithPath: commonReport).standardizedFileURL.resolvingSymlinksInPath()
            guard native != common else { throw Phase5TimingError.invalidConfiguration("Output destinations alias") }
        }
    }

    /// Parses unique key/value options and shared-driver requests without starting any workload.
    /// - Parameters:
    ///   - arguments: Arguments after the explicit `timing` subcommand; all options require a value.
    ///   - environment: Shared capture settings; explicit options take precedence.
    /// - Returns: Checked finite configuration with separate native/common output ownership.
    /// - Throws: Unknown/duplicate/missing options, invalid integers or inconsistent policies.
    static func parse(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        guard arguments.count.isMultiple(of: 2) else {
            throw Phase5TimingError.invalidConfiguration("Options require values")
        }
        var options: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard options.updateValue(arguments[index + 1], forKey: arguments[index]) == nil else {
                throw Phase5TimingError.invalidConfiguration("Duplicate option")
            }
        }
        let known: Set<String> = ["--case", "--adapter", "--connection-mode", "--tls", "--profile", "--seed",
            "--requests", "--concurrency", "--warmup-requests", "--pending", "--rate", "--delay-microseconds",
            "--duration-seconds", "--warmup-seconds", "--output", "--common-report"]
        guard Set(options.keys).isSubset(of: known) else { throw Phase5TimingError.invalidConfiguration("Unknown option") }
        var result = Self()
        result.scenario = options["--case"] ?? result.scenario
        result.adapter = options["--adapter"] ?? result.adapter
        result.connectionMode = options["--connection-mode"] ?? result.connectionMode
        result.profile = options["--profile"] ?? environment["DK_BENCHMARK_PROFILE"] ?? result.profile
        if let tls = options["--tls"] {
            guard ["true", "false"].contains(tls) else { throw Phase5TimingError.invalidConfiguration("Invalid TLS flag") }
            result.tls = tls == "true"
        }
        for (key, value) in [("--requests", options["--requests"]),
            ("--concurrency", options["--concurrency"] ?? environment["DK_BENCHMARK_CONCURRENCY"]),
            ("--warmup-requests", options["--warmup-requests"]), ("--pending", options["--pending"]),
            ("--rate", options["--rate"]), ("--delay-microseconds", options["--delay-microseconds"])] {
            guard let value else { continue }
            guard let number = Int(value) else { throw Phase5TimingError.invalidConfiguration("Invalid integer") }
            switch key {
            case "--requests": result.requests = number
            case "--concurrency": result.concurrency = number
            case "--warmup-requests": result.warmupRequests = number
            case "--pending": result.pending = number
            case "--rate": result.rate = number
            default: result.delayMicroseconds = number
            }
        }
        for (key, variable) in [("--seed", "DK_BENCHMARK_SEED"), ("--duration-seconds", "DK_BENCHMARK_DURATION_SECONDS"),
            ("--warmup-seconds", "DK_BENCHMARK_WARMUP_SECONDS")] {
            guard let value = options[key] ?? environment[variable] else { continue }
            guard let number = UInt64(value) else { throw Phase5TimingError.invalidConfiguration("Invalid unsigned integer") }
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
