// File: Tools/DiscordBenchmarkSupport/Sources/DiscordBenchmarkSupport/Report.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Foundation

/// Fail-closed errors for malformed or unsupported development evidence.
public enum BenchmarkReportError: Error, Equatable {
    case invalidVersion, invalidFormat, invalidIdentity, invalidTime, mixedClockDomains
    case invalidCounts, invalidGauge, unsupportedMetric, reportTooLarge, malformedLegacy
}

/// Harness outcomes partition whole populations without extending runtime timing enums.
public enum BenchmarkOutcome: String, Codable, Hashable, Sendable, CaseIterable {
    case success, failure, cancelled, timedOut, rejected, uncertain
}

/// Independent native formats are explicit adapter identities, not versions of the envelope.
public enum LegacyReportFormat: String, Codable, Sendable {
    case loadUnversioned = "DiscordKitLoadTests.unversioned"
    case dslVersion1 = "DiscordDSLBenchmarks.v1"
    case voiceVersion2 = "VoiceSessionQualification.v2"
}

/// Terminal harness status includes bounded partial evidence from interrupted or failed runs.
public enum BenchmarkRunStatus: String, Codable, Sendable { case completed, interrupted, failed, unqualified }

/// Finite workload dimensions and semantic versions; source code hashes live in provenance.
public struct ReportIdentity: Codable, Equatable, Sendable {
    public var catalog = "discordkit.timing"
    public var catalogVersion: UInt32 = 2
    public var scenario: String
    public var profile: String
    public var profileVersion: UInt32
    public var seed: UInt64?
    public var fixtureHashes: [String: String]
    public var inputSizes: [String: UInt64]
    public var instrumentation: String
    public var scheduler: String
    public var concurrency: UInt32?
    public var warmupNanoseconds: UInt64?
    public var requestedWarmupNanoseconds: UInt64?
    public var measuredNanoseconds: UInt64?
    public var repetitions: UInt32?

    /// Creates declared dimensions without fabricating missing legacy process policy.
    /// - Parameters:
    ///   - scenario: Finite, credential-free workload identity.
    ///   - profile: Reviewed profile identity, such as smoke or standard.
    ///   - profileVersion: Positive semantic version; endpoint/population changes require a new value.
    ///   - seed: Recorded deterministic workload seed; nil means unavailable.
    ///   - fixtureHashes: Exact input SHA-256 receipts; an empty map remains unavailable.
    ///   - inputSizes: Declared finite input dimensions, not persistent Discord identifiers.
    ///   - instrumentation: Collection mode and options defining comparable overhead.
    ///   - scheduler: Recorded scheduling/arrival policy, including any legacy order.
    ///   - concurrency: Actual finite active cohort, or nil when unavailable.
    ///   - warmupNanoseconds: Actual separate warmup interval; explicit zero is permitted.
    ///   - requestedWarmupNanoseconds: Configured warmup policy; compared independently of elapsed jitter.
    ///   - measuredNanoseconds: Actual measured interval, independent of requested duration.
    ///   - repetitions: Actual fresh-process repetition count; nil is unavailable.
    public init(scenario: String, profile: String, profileVersion: UInt32 = 1, seed: UInt64? = nil,
        fixtureHashes: [String: String] = [:], inputSizes: [String: UInt64] = [:],
        instrumentation: String = "aggregate", scheduler: String = "legacy-owner",
        concurrency: UInt32? = nil, warmupNanoseconds: UInt64? = nil, requestedWarmupNanoseconds: UInt64? = nil,
        measuredNanoseconds: UInt64? = nil, repetitions: UInt32? = nil) {
        self.scenario = scenario; self.profile = profile; self.profileVersion = profileVersion
        self.seed = seed; self.fixtureHashes = fixtureHashes; self.inputSizes = inputSizes
        self.instrumentation = instrumentation; self.scheduler = scheduler; self.concurrency = concurrency
        self.warmupNanoseconds = warmupNanoseconds; self.measuredNanoseconds = measuredNanoseconds
        self.requestedWarmupNanoseconds = requestedWarmupNanoseconds
        self.repetitions = repetitions
    }
}

/// Explicit nonnegative counts; outcomes cannot make failed/rejected work disappear.
public struct BenchmarkCounts: Codable, Equatable, Sendable {
    public var offered: UInt64
    public var admitted: UInt64
    public var completed: UInt64
    public var outcomes: [BenchmarkOutcome: UInt64]
    public var deadlineMisses: UInt64

