// File: Tools/DiscordBenchmarkSupport/Sources/DiscordBenchmarkSupport/Regression.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Foundation

/// Admission failures for versioned, bounded comparison documents.
public enum BenchmarkEvaluationError: Error, Equatable {
    case invalidSeries, invalidPolicy, documentTooLarge
}

/// Recorded process order; each standard series includes both orders.
public enum BenchmarkPairOrder: String, Codable, Sendable { case baselineFirst, candidateFirst }

/// One fresh-process pair. Process receipts must be unique across the entire series.
public struct BenchmarkPair: Codable, Sendable {
    public var id: String
    public var order: BenchmarkPairOrder
    public var baselineProcess: String
    public var candidateProcess: String
    public var hostContended: Bool
    public var baseline: DiscordBenchmarkReport
    public var candidate: DiscordBenchmarkReport

    /// Creates a recorded pair without measuring, accepting or modifying its evidence.
    /// - Parameters:
    ///   - id: Unique finite observation receipt, shared by the two paired arms.
    ///   - order: Actual recorded A/B process order.
    ///   - baselineProcess: Unique baseline invocation receipt, including the actual process ID.
    ///   - candidateProcess: Unique candidate invocation receipt, including the actual process ID.
    ///   - hostContended: True for known, unknown or uncontrolled host contention.
    ///   - baseline: Complete measured baseline envelope with original scope notes.
    ///   - candidate: Complete measured candidate envelope with original scope notes.
    public init(id: String, order: BenchmarkPairOrder, baselineProcess: String, candidateProcess: String,
        hostContended: Bool, baseline: DiscordBenchmarkReport, candidate: DiscordBenchmarkReport) {
        self.id = id; self.order = order; self.baselineProcess = baselineProcess
        self.candidateProcess = candidateProcess; self.hostContended = hostContended
        self.baseline = baseline; self.candidate = candidate
    }
}

/// Independent observations plus separately captured no-change calibration; no marginal percentiles are pooled.
public struct BenchmarkSeries: Codable, Sendable {
    public static let maximumSerializedBytes = 32 * 1_024 * 1_024
    public var format = "DiscordBenchmarkSeries"
    public var schemaVersion: UInt32 = 1
    public var pairs: [BenchmarkPair]
    public var noisePairs: [BenchmarkPair]

    /// Creates bounded offline evidence; qualification requires at least five pairs in both arrays.
    /// - Parameters:
    ///   - pairs: Fresh baseline/candidate pairs in actual observation order, at most ten.
    ///   - noisePairs: Independent no-change pairs with the same indexed seed schedule.
    public init(pairs: [BenchmarkPair], noisePairs: [BenchmarkPair]) {
        self.pairs = pairs; self.noisePairs = noisePairs
    }

    /// Checks version, cardinality and nested reports without claiming numerical qualification.
    /// - Throws: Unsupported series format/version, excessive observations, or nested report errors.
    public func validate() throws {
        guard format == "DiscordBenchmarkSeries", schemaVersion == 1,
            pairs.count <= 10, noisePairs.count <= 10 else { throw BenchmarkEvaluationError.invalidSeries }
        for pair in pairs + noisePairs {
            guard !pair.id.isEmpty, !pair.baselineProcess.isEmpty, !pair.candidateProcess.isEmpty else {
                throw BenchmarkEvaluationError.invalidSeries
            }
            try pair.baseline.validate(); try pair.candidate.validate()
        }
    }

    /// Decodes bounded evidence; missing calibration remains explicit until evaluation.
    /// - Parameter data: At most 32 MiB of version-one inline series JSON.
    /// - Returns: Structurally validated observations without a numerical classification.
    /// - Throws: Size, decoding, series identity or nested report errors.
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumSerializedBytes else { throw BenchmarkEvaluationError.documentTooLarge }
        let series = try JSONDecoder().decode(Self.self, from: data)
        try series.validate()
        return series
    }

    /// Computes review receipts from canonical report JSON and canonical no-change pair JSON.
    /// Hashing is provided by the CLI so other languages need not reproduce Foundation number encoding.
    /// Every receipt pins measured report bytes: a future fresh baseline capture requires a separate
    /// explicit review/update, even when the baseline executable itself is unchanged.
    /// - Returns: Ordered baseline report hashes and the complete no-change pair-array hash.
    /// - Throws: Series validation, report validation or encoding errors; nothing is written.
    public func hashes() throws -> BenchmarkSeriesHashes {
        try validate()
        return BenchmarkSeriesHashes(baselineHashes: try pairs.map { try BenchmarkEvidenceHash.report($0.baseline) },
            noiseSeriesHash: BenchmarkEvidenceHash.sha256(try Self.encoder().encode(noisePairs)))
    }

    /// Creates the canonical, locale-independent sorted-key encoder used for identity receipts.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// Immutable baseline/noise receipts to copy into a reviewed policy; hashing never promotes a baseline.
