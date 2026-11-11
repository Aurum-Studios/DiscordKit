// File: Tools/DiscordKitLoadTests/Sources/DiscordKitLoadTests/Phase8TimingConfiguration.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Foundation

/// Invalid policies fail before opening any peer, response sink, task or output.
enum Phase8TimingError: Error, Equatable {
    case invalidConfiguration(String), integrityFailure(String)
}

/// Finite, independent warmup and measured populations for local optional service workflows.
struct Phase8TimingConfiguration: Codable, Equatable, Sendable {
    var scenario = "oauth.lookup"
    var profile = "smoke"
    var seed: UInt64 = 1
    var requests = 64
    var concurrency = 4
    var warmupRequests = 8
    var fanOut = 2
    var delayMicroseconds = 2_000
    var storageDelayMicroseconds = 0
    var backendDelayMicroseconds = 0
    var subscriptionGroups = 1
    var ownersPerGroup = 1
    var queueDepth = 0
    var durationSeconds: UInt64 = 10
    var warmupSeconds: UInt64 = 1
    var output: String?
    var commonReport: String?

    /// Rejects unknown scenarios, unsafe limits and destinations sharing the same file.
    func validate() throws {
        guard Phase8TimingCommand.cases.contains(scenario), ["smoke", "standard", "stress", "soak"].contains(profile),
            (1...100_000).contains(requests),
            (1...(OAuthTimingScenario(rawValue: scenario)?.isScaling == true ? 256 : 64)).contains(concurrency),
            (0...10_000).contains(warmupRequests), (1...32).contains(fanOut),
            (0...1_000_000).contains(delayMicroseconds),
            (0...1_000_000).contains(storageDelayMicroseconds), (0...1_000_000).contains(backendDelayMicroseconds),
            (1...4_096).contains(subscriptionGroups), (1...4_096).contains(ownersPerGroup),
            subscriptionGroups * (ownersPerGroup + 1) <= 65_536, (0...4_096).contains(queueDepth), durationSeconds > 0,
            durationSeconds <= (profile == "soak" ? 3_600 : profile == "smoke" ? 10 : 300),
            warmupSeconds <= 60, output != "", commonReport != "" else {
            throw Phase8TimingError.invalidConfiguration("Unsupported case or finite workload limits")
        }
        guard OAuthTimingScenario(rawValue: scenario)?.isScaling == true ||
                (storageDelayMicroseconds == 0 && backendDelayMicroseconds == 0),
              scenario == "activities.subscriptionGroupsV1" || (subscriptionGroups == 1 && ownersPerGroup == 1),
              scenario == "rpc.queuedRepliesV1" || queueDepth == 0 else {
            throw Phase8TimingError.invalidConfiguration("Versioned dimensions require their matching workload")
        }
        guard OAuthTimingScenario(rawValue: scenario)?.isScaling != true || delayMicroseconds == 0 else {
            throw Phase8TimingError.invalidConfiguration("Versioned OAuth uses independent storage/backend delays")
        }
        if let output, let commonReport {
            guard URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath() !=
                URL(fileURLWithPath: commonReport).standardizedFileURL.resolvingSymlinksInPath() else {
                throw Phase8TimingError.invalidConfiguration("Output destinations alias")
            }
        }
    }

