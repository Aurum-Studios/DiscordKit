// File: Tools/DiscordBenchmarkSupport/Tests/DiscordBenchmarkSupportTests/HistogramTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Foundation
import Testing
@testable import DiscordBenchmarkSupport

@Suite("Bounded full-population distributions")
struct HistogramTests {
    /// Proves explicit ranges/precision reject invalid and unallocatable profiles before allocation.
    /// Includes the UInt64-wide range whose unit-width cell count would otherwise wrap to zero.
    @Test func configurationValidation() throws {
        #expect(throws: StatisticsError.invalidRange) {
            try HistogramConfiguration(lowerBoundNanoseconds: 2, upperBoundNanoseconds: 1, bucketWidthNanoseconds: 1)
        }
        #expect(throws: StatisticsError.invalidPrecision) {
            try HistogramConfiguration(lowerBoundNanoseconds: 0, upperBoundNanoseconds: 1, bucketWidthNanoseconds: 0)
        }
        #expect(throws: StatisticsError.storageBudgetExceeded) {
            try HistogramConfiguration(lowerBoundNanoseconds: 0, upperBoundNanoseconds: .max, bucketWidthNanoseconds: 1)
        }
        let configuration = try HistogramConfiguration(lowerBoundNanoseconds: 10, upperBoundNanoseconds: 32, bucketWidthNanoseconds: 10)
        #expect(configuration.bucketCount == 3)
        #expect(configuration.estimatedStorageBytes == 280)
        #expect(try JSONDecoder().decode(HistogramConfiguration.self, from: JSONEncoder().encode(configuration)) == configuration)
    }

    /// Checks whole-runner ceilings account every population, reservoir and declared key byte.
    /// A profile exactly at 16 MiB passes; adding one byte or a 4097-value reservoir fails.
    @Test func aggregateBudgetValidation() throws {
        let configuration = try HistogramConfiguration(lowerBoundNanoseconds: 0, upperBoundNanoseconds: 9, bucketWidthNanoseconds: 1)
        let reservoirBytes = 128 + 4_096 * 8
        let additional = AggregateStatisticsBudget.ceilingBytes - configuration.estimatedStorageBytes - reservoirBytes
        #expect(try AggregateStatisticsBudget.validate(histograms: [configuration], reservoirCapacities: [4_096], additionalBytes: additional) == AggregateStatisticsBudget.ceilingBytes)
        #expect(throws: StatisticsError.storageBudgetExceeded) {
            try AggregateStatisticsBudget.validate(histograms: [configuration], reservoirCapacities: [4_096], additionalBytes: additional + 1)
        }
        #expect(throws: StatisticsError.storageBudgetExceeded) {
            try AggregateStatisticsBudget.validate(histograms: [], additionalBytes: -1)
        }
        #expect(throws: StatisticsError.invalidReservoirCapacity) {
            try AggregateStatisticsBudget.validate(histograms: [], reservoirCapacities: [4_097])
        }
    }

    /// Verifies empty and invalid estimates are explicit, and zero multiplicity does not invent data.
    /// All assertions are synchronous and independent of platform clocks or scheduling.
    @Test func emptyAndInvalidQuantiles() throws {
        var histogram = BoundedHistogram(configuration: try configuration())
        histogram.record(50, count: 0)
        histogram.recordLoss(0)
        #expect(histogram.snapshot().observedCount == 0)
        #expect(histogram.snapshot().quantile(50) == .unavailable(.emptyPopulation))
        #expect(histogram.snapshot().maximum() == .unavailable(.emptyPopulation))
        #expect(histogram.snapshot().quantile(101) == .unavailable(.invalidQuantile))
        #expect(histogram.snapshot().quantile(0, outOf: 0) == .unavailable(.invalidQuantile))
    }

    /// Proves early, middle and late changes all survive collection and independent shard merging.
    /// Nearest-rank quantiles preserve interval precision and exact observed maximum evidence.
    @Test func completePopulationAndMerge() throws {
        let configuration = try configuration()
        var whole = BoundedHistogram(configuration: configuration)
        var merged = BoundedHistogram(configuration: configuration)
        for value: UInt64 in [11, 51, 91] {
            var shard = BoundedHistogram(configuration: configuration)
            for _ in 0..<10_000 { whole.record(value); shard.record(value) }
            try merged.merge(shard)
        }
        let snapshot = whole.snapshot()
        #expect(snapshot == merged.snapshot())
        #expect(snapshot.observedCount == 30_000)
        #expect(snapshot.inRangeCount == 30_000)
        #expect(snapshot.quantile(0) == .interval(lowerBoundNanoseconds: 10, upperBoundNanoseconds: 19))
        #expect(snapshot.quantile(50) == .interval(lowerBoundNanoseconds: 50, upperBoundNanoseconds: 59))
        #expect(snapshot.quantile(95) == .interval(lowerBoundNanoseconds: 90, upperBoundNanoseconds: 99))
        #expect(snapshot.quantile(99) == .interval(lowerBoundNanoseconds: 90, upperBoundNanoseconds: 99))
        #expect(snapshot.maximum() == .interval(lowerBoundNanoseconds: 91, upperBoundNanoseconds: 91))
        try snapshot.validate()
        #expect(try JSONDecoder().decode(HistogramSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    }

    /// Ensures out-of-range stalls remain censored full-population mass instead of a finite cap.
    /// Underflow, overflow and exact counts survive merges; unknown loss is tested separately.
    @Test func censoredMassAndMaximum() throws {
        var histogram = BoundedHistogram(configuration: try configuration())
        histogram.record(0, count: 200)
        histogram.record(50, count: 9_500)
        histogram.record(.max, count: 300)
        let snapshot = histogram.snapshot()
        #expect(snapshot.observedCount == 10_000)
        #expect(snapshot.underflowCount == 200)
        #expect(snapshot.overflowCount == 300)
        #expect(snapshot.quantile(1) == .underflow(upperExclusiveNanoseconds: 10))
        #expect(snapshot.quantile(95) == .interval(lowerBoundNanoseconds: 50, upperBoundNanoseconds: 59))
        #expect(snapshot.quantile(99) == .overflow(lowerExclusiveNanoseconds: 109))
        #expect(snapshot.maximum() == .overflow(lowerExclusiveNanoseconds: 109))
        var empty = BoundedHistogram(configuration: histogram.configuration)
        try empty.merge(histogram)
        #expect(empty.snapshot() == snapshot)
        try snapshot.validate()
    }

    /// Verifies populations entirely below range report a censored maximum and never the range cap.
    /// Inclusive endpoints belong to their actual cells, including a shortened final cell.
    @Test func rangeBoundariesAndShortFinalCell() throws {
        let configuration = try HistogramConfiguration(lowerBoundNanoseconds: 10, upperBoundNanoseconds: 32, bucketWidthNanoseconds: 10)
        var histogram = BoundedHistogram(configuration: configuration)
        histogram.record(9)
        #expect(histogram.snapshot().maximum() == .underflow(upperExclusiveNanoseconds: 10))
        histogram.record(10)
        histogram.record(32)
        #expect(histogram.snapshot().bucketCounts == [1, 0, 1])
        #expect(histogram.snapshot().quantile(95) == .interval(lowerBoundNanoseconds: 30, upperBoundNanoseconds: 32))
        #expect(histogram.snapshot().maximum() == .interval(lowerBoundNanoseconds: 32, upperBoundNanoseconds: 32))
    }

    /// Exercises exact UInt64 arithmetic near its maximum without rounding rank through Double.
    /// Configuration arithmetic also supports a one-cell range ending at UInt64.max.
    @Test func extremeRangeAndRankArithmetic() throws {
        let configuration = try HistogramConfiguration(lowerBoundNanoseconds: .max - 2, upperBoundNanoseconds: .max, bucketWidthNanoseconds: .max)
        var histogram = BoundedHistogram(configuration: configuration)
        histogram.record(.max, count: .max)
        #expect(histogram.snapshot().quantile(4_294_967_294, outOf: 4_294_967_295) == .interval(lowerBoundNanoseconds: .max - 2, upperBoundNanoseconds: .max))
        #expect(histogram.snapshot().maximum() == .interval(lowerBoundNanoseconds: .max, upperBoundNanoseconds: .max))
        #expect(!histogram.counterOverflow)
        try histogram.snapshot().validate()
    }

    /// Proves any unknown observation loss blocks finite quantiles and max despite adequate data.
    /// Exact loss accounting is conserved by merging and includes dropped observations in the total.
    @Test func unknownLossBlocksQualification() throws {
        var histogram = BoundedHistogram(configuration: try configuration())
        histogram.record(50, count: 10_000)
        var losses = BoundedHistogram(configuration: histogram.configuration)
        losses.recordLoss(3)
        try histogram.merge(losses)
        #expect(histogram.snapshot().observedCount == 10_003)
        #expect(histogram.snapshot().droppedCount == 3)
        #expect(histogram.snapshot().quantile(50) == .unavailable(.aggregateLoss))
        #expect(histogram.snapshot().quantile(99) == .unavailable(.aggregateLoss))
        #expect(histogram.snapshot().maximum() == .unavailable(.aggregateLoss))
        try histogram.snapshot().validate()
    }

    /// Exercises record and merge exhaustion directly without executing UInt64.max iterations.
    /// Counters saturate, the loss/overflow flag survives encoding, and numerical results fail closed.
    @Test func checkedCounterOverflow() throws {
        var histogram = BoundedHistogram(configuration: try configuration())
        histogram.record(50, count: .max)
        histogram.record(50)
        #expect(histogram.observedCount == .max)
        #expect(histogram.inRangeCount == .max)
        #expect(histogram.bucketCounts[4] == .max)
        #expect(histogram.counterOverflow)
        #expect(histogram.snapshot().quantile(99) == .unavailable(.counterOverflow))
        #expect(histogram.snapshot().maximum() == .unavailable(.counterOverflow))
        var merged = BoundedHistogram(configuration: histogram.configuration)
        merged.recordLoss(.max)
        try merged.merge(histogram)
        #expect(merged.counterOverflow)
        #expect(merged.droppedCount == .max)
        let encoded = try JSONEncoder().encode(merged.snapshot())
        #expect(try JSONDecoder().decode(HistogramSnapshot.self, from: encoded).counterOverflow)
    }

    /// Ensures merge rejects different precision before modifying any destination evidence.
    /// Repeated compatible merges add populations rather than silently deduplicating observations.
    @Test func mergeCompatibilityAndRepetition() throws {
        var histogram = BoundedHistogram(configuration: try configuration())
        histogram.record(50)
        let before = histogram.snapshot()
        let different = BoundedHistogram(configuration: try HistogramConfiguration(lowerBoundNanoseconds: 10, upperBoundNanoseconds: 109, bucketWidthNanoseconds: 5))
        #expect(throws: StatisticsError.incompatibleHistograms) { try histogram.merge(different) }
        #expect(histogram.snapshot() == before)
        let copy = histogram
        try histogram.merge(copy)
        #expect(histogram.observedCount == 2)
        #expect(histogram.snapshot().maximum() == .interval(lowerBoundNanoseconds: 50, upperBoundNanoseconds: 50))
    }

    /// Sparse tail output is explicitly unavailable until the fixed 10000-observation floor.
    /// Ordinary quantiles and observed maximum remain usable and cannot imply p99 qualification.
    @Test func sparseP99() throws {
        var histogram = BoundedHistogram(configuration: try configuration())
        histogram.record(50, count: 9_999)
        #expect(histogram.snapshot().quantile(99) == .unavailable(.insufficientTailData))
        #expect(histogram.snapshot().quantile(999, outOf: 1_000) == .unavailable(.insufficientTailData))
        #expect(histogram.snapshot().quantile(95) == .interval(lowerBoundNanoseconds: 50, upperBoundNanoseconds: 59))
        histogram.record(50)
        #expect(histogram.snapshot().quantile(99) == .interval(lowerBoundNanoseconds: 50, upperBoundNanoseconds: 59))
    }

    /// Rejects corrupted artifact counters, bucket dimensions and unsupported maximum evidence.
    /// JSON mutation exercises the public decoder rather than exposing unsafe collector setters.
    @Test func malformedSnapshotDecoding() throws {
        var histogram = BoundedHistogram(configuration: try configuration())
        histogram.record(50)
        let data = try JSONEncoder().encode(histogram.snapshot())
        let valid = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, value): (String, Any) in [
            ("observedCount", 2), ("bucketCounts", [1]),
            ("maxInRangeNanoseconds", 110), ("maxInRangeNanoseconds", 90),
        ] {
            var invalid = valid
            invalid[key] = value
            let encoded = try JSONSerialization.data(withJSONObject: invalid)
            #expect(throws: StatisticsError.malformedSnapshot) {
                try JSONDecoder().decode(HistogramSnapshot.self, from: encoded)
            }
        }
    }

    /// Creates the fixed small deterministic fixture profile shared by independent test cases.
    ///
    /// - Returns: Ten cells of width 10 over inclusive range 10...109 nanoseconds.
    /// - Throws: Configuration errors only if the fixture itself violates production invariants.
    private func configuration() throws -> HistogramConfiguration {
        try HistogramConfiguration(lowerBoundNanoseconds: 10, upperBoundNanoseconds: 109, bucketWidthNanoseconds: 10)
    }
}