public struct BenchmarkSeriesHashes: Codable, Equatable, Sendable {
    public let baselineHashes: [String]
    public let noiseSeriesHash: String
}

/// Reporting remains informational; required mode is an explicit reviewed promotion.
public enum BenchmarkPolicyMode: String, Codable, Sendable { case reporting, required }

/// Duration summaries, throughput, and explicitly named resource observations have distinct semantics.
public enum BenchmarkStatistic: String, Codable, Sendable { case p50, p95, p99, maximum, throughput, gauge }

/// Cost ceilings and throughput floors use opposite adverse directions.
public enum BenchmarkBudgetDirection: String, Codable, Sendable { case maximum, minimum }

/// A reviewed bound for one exact metric/version/outcome/statistic, or one named resource gauge.
public struct BenchmarkBudget: Codable, Sendable {
    public var id: String
    public var metricID: String?
    public var metricVersion: UInt32?
    public var outcome: BenchmarkOutcome?
    public var statistic: BenchmarkStatistic
    public var gauge: String?
    public var direction: BenchmarkBudgetDirection
    public var relativeTolerance: Double
    public var absoluteNoiseFloor: Double
    public var absoluteLimit: Double?

    /// Declares a workload-specific threshold. Floors use nanoseconds, gauge units, or operations/second.
    /// An adverse delta must exceed both the relative tolerance and measured absolute noise floor.
    /// - Parameters:
    ///   - id: Unique reviewed budget identity used in result rows.
    ///   - metricID: Exact catalog metric identity for duration statistics, otherwise nil.
    ///   - metricVersion: Positive metric semantic version for duration statistics.
    ///   - outcome: Exact terminal duration population, otherwise nil.
    ///   - statistic: One run-local percentile/maximum, throughput, or resource gauge.
    ///   - gauge: Exact report gauge key for resource bounds, otherwise nil.
    ///   - direction: Maximum for durations/resources; minimum for throughput.
    ///   - relativeTolerance: Finite nonnegative permitted adverse fraction.
    ///   - absoluteNoiseFloor: Reviewed finite floor no smaller than measured no-change variability.
    ///   - absoluteLimit: Optional hard cost maximum or throughput minimum, unaffected by noise floors.
    public init(id: String, metricID: String? = nil, metricVersion: UInt32? = nil, outcome: BenchmarkOutcome? = nil,
        statistic: BenchmarkStatistic, gauge: String? = nil, direction: BenchmarkBudgetDirection,
        relativeTolerance: Double, absoluteNoiseFloor: Double, absoluteLimit: Double? = nil) {
        self.id = id; self.metricID = metricID; self.metricVersion = metricVersion; self.outcome = outcome
        self.statistic = statistic; self.gauge = gauge; self.direction = direction
        self.relativeTolerance = relativeTolerance; self.absoluteNoiseFloor = absoluteNoiseFloor
        self.absoluteLimit = absoluteLimit
    }

    /// Refuses ambiguous identities, unsupported directions and nonfinite or negative budgets.
    func validate() throws {
        guard !id.isEmpty, relativeTolerance.isFinite, relativeTolerance >= 0,
            absoluteNoiseFloor.isFinite, absoluteNoiseFloor >= 0,
            absoluteLimit == nil || (absoluteLimit!.isFinite && absoluteLimit! >= 0) else {
            throw BenchmarkEvaluationError.invalidPolicy
        }
        switch statistic {
        case .throughput:
            guard direction == .minimum, metricID == nil, metricVersion == nil, outcome == nil, gauge == nil else {
                throw BenchmarkEvaluationError.invalidPolicy
            }
        case .gauge:
            guard direction == .maximum, gauge?.isEmpty == false,
                metricID == nil, metricVersion == nil, outcome == nil else { throw BenchmarkEvaluationError.invalidPolicy }
        default:
            guard direction == .maximum, metricID?.isEmpty == false,
                metricVersion != nil, metricVersion != 0, outcome != nil, gauge == nil else {
                throw BenchmarkEvaluationError.invalidPolicy
            }
        }
    }
}

