// File: Tools/DiscordBenchmarkSupport/Tests/DiscordBenchmarkSupportTests/SummaryTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Foundation
import Testing
@testable import DiscordBenchmarkSupport

@Suite struct SummaryTests {
    /// Creates a deterministic histogram with explicit finite precision and caller-selected mass.
    /// - Parameters:
    ///   - observations: Value and multiplicity pairs, including zero or censored values.
    ///   - loss: Unknown-value observation count, default zero; this invalidates every estimate if positive.
    /// - Returns: Immutable evidence over the inclusive 10...100 ns range with 10 ns bucket widths.
    /// - Throws: Configuration errors, indicating a fixture programming error rather than an external dependency.
    private func histogram(_ observations: [(UInt64, UInt64)] = [], loss: UInt64 = 0) throws -> HistogramSnapshot {
        var histogram = BoundedHistogram(configuration: try .init(lowerBoundNanoseconds: 10,
            upperBoundNanoseconds: 100, bucketWidthNanoseconds: 10))
        for (value, count) in observations { histogram.record(value, count: count) }
        histogram.recordLoss(loss)
        return histogram.snapshot()
    }

    /// Creates one schema-one, catalog-nine local artifact with exact terminal accounting and explicit missing provenance.
    /// - Parameter metrics: Independent metric/outcome populations, default empty for absence tests.
    /// - Returns: A completed report whose resource and cleanup scopes are explicit; no live system is measured.
    private func report(metrics: [BenchmarkMetric] = []) -> DiscordBenchmarkReport {
        var identity = ReportIdentity(scenario: "summary-fixture", profile: "smoke", seed: 7,
            instrumentation: "whole-population-aggregate", scheduler: "bounded-workers", concurrency: 2,
            warmupNanoseconds: 0, requestedWarmupNanoseconds: 0, measuredNanoseconds: 100, repetitions: 1)
        identity.catalogVersion = 9
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        outcomes[.success] = 10_000; outcomes[.failure] = 1; outcomes[.rejected] = 1
        return .init(identity: identity, provenance: .init(), adapter: "local.fixture", clockDomain: "fixture",
            status: .completed, counts: .init(offered: 10_002, admitted: 10_001, completed: 10_002,
                outcomes: outcomes, deadlineMisses: 2), metrics: metrics,
            gauges: ["processCPU": .init(value: 123, unit: "nanoseconds", method: "fixture",
                scope: "process-lifetime"),
                "processResidentBytes": .init(value: nil, unit: "bytes", method: "unavailable",
                    scope: "process", unavailableReason: "Not observed.")],
            cleanup: .init(completed: true, remainingOwners: 0), throughputPerSecond: 100)
    }

    /// Checks direct percentile intervals, exact maxima, every outcome and honest scoped resources together.
    /// - Throws: Unexpected fixture or strict render validation failure.
    @Test func completeReportKeepsPopulationsAndCountsVisible() throws {
        let success = BenchmarkMetric(id: BenchmarkWorkload.restRequest.rawValue, clockDomain: "fixture",
            distribution: try histogram([(42, 10_000)]))
        let failedPhase = BenchmarkMetric(id: BenchmarkWorkload.restBody.rawValue, outcome: .failure,
            clockDomain: "fixture", distribution: try histogram([(62, 1)]))
        let original = report(metrics: [success, failedPhase])
        let text = try BenchmarkReportSummary.render(original)
        #expect(text.contains("status=completed numericalQualification=false"))
        #expect(text.contains("load offered=10002 admitted=10001 completed=10002 deadlineMisses=2"))
        #expect(text.contains("outcomes success=10000 failure=1 cancelled=0 timedOut=0 rejected=1 uncertain=0"))
        #expect(text.contains("rest.request v1 outcome=success\n    p50=[40,49] ns p95=[40,49] ns p99=[40,49] ns max=[42,42] ns"))
        #expect(text.contains("rest.body v1 outcome=failure\n    p50=[60,69] ns p95=[60,69] ns p99=unavailable(insufficientTailData) max=[62,62] ns"))
        #expect(text.contains("observed=10000 inRange=10000 underflow=0 overflow=0 dropped=0 counterOverflow=false"))
        #expect(text.contains("range=[10,100] ns bucketWidth=10 ns"))
        #expect(text.contains("processCPU=123 unit=nanoseconds method=fixture scope=process-lifetime"))
        #expect(text.contains("processResidentBytes=unavailable unit=bytes method=unavailable scope=process\n    reason=Not observed."))
        #expect(text.contains("processPeakResidentBytes=unavailable (not declared)"))
        #expect(text.contains("cleanup completed=true remainingOwners=0"))
        #expect(text.contains("observerCost=unavailable"))
        #expect(text.contains("timeline=unavailable"))
        #expect(text == (try BenchmarkReportSummary.render(original)))
        #expect(original.metrics == [success, failedPhase])
        var reordered = original; reordered.metrics.reverse()
        #expect(try BenchmarkReportSummary.render(reordered) == text)
    }

