// File: Tools/DiscordFoundationBenchmarks/Sources/DiscordFoundationBenchmarks/DiscordFoundationBenchmarks.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation

@main struct DiscordFoundationBenchmarks {
    /// Runs a single CPU case; shared supervision owns fresh processes and external termination.
    /// Lists the finite catalog for --list-cases, otherwise validates settings before preparing the selected family.
    /// Native/common JSON writes occur only after warmup, measurement, full verification and report validation.
    /// - Throws: Configuration, fixture, cancellation, integrity, report-size/encoding or explicit destination errors.
    /// There is no implicit global service; direct execution needs external process supervision for bounded signal teardown.
    static func main() async throws {
        if CommandLine.arguments.dropFirst() == ["--list-cases"] {
            let workloads = try FoundationWorkloads.make()
            print(workloads.map(\.id).joined(separator: "\n")); return
        }
        let configuration = try FoundationConfiguration.parse(Array(CommandLine.arguments.dropFirst()))
        let workload = try FoundationWorkloads.selected(configuration.workload)
        let result = try FoundationHarness.run(configuration, workload: workload)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(result)
        guard data.count <= DiscordBenchmarkReport.maximumSerializedBytes else { throw BenchmarkReportError.reportTooLarge }
        if let destination = configuration.output {
            try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
        } else { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10])) }
        if let destination = configuration.commonReport {
            try result.common.validatedData().write(to: URL(fileURLWithPath: destination), options: .atomic)
        }
    }
}
