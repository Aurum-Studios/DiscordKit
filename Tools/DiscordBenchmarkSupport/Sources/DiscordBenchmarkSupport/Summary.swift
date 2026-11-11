// File: Tools/DiscordBenchmarkSupport/Sources/DiscordBenchmarkSupport/Summary.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

/// Admission failures for optional, caller-supplied timeline references.
public enum BenchmarkSummaryError: Error, Equatable, Sendable {
    case invalidTimelineReferences
}

/// Bounded, deterministic presentation of one common report, independent of runtime products.
///
/// Each metric/outcome retains its own population and endpoints. This view does not
/// reconstruct correlated intervals, add marginal percentiles, isolate observer cost,
/// or apply comparison policy. Original JSON remains the authoritative complete artifact.
public enum BenchmarkReportSummary {
    public static let maximumMetrics = 64
    public static let maximumGauges = 16
    public static let maximumNotes = 8
    public static let maximumFieldBytes = 160
    public static let maximumTimelineReferences = 4
    public static let maximumTimelineReferenceBytes = 512

    /// Renders validated evidence with explicit uncertainty and bounded display omissions.
    ///
    /// Input uses the common envelope's existing validation; callers reading files
    /// must enforce its 32-MiB serialized ceiling before decoding. At most 64
    /// metric populations, 16 resource gauges, eight notes in each note group and
    /// four timeline references are displayed. Omitted rows and shortened fields
    /// are visible; the report and references are never mutated. Work is bounded by
    /// validated histogram storage plus report metadata. No I/O, clocks or tasks run.
    /// - Parameters:
    ///   - report: One schema-one common report; native and series formats require their own tools.
    ///   - timelineReferences: Optional caller-supplied artifact references, each nonempty and at
    ///     most 512 UTF-8 bytes, with at most four entries. They are displayed but neither opened
    ///     nor validated for existence, correlation, content, completeness or clock compatibility.
    /// - Returns: Stable newline-separated text without a trailing newline. Durations use integer
    ///   nanoseconds; bucket intervals are inclusive and censored boundaries are exclusive.
    ///   Summary success establishes structural readability, never numerical qualification.
    /// - Throws: Existing report validation errors, or invalidTimelineReferences for invalid bounds.
    public static func render(_ report: DiscordBenchmarkReport, timelineReferences: [String] = []) throws -> String {
        try report.validate()
        guard timelineReferences.count <= maximumTimelineReferences,
            timelineReferences.allSatisfy({ !$0.isEmpty && $0.utf8.count <= maximumTimelineReferenceBytes }) else {
            throw BenchmarkSummaryError.invalidTimelineReferences
        }
        var lines = ["DiscordBenchmarkReport summary (schema \(report.schemaVersion))",
            "scenario=\(field(report.identity.scenario)) profile=\(field(report.identity.profile)) v\(report.identity.profileVersion) catalog=\(field(report.identity.catalog)) v\(report.identity.catalogVersion)",
            "adapter=\(field(report.adapter)) instrumentation=\(field(report.identity.instrumentation)) clockDomain=\(field(report.clockDomain ?? "unavailable"))",
            "status=\(report.status.rawValue) numericalQualification=false (single artifact; no comparison policy evaluated)",
            "durations=integer ns; intervals inclusive; censored bounds exclusive; metric populations remain separate",
            "scheduler=\(field(report.identity.scheduler)) concurrency=\(number(report.identity.concurrency.map(UInt64.init))) seed=\(number(report.identity.seed)) repetitions=\(number(report.identity.repetitions.map(UInt64.init)))",
            "warmupRequestedNs=\(number(report.identity.requestedWarmupNanoseconds)) warmupActualNs=\(number(report.identity.warmupNanoseconds)) measuredNs=\(number(report.identity.measuredNanoseconds))"]
        if let counts = report.counts {
            lines.append("load offered=\(counts.offered) admitted=\(counts.admitted) completed=\(counts.completed) deadlineMisses=\(counts.deadlineMisses)")
            lines.append("outcomes " + BenchmarkOutcome.allCases.map { "\($0.rawValue)=\(counts.outcomes[$0]!)" }.joined(separator: " "))
        } else {
            lines.append("load offered=unavailable admitted=unavailable completed=unavailable deadlineMisses=unavailable")
            lines.append("outcomes=unavailable (not inferred from metric populations or native summaries)")
        }
        lines.append("throughputPerSecond=\(report.throughputPerSecond.map(String.init(describing:)) ?? "unavailable")")
        let metrics = report.metrics.sorted {
            if $0.id != $1.id { return $0.id < $1.id }
            return $0.outcome.rawValue < $1.outcome.rawValue
        }
        lines.append("metrics=\(metrics.count) (direct observations; identify end-to-end and phase endpoints in the catalog)")
        for metric in metrics.prefix(maximumMetrics) {
            let distribution = metric.distribution
            lines.append("  \(field(metric.id)) v\(metric.version) outcome=\(metric.outcome.rawValue)")
            lines.append("    p50=\(estimate(metric.p50)) p95=\(estimate(metric.p95)) p99=\(estimate(metric.p99)) max=\(estimate(metric.maximum))")
            lines.append("    observed=\(distribution.observedCount) inRange=\(distribution.inRangeCount) underflow=\(distribution.underflowCount) overflow=\(distribution.overflowCount) dropped=\(distribution.droppedCount) counterOverflow=\(distribution.counterOverflow)")
            lines.append("    range=[\(distribution.configuration.lowerBoundNanoseconds),\(distribution.configuration.upperBoundNanoseconds)] ns bucketWidth=\(distribution.configuration.bucketWidthNanoseconds) ns")
        }
        if metrics.isEmpty { lines.append("  unavailable (no histograms captured)") }
        appendOmission(metrics.count, displayed: maximumMetrics, kind: "metric populations", to: &lines)
        let requiredGauges = ["processCPU", "processResidentBytes", "processPeakResidentBytes"]
        lines.append("resources=\(report.gauges.count) (scope and method belong to each observation)")
        for name in requiredGauges where report.gauges[name] == nil {
            lines.append("  \(name)=unavailable (not declared)")
        }
        for name in report.gauges.keys.sorted().prefix(maximumGauges) {
            let gauge = report.gauges[name]!
            let value = number(gauge.value)
            lines.append("  \(field(name))=\(value) unit=\(field(gauge.unit)) method=\(field(gauge.method)) scope=\(field(gauge.scope))")
            if let reason = gauge.unavailableReason { lines.append("    reason=\(field(reason))") }
        }
        appendOmission(report.gauges.count, displayed: maximumGauges, kind: "resource gauges", to: &lines)
        lines.append("cleanup completed=\(report.cleanup.completed.map(String.init(describing:)) ?? "unavailable") remainingOwners=\(number(report.cleanup.remainingOwners))")
        if let reason = report.cleanup.reason { lines.append("  reason=\(field(reason))") }
        lines.append("observerCost=unavailable (schema has no isolated observer-cost metric; gross operation durations include configured collection)")
        if metrics.contains(where: { $0.id == BenchmarkWorkload.instrumentation.rawValue }) {
            lines.append("  instrumentation.operation.gross is a complete fixture operation, not isolated observer overhead; no subtraction performed")
        }
        appendNotes(report.provenance.missingFields().sorted(), label: "unavailableProvenance", to: &lines)
        appendNotes(report.qualificationLimitations, label: "qualificationLimitations", to: &lines)
        if let legacy = report.legacy {
            lines.append("legacySource=\(legacy.format.rawValue) (original bytes retained in JSON; native values not promoted)")
        }
        if timelineReferences.isEmpty {
            lines.append("timeline=unavailable (common schema contains histograms, not correlated intervals)")
        } else {
            lines.append("timelineReferences=\(timelineReferences.count) (caller supplied; contents, existence and correlation unverified)")
            for reference in timelineReferences { lines.append("  \(field(reference))") }
        }
        lines.append("displayLimits metrics=\(maximumMetrics) gauges=\(maximumGauges) notesPerGroup=\(maximumNotes) fieldBytes=\(maximumFieldBytes); [truncated] marks shortened text; use original JSON for complete evidence")
        return lines.joined(separator: "\n")
    }

