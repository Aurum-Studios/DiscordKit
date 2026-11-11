// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/CacheScalingTimingConfiguration.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordLogging
import Foundation

/// Public cache implementation selected independently from fixture dimensions.
enum CacheScalingTimingOwner: String, Codable, CaseIterable, Sendable { case entity, read }

/// Versioned serial experiments; existing cache-client timing identities remain unchanged.
enum CacheScalingTimingScenario: String, Codable, CaseIterable, Sendable {
    case hotHit = "cache.hotHitV1"
    case miss = "cache.missV1"
    case update = "cache.updateV1"
    case expiryStorm = "cache.expiryStormV1"
    case capacity = "cache.capacityV1"
    case invalidation = "cache.invalidationV1"

    /// Actual entity-cache owner interval; the read cache exposes no corresponding hook.
    var ownerStage: DiscordIntervalStage {
        switch self {
        case .hotHit, .miss, .expiryStorm: .cacheLookup
        case .update, .capacity: .cacheMerge
        case .invalidation: .cacheInvalidation
        }
    }
}

enum CacheScalingTimingError: Error, Equatable { case invalidConfiguration, integrityFailure(String) }

/// Aggregate working set stays fixed when identity count, payload size or replacement churn changes.
struct CacheScalingTimingConfiguration: Codable, Equatable, Sendable {
    var scenario = CacheScalingTimingScenario.hotHit.rawValue
    var owner = CacheScalingTimingOwner.entity
    var profile = "smoke"
    var seed: UInt64 = 1
    var requests = 64
    var warmupRequests = 8
    var workingSet = 16
    var identities = 1
    var payloadBytes = 128
    var churnUpdates = 0
    var durationSeconds: UInt64 = 10
    var warmupSeconds: UInt64 = 1
    var output: String?
    var commonReport: String?

    /// Rejects invalid dimensions before creating owners, including more than 16 MiB charged state
    /// or ten million untimed setup/churn/recovery writes. Initial fills, expiry refills and
    /// recovery writes for separate active warmup/measured owners are all included in that bound.
    /// - Throws: `invalidConfiguration` for exceeded bounds, malformed cases or aliased destinations.
    func validate() throws {
        guard CacheScalingTimingScenario(rawValue: scenario) != nil,
              ["smoke", "standard", "stress"].contains(profile), (1...100_000).contains(requests),
              (0...10_000).contains(warmupRequests), (1...4_096).contains(workingSet),
              (1...min(32, workingSet)).contains(identities), (0...65_536).contains(payloadBytes),
              (0...64).contains(churnUpdates), (1...300).contains(durationSeconds), warmupSeconds <= 60,
              workingSet * (payloadBytes + 1_024) <= 16_777_216,
              output != "", commonReport != "" else { throw CacheScalingTimingError.invalidConfiguration }
        let warmupWrites = warmupRequests > 0 && warmupSeconds > 0 ? setupWrites(requests: warmupRequests) : 0
        guard setupWrites(requests: requests) + warmupWrites <= 10_000_000 else {
            throw CacheScalingTimingError.invalidConfiguration
        }
        if let output, let commonReport {
            guard URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath() !=
                URL(fileURLWithPath: commonReport).standardizedFileURL.resolvingSymlinksInPath() else {
                throw CacheScalingTimingError.invalidConfiguration
            }
        }
    }

    /// Counts every untimed write for one owner, including initial prefill and recovery.
    /// - Parameter requests: Positive already range-validated population size.
    /// - Returns: Exact bounded setup/churn count; measured operation calls are separate.
    private func setupWrites(requests: Int) -> Int {
        switch CacheScalingTimingScenario(rawValue: scenario)! {
        case .expiryStorm: requests * (workingSet + churnUpdates) + 1
        case .invalidation: workingSet + requests * (churnUpdates + 1)
        default: workingSet + requests * churnUpdates
        }
    }

    /// Parses unique value flags and shared supervisor defaults without allocating cache state.
    /// - Parameters:
    ///   - arguments: Unique option/value pairs after `cache-scaling-timing`.
    ///   - environment: Shared profile, seed, duration, warmup and sidecar defaults.
    /// - Returns: Validated finite configuration; measured concurrency is always one.
    /// - Throws: `invalidConfiguration` for unknown/duplicate options or malformed numeric values.
    static func parse(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        guard arguments.count.isMultiple(of: 2) else { throw CacheScalingTimingError.invalidConfiguration }
        var options: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard options.updateValue(arguments[index + 1], forKey: arguments[index]) == nil else {
                throw CacheScalingTimingError.invalidConfiguration
            }
        }
        let known: Set<String> = ["--case", "--owner", "--profile", "--seed", "--requests", "--warmup-requests",
            "--working-set", "--identities", "--payload-bytes", "--churn-updates", "--duration-seconds",
            "--warmup-seconds", "--output", "--common-report"]
        guard Set(options.keys).isSubset(of: known) else { throw CacheScalingTimingError.invalidConfiguration }
        var result = Self()
        result.scenario = options["--case"] ?? result.scenario
        result.profile = options["--profile"] ?? environment["DK_BENCHMARK_PROFILE"] ?? result.profile
        if let owner = options["--owner"] {
            guard let value = CacheScalingTimingOwner(rawValue: owner) else { throw CacheScalingTimingError.invalidConfiguration }
            result.owner = value
        }
        for key in ["--requests", "--warmup-requests", "--working-set", "--identities", "--payload-bytes", "--churn-updates"] {
            guard let value = options[key] else { continue }
            guard let number = Int(value) else { throw CacheScalingTimingError.invalidConfiguration }
            switch key {
            case "--requests": result.requests = number
            case "--warmup-requests": result.warmupRequests = number
            case "--working-set": result.workingSet = number
            case "--identities": result.identities = number
            case "--payload-bytes": result.payloadBytes = number
            default: result.churnUpdates = number
            }
        }
        for (key, variable) in [("--seed", "DK_BENCHMARK_SEED"), ("--duration-seconds", "DK_BENCHMARK_DURATION_SECONDS"),
            ("--warmup-seconds", "DK_BENCHMARK_WARMUP_SECONDS")] {
            guard let value = options[key] ?? environment[variable] else { continue }
            guard let number = UInt64(value) else { throw CacheScalingTimingError.invalidConfiguration }
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
