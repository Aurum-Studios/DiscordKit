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
    /// Commands are `validate FILE`, `compare BASELINE CANDIDATE`, `hash FILE`,
    /// `hash-series SERIES`, and `evaluate SERIES POLICY`. Validation
    /// proves structure; compare checks semantic evidence without numerical gating.
    /// Evaluate applies the reviewed policy mode and exits two when a required gate
    /// cannot pass. Hash commands produce canonical receipts without updating policies.
    /// Invalid documents and arguments fail through the throwing process entry point.
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
        case "hash" where arguments.count == 2:
            print(try BenchmarkEvidenceHash.report(read(arguments[1])))
        case "hash-series" where arguments.count == 2:
            let series = try BenchmarkSeries.decode(readData(arguments[1], maximumBytes: BenchmarkSeries.maximumSerializedBytes))
            print(String(decoding: try JSONEncoder.sorted.encode(series.hashes()), as: UTF8.self))
        case "evaluate" where arguments.count == 3:
            let series = try BenchmarkSeries.decode(readData(arguments[1], maximumBytes: BenchmarkSeries.maximumSerializedBytes))
            let policy = try BenchmarkPolicy.decode(readData(arguments[2], maximumBytes: BenchmarkPolicy.maximumSerializedBytes))
            let evaluation = try BenchmarkEvaluation.evaluate(series, policy: policy)
            print(String(decoding: try JSONEncoder.sorted.encode(evaluation), as: UTF8.self))
            if policy.mode == .required && !evaluation.requiredGatePassed { exit(2) }
        default:
            throw ReportCommandError.invalidArguments
        }
    }

    /// Reads at most the schema's serialized ceiling before strict decoding.
    /// - Parameter path: User-selected local report file; it is never a metric label.
    /// - Returns: A validated common envelope with original qualification scope.
    /// - Throws: Filesystem errors, documentTooLarge or strict schema validation errors.
    private static func read(_ path: String) throws -> DiscordBenchmarkReport {
        try DiscordBenchmarkReport.decode(readData(path, maximumBytes: DiscordBenchmarkReport.maximumSerializedBytes))
    }

    /// Reads only the document ceiling plus one byte so oversized input is rejected without an unbounded read.
    /// - Parameters:
    ///   - path: Explicit user-selected local document path, never evaluated as a command.
    ///   - maximumBytes: The schema-specific finite serialized input ceiling.
    /// - Returns: At most the declared maximum number of raw bytes.
    /// - Throws: Filesystem errors or documentTooLarge; no artifacts are modified.
    private static func readData(_ path: String, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(65_536, remaining)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { throw BenchmarkEvaluationError.documentTooLarge }
        return data
    }
}

private extension JSONEncoder {
    /// Uses the same deterministic sorted-key presentation for each CLI response.
    static var sorted: JSONEncoder {
        /// Allocates a response encoder without changing receipt canonicalization.
        get {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return encoder
        }
    }
}
