// File: Tools/DiscordBenchmarkSupport/Sources/DiscordBenchmarkSupport/Histogram.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

/// Configuration and integrity failures for development-only bounded statistics.
public enum StatisticsError: Error, Equatable, Sendable {
    case invalidRange
    case invalidPrecision
    case storageBudgetExceeded
    case invalidReservoirCapacity
    case incompatibleHistograms
    case malformedSnapshot
}

/// Explicit inclusive range and fixed absolute precision, shared by mergeable populations.
public struct HistogramConfiguration: Codable, Equatable, Sendable {
    public let lowerBoundNanoseconds: UInt64
    public let upperBoundNanoseconds: UInt64
    public let bucketWidthNanoseconds: UInt64
    public let bucketCount: Int
    public let estimatedStorageBytes: Int

    /// Validates a finite range and allocatable precision before any histogram storage exists.
    ///
    /// - Parameters:
    ///   - lowerBoundNanoseconds: Inclusive minimum; zero is valid.
    ///   - upperBoundNanoseconds: Inclusive maximum, at least the minimum.
    ///   - bucketWidthNanoseconds: Positive absolute precision. The last bucket may be shorter.
    /// - Throws: `invalidRange`, `invalidPrecision`, or `storageBudgetExceeded` when the
    ///   configuration cannot fit the 16 MiB runner ceiling by itself. Aggregate callers must
    ///   additionally validate every population, reservoir and key with `AggregateStatisticsBudget`.
    /// - Note: Each histogram reserves 256 accounting bytes in addition to its UInt64 cells.
    public init(lowerBoundNanoseconds: UInt64, upperBoundNanoseconds: UInt64, bucketWidthNanoseconds: UInt64) throws {
        guard lowerBoundNanoseconds <= upperBoundNanoseconds else { throw StatisticsError.invalidRange }
        guard bucketWidthNanoseconds > 0 else { throw StatisticsError.invalidPrecision }
        let count = ((upperBoundNanoseconds - lowerBoundNanoseconds) / bucketWidthNanoseconds).addingReportingOverflow(1)
        guard !count.overflow, count.partialValue <= UInt64((AggregateStatisticsBudget.ceilingBytes - 256) / 8) else {
            throw StatisticsError.storageBudgetExceeded
        }
        self.lowerBoundNanoseconds = lowerBoundNanoseconds
        self.upperBoundNanoseconds = upperBoundNanoseconds
        self.bucketWidthNanoseconds = bucketWidthNanoseconds
        self.bucketCount = Int(count.partialValue)
        self.estimatedStorageBytes = 256 + self.bucketCount * 8
    }

    private enum CodingKeys: String, CodingKey {
        case lowerBoundNanoseconds, upperBoundNanoseconds, bucketWidthNanoseconds
    }

    /// Decodes through the validated initializer so an artifact cannot request unbounded cells.
    ///
    /// - Parameter decoder: Decoder holding the three explicit range/precision fields.
    /// - Throws: Decoding errors or the same range, precision and storage errors as initialization.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            lowerBoundNanoseconds: container.decode(UInt64.self, forKey: .lowerBoundNanoseconds),
            upperBoundNanoseconds: container.decode(UInt64.self, forKey: .upperBoundNanoseconds),
            bucketWidthNanoseconds: container.decode(UInt64.self, forKey: .bucketWidthNanoseconds)
        )
    }
}

/// Accounts all declared populations before a runner allocates aggregate storage.
public enum AggregateStatisticsBudget {
    public static let ceilingBytes = 16 * 1_024 * 1_024
    public static let maximumReservoirCapacity = 4_096