    /// Records the entire workload population, independent of histogram sampling.
    /// - Parameters:
    ///   - offered: Total logical arrivals, including work refused before admission.
    ///   - admitted: Work admitted to the owner; no greater than offered.
    ///   - completed: Terminal work, including known rejection/failure classifications.
    ///   - outcomes: Exact terminal partition; all declared categories must be present, including zeroes.
    ///   - deadlineMisses: Observed missed deadlines, bounded by offered.
    public init(offered: UInt64, admitted: UInt64, completed: UInt64,
        outcomes: [BenchmarkOutcome: UInt64], deadlineMisses: UInt64) {
        self.offered = offered; self.admitted = admitted; self.completed = completed
        self.outcomes = outcomes; self.deadlineMisses = deadlineMisses
    }

    /// Checks ordering, complete outcomes and overflow without mutating evidence.
    /// - Throws: `BenchmarkReportError.invalidCounts` for inconsistent or overflowing totals.
    public func validate() throws {
        guard admitted <= offered, completed <= offered, deadlineMisses <= offered,
              Set(outcomes.keys) == Set(BenchmarkOutcome.allCases) else { throw BenchmarkReportError.invalidCounts }
        var total: UInt64 = 0
        for value in outcomes.values {
            let (sum, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { throw BenchmarkReportError.invalidCounts }
            total = sum
        }
        guard total == completed else { throw BenchmarkReportError.invalidCounts }
    }

    private enum CodingKeys: String, CodingKey { case offered, admitted, completed, outcomes, deadlineMisses }

    /// Decodes readable named outcomes and rejects unknown categories or incomplete totals.
    /// - Parameter decoder: One common-schema count object; all six outcomes are mandatory.
    /// - Throws: Decoding or invalidCounts errors, including unknown outcome names and arithmetic overflow.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let named = try container.decode([String: UInt64].self, forKey: .outcomes)
        var outcomes: [BenchmarkOutcome: UInt64] = [:]
        for (name, count) in named {
            guard let outcome = BenchmarkOutcome(rawValue: name) else { throw BenchmarkReportError.invalidCounts }
            outcomes[outcome] = count
        }
        self.init(offered: try container.decode(UInt64.self, forKey: .offered),
            admitted: try container.decode(UInt64.self, forKey: .admitted),
            completed: try container.decode(UInt64.self, forKey: .completed), outcomes: outcomes,
            deadlineMisses: try container.decode(UInt64.self, forKey: .deadlineMisses))
        try validate()
    }

    /// Encodes named outcome keys so sorted JSON remains deterministic and directly reviewable.
    /// - Parameter encoder: Caller-owned encoder, configured with sortedKeys by the envelope writer.
    /// - Throws: Encoding errors; no observations, tasks or external writes are created.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(offered, forKey: .offered); try container.encode(admitted, forKey: .admitted)
        try container.encode(completed, forKey: .completed); try container.encode(deadlineMisses, forKey: .deadlineMisses)
        try container.encode(Dictionary(uniqueKeysWithValues: outcomes.map { ($0.key.rawValue, $0.value) }), forKey: .outcomes)
    }
}

/// One finite metric/outcome histogram in a single explicit run-local monotonic domain.
public struct BenchmarkMetric: Codable, Equatable, Sendable {
    public var id: String
    public var version: UInt32
    public var outcome: BenchmarkOutcome
    public var clockDomain: String
    public var distribution: HistogramSnapshot

    /// Median estimate with explicit precision/censoring; never a fabricated exact value.
    public var p50: QuantileEstimate {
        /// Derives the median from the whole-population histogram without retaining samples.
        get { distribution.quantile(50) }
    }
    /// 95th-percentile estimate, unavailable whenever aggregate loss could bias the population.
    public var p95: QuantileEstimate {
        /// Derives the percentile from bounded cells and explicit censored mass.
        get { distribution.quantile(95) }
    }
    /// 99th-percentile estimate; sparse tails remain insufficient-tail-data.
    public var p99: QuantileEstimate {
        /// Applies the histogram's minimum-population and loss qualification rules.
        get { distribution.quantile(99) }
    }
    /// Exact observed in-range maximum or explicit out-of-range/unavailable evidence.
    public var maximum: QuantileEstimate {
        /// Derives maximum evidence without clamping out-of-range observations.
        get { distribution.maximum() }
    }

