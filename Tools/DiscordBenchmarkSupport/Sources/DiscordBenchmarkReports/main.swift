// File: Tools/DiscordBenchmarkSupport/Sources/DiscordBenchmarkReports/main.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation

/// Sanitized command admission errors; filenames and report bodies are never retained.
private enum ReportCommandError: Error { case invalidArguments }

/// Offline report commands exercise the same strict schema APIs used by deterministic tests.
@main struct DiscordBenchmarkReports {
    /// Validates one envelope or explains compatibility of two bounded local artifacts.
    ///
    /// Commands are `validate FILE` and `compare BASELINE CANDIDATE`. Validation
    /// proves structure; compatibility checks semantic evidence and never promote a
    /// numerical gate. Incompatible comparisons return a JSON reason list. Invalid
    /// documents and arguments fail nonzero through the throwing process entry point.
    /// - Throws: Argument, file, schema or bounded decoding errors.
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "validate" where arguments.count == 2:
            let report = try read(arguments[1])
            let response: [String: Any] = ["valid": true, "status": report.status.rawValue,
                "metricPopulations": report.metrics.count, "numericalQualification": false]
            print(String(decoding: try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]), as: UTF8.self))
        case "compare" where arguments.count == 3:
            let baseline = try read(arguments[1]), candidate = try read(arguments[2])
            let result = baseline.comparison(with: candidate)
            let response: [String: Any] = ["compatible": result.reasons.isEmpty,
                "reasons": result.reasons, "numericalQualification": false]
            print(String(decoding: try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]), as: UTF8.self))
        default:
            throw ReportCommandError.invalidArguments
        }
    }

    /// Reads at most the schema's serialized ceiling before strict decoding.
    /// - Parameter path: User-selected local report file; it is never a metric label.
    /// - Returns: A validated common envelope with original qualification scope.
    /// - Throws: Filesystem errors, reportTooLarge or strict schema validation errors.
    private static func read(_ path: String) throws -> DiscordBenchmarkReport {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var data = Data()
        while data.count <= DiscordBenchmarkReport.maximumSerializedBytes {
            let remaining = DiscordBenchmarkReport.maximumSerializedBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(65_536, remaining)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return try DiscordBenchmarkReport.decode(data)
    }
}