    /// Checks combined retained statistics, including the runner's own finite key/counter storage.
    ///
    /// - Parameters:
    ///   - histograms: One configuration for every allocated population, including each outcome.
    ///   - reservoirCapacities: Every optional reservoir capacity, each in `0...4096`.
    ///   - additionalBytes: Nonnegative upper bound for keys, registries and other aggregate counters.
    /// - Returns: The checked byte budget, at most 16 MiB. Reservoir accounting includes 128
    ///   fixed bytes plus UInt64 cells. Call before allocating any declared population.
    /// - Throws: `invalidReservoirCapacity` or `storageBudgetExceeded`; no allocations are made.
    @discardableResult
    public static func validate(
        histograms: [HistogramConfiguration], reservoirCapacities: [Int] = [], additionalBytes: Int = 0
    ) throws -> Int {
        guard additionalBytes >= 0, additionalBytes <= ceilingBytes else { throw StatisticsError.storageBudgetExceeded }
        var total = additionalBytes
        for histogram in histograms {
            guard histogram.estimatedStorageBytes <= ceilingBytes - total else { throw StatisticsError.storageBudgetExceeded }
            total += histogram.estimatedStorageBytes
        }
        for capacity in reservoirCapacities {
            guard (0...maximumReservoirCapacity).contains(capacity) else { throw StatisticsError.invalidReservoirCapacity }
            let bytes = 128 + capacity * 8
            guard bytes <= ceilingBytes - total else { throw StatisticsError.storageBudgetExceeded }
            total += bytes
        }
        return total
    }
}

/// Explains why an estimate cannot be numerically qualified.
public enum QuantileUnavailableReason: String, Codable, Equatable, Sendable {
    case emptyPopulation
    case aggregateLoss
    case counterOverflow
    case insufficientTailData
    case invalidQuantile
}

/// An inclusive bucket interval, censored mass boundary, or explicit unavailable result.
public enum QuantileEstimate: Codable, Equatable, Sendable {
    case interval(lowerBoundNanoseconds: UInt64, upperBoundNanoseconds: UInt64)
    case underflow(upperExclusiveNanoseconds: UInt64)
    case overflow(lowerExclusiveNanoseconds: UInt64)
    case unavailable(QuantileUnavailableReason)
}

/// Immutable full-population evidence. Counts remain exact until `counterOverflow` is flagged.
public struct HistogramSnapshot: Codable, Equatable, Sendable {
    public let configuration: HistogramConfiguration
    public let bucketCounts: [UInt64]
    public let inRangeCount: UInt64
    public let underflowCount: UInt64
    public let overflowCount: UInt64
    public let droppedCount: UInt64
    public let counterOverflow: Bool
    public let observedCount: UInt64
    public let maxInRangeNanoseconds: UInt64?

    /// Captures the already-bounded collector state without creating an additional observation.
    ///
    /// - Parameter histogram: Collector whose counters and cells are copied by value; Swift's
    ///   copy-on-write array permits immutable handoff after collection without immediate copying.
    /// - Note: The collector is a value type; callers serialize mutations through their own owner.
    init(histogram: BoundedHistogram) {
        configuration = histogram.configuration
        bucketCounts = histogram.bucketCounts
        inRangeCount = histogram.inRangeCount
        underflowCount = histogram.underflowCount
        overflowCount = histogram.overflowCount
        droppedCount = histogram.droppedCount
        counterOverflow = histogram.counterOverflow
        observedCount = histogram.observedCount
        maxInRangeNanoseconds = histogram.maxInRangeNanoseconds
    }

    private enum CodingKeys: String, CodingKey {
        case configuration, bucketCounts, inRangeCount, underflowCount, overflowCount
        case droppedCount, counterOverflow, observedCount, maxInRangeNanoseconds
    }

