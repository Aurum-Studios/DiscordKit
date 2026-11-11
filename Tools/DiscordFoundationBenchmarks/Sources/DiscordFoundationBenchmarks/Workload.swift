// File: Tools/DiscordFoundationBenchmarks/Sources/DiscordFoundationBenchmarks/Workload.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Foundation

/// Minimal observable result consumed inside a batch; expected refusal is a counted result.
struct FoundationObservation: Equatable {
    let checksum: UInt64
    let rejections: UInt64

    /// Creates a minimal synchronous call result without recording time or retaining the operation output.
    /// - Parameters:
    ///   - checksum: Observable unsigned fixture result; the harness combines values with wrapping addition.
    ///   - rejections: Zero for success (default), one for an expected rejection; larger values fail integrity checks.
    init(checksum: UInt64, rejections: UInt64 = 0) {
        self.checksum = checksum; self.rejections = rejections
    }
}

/// Prepared immutable fixture and operation closures; setup and full verification are outside timers.
struct FoundationWorkload {
    let id: String
    let dimensions: [String: UInt64]
    let fixture: Data
    let operation: (UInt64) throws -> FoundationObservation
    let expected: (UInt64) -> FoundationObservation
    let verify: () throws -> Void
}

enum FoundationBenchmarkError: Error, Equatable {
    case invalidConfiguration(String), integrityFailure(String)
}

enum FoundationWorkloads {
    /// Retains only the chosen case during warmup/measurement; unrelated fixture families are never constructed.
    /// - Parameter id: Exact ID from the finite catalog, including its family and size dimensions.
    /// - Returns: One prepared case; other cases temporarily constructed in its family are released.
    /// - Throws: Unknown family/case or fixture construction errors. Performs no measured work or I/O.
    static func selected(_ id: String) throws -> FoundationWorkload {
        let cases: [FoundationWorkload]
        switch id.split(separator: ".").first {
        case "json": cases = try id.hasPrefix("json.v2.") ? JSONDimensionWorkloads.make() : JSONWorkloads.make()
        case "bits", "identifier": cases = try BitsWorkloads.make()
        case "model": cases = try ModelWorkloads.make()
        case "builder": cases = try BuilderWorkloads.make()
        case "permission": cases = try PermissionWorkloads.make()
        case "rpc": cases = try RPCWorkloads.make()
        default: throw FoundationBenchmarkError.invalidConfiguration("Unknown case family")
        }
        guard let selected = cases.first(where: { $0.id == id }) else {
            throw FoundationBenchmarkError.invalidConfiguration("Unknown case")
        }
        return selected
    }

    /// Constructs the finite representative workload matrix without running measured batches.
    /// - Returns: All uniquely named cases, retaining their fixtures for catalog listing or deterministic tests.
    /// - Throws: Fixture construction or duplicate/absent identity errors; callers own the returned fixture lifetime.
    static func make() throws -> [FoundationWorkload] {
        let cases = try JSONWorkloads.make() + JSONDimensionWorkloads.make() + BitsWorkloads.make() + ModelWorkloads.make()
            + BuilderWorkloads.make() + PermissionWorkloads.make() + RPCWorkloads.make()
        guard Set(cases.map(\.id)).count == cases.count, !cases.isEmpty else {
            throw FoundationBenchmarkError.integrityFailure("Duplicate or absent workload IDs")
        }
        return cases
    }
}
