// File: Tools/DiscordDSLBenchmarks/Tests/DiscordDSLBenchmarksTests/CompilerTimingTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation
import Testing
@testable import DiscordDSLBenchmarks

/// Compiler conversion uses exact raw integer builds and never interprets legacy runtime percentiles.
@Suite struct CompilerTimingTests {
    /// Creates a bounded new compiler receipt with independent clean and edited process observations.
    /// - Parameter clean: Raw monotonic clean wall duration, permitted to exceed the histogram range.
    /// - Returns: A native object whose irrelevant compiler details are deliberately minimal and fixed.
    private func fixture(clean: UInt64 = 2_000_000_000) -> [String: Any] {
        let digest = String(repeating: "a", count: 64)
        return ["schemaVersion": 1, "metricCatalogVersion": 7, "reportKind": "dsl-compiler-cost",
            "configuration": ["modules": 1, "jobs": 4, "samples": 1, "configuration": "debug", "buildSystem": "native", "timingBoundary": "supervised-process-lifetime-v1", "dependencyColdBuildIncluded": false],
            "environment": ["operatingSystem": "fixture", "architecture": "fixture", "processorCount": 4,
                "compiler": "Swift version 6.4 fixture", "hardwareModel": "fixture", "physicalMemoryBytes": 1_024],
            "revision": "fixture-source", "sourceHash": digest, "fixtureHash": digest, "resolutionHash": digest,
            "manifestHash": digest, "buildCommand": ["swift", "build", "--configuration", "debug"],
            "workloads": [["mode": "manual", "handlerCount": 10, "functionalGatesPassed": true,
                "samples": [["clean": ["wallNanoseconds": clean, "peakRSSBytes": 1_024],
                    "incremental": ["wallNanoseconds": 200_000_000, "peakRSSBytes": 2_048], "binarySHA256": digest]]]]]
    }

    /// Decodes the same bounded native JSON format accepted by the compiler-report subcommand.
    /// - Parameter object: Mutatable independent fixture for one semantic case.
    /// - Returns: Strict integer-based compiler observations.
    /// - Throws: Encoding or decoding errors; floating legacy summaries are never accepted as substitutes.
    private func decode(_ object: [String: Any]) throws -> CompilerTimingInput {
        try JSONDecoder().decode(CompilerTimingInput.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// Clean and incremental builds retain different metric populations, fixture receipts and process RSS scope.
    /// - Throws: Unexpected schema, hash, conversion or validation errors.
    @Test func rawBuildPopulationAndHashes() throws {
        let report = try CompilerTimingCommand.convert(decode(fixture()), mode: "manual", handlers: 10)
        #expect(report.counts?.completed == 2)
        #expect(report.identity.catalogVersion == 7)
        #expect(report.metrics.map(\.id) == ["compiler.clean", "compiler.incremental"])
        #expect(report.metrics.allSatisfy { $0.distribution.observedCount == 1 })
        #expect(report.metrics[0].distribution.configuration.bucketWidthNanoseconds == 1_000_000_000)
        #expect(report.gauges["compilerPeakResidentBytes"]?.value == 2_048)
        #expect(report.provenance.fixtureHashes == report.identity.fixtureHashes)
        #expect(report.provenance.dependencyHashes.count == 1)
        try report.validate()
        #expect(throws: BenchmarkError.self) { try CompilerTimingCommand.convert(decode(fixture()), mode: "macro", handlers: 10) }
    }

    /// Hour-long overflow remains explicit censored mass instead of a fabricated finite percentile or maximum.
    /// - Throws: Unexpected raw conversion or schema errors.
    @Test func overflowRemainsCensored() throws {
        let report = try CompilerTimingCommand.convert(decode(fixture(clean: 3_600_000_000_001)), mode: "manual", handlers: 10)
        #expect(report.metrics[0].distribution.overflowCount == 1)
        #expect(report.metrics[0].maximum == .overflow(lowerExclusiveNanoseconds: 3_600_000_000_000))
    }

    /// Legacy summary-only, malformed identity, duplicate selection and failed native gates are rejected.
    /// - Throws: Unexpected fixture decoding errors; intended invalid receipts are captured by assertions.
    @Test func malformedAndLegacyEvidenceRejected() throws {
        var legacy = fixture()
        legacy.removeValue(forKey: "metricCatalogVersion")
        #expect(throws: (any Error).self) { try decode(legacy) }
        var oldBoundary = fixture()
        var configuration = try #require(oldBoundary["configuration"] as? [String: Any])
        configuration["timingBoundary"] = "legacy-direct-wait"
        oldBoundary["configuration"] = configuration
        #expect(throws: BenchmarkError.self) { try CompilerTimingCommand.convert(decode(oldBoundary), mode: "manual", handlers: 10) }
        var malformed = fixture()
        malformed["fixtureHash"] = "invalid"
        #expect(throws: BenchmarkError.self) { try CompilerTimingCommand.convert(decode(malformed), mode: "manual", handlers: 10) }
        var duplicated = fixture()
        let rows = try #require(duplicated["workloads"] as? [[String: Any]])
        duplicated["workloads"] = rows + rows
        #expect(throws: BenchmarkError.self) { try CompilerTimingCommand.convert(decode(duplicated), mode: "manual", handlers: 10) }
        var failed = rows[0]
        failed["functionalGatesPassed"] = false
        duplicated["workloads"] = [failed]
        #expect(throws: BenchmarkError.self) { try CompilerTimingCommand.convert(decode(duplicated), mode: "manual", handlers: 10) }
    }
}