    /// Associates a bounded complete-population histogram with its frozen semantic identity.
    /// - Parameters:
    ///   - id: Registered finite catalog/workload identity; unknown labels are rejected on validation.
    ///   - version: Positive metric semantic version, initially one.
    ///   - outcome: Terminal population represented by this histogram.
    ///   - clockDomain: Run-local monotonic identifier, shared by every metric in the report.
    ///   - distribution: Validated bounded histogram, including censored/lost mass.
    public init(id: String, version: UInt32 = 1, outcome: BenchmarkOutcome = .success,
        clockDomain: String, distribution: HistogramSnapshot) {
        self.id = id; self.version = version; self.outcome = outcome
        self.clockDomain = clockDomain; self.distribution = distribution
    }

    private enum CodingKeys: String, CodingKey {
        case id, version, outcome, clockDomain, distribution, p50, p95, p99, maximum
    }

    /// Decodes histogram evidence and rejects stale or fabricated serialized percentile summaries.
    /// - Parameter decoder: One bounded metric object in the common schema.
    /// - Throws: Decoding errors or invalidCounts when summary evidence disagrees with cells/loss.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(String.self, forKey: .id),
            version: try container.decode(UInt32.self, forKey: .version),
            outcome: try container.decode(BenchmarkOutcome.self, forKey: .outcome),
            clockDomain: try container.decode(String.self, forKey: .clockDomain),
            distribution: try container.decode(HistogramSnapshot.self, forKey: .distribution))
        guard try container.decode(QuantileEstimate.self, forKey: .p50) == p50,
            try container.decode(QuantileEstimate.self, forKey: .p95) == p95,
            try container.decode(QuantileEstimate.self, forKey: .p99) == p99,
            try container.decode(QuantileEstimate.self, forKey: .maximum) == maximum else { throw BenchmarkReportError.invalidCounts }
    }

    /// Encodes percentile evidence derived at serialization time from the current histogram.
    /// - Parameter encoder: Caller-owned JSON encoder; performs no file writes or measurements.
    /// - Throws: Encoding errors propagated without altering collected observations.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id); try container.encode(version, forKey: .version)
        try container.encode(outcome, forKey: .outcome); try container.encode(clockDomain, forKey: .clockDomain)
        try container.encode(distribution, forKey: .distribution)
        try container.encode(p50, forKey: .p50); try container.encode(p95, forKey: .p95)
        try container.encode(p99, forKey: .p99); try container.encode(maximum, forKey: .maximum)
    }
}

/// A measured resource value, or an explicit unavailable result with its scope and reason.
public struct BenchmarkGauge: Codable, Equatable, Sendable {
    public var value: UInt64?
    public var unit: String
    public var method: String
    public var scope: String
    public var unavailableReason: String?

    /// Creates one nonnegative integer resource gauge; nil requires a nonempty reason.
    /// - Parameters:
    ///   - value: Observed quantity, or nil for an unsupported/unobserved gauge.
    ///   - unit: Explicit unit, such as bytes or nanoseconds.
    ///   - method: Native sampling API or explicit unavailable method.
    ///   - scope: Process lifetime, measured interval, or other honest resource scope.
    ///   - unavailableReason: Why no value exists; never replace absence with zero.
    public init(value: UInt64?, unit: String, method: String, scope: String, unavailableReason: String? = nil) {
        self.value = value; self.unit = unit; self.method = method; self.scope = scope
        self.unavailableReason = unavailableReason
    }

    /// Validates that a value and absence reason cannot contradict each other.
    /// - Throws: `BenchmarkReportError.invalidGauge` for missing unit/scope/method or ambiguous absence.
    public func validate() throws {
        guard !unit.isEmpty, !method.isEmpty, !scope.isEmpty,
            (value == nil ? unavailableReason?.isEmpty == false : unavailableReason == nil) else {
            throw BenchmarkReportError.invalidGauge
        }
    }
}

/// Ownership teardown evidence is separate from process memory retained by an allocator.
public struct BenchmarkCleanup: Codable, Equatable, Sendable {
    public var completed: Bool?
    public var remainingOwners: UInt64?
    public var reason: String?

    /// Records awaited teardown, or explains why a legacy adapter cannot establish it.
    /// - Parameters:
    ///   - completed: True only after owned work is joined; nil means unavailable.
    ///   - remainingOwners: Exact retained owner count when measured, otherwise nil.
    ///   - reason: Failure or unavailability reason, with no arbitrary product payload.
    public init(completed: Bool? = nil, remainingOwners: UInt64? = nil, reason: String? = nil) {
        self.completed = completed; self.remainingOwners = remainingOwners; self.reason = reason
    }
}