    /// Preserves exclusive censoring, sparse tails, unknown loss, counter overflow and empty evidence beside counts.
    /// - Throws: Unexpected bounded-histogram or summary validation failure.
    @Test func uncertaintyIsDisplayedWithoutFabricatedNumbers() throws {
        let cases: [(HistogramSnapshot, String, String)] = [
            (try histogram([(9, 5_000), (101, 5_000)]),
                "p50=<10 ns (censored) p95=>100 ns (censored) p99=>100 ns (censored) max=>100 ns (censored)",
                "underflow=5000 overflow=5000 dropped=0 counterOverflow=false"),
            (try histogram([(42, 1)]), "p99=unavailable(insufficientTailData)", "observed=1 inRange=1"),
            (try histogram([(42, 10_000)], loss: 1), "p50=unavailable(aggregateLoss)", "dropped=1 counterOverflow=false"),
            (try histogram([(42, UInt64.max), (42, 1)]), "p50=unavailable(counterOverflow)", "counterOverflow=true"),
            (try histogram(), "p50=unavailable(emptyPopulation)", "observed=0 inRange=0")]
        for (distribution, estimate, counts) in cases {
            let original = report(metrics: [.init(id: BenchmarkWorkload.restRequest.rawValue,
                clockDomain: "fixture", distribution: distribution)])
            let text = try BenchmarkReportSummary.render(original)
            #expect(text.contains(estimate))
            #expect(text.contains(counts))
            if distribution.droppedCount > 0 || distribution.counterOverflow {
                #expect(text.contains("max=unavailable("))
                #expect(text.contains("p99=unavailable("))
            }
        }
    }

    /// Missing accounting and cleanup remain unavailable while run outcomes and limitation text remain explicit.
    /// - Throws: Unexpected renderer validation error for legal partial evidence.
    @Test func partialEvidenceNeverTurnsAbsenceIntoZero() throws {
        for status in [BenchmarkRunStatus.failed, .interrupted, .unqualified] {
            var original = report()
            original.status = status; original.counts = nil; original.throughputPerSecond = nil
            original.cleanup = .init(reason: "Owner join not observed.")
            original.qualificationLimitations = ["Local fixture only."]
            let text = try BenchmarkReportSummary.render(original)
            #expect(text.contains("status=\(status.rawValue) numericalQualification=false"))
            #expect(text.contains("load offered=unavailable admitted=unavailable completed=unavailable deadlineMisses=unavailable"))
            #expect(text.contains("outcomes=unavailable"))
            #expect(text.contains("throughputPerSecond=unavailable"))
            #expect(text.contains("metrics=0"))
            #expect(text.contains("unavailable (no histograms captured)"))
            #expect(text.contains("cleanup completed=unavailable remainingOwners=unavailable"))
            #expect(text.contains("reason=Owner join not observed."))
            #expect(text.contains("qualificationLimitations=1\n  Local fixture only."))
            #expect(text.contains("unavailableProvenance="))
        }
    }

    /// Gross instrumentation operations cannot be presented as isolated observer cost or subtracted overhead.
    /// - Throws: Unexpected fixture or strict renderer validation failure.
    @Test func grossInstrumentationIsNotObserverOverhead() throws {
        let original = report(metrics: [.init(id: BenchmarkWorkload.instrumentation.rawValue,
            clockDomain: "fixture", distribution: try histogram([(42, 10_000)]))])
        let text = try BenchmarkReportSummary.render(original)
        #expect(text.contains("observerCost=unavailable (schema has no isolated observer-cost metric"))
        #expect(text.contains("instrumentation.operation.gross is a complete fixture operation, not isolated observer overhead; no subtraction performed"))
    }

