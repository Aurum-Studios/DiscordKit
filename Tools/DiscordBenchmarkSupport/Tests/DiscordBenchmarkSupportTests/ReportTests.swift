// File: Tools/DiscordBenchmarkSupport/Tests/DiscordBenchmarkSupportTests/ReportTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Foundation
import Testing
@testable import DiscordBenchmarkSupport

@Suite struct ReportTests {
    /// Builds one complete comparable receipt using deterministic inert hashes and exact counters.
    /// - Returns: A one-observation complete report; no real process or benchmark is invoked.
    /// - Throws: Histogram configuration errors, which indicate a fixture programming error.
    private func completeReport() throws -> DiscordBenchmarkReport {
        let hash = String(repeating: "a", count: 64)
        let provenance = BenchmarkProvenance(machineIdentity: "runner-1", cpuModel: "cpu-1", architecture: "arm64",
            cpuAllocation: "cores=4;affinity=0-3;quota=4", memoryBytes: 8_589_934_592,
            compiler: "Swift 6.4.1", optimization: "release -O", operatingSystem: "OS-1", sdk: "SDK-1",
            target: "arm64-example", sourceRevision: "revision-A", dirtyFingerprint: hash,
            dependencyHashes: ["root": hash], fixtureHashes: ["input": hash], executableHash: hash, buildFlags: ["-O"])
        let identity = ReportIdentity(scenario: "transport", profile: "standard", seed: 42,
            fixtureHashes: ["input": hash], inputSizes: ["bytes": 64], instrumentation: "aggregate",
            scheduler: "fixed-cohort", concurrency: 4, warmupNanoseconds: 0, requestedWarmupNanoseconds: 0,
            measuredNanoseconds: 1_000, repetitions: 5)
        var histogram = BoundedHistogram(configuration: try .init(lowerBoundNanoseconds: 0,
            upperBoundNanoseconds: 100, bucketWidthNanoseconds: 10))
        histogram.record(42)
        var outcomes = Dictionary(uniqueKeysWithValues: BenchmarkOutcome.allCases.map { ($0, UInt64(0)) })
        outcomes[.success] = 1
        let unavailable = BenchmarkGauge(value: nil, unit: "bytes", method: "unavailable", scope: "process",
            unavailableReason: "Unsupported in this deterministic fixture.")
        return DiscordBenchmarkReport(identity: identity, provenance: provenance, adapter: "local.fixture",
            clockDomain: "run-A", status: .completed,
            counts: .init(offered: 1, admitted: 1, completed: 1, outcomes: outcomes, deadlineMisses: 0),
            metrics: [.init(id: BenchmarkWorkload.transport.rawValue, clockDomain: "run-A", distribution: histogram.snapshot())],
            gauges: ["processCPU": unavailable, "processResidentBytes": unavailable, "processPeakResidentBytes": unavailable],
            cleanup: .init(completed: true, remainingOwners: 0), throughputPerSecond: 1_000_000)
    }

    /// Catalog three accepts the new gross operation metric while catalog-two legacy reports remain readable.
    /// - Throws: Unexpected fixture initialization or common-envelope validation/round-trip error.
    @Test func instrumentationCatalogIsExplicitAndLegacyCompatible() throws {
        var report = try completeReport()
        #expect(report.identity.catalogVersion == 2)
        try report.validate()
        report.metrics[0].id = BenchmarkWorkload.instrumentation.rawValue
        #expect(throws: BenchmarkReportError.unsupportedMetric) { try report.validate() }
        report.identity.catalogVersion = 3
        #expect(try DiscordBenchmarkReport.decode(report.validatedData()) == report)
        var oldCatalog = report
        oldCatalog.identity.catalogVersion = 2
        oldCatalog.metrics[0].id = BenchmarkWorkload.transport.rawValue
        #expect(!report.comparison(with: oldCatalog).isCompatible)
        report.identity.catalogVersion = 4
        #expect(throws: BenchmarkReportError.invalidIdentity) { try report.validate() }
    }

    /// Ensures stable common-envelope round trips preserve complete explicit evidence.
    @Test func roundTripAndCompare() throws {
        let original = try completeReport()
        let decoded = try DiscordBenchmarkReport.decode(original.validatedData())
        #expect(decoded == original)
        #expect(decoded.comparison(with: original).isCompatible)
        #expect(try decoded.validatedData() == original.validatedData())
    }