/// Byte-preserving original artifact with a distinct explicit source format.
public struct LegacyBenchmarkArtifact: Codable, Equatable, Sendable {
    public let format: LegacyReportFormat
    public let jsonUTF8: String
}

/// Type-directed schema probing rejects booleans and overflowing version numbers.
private struct LegacyVersionProbe: Decodable { let schemaVersion: UInt32 }

/// Only authentic typed voice fields establish a recognized native shape.
private struct LegacyVoiceProbe: Decodable { let schemaVersion: UInt32; let scope: String; let successful: Bool }

/// Typed HTTP discriminator counters reject strings, booleans and negative native counts.
private struct LegacyHTTPProbe: Decodable { let offeredRequests: UInt64; let successfulRequests: UInt64 }

/// Typed cache discriminator preserves explicit scenario/profile strings and nonnegative rounds.
private struct LegacyCacheProbe: Decodable { let scenario: String; let profile: String; let completedRounds: UInt64 }

/// Typed Gateway discriminator identifies the native owner-cleanup report shape.
private struct LegacyGatewayProbe: Decodable { let profile: String; let deliveredDispatches: UInt64; let ownedConnectionsAfterShutdown: UInt64 }

/// Comparison compatibility is informational and never itself a numerical performance gate.
public struct BenchmarkCompatibility: Equatable, Sendable {
    public let reasons: [String]
    /// Indicates complete matching semantics/provenance; no timing threshold is evaluated.
    public var isCompatible: Bool {
        /// Returns true only when every compatibility requirement was established.
        get { reasons.isEmpty }
    }
}

/// Version-one common development envelope, deliberately distinct from every legacy schema.
public struct DiscordBenchmarkReport: Codable, Equatable, Sendable {
    public static let formatIdentifier = "DiscordBenchmarkReport"
    public static let maximumSerializedBytes = 32 * 1_024 * 1_024
    public var format = Self.formatIdentifier
    public var schemaVersion: UInt32 = 1
    public var identity: ReportIdentity
    public var provenance: BenchmarkProvenance
    public var adapter: String
    public var clockDomain: String?
    public var status: BenchmarkRunStatus
    public var counts: BenchmarkCounts?
    public var metrics: [BenchmarkMetric]
    public var gauges: [String: BenchmarkGauge]
    public var cleanup: BenchmarkCleanup
    public var throughputPerSecond: Double?
    public var qualificationLimitations: [String]
    public var legacy: LegacyBenchmarkArtifact?

    /// Constructs reviewable evidence; call validatedData before publishing serialized output.
    /// - Parameters:
    ///   - identity: Explicit semantic workload policy and versions.
    ///   - provenance: Actual build/host receipts; missing data blocks comparisons.
    ///   - adapter: Finite execution/source adapter identity.
    ///   - clockDomain: Single nonempty monotonic domain, or nil when unavailable.
    ///   - status: Terminal completed/interrupted/failed/unqualified state.
    ///   - counts: Full offered/admitted/outcome accounting, or nil when unavailable.
    ///   - metrics: Bounded registered histograms from the measured population.
    ///   - gauges: Named resource observations with explicit unavailable values.
    ///   - cleanup: Awaited ownership teardown receipt.
    ///   - throughputPerSecond: Finite nonnegative measured throughput, or nil when unavailable.
    ///   - qualificationLimitations: Reasons evidence cannot establish numerical qualification.
    public init(identity: ReportIdentity, provenance: BenchmarkProvenance, adapter: String,
        clockDomain: String?, status: BenchmarkRunStatus, counts: BenchmarkCounts? = nil,
        metrics: [BenchmarkMetric] = [], gauges: [String: BenchmarkGauge] = [:],
        cleanup: BenchmarkCleanup = .init(reason: "Not captured."), throughputPerSecond: Double? = nil,
        qualificationLimitations: [String] = []) {
        self.identity = identity; self.provenance = provenance; self.adapter = adapter
        self.clockDomain = clockDomain; self.status = status; self.counts = counts; self.metrics = metrics
        self.gauges = gauges; self.cleanup = cleanup; self.throughputPerSecond = throughputPerSecond
        self.qualificationLimitations = qualificationLimitations
    }