/// Version-one policy binds reviewed thresholds to frozen baseline and no-change evidence hashes.
public struct BenchmarkPolicy: Codable, Sendable {
    public static let maximumSerializedBytes = 1_024 * 1_024
    public var format = "DiscordBenchmarkPolicy"
    public var schemaVersion: UInt32 = 1
    public var mode: BenchmarkPolicyMode
    public var baselineHashes: [String]
    public var noiseSeriesHash: String
    public var acceptedQualificationLimitations: [String]
    public var budgets: [BenchmarkBudget]
    public var maximumErrors: UInt64
    public var maximumDeadlineMisses: UInt64

    /// Creates an explicit policy. No evaluator writes or updates these receipts or thresholds.
    /// - Parameters:
    ///   - mode: Reporting pilot or explicitly reviewed required promotion.
    ///   - baselineHashes: Ordered canonical report hashes for exactly this captured baseline cohort.
    ///   - noiseSeriesHash: Canonical hash of the complete separately captured no-change pair array.
    ///   - acceptedQualificationLimitations: Exact reviewed scope-note strings; unknown notes still refuse.
    ///   - budgets: Nonempty reviewed metric/version/resource bounds, at most 64.
    ///   - maximumErrors: Hard permitted offered-minus-success count per run; default zero.
    ///   - maximumDeadlineMisses: Hard permitted deadline-miss count per run; default zero.
    public init(mode: BenchmarkPolicyMode, baselineHashes: [String], noiseSeriesHash: String,
        acceptedQualificationLimitations: [String] = [], budgets: [BenchmarkBudget],
        maximumErrors: UInt64 = 0, maximumDeadlineMisses: UInt64 = 0) {
        self.mode = mode; self.baselineHashes = baselineHashes; self.noiseSeriesHash = noiseSeriesHash
        self.acceptedQualificationLimitations = acceptedQualificationLimitations; self.budgets = budgets
        self.maximumErrors = maximumErrors; self.maximumDeadlineMisses = maximumDeadlineMisses
    }

    /// Checks positive version, finite bounds, exact hash syntax and unique nonempty budget identities.
    /// - Throws: Invalid policy version, receipts, directions, identities or numerical limits.
    public func validate() throws {
        guard format == "DiscordBenchmarkPolicy", schemaVersion == 1,
            !baselineHashes.isEmpty, baselineHashes.count <= 10,
            baselineHashes.allSatisfy({ BenchmarkProvenance.validHash($0) }),
            BenchmarkProvenance.validHash(noiseSeriesHash), !budgets.isEmpty, budgets.count <= 64,
            Set(budgets.map(\.id)).count == budgets.count,
            acceptedQualificationLimitations.allSatisfy({ !$0.isEmpty }),
            Set(acceptedQualificationLimitations).count == acceptedQualificationLimitations.count else {
            throw BenchmarkEvaluationError.invalidPolicy
        }
        for budget in budgets { try budget.validate() }
    }

    /// Decodes only the supported bounded policy; malformed or absent bounds never become defaults.
    /// - Parameter data: At most one MiB of explicit version-one policy JSON.
    /// - Returns: Validated reviewed declarations; no baseline or floor is inferred.
    /// - Throws: Size, decoding or policy-admission errors.
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumSerializedBytes else { throw BenchmarkEvaluationError.documentTooLarge }
        let policy = try JSONDecoder().decode(Self.self, from: data)
        try policy.validate()
        return policy
    }
}

/// Distinct evidence outcomes keep unavailable or failed measurements from becoming a pass.
public enum BenchmarkEvaluationStatus: String, Codable, Sendable {
    case passed, regression, incompatible, insufficientSamples, hostFailure, harnessFailure
}

/// One independent run's interval-aware paired delta; no operation-level confidence interval is invented.
public struct BenchmarkPairedDelta: Codable, Sendable {
    public let pairID: String
    public let baselineLower: Double
    public let baselineUpper: Double
    public let candidateLower: Double
    public let candidateUpper: Double
    public let baselineSamples: UInt64?
    public let candidateSamples: UInt64?
    public let adverseLower: Double
    public let adverseUpper: Double
    public let definitelyExceedsBudget: Bool
    public let possiblyExceedsBudget: Bool
    public let greaterThanTenPercent: Bool
}