    /// Confirms code/executable identity changes are permitted while actual receipts remain required.
    @Test func codeChangesAndElapsedJitterAreAllowed() throws {
        let baseline = try completeReport()
        var candidate = baseline
        candidate.provenance.sourceRevision = "revision-B"
        candidate.provenance.dirtyFingerprint = String(repeating: "b", count: 64)
        candidate.provenance.executableHash = String(repeating: "c", count: 64)
        candidate.identity.warmupNanoseconds = 10
        candidate.identity.measuredNanoseconds = 2_000
        candidate.clockDomain = "run-B"
        candidate.metrics[0].clockDomain = "run-B"
        #expect(candidate.comparison(with: baseline).isCompatible)
    }

    /// Exercises every compatibility axis without conflating provenance with code equality.
    @Test func incompatibleHostCompilerFixturesAndPolicy() throws {
        let baseline = try completeReport()
        var changed = baseline; changed.provenance.cpuAllocation = "cores=2"
        #expect(!changed.comparison(with: baseline).isCompatible)
        changed = baseline; changed.provenance.compiler = "Swift other"
        #expect(!changed.comparison(with: baseline).isCompatible)
        changed = baseline; changed.provenance.optimization = "debug"
        #expect(!changed.comparison(with: baseline).isCompatible)
        changed = baseline; changed.identity.instrumentation = "diagnostics"
        #expect(!changed.comparison(with: baseline).isCompatible)
        changed = baseline; changed.adapter = "other"
        #expect(!changed.comparison(with: baseline).isCompatible)
        changed = baseline; changed.identity.fixtureHashes = ["input": String(repeating: "b", count: 64)]
        #expect(!changed.comparison(with: baseline).isCompatible)
        changed = baseline; changed.identity.profileVersion = 2
        #expect(!changed.comparison(with: baseline).isCompatible)
        changed = baseline; changed.identity.requestedWarmupNanoseconds = 1
        #expect(!changed.comparison(with: baseline).isCompatible)
    }

    /// Unknown host identity or empty/hash placeholders must fail even if both reports agree.
    @Test func missingProvenanceNeverQualifies() throws {
        var missing = try completeReport()
        missing.provenance.machineIdentity = nil
        #expect(!missing.comparison(with: missing).isCompatible)
        missing = try completeReport(); missing.provenance.fixtureHashes = ["input": ""]
        #expect(!missing.comparison(with: missing).isCompatible)
        missing = try completeReport(); missing.identity.fixtureHashes = ["input": "unavailable"]
        #expect(!missing.comparison(with: missing).isCompatible)
        missing = try completeReport(); missing.provenance.executableHash = "unavailable"
        #expect(!missing.comparison(with: missing).isCompatible)
    }

    /// Load, DSL and voice remain distinct explicit adapters preserving exact native bytes.
    @Test func explicitLegacyAdaptersPreserveOriginal() throws {
        let identity = ReportIdentity(scenario: "fixture", profile: "smoke")
        let cases: [(LegacyReportFormat, String)] = [
            (.loadUnversioned, "{ \"measurement\":{}, \"afterShutdown\":{} }\n"),
            (.dslVersion1, "{\"schemaVersion\":1,\"configuration\":{},\"environment\":{},\"workloads\":[]}"),
            (.voiceVersion2, "{\"schemaVersion\":2,\"scope\":\"local\",\"successful\":true}")]
        for (format, json) in cases {
            let report = try DiscordBenchmarkReport.adaptingLegacy(Data(json.utf8), format: format, identity: identity)
            #expect(report.format == "DiscordBenchmarkReport")
            #expect(report.schemaVersion == 1)
            #expect(report.status == .unqualified)
            #expect(report.legacy?.format == format)
            #expect(report.legacy?.jsonUTF8 == json)
            #expect(report.counts == nil)
            #expect(report.clockDomain == nil)
            #expect(report.gauges["processCPU"]?.value == nil)
            #expect(report.gauges["processCPU"]?.unavailableReason != nil)
            #expect(!report.comparison(with: report).isCompatible)
            #expect(try DiscordBenchmarkReport.decode(report.validatedData()) == report)
        }
    }