    /// Imports only a specifically selected native schema and preserves its original UTF-8 bytes.
    /// Native millisecond summaries, old RSS rows and prefix samples are not promoted into
    /// invented clocks, complete populations or comparable provenance. Added histograms keep
    /// their own declared identities; the import remains explicitly unqualified.
    /// - Parameters:
    ///   - data: A bounded JSON object in the selected source format.
    ///   - format: Explicit load-unversioned, DSL-v1 or voice-v2 adapter.
    ///   - identity: Caller-known dimensions; unavailable fields remain nil/empty.
    ///   - provenance: Conservative local capture by default, or authoritative supplied receipts.
    ///   - metrics: Actual new histograms captured by the owning runner, never derived from percentiles.
    /// - Returns: A distinct version-one common envelope retaining the native artifact verbatim.
    /// - Throws: Malformed JSON, wrong source version, invalid metrics or report-size violations.
    public static func adaptingLegacy(_ data: Data, format: LegacyReportFormat, identity: ReportIdentity,
        provenance: BenchmarkProvenance = .capture(), metrics: [BenchmarkMetric] = []) throws -> Self {
        try validateLegacy(data, format: format)
        let json = String(decoding: data, as: UTF8.self)
        let unavailable = "Legacy source does not establish the common-envelope measurement scope."
        var result = Self(identity: identity, provenance: provenance, adapter: format.rawValue,
            clockDomain: metrics.first?.clockDomain, status: .unqualified, metrics: metrics,
            gauges: ["processCPU": .init(value: nil, unit: "nanoseconds", method: "unavailable",
                    scope: "process", unavailableReason: unavailable),
                "processResidentBytes": .init(value: nil, unit: "bytes", method: "unavailable",
                    scope: "process", unavailableReason: unavailable),
                "processPeakResidentBytes": .init(value: nil, unit: "bytes", method: "unavailable",
                    scope: "process-lifetime", unavailableReason: unavailable)],
            cleanup: .init(reason: unavailable), qualificationLimitations: [
                "Explicit legacy import; original timing and population semantics are retained.",
                "Common offered/admitted/completed outcomes, deadline misses and cleanup were not captured by this adapter.",
                "Legacy summaries cannot establish histogram loss, clock domains or complete process/build provenance."])
        result.legacy = LegacyBenchmarkArtifact(format: format, jsonUTF8: json)
        try result.validate()
        return result
    }

