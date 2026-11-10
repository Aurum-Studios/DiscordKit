// File: Tools/DiscordDSLBenchmarks/Sources/DiscordDSLBenchmarks/Configuration.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Foundation

/// Explicit finite dimensions shared by every paired workload; changing one invalidates baseline comparison.
struct BenchmarkConfiguration: Codable, Equatable, Sendable {
    var invocations = 1_000_000
    var handlerCounts = [10, 100, 1_000]
    var concurrency = 8
    var sampleLimit = 10_000
    var payloadBytes = 64
    var minimumDurationSeconds = 0
    static let maximumInvocations = 100_000_000

    /// Rejects invalid dimensions before constructing plans, fixtures, workers or response owners.
    /// - Throws: A sanitized configuration error for any absent, duplicate or excessive dimension.
    func validate() throws {
        guard (1...10_000_000).contains(invocations), !handlerCounts.isEmpty,
              handlerCounts.count <= 3, Set(handlerCounts).count == handlerCounts.count,
              handlerCounts.allSatisfy({ [10, 100, 1_000].contains($0) }),
              (1...64).contains(concurrency), (1...100_000).contains(sampleLimit),
              (1...1_024).contains(payloadBytes), (0...1_800).contains(minimumDurationSeconds) else {
            throw BenchmarkError.invalidConfiguration
        }
    }

    /// Decodes the explicit offline CLI without reading credentials or ambient configuration.
    /// - Parameter arguments: Option/value pairs after the executable name; an empty array selects the matrix.
    /// --mode isolates direct or DSL in a fresh process; absence retains the legacy paired matrix.
    /// --warmup-invocations selects 0...1,000,000 unmeasured invocations per working set.
    /// - Returns: Validated dimensions, output, optional single mode and explicit warmup count.
    /// - Throws: Invalid configuration for unknown, repeated, incomplete or malformed options.
    static func parse(_ arguments: [String]) throws -> (configuration: Self, output: String?, mode: String?, warmupInvocations: Int) {
        var result = Self(), output: String?, seen: Set<String> = []
        var mode: String?, warmupInvocations = 0
        guard arguments.count.isMultiple(of: 2) else { throw BenchmarkError.invalidConfiguration }
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let option = arguments[index], value = arguments[index + 1]
            guard seen.insert(option).inserted else { throw BenchmarkError.invalidConfiguration }
            if option == "--mode" {
                guard ["direct", "dsl"].contains(value) else { throw BenchmarkError.invalidConfiguration }
                mode = value
            } else if option == "--warmup-invocations" {
                guard let count = Int(value), (0...1_000_000).contains(count) else { throw BenchmarkError.invalidConfiguration }
                warmupInvocations = count
            } else if option == "--output" {
                guard !value.isEmpty else { throw BenchmarkError.invalidConfiguration }
                output = value
            } else if option == "--handlers" {
                let parts = value.split(separator: ",", omittingEmptySubsequences: false)
                let counts = parts.compactMap { Int($0) }
                guard counts.count == parts.count else { throw BenchmarkError.invalidConfiguration }
                result.handlerCounts = counts
            } else {
                guard let integer = Int(value) else { throw BenchmarkError.invalidConfiguration }
                switch option {
                case "--invocations": result.invocations = integer
                case "--concurrency": result.concurrency = integer
                case "--sample-limit": result.sampleLimit = integer
                case "--payload-bytes": result.payloadBytes = integer
                case "--minimum-duration-seconds": result.minimumDurationSeconds = integer
                default: throw BenchmarkError.invalidConfiguration
                }
            }
        }
        try result.validate()
        return (result, output, mode, warmupInvocations)
    }
}

/// Bounded failures avoid retaining interaction payloads and filesystem or transport diagnostics.
enum BenchmarkError: Error { case invalidConfiguration, functionalGate, invocationCeiling }
