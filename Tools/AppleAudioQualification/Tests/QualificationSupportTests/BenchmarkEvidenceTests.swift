// File: Tools/AppleAudioQualification/Tests/QualificationSupportTests/BenchmarkEvidenceTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation
import QualificationSupport
import Testing

/// Direct report mapping and consent policy only; these tests never instantiate a native device.
@Suite struct BenchmarkEvidenceTests {
    /// Actual codec attempts partition outcomes, retain overflow, and round-trip in catalog nine.
    @Test func directCodecPopulationAndResourceMapping() throws {
        let capture = try AppleAudioBenchmarkCapture()
        for _ in 0..<99 { capture.recordCodec(.microseconds(150), outcome: .success) }
        capture.recordCodec(.seconds(2), outcome: .failure)
        var evidence = DuplexEvidence()
        evidence.capturedFrames = 96_000; evidence.processedFrames = 95_040; evidence.playedFrames = 94_080
        evidence.residentMemory.record(bytes: 2_000)
        evidence.residentMemory.record(bytes: 1_500)
        let report = try capture.report(mode: .duplex, requestedSeconds: 600, elapsed: .seconds(600),
            evidence: evidence, nativeIOStarted: true, passed: false, failed: true,
            cleanup: .init(completed: true, remainingOwners: 0), provenance: .init())
        #expect(report.identity.catalogVersion == 9 && report.status == .failed)
        #expect(report.counts?.offered == 100 && report.counts?.completed == 100)
        #expect(report.counts?.outcomes[.success] == 99 && report.counts?.outcomes[.failure] == 1)
        #expect(report.counts?.deadlineMisses == 1)
        #expect(report.metrics.count == 2 && report.metrics.allSatisfy { $0.id == "appleAudio.codec" })
        #expect(report.metrics.first { $0.outcome == .failure }?.distribution.overflowCount == 1)
        #expect(report.metrics.first { $0.outcome == .success }?.distribution.maxInRangeNanoseconds == 150_000)
        #expect(report.gauges["capturedFrames"]?.value == 96_000)
        #expect(report.gauges["processedFrames"]?.value == 95_040)
        #expect(report.gauges["playedFrames"]?.value == 94_080)
        #expect(report.gauges["processResidentBytes"]?.value == 1_500)
        #expect(report.gauges["processPeakResidentBytes"]?.value == nil)
        #expect(report.gauges["processSampledMaximumResidentBytes"]?.value == 2_000)
        #expect(report.gauges["processCPU"]?.value == nil)
        #expect(report.identity.measuredNanoseconds == 600_000_000_000)
        #expect(try DiscordBenchmarkReport.decode(report.validatedData()) == report)
        #expect(!report.comparison(with: report).isCompatible)
    }

    /// Existing native summary values cannot manufacture a common histogram or caller count.
    @Test func probeAndFaultAbsenceAndNoSummaryPromotion() throws {
        for mode in [QualificationMode.probe, .route, .unplug, .interruption] {
            let capture = try AppleAudioBenchmarkCapture()
            let report = try capture.report(mode: mode, requestedSeconds: 120, elapsed: nil,
                evidence: nil, nativeIOStarted: mode != .probe, passed: true, failed: false,
                cleanup: .init(completed: true, remainingOwners: 0), provenance: .init())
            #expect(report.status == .unqualified)
            #expect(report.metrics.isEmpty && report.counts == nil && report.clockDomain == nil)
            #expect(report.throughputPerSecond == nil && report.identity.measuredNanoseconds == nil)
            #expect(report.gauges["processResidentBytes"]?.value == nil)
            try report.validate()
        }
        var native = DuplexEvidence()
        for _ in 0..<100 { native.processing.record(milliseconds: 1) }
        let report = try AppleAudioBenchmarkCapture().report(mode: .duplex, requestedSeconds: 600,
            elapsed: .seconds(600), evidence: native, nativeIOStarted: true, passed: true, failed: false,
            cleanup: .init(completed: true, remainingOwners: 0), provenance: .init())
        #expect(report.metrics.isEmpty && report.counts?.completed == 0 && report.status == .unqualified)
    }

    /// Companion output is explicit, distinct, duplicate-checked, and grants no native consent.
    @Test func companionOutputAndExistingConsent() throws {
        let options = try QualificationOptions(arguments: ["--output", "native.json", "--common-output", "common.json"])
        #expect(options.mode == .probe && options.commonReportPath == "common.json")
        #expect(try QualificationOptions(arguments: ["--output", "native.json"]).commonReportPath == nil)
        for arguments in [
            ["--output", "native.json", "--common-output", "native.json"],
            ["--output", "native.json", "--common-output", "./native.json"],
            ["--output", "native.json", "--common-output", ""],
            ["--output", "native.json", "--common-output"],
            ["--output", "native.json", "--common-output", "x", "--common-output", "y"],
        ] {
            #expect(throws: QualificationError.invalidArguments) { try QualificationOptions(arguments: arguments) }
        }
        #expect(throws: QualificationError.missingConsent) {
            try QualificationOptions(arguments: ["--mode", "duplex", "--output", "native.json", "--common-output", "common.json"])
        }
    }

    /// A symbolic alias cannot overwrite the native artifact with its common companion.
    @Test func companionSymbolicAliasFailsBeforeDeviceAccess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let native = directory.appendingPathComponent("native.json")
        let alias = directory.appendingPathComponent("common.json")
        try Data().write(to: native)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: native)
        #expect(throws: QualificationError.invalidArguments) {
            try QualificationOptions(arguments: ["--output", native.path, "--common-output", alias.path])
        }
    }

    /// A codec population cannot be relabeled as a probe/fault observation or given backwards time.
    @Test func invalidPopulationAndClockFailClosed() throws {
        let capture = try AppleAudioBenchmarkCapture()
        capture.recordCodec(.microseconds(100), outcome: .success)
        #expect(throws: QualificationError.invalidArguments) {
            try capture.report(mode: .probe, requestedSeconds: 1, elapsed: nil, evidence: nil,
                nativeIOStarted: false, passed: false, failed: false, cleanup: .init(), provenance: .init())
        }
        #expect(throws: BenchmarkReportError.invalidTime) {
            try capture.report(mode: .duplex, requestedSeconds: 600, elapsed: .seconds(-1), evidence: nil,
                nativeIOStarted: true, passed: false, failed: true, cleanup: .init(), provenance: .init())
        }
    }
}