    /// Parses unique value options; explicit values override the shared subprocess driver.
    static func parse(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        guard arguments.count.isMultiple(of: 2) else { throw Phase8TimingError.invalidConfiguration("Options require values") }
        var options: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard options.updateValue(arguments[index + 1], forKey: arguments[index]) == nil else {
                throw Phase8TimingError.invalidConfiguration("Duplicate option")
            }
        }
        let known: Set<String> = ["--case", "--profile", "--seed", "--requests", "--concurrency", "--warmup-requests",
            "--fan-out", "--delay-microseconds", "--storage-delay-microseconds", "--backend-delay-microseconds",
            "--subscription-groups", "--owners-per-group", "--queue-depth", "--duration-seconds", "--warmup-seconds", "--output", "--common-report"]
        guard Set(options.keys).isSubset(of: known) else { throw Phase8TimingError.invalidConfiguration("Unknown option") }
        var result = Self()
        result.scenario = options["--case"] ?? result.scenario
        result.profile = options["--profile"] ?? environment["DK_BENCHMARK_PROFILE"] ?? result.profile
        for (key, value) in [("--requests", options["--requests"]),
            ("--concurrency", options["--concurrency"] ?? environment["DK_BENCHMARK_CONCURRENCY"]),
            ("--warmup-requests", options["--warmup-requests"]), ("--fan-out", options["--fan-out"]),
            ("--delay-microseconds", options["--delay-microseconds"]),
            ("--storage-delay-microseconds", options["--storage-delay-microseconds"]),
            ("--backend-delay-microseconds", options["--backend-delay-microseconds"]),
            ("--subscription-groups", options["--subscription-groups"]), ("--owners-per-group", options["--owners-per-group"]),
            ("--queue-depth", options["--queue-depth"])] {
            guard let value else { continue }
            guard let number = Int(value) else { throw Phase8TimingError.invalidConfiguration("Invalid integer") }
            switch key {
            case "--requests": result.requests = number
            case "--concurrency": result.concurrency = number
            case "--warmup-requests": result.warmupRequests = number
            case "--fan-out": result.fanOut = number
            case "--storage-delay-microseconds": result.storageDelayMicroseconds = number
            case "--backend-delay-microseconds": result.backendDelayMicroseconds = number
            case "--subscription-groups": result.subscriptionGroups = number
            case "--owners-per-group": result.ownersPerGroup = number
            case "--queue-depth": result.queueDepth = number
            default: result.delayMicroseconds = number
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
        if OAuthTimingScenario(rawValue: result.scenario)?.isScaling == true && options["--delay-microseconds"] == nil {
            result.delayMicroseconds = 0
        }
        try result.validate()
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case scenario, profile, seed, requests, concurrency, warmupRequests, fanOut, delayMicroseconds
        case storageDelayMicroseconds, backendDelayMicroseconds, subscriptionGroups, ownersPerGroup, queueDepth
        case durationSeconds, warmupSeconds, output, commonReport
    }

    /// Creates the retained smoke defaults without allocating any runtime service owner.
    init() {}

    /// Older native reports omit only the newly introduced versioned dimensions.
    /// - Parameter decoder: Native report configuration containing the original finite policy fields.
    /// - Throws: Missing original fields or a field of an incompatible serialized type.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        scenario = try values.decode(String.self, forKey: .scenario)
        profile = try values.decode(String.self, forKey: .profile)
        seed = try values.decode(UInt64.self, forKey: .seed)
        requests = try values.decode(Int.self, forKey: .requests)
        concurrency = try values.decode(Int.self, forKey: .concurrency)
        warmupRequests = try values.decode(Int.self, forKey: .warmupRequests)
        fanOut = try values.decode(Int.self, forKey: .fanOut)
        delayMicroseconds = try values.decode(Int.self, forKey: .delayMicroseconds)
        storageDelayMicroseconds = try values.decodeIfPresent(Int.self, forKey: .storageDelayMicroseconds) ?? 0
        backendDelayMicroseconds = try values.decodeIfPresent(Int.self, forKey: .backendDelayMicroseconds) ?? 0
        subscriptionGroups = try values.decodeIfPresent(Int.self, forKey: .subscriptionGroups) ?? 1
        ownersPerGroup = try values.decodeIfPresent(Int.self, forKey: .ownersPerGroup) ?? 1
        queueDepth = try values.decodeIfPresent(Int.self, forKey: .queueDepth) ?? 0
        durationSeconds = try values.decode(UInt64.self, forKey: .durationSeconds)
        warmupSeconds = try values.decode(UInt64.self, forKey: .warmupSeconds)
        output = try values.decodeIfPresent(String.self, forKey: .output)
        commonReport = try values.decodeIfPresent(String.self, forKey: .commonReport)
    }
}