    /// Wrong independent versions, bool versions, unknown objects and numeric booleans are rejected.
    @Test func malformedLegacyNeverSilentlyImports() throws {
        let identity = ReportIdentity(scenario: "fixture", profile: "smoke")
        for json in ["{}", "[]", "{\"anything\":1}", "{\"schemaVersion\":1}",
            "{\"profile\":{},\"offeredRequests\":true,\"successfulRequests\":0}",
            "{\"scenario\":\"cache\",\"profile\":\"smoke\",\"completedRounds\":\"bad\"}"] {
            #expect(throws: (any Error).self) {
                try DiscordBenchmarkReport.adaptingLegacy(Data(json.utf8), format: .loadUnversioned, identity: identity)
            }
        }
        for json in ["{\"schemaVersion\":2}", "{\"schemaVersion\":true,\"configuration\":{},\"environment\":{},\"workloads\":[]}",
            "{\"schemaVersion\":1,\"configuration\":{}}",
            "{\"schemaVersion\":1,\"configuration\":false,\"environment\":0,\"workloads\":[]}"] {
            #expect(throws: (any Error).self) {
                try DiscordBenchmarkReport.adaptingLegacy(Data(json.utf8), format: .dslVersion1, identity: identity)
            }
        }
        for json in ["{\"schemaVersion\":1,\"scope\":\"local\",\"successful\":true}",
            "{\"schemaVersion\":2,\"scope\":\"local\",\"successful\":1}"] {
            #expect(throws: (any Error).self) {
                try DiscordBenchmarkReport.adaptingLegacy(Data(json.utf8), format: .voiceVersion2, identity: identity)
            }
        }
    }

    /// Schema versions, required fields and UInt64 offset overflow are rejected after parsing.
    @Test func malformedCommonSchemaRejected() throws {
        let report = try completeReport()
        var object = try #require(JSONSerialization.jsonObject(with: report.validatedData()) as? [String: Any])
        object["schemaVersion"] = 99
        #expect(throws: BenchmarkReportError.invalidVersion) {
            try DiscordBenchmarkReport.decode(JSONSerialization.data(withJSONObject: object))
        }
        object["schemaVersion"] = 1; object.removeValue(forKey: "identity")
        #expect(throws: (any Error).self) { try DiscordBenchmarkReport.decode(JSONSerialization.data(withJSONObject: object)) }
        let json = String(decoding: try report.validatedData(), as: UTF8.self)
            .replacingOccurrences(of: "\"measuredNanoseconds\":1000", with: "\"measuredNanoseconds\":18446744073709551616")
        #expect(throws: (any Error).self) { try DiscordBenchmarkReport.decode(Data(json.utf8)) }
    }

    /// Revalidates embedded legacy schema/adapter pairs rather than trusting their outer envelope.
    @Test func tamperedEmbeddedLegacyRejected() throws {
        let original = try DiscordBenchmarkReport.adaptingLegacy(
            Data("{\"schemaVersion\":2,\"scope\":\"local\",\"successful\":true}".utf8),
            format: .voiceVersion2, identity: .init(scenario: "fixture", profile: "smoke"))
        var object = try #require(JSONSerialization.jsonObject(with: original.validatedData()) as? [String: Any])
        var legacy = try #require(object["legacy"] as? [String: Any])
        legacy["jsonUTF8"] = "{\"schemaVersion\":1,\"scope\":\"local\",\"successful\":true}"
        object["legacy"] = legacy
        #expect(throws: BenchmarkReportError.invalidVersion) {
            try DiscordBenchmarkReport.decode(JSONSerialization.data(withJSONObject: object))
        }
        var altered = original; altered.adapter = "unrelated"
        #expect(throws: BenchmarkReportError.malformedLegacy) { try altered.validatedData() }
        altered = original; altered.status = .completed
        #expect(throws: BenchmarkReportError.malformedLegacy) { try altered.validatedData() }
    }

    /// A single report cannot assert contradictory actual fixture identities in separate receipts.
    @Test func contradictoryFixturesRejected() throws {
        var report = try completeReport()
        report.provenance.fixtureHashes = ["input": String(repeating: "b", count: 64)]
        #expect(throws: BenchmarkReportError.invalidIdentity) { try report.validatedData() }
    }

    /// A finite percentile cannot replace insufficient/lost/censored evidence during import.
    @Test func fabricatedPercentilesRejected() throws {
        let baseline = try completeReport()
        var object = try #require(JSONSerialization.jsonObject(with: baseline.validatedData()) as? [String: Any])
        var metrics = try #require(object["metrics"] as? [[String: Any]])
        metrics[0]["p99"] = metrics[0]["p50"]
        object["metrics"] = metrics
        #expect(throws: BenchmarkReportError.invalidCounts) {
            try DiscordBenchmarkReport.decode(JSONSerialization.data(withJSONObject: object))
        }
        var counts = try #require(object["counts"] as? [String: Any])
        var outcomes = try #require(counts["outcomes"] as? [String: Any])
        outcomes["unknown"] = 0
        counts["outcomes"] = outcomes; object["counts"] = counts
        #expect(throws: BenchmarkReportError.invalidCounts) {
            try DiscordBenchmarkReport.decode(JSONSerialization.data(withJSONObject: object))
        }
    }

    /// Mixed run domains and duplicate/unknown metric keys cannot become common report rows.
    @Test func mixedDomainsUnknownKeysAndDuplicatesRejected() throws {
        var report = try completeReport()
        report.metrics[0].clockDomain = "different"
        #expect(throws: BenchmarkReportError.mixedClockDomains) { try report.validatedData() }
        report = try completeReport(); report.metrics[0].id = "arbitrary.user.label"
        #expect(throws: BenchmarkReportError.unsupportedMetric) { try report.validatedData() }
        report = try completeReport(); report.metrics.append(report.metrics[0])
        #expect(throws: BenchmarkReportError.unsupportedMetric) { try report.validatedData() }
    }

    /// Overflowing outcome totals and contradictory unavailable gauges fail validation.
    @Test func invalidCountsAndGaugesRejected() throws {
        var report = try completeReport()
        report.counts?.outcomes[.success] = UInt64.max
        report.counts?.outcomes[.failure] = 1
        #expect(throws: BenchmarkReportError.invalidCounts) { try report.validatedData() }
        report = try completeReport(); report.gauges["processCPU"]?.unavailableReason = nil
        #expect(throws: BenchmarkReportError.invalidGauge) { try report.validatedData() }
        report = try completeReport(); report.throughputPerSecond = -.infinity
        #expect(throws: BenchmarkReportError.invalidCounts) { try report.validatedData() }
    }

    /// Aggregate loss and incomplete ownership teardown cannot appear as compatible evidence.
    @Test func aggregateLossAndFailedCleanupBlockComparison() throws {
        let baseline = try completeReport()
        var histogram = BoundedHistogram(configuration: baseline.metrics[0].distribution.configuration)
        histogram.record(42); histogram.recordLoss()
        var candidate = baseline; candidate.metrics[0].distribution = histogram.snapshot()
        #expect(!candidate.comparison(with: baseline).isCompatible)
        candidate = baseline; candidate.cleanup.remainingOwners = 1
        #expect(!candidate.comparison(with: baseline).isCompatible)
        candidate = baseline; candidate.status = .interrupted
        #expect(!candidate.comparison(with: baseline).isCompatible)
    }

    /// Resource comparison requires identical gauge semantics and availability while allowing measured values to change.
    /// Process-lifetime peaks cannot silently become measured-interval observations; unavailable data cannot
    /// disappear or become a comparable zero. Probe methods and units also define the population being compared.
    @Test func resourceGaugeSemanticsAndAvailabilityMustMatch() throws {
        var baseline = try completeReport()
        baseline.gauges["processPeakResidentBytes"] = .init(value: 1_024, unit: "bytes",
            method: "native-process-high-water", scope: "process-lifetime")
        var candidate = baseline
        candidate.gauges["processPeakResidentBytes"]?.value = 2_048
        #expect(candidate.comparison(with: baseline).isCompatible)
        candidate = baseline; candidate.gauges["processPeakResidentBytes"]?.scope = "measured-interval"
        #expect(!candidate.comparison(with: baseline).isCompatible)
        candidate = baseline; candidate.gauges["processPeakResidentBytes"]?.unit = "kilobytes"
        #expect(!candidate.comparison(with: baseline).isCompatible)
        candidate = baseline; candidate.gauges["processPeakResidentBytes"]?.method = "sampled-current-rss"
        #expect(!candidate.comparison(with: baseline).isCompatible)
        candidate = baseline
        candidate.gauges["processPeakResidentBytes"]?.value = nil
        candidate.gauges["processPeakResidentBytes"]?.unavailableReason = "Probe unavailable."
        #expect(!candidate.comparison(with: baseline).isCompatible)
        candidate = baseline; candidate.gauges.removeValue(forKey: "processPeakResidentBytes")
        #expect(!candidate.comparison(with: baseline).isCompatible)
        candidate = baseline
        candidate.gauges["optionalObservation"] = .init(value: nil, unit: "bytes", method: "unavailable",
            scope: "process", unavailableReason: "Unsupported optional gauge.")
        #expect(!candidate.comparison(with: baseline).isCompatible)
    }

    /// Input and output ceilings are checked before accepting oversized serialized artifacts.
    @Test func serializedCeilingIsEnforced() throws {
        let excessive = Data(repeating: 32, count: DiscordBenchmarkReport.maximumSerializedBytes + 1)
        #expect(throws: BenchmarkReportError.reportTooLarge) { try DiscordBenchmarkReport.decode(excessive) }
        #expect(throws: BenchmarkReportError.reportTooLarge) {
            try DiscordBenchmarkReport.adaptingLegacy(excessive, format: .loadUnversioned,
                identity: .init(scenario: "fixture", profile: "smoke"))
        }
        var oversized = try completeReport()
        oversized.qualificationLimitations = [String(repeating: "x", count: DiscordBenchmarkReport.maximumSerializedBytes)]
        #expect(throws: BenchmarkReportError.reportTooLarge) { try oversized.validatedData() }
    }
}

