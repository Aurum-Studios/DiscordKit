// File: Tools/DiscordBenchmarkSupport/Sources/DiscordBenchmarkSupport/Reservoir.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

/// Seeded Algorithm R raw examples from the entire run, separate from full-population statistics.
public struct SeededReservoir: Sendable {
    public let capacity: Int
    public let seed: UInt64
    public private(set) var values: [UInt64] = []
    public private(set) var observedCount: UInt64 = 0
    public private(set) var counterOverflow = false
    private var randomState: UInt64

    /// Allocates a finite optional sample population with reproducible replacement.
    ///
    /// - Parameters:
    ///   - capacity: Maximum observations in `0...4096`. Zero explicitly disables raw retention.
    ///   - seed: Run-recorded SplitMix64 seed; identical input order and seed yield identical samples.
    /// - Throws: `invalidReservoirCapacity` outside the fixed ceiling. Callers must additionally
    ///   include this allocation in their complete `AggregateStatisticsBudget` validation.
    /// - Note: The runner owns serialization; there are no tasks, clocks or shared random generators.
    public init(capacity: Int, seed: UInt64) throws {
        guard (0...AggregateStatisticsBudget.maximumReservoirCapacity).contains(capacity) else {
            throw StatisticsError.invalidReservoirCapacity
        }
        self.capacity = capacity
        self.seed = seed
        self.randomState = seed
        self.values.reserveCapacity(capacity)
    }

    /// Offers one raw value with equal retention probability across the whole ordered stream.
    ///
    /// - Parameter nanoseconds: Raw observation in integer nanoseconds; no quantile is inferred.
    /// - Note: Algorithm R replaces retained indices using unbiased rejection sampling. Runtime is
    ///   expected constant after bounded allocation. After count exhaustion the collector latches
    ///   `counterOverflow` and retains its previous samples; they must not qualify numerical tails.
    public mutating func record(_ nanoseconds: UInt64) {
        let next = observedCount.addingReportingOverflow(1)
        guard !next.overflow else { counterOverflow = true; return }
        observedCount = next.partialValue
        guard capacity > 0 else { return }
        if values.count < capacity {
            values.append(nanoseconds)
        } else {
            let index = random(lessThan: observedCount)
            if index < UInt64(capacity) { values[Int(index)] = nanoseconds }
        }
    }

    /// Draws an unbiased integer below a positive bound without floating point rounding.
    ///
    /// - Parameter upperBound: Positive exclusive bound; record supplies its nonzero population size.
    /// - Returns: Uniform pseudorandom integer in `0..<upperBound` under the SplitMix64 generator.
    /// - Note: Rejection avoids modulo bias; this is reproducible sampling, not cryptographic entropy.
    private mutating func random(lessThan upperBound: UInt64) -> UInt64 {
        let threshold = (0 &- upperBound) % upperBound
        while true {
            let value = nextRandom()
            if value >= threshold { return value % upperBound }
        }
    }

    /// Advances the explicitly seeded SplitMix64 generator using its defined wrapping arithmetic.
    ///
    /// - Returns: The next reproducible 64-bit word. Only PRNG state intentionally wraps; population
    ///   counters elsewhere use checked arithmetic and cannot silently wrap.
    private mutating func nextRandom() -> UInt64 {
        randomState &+= 0x9E3779B97F4A7C15
        var value = randomState
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
