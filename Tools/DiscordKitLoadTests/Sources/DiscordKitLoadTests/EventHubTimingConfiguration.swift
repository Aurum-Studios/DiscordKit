// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/EventHubTimingConfiguration.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Foundation

enum EventHubTimingScenario: String, Codable, CaseIterable, Sendable {
    case queued = "gateway.hubQueuedV1"
    case waiting = "gateway.hubWaitingV1"
    case overflow = "gateway.hubOverflowV1"
    case cancelled = "gateway.hubCancelledV1"
}

enum EventHubTimingPolicy: String, Codable, CaseIterable, Sendable {
    case resynchronize, dropNewest, dropOldest
}

enum EventHubTimingError: Error, Equatable {
    case invalidConfiguration, integrityFailure(String)
}

/// Independent finite fan-out, identity, payload and backlog dimensions; no peers or credentials.
struct EventHubTimingConfiguration: Codable, Equatable, Sendable {
    var scenario = EventHubTimingScenario.queued.rawValue
    var profile = "smoke"
    var seed: UInt64 = 1
    var requests = 64
    var warmupRequests = 8
    var subscriptions = 8
    var hubs = 1
    var queuedDepth = 16
    var payloadBytes = 128
    var policy = EventHubTimingPolicy.dropNewest
    var delayMicroseconds = 0
    var durationSeconds: UInt64 = 10
    var warmupSeconds: UInt64 = 1
    var output: String?
    var commonReport: String?

    /// Bounds metadata, retained envelope charges and offered work before allocating owners.
    /// Rejects invalid ranges, more than 512 subscriptions, more than 262,144 retained copies,
    /// a 64 MiB conservative retained-envelope ceiling, and more than ten million offered copies.
    /// This development-workload ceiling is independent of a supervisor profile's tighter resource cap.
    /// - Throws: `invalidConfiguration` for any exceeded bound or aliased/empty output destination.
    func validate() throws {
        guard EventHubTimingScenario(rawValue: scenario) != nil,
              ["smoke", "standard", "stress"].contains(profile), (1...100_000).contains(requests),
              (0...10_000).contains(warmupRequests), (1...256).contains(subscriptions), (1...8).contains(hubs),
              subscriptions * hubs <= 512, (0...4_096).contains(queuedDepth),
              (0...65_536).contains(payloadBytes), (0...1_000_000).contains(delayMicroseconds),
              (1...300).contains(durationSeconds), warmupSeconds <= 60,
              output != "", commonReport != "",
              subscriptions * hubs * (queuedDepth + 1) <= 262_144,
              subscriptions * hubs * (queuedDepth + 1) * (payloadBytes + 1_024) <= 67_108_864,
              requests * subscriptions * hubs <= 10_000_000 else {
            throw EventHubTimingError.invalidConfiguration
        }
        if let output, let commonReport {
            guard URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath() !=
                URL(fileURLWithPath: commonReport).standardizedFileURL.resolvingSymlinksInPath() else {
                throw EventHubTimingError.invalidConfiguration
            }
        }
    }

    /// Parses unique options; explicit values override the shared benchmark-driver environment.
    /// - Parameters:
    ///   - arguments: Unique value-option pairs after the subcommand; unknown or repeated flags fail.
    ///   - environment: Driver profile/seed/duration/warmup/sidecar defaults, using the process environment
    ///     unless injected. Concurrency remains one sequential publisher; fan-out has separate options.
    /// - Returns: Validated finite configuration, without creating owners or writing output.
    /// - Throws: `invalidConfiguration` for malformed arguments, unknown policies or exceeded bounds.
    static func parse(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        guard arguments.count.isMultiple(of: 2) else { throw EventHubTimingError.invalidConfiguration }
        var options: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard options.updateValue(arguments[index + 1], forKey: arguments[index]) == nil else {
                throw EventHubTimingError.invalidConfiguration
            }
        }
        let known: Set<String> = ["--case", "--profile", "--seed", "--requests", "--warmup-requests", "--subscriptions",
            "--hubs", "--queued-depth", "--payload-bytes", "--policy", "--delay-microseconds", "--duration-seconds",
            "--warmup-seconds", "--output", "--common-report"]
        guard Set(options.keys).isSubset(of: known) else { throw EventHubTimingError.invalidConfiguration }
        var result = Self()
        result.scenario = options["--case"] ?? result.scenario
        result.profile = options["--profile"] ?? environment["DK_BENCHMARK_PROFILE"] ?? result.profile
        for key in ["--requests", "--warmup-requests", "--subscriptions", "--hubs", "--queued-depth", "--payload-bytes", "--delay-microseconds"] {
            guard let value = options[key] else { continue }
            guard let number = Int(value) else { throw EventHubTimingError.invalidConfiguration }
            switch key {
            case "--requests": result.requests = number
            case "--warmup-requests": result.warmupRequests = number
            case "--subscriptions": result.subscriptions = number
            case "--hubs": result.hubs = number
            case "--queued-depth": result.queuedDepth = number
            case "--payload-bytes": result.payloadBytes = number
            default: result.delayMicroseconds = number
            }
        }
        for (key, variable) in [("--seed", "DK_BENCHMARK_SEED"), ("--duration-seconds", "DK_BENCHMARK_DURATION_SECONDS"),
            ("--warmup-seconds", "DK_BENCHMARK_WARMUP_SECONDS")] {
            guard let value = options[key] ?? environment[variable] else { continue }
            guard let number = UInt64(value) else { throw EventHubTimingError.invalidConfiguration }
            switch key {
            case "--seed": result.seed = number
            case "--duration-seconds": result.durationSeconds = number
            default: result.warmupSeconds = number
            }
        }
        if let policy = options["--policy"] {
            guard let value = EventHubTimingPolicy(rawValue: policy) else { throw EventHubTimingError.invalidConfiguration }
            result.policy = value
        }
        result.output = options["--output"]
        result.commonReport = options["--common-report"] ?? environment["DK_BENCHMARK_ENVELOPE"]
        try result.validate()
        return result
    }
}