    /// Formats one estimate without rounding, clamping, substituting zero or dropping uncertainty.
    /// - Parameter value: Estimate already derived from a validated complete-population histogram.
    /// - Returns: Inclusive integer interval, exclusive censored boundary, or original unavailability reason.
    private static func estimate(_ value: QuantileEstimate) -> String {
        switch value {
        case let .interval(lower, upper): "[\(lower),\(upper)] ns"
        case let .underflow(upper): "<\(upper) ns (censored)"
        case let .overflow(lower): ">\(lower) ns (censored)"
        case let .unavailable(reason): "unavailable(\(reason.rawValue))"
        }
    }

    /// Preserves optional integer absence independently of an observed zero.
    /// - Parameter value: Known nonnegative integer, or nil when unobserved.
    /// - Returns: Exact base-ten integer or the literal unavailable marker, without locale formatting.
    private static func number(_ value: UInt64?) -> String { value.map(String.init) ?? "unavailable" }

    /// Bounds and escapes one display field without emitting terminal control characters.
    /// - Parameter value: Original metadata, which is never changed in the authoritative artifact.
    /// - Returns: At most 160 UTF-8 bytes; ASCII controls are escaped and a visible suffix marks
    ///   truncation. Scalar boundaries are preserved. Iteration stops after the display budget.
    private static func field(_ value: String) -> String {
        let suffix = "[truncated]"
        var result = ""
        for scalar in value.unicodeScalars {
            let piece: String
            switch scalar.value {
            case 0...31, 127...159: piece = "\\u{\(String(scalar.value, radix: 16))}"
            default: piece = String(scalar)
            }
            guard result.utf8.count + piece.utf8.count <= maximumFieldBytes - suffix.utf8.count else {
                return result + suffix
            }
            result += piece
        }
        return result
    }

    /// Appends a bounded group while retaining the original count and precise omitted-row count.
    /// - Parameters:
    ///   - notes: Ordered original notes; strings are bounded and escaped individually.
    ///   - label: Fixed presentation group identity, never a metric or qualification decision.
    ///   - lines: Caller-owned output lines, extended synchronously without external side effects.
    private static func appendNotes(_ notes: [String], label: String, to lines: inout [String]) {
        lines.append("\(label)=\(notes.count)")
        for note in notes.prefix(maximumNotes) { lines.append("  \(field(note))") }
        appendOmission(notes.count, displayed: maximumNotes, kind: label, to: &lines)
    }

    /// Adds an exact omission marker only when a finite group exceeds its display ceiling.
    /// - Parameters:
    ///   - total: Nonnegative original row count.
    ///   - displayed: Fixed positive display ceiling, rather than a measurement sample limit.
    ///   - kind: Fixed human-readable group label.
    ///   - lines: Caller-owned lines receiving at most one marker; authoritative data remains intact.
    private static func appendOmission(_ total: Int, displayed: Int, kind: String, to lines: inout [String]) {
        if total > displayed { lines.append("  ... \(total - displayed) \(kind) omitted from display; see original JSON") }
    }
}