    /// Checks an explicitly selected legacy version and recognized native object shape.
    /// - Parameters:
    ///   - data: Original bounded UTF-8 JSON, retained exactly by the envelope.
    ///   - format: Independent source format; no automatic version coercion is performed.
    /// - Throws: Size, malformed-object and unsupported-version errors without promoting legacy values.
    private static func validateLegacy(_ data: Data, format: LegacyReportFormat) throws {
        guard data.count <= maximumSerializedBytes else { throw BenchmarkReportError.reportTooLarge }
        guard String(data: data, encoding: .utf8) != nil,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], !object.isEmpty else {
            throw BenchmarkReportError.malformedLegacy
        }
        switch format {
        case .loadUnversioned:
            guard object["schemaVersion"] == nil else { throw BenchmarkReportError.invalidVersion }
            let transport = object["measurement"] is [String: Any] && object["afterShutdown"] is [String: Any]
            let http = object["profile"] is [String: Any] && (try? JSONDecoder().decode(LegacyHTTPProbe.self, from: data)) != nil
            let cache = (try? JSONDecoder().decode(LegacyCacheProbe.self, from: data)) != nil
            let gateway = (try? JSONDecoder().decode(LegacyGatewayProbe.self, from: data)) != nil
            guard transport || http || cache || gateway else { throw BenchmarkReportError.malformedLegacy }
        case .dslVersion1:
            guard let version = try? JSONDecoder().decode(LegacyVersionProbe.self, from: data), version.schemaVersion == 1 else { throw BenchmarkReportError.invalidVersion }
            guard object["configuration"] is [String: Any], object["environment"] is [String: Any], object["workloads"] is [[String: Any]] else {
                throw BenchmarkReportError.malformedLegacy
            }
        case .voiceVersion2:
            guard let version = try? JSONDecoder().decode(LegacyVersionProbe.self, from: data), version.schemaVersion == 2 else { throw BenchmarkReportError.invalidVersion }
            guard (try? JSONDecoder().decode(LegacyVoiceProbe.self, from: data)) != nil else { throw BenchmarkReportError.malformedLegacy }
        }
    }

    /// Validates bounded data, identities, integer clocks, gauge absence and histogram integrity.
    /// - Throws: Explicit report errors or histogram validation errors; no output is written.
    public func validate() throws {
        guard format == Self.formatIdentifier else { throw BenchmarkReportError.invalidFormat }
        guard schemaVersion == 1 else { throw BenchmarkReportError.invalidVersion }
        guard identity.catalog == "discordkit.timing", [2, 3, 4].contains(identity.catalogVersion),
            identity.profileVersion > 0, !identity.scenario.isEmpty, !identity.profile.isEmpty,
            !identity.instrumentation.isEmpty, !identity.scheduler.isEmpty, !adapter.isEmpty,
            identity.concurrency != 0, identity.repetitions != 0 else { throw BenchmarkReportError.invalidIdentity }
        if let throughputPerSecond, !throughputPerSecond.isFinite || throughputPerSecond < 0 {
            throw BenchmarkReportError.invalidCounts
        }
        if !identity.fixtureHashes.isEmpty && !provenance.fixtureHashes.isEmpty,
            identity.fixtureHashes != provenance.fixtureHashes { throw BenchmarkReportError.invalidIdentity }
        if let legacy {
            guard adapter == legacy.format.rawValue, status == .unqualified,
                !qualificationLimitations.isEmpty else { throw BenchmarkReportError.malformedLegacy }
            try Self.validateLegacy(Data(legacy.jsonUTF8.utf8), format: legacy.format)
        }
        try counts?.validate()
        for gauge in gauges.values { try gauge.validate() }
        guard metrics.count <= 256 else { throw BenchmarkReportError.unsupportedMetric }
        let supported = Set(BenchmarkWorkload.allCases.map(\.rawValue))
        var keys: Set<String> = []
        for metric in metrics {
            guard supported.contains(metric.id), metric.version == 1,
                metric.id != BenchmarkWorkload.instrumentation.rawValue || identity.catalogVersion >= 3,
                metric.id != BenchmarkWorkload.pureBatch.rawValue || identity.catalogVersion >= 4,
                keys.insert(metric.id + ":" + metric.outcome.rawValue).inserted else { throw BenchmarkReportError.unsupportedMetric }
            guard let clockDomain, !clockDomain.isEmpty, metric.clockDomain == clockDomain else {
                throw BenchmarkReportError.mixedClockDomains
            }
            try metric.distribution.validate()
        }
        try AggregateStatisticsBudget.validate(histograms: metrics.map(\.distribution.configuration), additionalBytes: metrics.count * 256)
        if let clockDomain, clockDomain.isEmpty { throw BenchmarkReportError.mixedClockDomains }
    }

    /// Encodes stable sorted JSON after validating the complete report and its 32-MiB ceiling.
    /// - Returns: UTF-8 JSON suitable for atomic application-owned writes.
    /// - Throws: Schema/encoding errors or reportTooLarge; no filesystem work occurs.
    public func validatedData() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumSerializedBytes else { throw BenchmarkReportError.reportTooLarge }
        return data
    }

    /// Decodes only the common format; independent legacy versions require explicit adapters.
    /// - Parameter data: Bounded UTF-8 common-envelope JSON.
    /// - Returns: Validated evidence with no inferred missing values.
    /// - Throws: Oversize, malformed, unsupported schema, mixed-domain or histogram errors.
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumSerializedBytes else { throw BenchmarkReportError.reportTooLarge }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }

    /// Compares semantics and complete actual allocation/build receipts, permitting code changes.
    /// Source revision, dirty-content fingerprint and executable hash must exist but intentionally
    /// need not equal. Run-local clock identifiers also need not equal across fresh processes.
    /// - Parameter other: Baseline or candidate evidence; direction does not change compatibility.
    /// - Returns: Every known incompatibility; an empty reason list never establishes numerical gates.
    public func comparison(with other: Self) -> BenchmarkCompatibility {
        var reasons: [String] = []
        do { try validate(); try other.validate() } catch { reasons.append("Invalid or unsupported report: \(error)") }
        if status != .completed || other.status != .completed { reasons.append("Both runs must have completed qualification scope.") }
        if !qualificationLimitations.isEmpty || !other.qualificationLimitations.isEmpty { reasons.append("Qualification limitations remain.") }
        let missing = Set(provenance.missingFields() + other.provenance.missingFields())
        for field in missing.sorted() { reasons.append("Unavailable provenance: \(field)") }
        let semanticIdentity = identity.catalog == other.identity.catalog && identity.catalogVersion == other.identity.catalogVersion
            && identity.scenario == other.identity.scenario && identity.profile == other.identity.profile
            && identity.profileVersion == other.identity.profileVersion && identity.seed == other.identity.seed
            && identity.fixtureHashes == other.identity.fixtureHashes && identity.inputSizes == other.identity.inputSizes
            && identity.instrumentation == other.identity.instrumentation && identity.scheduler == other.identity.scheduler
            && identity.concurrency == other.identity.concurrency && identity.requestedWarmupNanoseconds == other.identity.requestedWarmupNanoseconds
            && identity.repetitions == other.identity.repetitions
        if !semanticIdentity { reasons.append("Workload, catalog, profile, fixtures or instrumentation differ.") }
        for item in [identity, other.identity] {
            if item.seed == nil || !BenchmarkProvenance.validHashes(item.fixtureHashes) || item.inputSizes.isEmpty || item.concurrency == nil
                || item.warmupNanoseconds == nil || item.requestedWarmupNanoseconds == nil || item.measuredNanoseconds == nil || item.repetitions == nil {
                reasons.append("Unavailable workload policy or fixture identity.")
            }
        }
        let left = provenance, right = other.provenance
        if left.machineIdentity != right.machineIdentity || left.cpuModel != right.cpuModel
            || left.architecture != right.architecture || left.cpuAllocation != right.cpuAllocation
            || left.memoryBytes != right.memoryBytes { reasons.append("Host identity or allocation differs.") }
        if left.compiler != right.compiler || left.optimization != right.optimization || left.operatingSystem != right.operatingSystem
            || left.sdk != right.sdk || left.target != right.target || left.buildFlags != right.buildFlags
            || left.dependencyHashes != right.dependencyHashes || left.fixtureHashes != right.fixtureHashes {
            reasons.append("Compiler, optimization, platform, dependencies or fixtures differ.")
        }
        if adapter != other.adapter { reasons.append("Adapters differ.") }
        let metricKeys = Set(metrics.map { "\($0.id):\($0.version):\($0.outcome.rawValue)" })
        let otherKeys = Set(other.metrics.map { "\($0.id):\($0.version):\($0.outcome.rawValue)" })
        if metricKeys.isEmpty || metricKeys != otherKeys { reasons.append("Metric identities or outcome populations differ/unavailable.") }
        for metric in metrics {
            if let counterpart = other.metrics.first(where: { $0.id == metric.id && $0.outcome == metric.outcome }),
                counterpart.distribution.configuration != metric.distribution.configuration {
                reasons.append("Histogram precision/range differs for \(metric.id).")
            }
            if metric.distribution.droppedCount > 0 || metric.distribution.counterOverflow { reasons.append("Aggregate loss or counter overflow blocks qualification.") }
        }
        if other.metrics.contains(where: { $0.distribution.droppedCount > 0 || $0.distribution.counterOverflow }) {
            reasons.append("Aggregate loss or counter overflow blocks qualification.")
        }
        if counts == nil || other.counts == nil || throughputPerSecond == nil || other.throughputPerSecond == nil {
            reasons.append("Outcome accounting or throughput unavailable.")
        }
        if cleanup.completed != true || other.cleanup.completed != true || cleanup.remainingOwners != 0 || other.cleanup.remainingOwners != 0 {
            reasons.append("Awaited zero-owner cleanup unavailable or incomplete.")
        }
        for report in [self, other] {
            for key in ["processCPU", "processResidentBytes", "processPeakResidentBytes"] where report.gauges[key] == nil {
                reasons.append("Gauge availability not declared: \(key)")
            }
        }
        if Set(gauges.keys) != Set(other.gauges.keys) { reasons.append("Resource gauge identities differ.") }
        for (key, gauge) in gauges {
            guard let counterpart = other.gauges[key] else { continue }
            if gauge.unit != counterpart.unit || gauge.method != counterpart.method || gauge.scope != counterpart.scope {
                reasons.append("Resource gauge unit, method or scope differs: \(key)")
            }
            if (gauge.value == nil) != (counterpart.value == nil) {
                reasons.append("Resource gauge availability differs: \(key)")
            }
        }
        return BenchmarkCompatibility(reasons: Array(Set(reasons)).sorted())
    }
}