    /// Decodes and verifies shape, count conservation and maximum evidence before accepting data.
    ///
    /// - Parameter decoder: Decoder for a bounded snapshot; report readers must also cap input bytes.
    /// - Throws: Decoding errors or `malformedSnapshot` for inconsistent cell/counter evidence.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configuration = try container.decode(HistogramConfiguration.self, forKey: .configuration)
        var cells = try container.nestedUnkeyedContainer(forKey: .bucketCounts)
        if let count = cells.count, count != configuration.bucketCount {
            throw StatisticsError.malformedSnapshot
        }
        var boundedCells: [UInt64] = []
        boundedCells.reserveCapacity(configuration.bucketCount)
        for _ in 0..<configuration.bucketCount {
            guard !cells.isAtEnd else { throw StatisticsError.malformedSnapshot }
            boundedCells.append(try cells.decode(UInt64.self))
        }
        guard cells.isAtEnd else { throw StatisticsError.malformedSnapshot }
        bucketCounts = boundedCells
        inRangeCount = try container.decode(UInt64.self, forKey: .inRangeCount)
        underflowCount = try container.decode(UInt64.self, forKey: .underflowCount)
        overflowCount = try container.decode(UInt64.self, forKey: .overflowCount)
        droppedCount = try container.decode(UInt64.self, forKey: .droppedCount)
        counterOverflow = try container.decode(Bool.self, forKey: .counterOverflow)
        observedCount = try container.decode(UInt64.self, forKey: .observedCount)
        maxInRangeNanoseconds = try container.decodeIfPresent(UInt64.self, forKey: .maxInRangeNanoseconds)
        try validate()
    }

    /// Rejects corrupted dimensions, inconsistent exact counts and unsupported maximum claims.
    ///
    /// - Throws: `malformedSnapshot` when evidence is inconsistent. Overflowed snapshots preserve
    ///   saturated counters but remain unusable for numerical qualification through estimate APIs.
    /// - Note: This performs one bounded pass over cells and has no side effects.
    public func validate() throws {
        guard bucketCounts.count == configuration.bucketCount else { throw StatisticsError.malformedSnapshot }
        if let maximum = maxInRangeNanoseconds {
            guard inRangeCount > 0,
                maximum >= configuration.lowerBoundNanoseconds,
                maximum <= configuration.upperBoundNanoseconds else { throw StatisticsError.malformedSnapshot }
            let maximumIndex = Int((maximum - configuration.lowerBoundNanoseconds) / configuration.bucketWidthNanoseconds)
            guard bucketCounts[maximumIndex] > 0,
                !bucketCounts.dropFirst(maximumIndex + 1).contains(where: { $0 != 0 }) else {
                throw StatisticsError.malformedSnapshot
            }
        } else if inRangeCount != 0 {
            throw StatisticsError.malformedSnapshot
        }
        if counterOverflow { return }
        var cellTotal: UInt64 = 0
        for count in bucketCounts {
            let addition = cellTotal.addingReportingOverflow(count)
            guard !addition.overflow else { throw StatisticsError.malformedSnapshot }
            cellTotal = addition.partialValue
        }
        guard cellTotal == inRangeCount else { throw StatisticsError.malformedSnapshot }
        var total = inRangeCount
        for count in [underflowCount, overflowCount, droppedCount] {
            let addition = total.addingReportingOverflow(count)
            guard !addition.overflow else { throw StatisticsError.malformedSnapshot }
            total = addition.partialValue
        }
        guard total == observedCount else { throw StatisticsError.malformedSnapshot }
    }

    /// Finds an exact nearest-rank quantile using integer arithmetic over the entire population.
    ///
    /// - Parameters:
    ///   - numerator: Fraction numerator in `0...denominator`; zero selects the minimum rank.
    ///   - denominator: Positive denominator, default 100 for integer percentiles.
    /// - Returns: Inclusive bucket bounds or an exclusive censored boundary. Any unknown aggregate
    ///   loss/counter overflow makes the result unavailable. Fractions at least 99/100 require
    ///   10,000 observations; this is a data gate, not a claim of statistical confidence.
    /// - Note: Runtime is bounded by configured cells. No samples are sorted or allocated.
    public func quantile(_ numerator: UInt32, outOf denominator: UInt32 = 100) -> QuantileEstimate {
        guard denominator > 0, numerator <= denominator else { return .unavailable(.invalidQuantile) }
        if counterOverflow { return .unavailable(.counterOverflow) }
        if droppedCount > 0 { return .unavailable(.aggregateLoss) }
        if observedCount == 0 { return .unavailable(.emptyPopulation) }
        if UInt64(numerator) * 100 >= UInt64(denominator) * 99, observedCount < 10_000 {
            return .unavailable(.insufficientTailData)
        }
        let divisor = UInt64(denominator)
        let multiplier = UInt64(numerator)
        let remainderProduct = (observedCount % divisor) * multiplier
        let fractionalRank = remainderProduct / divisor + (remainderProduct % divisor == 0 ? 0 : 1)
        let rank = max(1, (observedCount / divisor) * multiplier + fractionalRank)
        if rank <= underflowCount { return .underflow(upperExclusiveNanoseconds: configuration.lowerBoundNanoseconds) }
        var cumulative = underflowCount
        for (index, count) in bucketCounts.enumerated() {
            cumulative += count
            if rank <= cumulative {
                let lower = configuration.lowerBoundNanoseconds + UInt64(index) * configuration.bucketWidthNanoseconds
                let width = min(configuration.bucketWidthNanoseconds - 1, configuration.upperBoundNanoseconds - lower)
                return .interval(lowerBoundNanoseconds: lower, upperBoundNanoseconds: lower + width)
            }
        }
        return .overflow(lowerExclusiveNanoseconds: configuration.upperBoundNanoseconds)
    }

    /// Reports the exact observed maximum only when no higher or unknown observations are hidden.
    ///
    /// - Returns: A point interval for an in-range maximum, a censored bound for out-of-range
    ///   maxima, or an unavailable reason for empty, dropped or overflowed populations. Sparse
    ///   populations can still report their observed maximum; no p99 qualification is inferred.
    public func maximum() -> QuantileEstimate {
        if counterOverflow { return .unavailable(.counterOverflow) }
        if droppedCount > 0 { return .unavailable(.aggregateLoss) }
        if observedCount == 0 { return .unavailable(.emptyPopulation) }
        if overflowCount > 0 { return .overflow(lowerExclusiveNanoseconds: configuration.upperBoundNanoseconds) }
        if let maximum = maxInRangeNanoseconds {
            return .interval(lowerBoundNanoseconds: maximum, upperBoundNanoseconds: maximum)
        }
        return .underflow(upperExclusiveNanoseconds: configuration.lowerBoundNanoseconds)
    }
}

