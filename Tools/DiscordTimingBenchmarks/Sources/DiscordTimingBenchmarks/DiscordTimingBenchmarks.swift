// File: Tools/DiscordTimingBenchmarks/Sources/DiscordTimingBenchmarks/DiscordTimingBenchmarks.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation

/// Development-only entry point; no Discord request, global logging bootstrap or background service is started.
@main struct DiscordTimingBenchmarks {
    /// Runs one selected mode in this process and emits native plus optional common evidence after flush.
    /// Shared process supervision supplies fresh repetitions, deadline enforcement and bounded diagnostics.
    /// - Throws: Invalid arguments, integrity, unsupported-platform, serialization or explicit output failures.
    ///   A failed process exits nonzero; the supervisor preserves partial diagnostics and teardown receipts.
    static func main() async throws {
        if CommandLine.arguments.dropFirst() == ["--list-modes"] {
            print(TimingMode.allCases.map(\.rawValue).joined(separator: "\n"))
            return
        }
        let configuration = try TimingConfiguration.parse(Array(CommandLine.arguments.dropFirst()))
        let result = try await TimingHarness.run(configuration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let native = try encoder.encode(result)
        guard native.count <= DiscordBenchmarkReport.maximumSerializedBytes else { throw BenchmarkReportError.reportTooLarge }
        if let destination = configuration.output {
            try native.write(to: URL(fileURLWithPath: destination), options: .atomic)
        } else {
            FileHandle.standardOutput.write(native)
            FileHandle.standardOutput.write(Data([10]))
        }
        if let destination = configuration.commonReport {
            try result.common.validatedData().write(to: URL(fileURLWithPath: destination), options: .atomic)
        }
    }
}