/// Descriptive spread across independent paired runs, deliberately without a confidence estimate.
public struct BenchmarkRunVariability: Codable, Sendable {
    public let independentPairs: Int
    public let minimumAdverseDelta: Double
    public let maximumAdverseDelta: Double
}

/// Per-budget evidence retains all paired observations and measured no-change noise.
public struct BenchmarkBudgetEvaluation: Codable, Sendable {
    public let id: String
    public let measuredAbsoluteNoise: Double
    public let deltas: [BenchmarkPairedDelta]
    public let variability: BenchmarkRunVariability
    public let investigationRequired: Bool
}

/// Offline classification; only an explicit required policy may turn a passing result into a required gate.
public struct BenchmarkEvaluation: Encodable, Sendable {
    public let format = "DiscordBenchmarkEvaluation"
    public let schemaVersion: UInt32 = 1
    public let mode: BenchmarkPolicyMode
    public let status: BenchmarkEvaluationStatus
    public let reasons: [String]
    public let budgets: [BenchmarkBudgetEvaluation]
    /// True only for a promoted policy with complete passing evidence and no pending investigation.
    public var requiredGatePassed: Bool {
        /// Keeps reporting results and unresolved three-run investigations from qualifying required gates.
        get { mode == .required && status == .passed && !budgets.contains(where: \.investigationRequired) }
    }

    private enum CodingKeys: String, CodingKey {
        case format, schemaVersion, mode, status, reasons, budgets, requiredGatePassed
    }

