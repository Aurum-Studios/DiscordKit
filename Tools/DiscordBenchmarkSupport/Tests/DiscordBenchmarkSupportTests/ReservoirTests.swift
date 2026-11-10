// File: Tools/DiscordBenchmarkSupport/Tests/DiscordBenchmarkSupportTests/ReservoirTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Testing
import DiscordBenchmarkSupport

@Suite("Seeded whole-run raw reservoir")
struct ReservoirTests {
    /// Verifies invalid capacities fail before allocation, while zero explicitly disables retention.
    /// A disabled reservoir still accounts input observations without pretending they were lost.
    @Test func capacityAndDisabledRetention() throws {
        #expect(throws: StatisticsError.invalidReservoirCapacity) { try SeededReservoir(capacity: -1, seed: 0) }
        #expect(throws: StatisticsError.invalidReservoirCapacity) { try SeededReservoir(capacity: 4_097, seed: 0) }
        var disabled = try SeededReservoir(capacity: 0, seed: 0)
        disabled.record(42)
        #expect(disabled.values.isEmpty)
        #expect(disabled.observedCount == 1)
        #expect(!disabled.counterOverflow)
        let maximum = try SeededReservoir(capacity: 4_096, seed: .max)
        #expect(maximum.capacity == 4_096)
        #expect(maximum.seed == .max)
    }

    /// Proves the documented seed and stream ordering determine reproducible Algorithm R examples.
    /// The fixed vector also detects accidental PRNG changes that would invalidate run replay.
    @Test func deterministicSeedAndWholeRunCoverage() throws {
        var vector = try SeededReservoir(capacity: 8, seed: 42)
        for value in UInt64(0)..<100 { vector.record(value) }
        #expect(vector.values == [11, 50, 32, 57, 94, 84, 19, 12])
        var first = try SeededReservoir(capacity: 128, seed: 4_294_967_311)
        var second = try SeededReservoir(capacity: 128, seed: 4_294_967_311)
        var otherSeed = try SeededReservoir(capacity: 128, seed: 4_294_967_312)
        for value in UInt64(0)..<30_000 {
            first.record(value)
            second.record(value)
            otherSeed.record(value)
        }
        #expect(first.values == second.values)
        #expect(first.values != otherSeed.values)
        #expect(first.values.count == 128)
        #expect(first.observedCount == 30_000)
        #expect(first.values.contains(where: { $0 < 10_000 }))
        #expect(first.values.contains(where: { (10_000..<20_000).contains($0) }))
        #expect(first.values.contains(where: { $0 >= 20_000 }))
    }

    /// Ensures short streams retain every raw value in order before bounded replacement begins.
    /// Repeated input values remain distinct observations with an exact full-stream count.
    @Test func unfilledAndRepeatedValues() throws {
        var reservoir = try SeededReservoir(capacity: 3, seed: 0)
        reservoir.record(10)
        reservoir.record(20)
        #expect(reservoir.values == [10, 20])
        reservoir.record(20)
        #expect(reservoir.values == [10, 20, 20])
        for _ in 0..<100 { reservoir.record(20) }
        #expect(reservoir.values.count == 3)
        #expect(reservoir.values.allSatisfy { $0 == 10 || $0 == 20 })
        #expect(reservoir.observedCount == 103)
    }
}
