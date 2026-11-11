// File: Tools/DiscordMediaBenchmarks/Sources/DiscordMediaBenchmarks/DiscordMediaBenchmarks.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordLogging
import Foundation

@main struct DiscordMediaBenchmarks {
    /// Shared supervision owns fresh processes and external termination; writes follow joined verification.
    static func main() async throws {
        if CommandLine.arguments.dropFirst() == ["--list-cases"] {
            print(MediaCatalog.ids.joined(separator: "\n")); return
        }
        let configuration = try MediaConfiguration.parse(Array(CommandLine.arguments.dropFirst()))
        let workload = try MediaCatalog.selected(configuration.workload)
        let result = try await DiscordLog.$loggerFactory.withValue({ label in
            Logger(label: label) { _ in SwiftLogNoOpLogHandler() }
        }) { try await MediaHarness.run(configuration, workload: workload) }
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
