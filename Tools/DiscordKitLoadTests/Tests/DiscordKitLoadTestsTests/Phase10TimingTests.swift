// File: Tools/DiscordKitLoadTests/Tests/DiscordKitLoadTestsTests/Phase10TimingTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation
import Testing
@testable import DiscordKitLoadTests

@Suite struct Phase10TimingTests {
    /// A bounded30-minute target is explicit, with no population-sized retained reports.
    @Test func policy() throws {
        let value = try Phase10TimingConfiguration.parse(["--profile", "soak", "--seed", "9"], environment: [:])
        #expect(value.durationSeconds == 1_800 && value.cycleSeconds == 8)
        #expect(value.durationSeconds / value.cycleSeconds == 225)
        #expect(value.maximumCPUSeconds == 3_600 && value.maximumRSSBytes == 1_073_741_824)
        let disabled = try Phase10TimingConfiguration.parse(["--observer-mode", "disabled", "--duration-seconds", "4",
            "--cycle-seconds", "4"], environment: ["DK_BENCHMARK_SEED": "7", "DK_BENCHMARK_ENVELOPE": "common.json"])
        #expect(disabled.observerMode == "disabled" && disabled.seed == 7 && disabled.commonReport == "common.json")
    }

    /// Invalid resource limits, overflow inputs and incomplete cycles fail before creating runtime owners.
    @Test(arguments: [["--duration-seconds"], ["--wat", "1"], ["--seed", "1", "--seed", "2"],
        ["--duration-seconds", "3"], ["--duration-seconds", "9"], ["--cycle-seconds", "6"],
        ["--profile", "unknown"], ["--observer-mode", "unknown"], ["--maximum-rss-bytes", "1"],
        ["--maximum-cpu-seconds", "0"], ["--duration-seconds", "18446744073709551615"],
        ["--duration-seconds", "3600", "--cycle-seconds", "4"],
        ["--output", "same.json", "--common-report", "./same.json"]])
    func invalidPolicy(arguments: [String]) {
        #expect(throws: (any Error).self) { try Phase10TimingConfiguration.parse(arguments, environment: [:]) }
    }

    /// Full terminal counts include overload refusals while latency samples include only submitted work.
    @available(macOS 15, *)
    @Test func completeMixedCycle() async throws {
        var configuration = Phase10TimingConfiguration()
        configuration.durationSeconds = 4; configuration.cycleSeconds = 4
        let result = try await Phase10TimingCommand.measure(configuration)
        #expect(result.common.status == .completed)
        #expect(result.measurement.completedCycles == 1)
        #expect(result.measurement.durationNanoseconds >= 4_000_000_000)
        #expect(result.measurement.counts.offered == 240)
        #expect(result.measurement.counts.completed == 240)
        #expect(result.measurement.counts.outcomes[.rejected, default: 0] > 0)
        #expect(result.measurement.counts.outcomes[.cancelled, default: 0] > 0)
        #expect(result.measurement.cacheExpirations > 0)
        #expect(result.measurement.controlProgress > 0 && !result.measurement.controlFailure)
        #expect(result.measurement.cleanup.completed == true && result.measurement.cleanup.remainingOwners == 0)
        #expect(result.measurement.restCleanup.isEmpty && result.measurement.gatewayCleanup.isEmpty)
        #expect(result.measurement.bands.map(\.name) == ["below", "near", "above", "recovery"])
        #expect(result.measurement.bands.allSatisfy { $0.controlProgress > 0 && $0.peakActive <= 8 && $0.peakPending <= 8 })
        let submitted = result.measurement.bands.reduce(0) { $0 + $1.submitted }
        for id in ["arrival.scheduledResponse", "arrival.submittedResponse", "arrival.lateness"] {
            #expect(result.common.metrics.filter { $0.id == id }.reduce(UInt64(0)) { $0 + $1.distribution.observedCount } == UInt64(submitted))
        }
        #expect(try DiscordBenchmarkReport.decode(result.common.validatedData()) == result.common)
        #expect(try JSONEncoder().encode(result).count <= DiscordBenchmarkReport.maximumSerializedBytes)
    }

    /// A resource ceiling hit remains failed evidence and cannot be promoted to a shorter successful soak.
    @available(macOS 15, *)
    @Test func resourceFailure() async throws {
        var configuration = Phase10TimingConfiguration()
        configuration.durationSeconds = 4; configuration.cycleSeconds = 4
        configuration.maximumRSSBytes = 16_777_216
        let result = try await Phase10TimingCommand.measure(configuration)
        #expect(result.common.status == .failed)
        #expect(result.measurement.resources.capExceeded)
        #expect(result.measurement.cleanup.completed == true && result.measurement.cleanup.remainingOwners == 0)
    }
}