    /// Serializes the complete classification, including whether an explicitly promoted gate passed.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format); try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(mode, forKey: .mode); try container.encode(status, forKey: .status)
        try container.encode(reasons, forKey: .reasons); try container.encode(budgets, forKey: .budgets)
        try container.encode(requiredGatePassed, forKey: .requiredGatePassed)
    }

    /// Evaluates fresh matching pairs with hard accounting/loss/cleanup bounds and reviewed noise.
    /// A slowdown greater than ten percent in three matching runs requires investigation even
    /// when a workload-specific relative tolerance is wider. It is reported separately from
    /// reviewed budget violations. Percentiles remain run-local bucket intervals throughout.
    /// - Parameters:
    ///   - series: Captured independent observations plus measured no-change calibration.
    ///   - policy: Explicit hash-bound thresholds and reviewed scope-note acceptance.
    /// - Returns: A distinct pass, regression, incompatibility, insufficiency, host or harness status.
    /// - Throws: Structurally invalid report/series/policy documents, never a measured regression.
    public static func evaluate(_ series: BenchmarkSeries, policy: BenchmarkPolicy) throws -> Self {
        try series.validate(); try policy.validate()
        /// Keeps all early refusals distinct while sorting finite, credential-free reasons.
        func result(_ status: BenchmarkEvaluationStatus, _ reasons: [String],
            _ budgets: [BenchmarkBudgetEvaluation] = []) -> Self {
            Self(mode: policy.mode, status: status, reasons: Array(Set(reasons)).sorted(), budgets: budgets)
        }
        let hashes = try series.hashes()
        guard hashes.baselineHashes == policy.baselineHashes, hashes.noiseSeriesHash == policy.noiseSeriesHash else {
            return result(.incompatible, ["Baseline or no-change calibration hash does not match the reviewed policy."])
        }
        guard series.pairs.count >= 5, series.noisePairs.count >= 5 else {
            return result(.insufficientSamples, ["Standard qualification requires five fresh-process pairs and five independent no-change pairs."])
        }
        guard series.pairs.count == series.noisePairs.count,
            zip(series.pairs, series.noisePairs).allSatisfy({ $0.baseline.identity.seed == $1.baseline.identity.seed }) else {
            return result(.incompatible, ["No-change calibration must match the measured pair count and recorded seed schedule."])
        }
        let all = series.pairs + series.noisePairs
        guard !all.contains(where: \.hostContended) else {
            return result(.hostFailure, ["Recorded host contention invalidates controlled-host qualification."])
        }
        let processIDs = all.flatMap { [$0.baselineProcess, $0.candidateProcess] }
        guard Set(processIDs).count == processIDs.count, Set(all.map(\.id)).count == all.count else {
            return result(.harnessFailure, ["Pair and fresh-process receipts must be unique across measurement and no-change calibration."])
        }
        for pairs in [series.pairs, series.noisePairs] {
            guard Set(pairs.map(\.order)).count == 2,
                zip(pairs, pairs.dropFirst()).allSatisfy({ $0.order != $1.order }) else {
                return result(.incompatible, ["A/B order must alternate across independent measurement and no-change pairs."])
            }
        }
        let anchor = series.pairs[0].baseline
        let optimization = anchor.provenance.optimization?.lowercased() ?? ""
        let release = optimization == "release" || optimization.hasPrefix("release ")
        let compilerOnly = !anchor.metrics.isEmpty && anchor.metrics.allSatisfy {
            $0.id == BenchmarkWorkload.compilerClean.rawValue || $0.id == BenchmarkWorkload.compilerIncremental.rawValue
        }
        let compilerDebug = compilerOnly && (optimization == "debug" || optimization.hasPrefix("debug "))
        guard release || compilerDebug else {
            return result(.incompatible, ["Runtime timing requires a release build; explicit debug configuration is reserved for versioned compiler-only populations."])
        }
        /// Matches source and executable receipts without conflating them with measurement equality.
        func sameBuild(_ left: DiscordBenchmarkReport, _ right: DiscordBenchmarkReport) -> Bool {
            left.provenance.sourceRevision == right.provenance.sourceRevision
                && left.provenance.dirtyFingerprint == right.provenance.dirtyFingerprint
                && left.provenance.executableHash == right.provenance.executableHash
        }
        guard series.pairs.allSatisfy({ sameBuild(anchor, $0.baseline) && sameBuild(series.pairs[0].candidate, $0.candidate) }),
            series.noisePairs.allSatisfy({ sameBuild(anchor, $0.baseline) && sameBuild(anchor, $0.candidate) }) else {
            return result(.incompatible, ["Baseline, candidate and no-change cohorts must each retain their exact build receipts; calibration uses the baseline build."])
        }
        let accepted = Set(policy.acceptedQualificationLimitations)
        var incompatibilities: [String] = []
        var hardFailures: [String] = []
        for (isCalibration, pairs) in [(false, series.pairs), (true, series.noisePairs)] {
            for pair in pairs {
                if pair.baseline.identity.seed != pair.candidate.identity.seed {
                    return result(.incompatible, ["Each paired baseline/candidate must use the same recorded seed: \(pair.id)."])
                }
                for (isCandidate, report) in [(false, pair.baseline), (true, pair.candidate)] {
                    if report.status != .completed {
                        return result(.harnessFailure, ["Run did not complete: \(pair.id)."])
                    }
                    if report.metrics.contains(where: { $0.distribution.counterOverflow }) {
                        return result(.harnessFailure, ["Overflowed aggregate counters cannot qualify: \(pair.id)."])
                    }
                    let loss = report.metrics.contains { $0.distribution.droppedCount > 0 }
                    let incompleteCleanup = report.cleanup.completed != true || report.cleanup.remainingOwners != 0
                    guard let counts = report.counts else {
                        return result(.harnessFailure, ["Missing outcome accounting: \(pair.id)."])
                    }
                    guard counts.offered > 0, counts.completed > 0, !report.metrics.isEmpty,
                        report.metrics.allSatisfy({ $0.distribution.observedCount > 0 }) else {
                        return result(.insufficientSamples, ["Actual positive work and observed metric populations are required: \(pair.id)."])
                    }
                    let errors = counts.offered - counts.outcomes[.success, default: 0]
                    let badAccounting = counts.completed != counts.offered
                    let exceeded = loss || incompleteCleanup || badAccounting || errors > policy.maximumErrors
                        || counts.deadlineMisses > policy.maximumDeadlineMisses
                    if exceeded {
                        let reason = "Hard error/deadline/loss/cleanup bound failed: \(pair.id)."
                        if !isCandidate || isCalibration { return result(.harnessFailure, [reason]) }
                        hardFailures.append(reason)
                    }
                    if report.metrics.contains(where: { $0.distribution.underflowCount > 0 || $0.distribution.overflowCount > 0 }) {
                        return result(.insufficientSamples, ["Censored histogram population cannot qualify: \(pair.id)."])
                    }
                    // Hard failures are already classified above. Avoid relabeling their cleanup/loss as incompatibility.
                    var normalized = report
                    // The frozen per-pair seed schedule may vary across independent observations.
                    normalized.identity.seed = anchor.identity.seed
                    let reasons = anchor.comparison(with: normalized, acceptingQualificationLimitations: accepted).reasons
                    incompatibilities += reasons.filter {
                        $0 != "Aggregate loss or counter overflow blocks qualification."
                            && $0 != "Awaited zero-owner cleanup unavailable or incomplete."
                    }
                }
            }
        }
        if !incompatibilities.isEmpty { return result(.incompatible, incompatibilities) }
        if !hardFailures.isEmpty { return result(.regression, hardFailures) }
        for budget in policy.budgets {
            if budget.statistic == .gauge {
                guard let name = budget.gauge, anchor.gauges[name] != nil else {
                    return result(.incompatible, ["Policy names an unknown resource gauge: \(budget.id)."])
                }
            } else if budget.statistic != .throughput {
                guard anchor.metrics.contains(where: {
                    $0.id == budget.metricID && $0.version == budget.metricVersion && $0.outcome == budget.outcome
                }) else { return result(.incompatible, ["Policy metric/version/outcome identity does not exist: \(budget.id)."]) }
            }
        }
        var evaluations: [BenchmarkBudgetEvaluation] = []
        var violations: [String] = [], uncertainty: [String] = []
        for budget in policy.budgets {
            var measuredNoise: Double = 0
            for pair in series.noisePairs {
                guard let baseline = value(pair.baseline, budget), let candidate = value(pair.candidate, budget) else {
                    return result(.insufficientSamples, ["Unavailable, sparse or unsupported no-change population: \(budget.id)."])
                }
                measuredNoise = max(measuredNoise, abs(candidate.upper - baseline.lower), abs(baseline.upper - candidate.lower))
            }
            guard budget.absoluteNoiseFloor >= measuredNoise else {
                return result(.incompatible, ["Reviewed absolute noise floor is below measured no-change variability: \(budget.id)."])
            }
            var deltas: [BenchmarkPairedDelta] = []
            for pair in series.pairs {
                guard let baseline = value(pair.baseline, budget), let candidate = value(pair.candidate, budget) else {
                    return result(.insufficientSamples, ["Unavailable or insufficient population (p99 requires 10,000 observations per arm): \(budget.id)."])
                }
                let isMaximum = budget.direction == .maximum
                let adverseLower = isMaximum ? candidate.lower - baseline.upper : baseline.lower - candidate.upper
                let adverseUpper = isMaximum ? candidate.upper - baseline.lower : baseline.upper - candidate.lower
                let lowerThreshold = max(budget.absoluteNoiseFloor, baseline.lower * budget.relativeTolerance)
                let upperThreshold = max(budget.absoluteNoiseFloor, baseline.upper * budget.relativeTolerance)
                var definite = adverseLower > upperThreshold
                var possible = adverseUpper > lowerThreshold
                if let bound = budget.absoluteLimit {
                    definite = definite || (isMaximum ? candidate.lower > bound : candidate.upper < bound)
                    possible = possible || (isMaximum ? candidate.upper > bound : candidate.lower < bound)
                }
                let tenPercent = adverseLower > max(budget.absoluteNoiseFloor, baseline.upper * 0.1)
                deltas.append(BenchmarkPairedDelta(pairID: pair.id, baselineLower: baseline.lower, baselineUpper: baseline.upper,
                    candidateLower: candidate.lower, candidateUpper: candidate.upper,
                    baselineSamples: baseline.samples, candidateSamples: candidate.samples,
                    adverseLower: adverseLower, adverseUpper: adverseUpper, definitelyExceedsBudget: definite,
                    possiblyExceedsBudget: possible, greaterThanTenPercent: tenPercent))
            }
            let investigation = deltas.filter(\.greaterThanTenPercent).count >= 3
            if deltas.contains(where: \.definitelyExceedsBudget) { violations.append("Reviewed budget exceeded: \(budget.id).") }
            else if deltas.contains(where: \.possiblyExceedsBudget) { uncertainty.append("Histogram precision overlaps the reviewed bound: \(budget.id).") }
            evaluations.append(BenchmarkBudgetEvaluation(id: budget.id, measuredAbsoluteNoise: measuredNoise,
                deltas: deltas, variability: BenchmarkRunVariability(independentPairs: deltas.count,
                    minimumAdverseDelta: deltas.map(\.adverseLower).min()!, maximumAdverseDelta: deltas.map(\.adverseUpper).max()!),
                investigationRequired: investigation))
        }
        if !violations.isEmpty { return result(.regression, violations, evaluations) }
        if !uncertainty.isEmpty { return result(.insufficientSamples, uncertainty, evaluations) }
        let investigations = evaluations.filter(\.investigationRequired).map { "Greater than 10% adverse change reproduced in three runs; investigation required: \($0.id)." }
        return result(.passed, investigations, evaluations)
    }

    /// Extracts a finite closed interval, preserving histogram precision and sample sufficiency.
    private static func value(_ report: DiscordBenchmarkReport, _ budget: BenchmarkBudget)
        -> (lower: Double, upper: Double, samples: UInt64?)? {
        switch budget.statistic {
        case .throughput:
            guard let value = report.throughputPerSecond, value.isFinite else { return nil }
            return (value, value, nil)
        case .gauge:
            guard let name = budget.gauge, let gauge = report.gauges[name], let value = gauge.value else { return nil }
            return (value <= 9_007_199_254_740_992 ? Double(value) : Double(value).nextDown,
                value <= 9_007_199_254_740_992 ? Double(value) : Double(value).nextUp, nil)
        default:
            guard let metric = report.metrics.first(where: {
                $0.id == budget.metricID && $0.version == budget.metricVersion && $0.outcome == budget.outcome
            }), metric.distribution.observedCount > 0 else { return nil }
            if budget.statistic == .p99 && metric.distribution.observedCount < 10_000 { return nil }
            let estimate: QuantileEstimate
            switch budget.statistic {
            case .p50: estimate = metric.p50
            case .p95: estimate = metric.p95
            case .p99: estimate = metric.p99
            default: estimate = metric.maximum
            }
            guard case .interval(let lower, let upper) = estimate else { return nil }
            return (lower <= 9_007_199_254_740_992 ? Double(lower) : Double(lower).nextDown,
                upper <= 9_007_199_254_740_992 ? Double(upper) : Double(upper).nextUp, metric.distribution.observedCount)
        }
    }
}