/// Mutable bounded histogram, owned and serialized by the invoking runner rather than a global sink.
public struct BoundedHistogram: Sendable {
    public let configuration: HistogramConfiguration
    public private(set) var bucketCounts: [UInt64]
    public private(set) var inRangeCount: UInt64 = 0
    public private(set) var underflowCount: UInt64 = 0
    public private(set) var overflowCount: UInt64 = 0
    public private(set) var droppedCount: UInt64 = 0
    public private(set) var counterOverflow = false
    public private(set) var observedCount: UInt64 = 0
    public private(set) var maxInRangeNanoseconds: UInt64?

    /// Allocates exactly the validated fixed cell count, with no per-observation allocation.
    ///
    /// - Parameter configuration: Validated range/precision. The runner must first validate its
    ///   combined histogram, reservoir and key budget; this initializer has no global registry.
    public init(configuration: HistogramConfiguration) {
        self.configuration = configuration
        self.bucketCounts = Array(repeating: 0, count: configuration.bucketCount)
    }

    /// Accounts all supplied observations, including censored values anywhere in the run.
    ///
    /// - Parameters:
    ///   - nanoseconds: Nonnegative integer duration; out-of-range values remain censored mass.
    ///   - count: Number of identical observations, default one. Zero has no effects. Multiplicity
    ///     supports merging fixtures without loops and retains the same exact nearest-rank semantics.
    /// - Note: Constant time, nonthrowing and synchronous. UInt64 exhaustion saturates counters and
    ///   flags invalid evidence; it never wraps or changes the operation being measured.
    public mutating func record(_ nanoseconds: UInt64, count: UInt64 = 1) {
        guard count > 0 else { return }
        Self.add(count, to: &observedCount, overflow: &counterOverflow)
        if nanoseconds < configuration.lowerBoundNanoseconds {
            Self.add(count, to: &underflowCount, overflow: &counterOverflow)
        } else if nanoseconds > configuration.upperBoundNanoseconds {
            Self.add(count, to: &overflowCount, overflow: &counterOverflow)
        } else {
            Self.add(count, to: &inRangeCount, overflow: &counterOverflow)
            let index = Int((nanoseconds - configuration.lowerBoundNanoseconds) / configuration.bucketWidthNanoseconds)
            Self.add(count, to: &bucketCounts[index], overflow: &counterOverflow)
            maxInRangeNanoseconds = max(maxInRangeNanoseconds ?? nanoseconds, nanoseconds)
        }
    }