    /// Caller references remain explicit unverified pointers and obey finite cardinality and UTF-8 byte bounds.
    /// - Throws: Unexpected rendering failure for a reference within the documented limits.
    @Test func timelinesAreOptionalReferencesRatherThanInventedIntervals() throws {
        let original = report()
        let text = try BenchmarkReportSummary.render(original, timelineReferences: ["capture.json", "trace.jsonl"])
        #expect(text.contains("timelineReferences=2 (caller supplied; contents, existence and correlation unverified)\n  capture.json\n  trace.jsonl"))
        #expect(throws: BenchmarkSummaryError.invalidTimelineReferences) {
            try BenchmarkReportSummary.render(original, timelineReferences: [""])
        }
        #expect(throws: BenchmarkSummaryError.invalidTimelineReferences) {
            try BenchmarkReportSummary.render(original, timelineReferences: Array(repeating: "trace", count: 5))
        }
        #expect(throws: BenchmarkSummaryError.invalidTimelineReferences) {
            try BenchmarkReportSummary.render(original, timelineReferences: [String(repeating: "a", count: 513)])
        }
        #expect(throws: BenchmarkSummaryError.invalidTimelineReferences) {
            try BenchmarkReportSummary.render(original, timelineReferences: [String(repeating: "é", count: 257)])
        }
        #expect(try BenchmarkReportSummary.render(original,
            timelineReferences: [String(repeating: "a", count: 512)]).contains("[truncated]"))
    }

    /// Large valid metadata is bounded visibly, controls are escaped and input order cannot perturb metric selection.
    /// - Throws: Unexpected fixture generation, validation or renderer failure.
    @Test func presentationBoundsDoNotSilentlyDiscardEvidence() throws {
        let distribution = try histogram([(42, 1)])
        let metrics = BenchmarkWorkload.allCases.prefix(65).map {
            BenchmarkMetric(id: $0.rawValue, clockDomain: "fixture", distribution: distribution)
        }
        #expect(metrics.count == 65)
        var original = report(metrics: metrics)
        original.identity.profile = "first\nsecond\u{1B}[31m" + String(repeating: "é", count: 500)
        original.gauges = Dictionary(uniqueKeysWithValues: (0..<20).map {
            ("gauge-\($0)", BenchmarkGauge(value: 0, unit: "bytes", method: "fixture", scope: "process"))
        })
        original.qualificationLimitations = (0..<11).map { "note-\($0) " + String(repeating: "x", count: 10_000) }
        let text = try BenchmarkReportSummary.render(original)
        #expect(text.contains("first\\u{a}second\\u{1b}[31m"))
        #expect(!text.contains("\u{1B}"))
        #expect(text.contains("[truncated]"))
        #expect(text.contains("1 metric populations omitted from display"))
        #expect(text.contains("4 resource gauges omitted from display"))
        #expect(text.contains("3 qualificationLimitations omitted from display"))
        #expect(text.components(separatedBy: "\n  ").filter { $0.hasPrefix("note-") }.count == 8)
        #expect(text.utf8.count < 100_000)
        #expect(text.components(separatedBy: "\n")[1].utf8.count < 500)
        #expect(original.qualificationLimitations[0].utf8.count > 10_000)
        var reversed = original; reversed.metrics.reverse()
        #expect(try BenchmarkReportSummary.render(reversed) == text)
    }

    /// Unsupported versions, clock mismatches, inconsistent counts and gauge contradictions fail before presentation.
    /// - Throws: Unexpected fixture construction failure; malformed reports must throw their existing strict errors.
    @Test func invalidReportsCannotAcquireAReadableSummary() throws {
        var invalid = report(); invalid.schemaVersion = 2
        #expect(throws: BenchmarkReportError.invalidVersion) { try BenchmarkReportSummary.render(invalid) }
        invalid = report(metrics: [.init(id: BenchmarkWorkload.restRequest.rawValue, clockDomain: "other",
            distribution: try histogram([(42, 1)]))])
        #expect(throws: BenchmarkReportError.mixedClockDomains) { try BenchmarkReportSummary.render(invalid) }
        invalid = report(); invalid.counts?.completed = 0
        #expect(throws: BenchmarkReportError.invalidCounts) { try BenchmarkReportSummary.render(invalid) }
        invalid = report(); invalid.gauges["invalid"] = .init(value: nil, unit: "bytes", method: "fixture", scope: "process")
        #expect(throws: BenchmarkReportError.invalidGauge) { try BenchmarkReportSummary.render(invalid) }
        #expect(throws: (any Error).self) { try DiscordBenchmarkReport.decode(Data("{}".utf8)) }
    }

    /// Explicit legacy adapters keep native bytes separate and cannot gain inferred load or timeline evidence.
    /// - Throws: Unexpected fixture adapter, schema or presentation validation failure.
    @Test func legacyEvidenceRetainsUnavailableAccounting() throws {
        let original = try DiscordBenchmarkReport.adaptingLegacy(Data("{\"measurement\":{},\"afterShutdown\":{}}".utf8),
            format: .loadUnversioned, identity: .init(scenario: "legacy-fixture", profile: "smoke"), provenance: .init())
        let text = try BenchmarkReportSummary.render(original)
        #expect(text.contains("legacySource=DiscordKitLoadTests.unversioned"))
        #expect(text.contains("status=unqualified numericalQualification=false"))
        #expect(text.contains("outcomes=unavailable"))
        #expect(text.contains("timeline=unavailable"))
        #expect(text.contains("Common offered/admitted/completed outcomes, deadline misses and cleanup were not captured"))
    }
}