@Suite struct ProvenanceAndTimeTests {
    /// Actual lightweight native capture never guesses compiler/build or stable allocation receipts.
    @Test func nativeCaptureExplicitlyDeclaresUnavailableFacts() {
        let captured = BenchmarkProvenance.capture()
        #expect(captured.architecture?.isEmpty == false)
        #expect(captured.operatingSystem?.isEmpty == false)
        #expect(captured.compiler == nil)
        #expect(captured.machineIdentity == nil)
        #expect(captured.memoryBytes == nil)
        #expect(captured.missingFields().contains("cpuAllocation"))
        #expect(captured.unavailabilityReasons["cpuAllocation"]?.isEmpty == false)
        #expect(captured.unavailabilityReasons["compiler"]?.isEmpty == false)
    }

    /// Checked conversion rejects negative, nonfinite, overflowing and regressing observations.
    @Test func checkedNanosecondConversionsAndDomains() throws {
        #expect(try BenchmarkTime.nanoseconds(seconds: 0) == 0)
        #expect(try BenchmarkTime.nanoseconds(seconds: 0.000000001) == 1)
        #expect(try BenchmarkTime.nanoseconds(duration: .nanoseconds(42)) == 42)
        #expect(try BenchmarkTime.nanoseconds(duration: .seconds(2)) == 2_000_000_000)
        for seconds in [-1.0, .infinity, .nan, Double(UInt64.max)] {
            #expect(throws: BenchmarkReportError.invalidTime) { try BenchmarkTime.nanoseconds(seconds: seconds) }
        }
        #expect(throws: BenchmarkReportError.invalidTime) { try BenchmarkTime.nanoseconds(duration: .seconds(-1)) }
        #expect(throws: BenchmarkReportError.invalidTime) { try BenchmarkTime.nanoseconds(duration: .seconds(Int64.max)) }
        #expect(try BenchmarkTime.interval(start: 1, end: 2, startDomain: "run", endDomain: "run") == 1)
        #expect(throws: BenchmarkReportError.invalidTime) {
            try BenchmarkTime.interval(start: 2, end: 1, startDomain: "run", endDomain: "run")
        }
        #expect(throws: BenchmarkReportError.invalidTime) {
            try BenchmarkTime.interval(start: 1, end: 2, startDomain: "run", endDomain: "other")
        }
    }
}