    /// Records observations whose values could not be retained or converted.
    ///
    /// - Parameter count: Unknown-value observation count, default one; zero has no effects.
    /// - Note: Included in `observedCount`. Even one loss blocks every required quantile and max
    ///   because its unknown rank could bias the result. Saturation additionally flags overflow.
    public mutating func recordLoss(_ count: UInt64 = 1) {
        Self.add(count, to: &observedCount, overflow: &counterOverflow)
        Self.add(count, to: &droppedCount, overflow: &counterOverflow)
    }

    /// Combines compatible full populations without discarding early, middle or late observations.
    ///
    /// - Parameter other: Histogram with exactly matching inclusive range and precision.
    /// - Throws: `incompatibleHistograms` before mutation when configuration differs.
    /// - Note: Bounded linear work in cell count. Checked saturation propagates overflow/loss;
    ///   the other value remains unchanged. Self-merge is a valid duplication of the population.
    public mutating func merge(_ other: BoundedHistogram) throws {
        guard configuration == other.configuration else { throw StatisticsError.incompatibleHistograms }
        counterOverflow = counterOverflow || other.counterOverflow
        Self.add(other.observedCount, to: &observedCount, overflow: &counterOverflow)
        Self.add(other.inRangeCount, to: &inRangeCount, overflow: &counterOverflow)
        Self.add(other.underflowCount, to: &underflowCount, overflow: &counterOverflow)
        Self.add(other.overflowCount, to: &overflowCount, overflow: &counterOverflow)
        Self.add(other.droppedCount, to: &droppedCount, overflow: &counterOverflow)
        for index in bucketCounts.indices { Self.add(other.bucketCounts[index], to: &bucketCounts[index], overflow: &counterOverflow) }
        if let maximum = other.maxInRangeNanoseconds {
            maxInRangeNanoseconds = max(maxInRangeNanoseconds ?? maximum, maximum)
        }
    }

    /// Returns immutable serializable evidence after collection or at an explicit checkpoint.
    ///
    /// - Returns: A value snapshot sharing copy-on-write cells until a collector is mutated.
    /// - Note: Retaining snapshots while continuing collection requires caller-owned extra budget.
    public func snapshot() -> HistogramSnapshot { HistogramSnapshot(histogram: self) }

    /// Adds a nonnegative counter increment without wrapping and latches invalid evidence.
    ///
    /// - Parameters:
    ///   - amount: Increment, including zero.
    ///   - counter: Exclusively borrowed counter, saturated at UInt64.max on exhaustion.
    ///   - overflow: Sticky overflow flag shared by the caller counters.
    /// - Note: This helper mutates only the counter and the overflow flag; it cannot throw.
    private static func add(_ amount: UInt64, to counter: inout UInt64, overflow: inout Bool) {
        let result = counter.addingReportingOverflow(amount)
        counter = result.overflow ? .max : result.partialValue
        overflow = overflow || result.overflow
    }
}