/// Dependency-free SHA-256 receipts over exact canonical bytes; not a source of measurement evidence.
public enum BenchmarkEvidenceHash {
    /// Hashes a validated report using the same canonical encoder as report serialization.
    /// - Parameter report: One complete common envelope, retained without mutation.
    /// - Returns: Lowercase SHA-256 over its canonical JSON bytes.
    /// - Throws: Report validation or encoding errors.
    public static func report(_ report: DiscordBenchmarkReport) throws -> String { sha256(try report.validatedData()) }

    /// Computes standard SHA-256 without shelling out or reading unbounded external files.
    /// - Parameter data: Caller-bounded exact input bytes, including any intended whitespace.
    /// - Returns: The standard lowercase 64-character hexadecimal digest.
    public static func sha256(_ data: Data) -> String {
        let constants: [UInt32] = [
            0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
            0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
            0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
            0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
            0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
            0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
            0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
        var words: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
        var bytes = Array(data), schedule = [UInt32](repeating: 0, count: 64)
        let bits = UInt64(bytes.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: bits >> shift)) }
        /// Rotates one SHA-256 word using defined unsigned shifts.
        func rotate(_ value: UInt32, _ amount: UInt32) -> UInt32 { (value >> amount) | (value << (32 - amount)) }
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            for index in 0..<16 {
                let start = offset + index * 4
                schedule[index] = UInt32(bytes[start]) << 24 | UInt32(bytes[start + 1]) << 16
                    | UInt32(bytes[start + 2]) << 8 | UInt32(bytes[start + 3])
            }
            for index in 16..<64 {
                let x = schedule[index - 15], y = schedule[index - 2]
                let s0 = rotate(x, 7) ^ rotate(x, 18) ^ (x >> 3)
                let s1 = rotate(y, 17) ^ rotate(y, 19) ^ (y >> 10)
                schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
            }
            var a = words[0], b = words[1], c = words[2], d = words[3]
            var e = words[4], f = words[5], g = words[6], h = words[7]
            for index in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let temp1 = h &+ s1 &+ ((e & f) ^ (~e & g)) &+ constants[index] &+ schedule[index]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let temp2 = s0 &+ ((a & b) ^ (a & c) ^ (b & c))
                h = g; g = f; f = e; e = d &+ temp1; d = c; c = b; b = a; a = temp1 &+ temp2
            }
            for (index, value) in [a,b,c,d,e,f,g,h].enumerated() { words[index] &+= value }
        }
        return words.map { String(format: "%08x", $0) }.joined()
    }
}
