// File: Tools/DiscordFoundationBenchmarks/Sources/DiscordFoundationBenchmarks/JSONWorkloads.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordCore
import Foundation

/// Lossless JSON batches keep source construction and whole-tree comparisons outside timing.
/// All operations are synchronous and own only local temporary values; the enclosing batch checks cancellation.
enum JSONWorkloads {
    /// Prepares the finite ASCII/Unicode parse, serialization and rejection matrix before measurement.
    /// - Returns: Seventeen ordered cases, each retaining four immutable variants and untimed semantic checks.
    /// - Throws: Fixture configuration/integrity failures or unexpected JSON number/writer failures during setup.
    /// Construction allocates bounded source/tree fixtures up to 256 KiB per variant and performs no I/O.
    static func make() throws -> [FoundationWorkload] {
        var workloads: [FoundationWorkload] = []
        for (size, depth, width) in [(1_024, 1, 4), (16_384, 8, 32), (262_144, 64, 256)] {
            for unicode in [false, true] {
                let fixtures = try (0..<4).map {
                    try Fixture(bytes: size, depth: depth, width: width, unicode: unicode, variant: $0)
                }
                let dimensions: [String: UInt64] = [
                    "payloadBytes": UInt64(size), "depth": UInt64(depth), "width": UInt64(width),
                    "unicode": unicode ? 1 : 0, "variants": 4,
                ]
                let label = "\(size).depth\(depth).\(unicode ? "unicode" : "ascii")"
                let fixture = fixtures.reduce(into: Data()) { $0.append($1.source) }
                let verify = {
                    for item in fixtures {
                        guard try JSONValue.parse(item.source) == item.tree,
                              try item.tree.serialized() == item.source else {
                            throw FoundationBenchmarkError.integrityFailure("JSON semantic or canonical-byte mismatch")
                        }
                    }
                }
                workloads.append(FoundationWorkload(
                    id: "json.parse.\(label)", dimensions: dimensions, fixture: fixture,
                    operation: { try parse(fixtures[Int($0 % 4)]) },
                    expected: { FoundationObservation(checksum: UInt64(width) &+ ($0 % 4)) },
                    verify: verify
                ))
                workloads.append(FoundationWorkload(
                    id: "json.serialize.\(label)", dimensions: dimensions, fixture: fixture,
                    operation: { try serialize(fixtures[Int($0 % 4)]) },
                    expected: { FoundationObservation(checksum: UInt64(size) &+ 48 &+ ($0 % 4)) },
                    verify: verify
                ))
            }
        }
        workloads.append(contentsOf: try rejectionWorkloads())
        return workloads
    }

    /// Independently authored trees and compact source bytes share only their fixture values.
    private struct Fixture {
        let source: Data
        let tree: JSONValue

        /// Builds matching independent tree and canonical UTF-8 representations with an exact byte budget.
        /// - Parameters:
        ///   - bytes: Target document bytes; the caller selects 1,024, 16,384 or 262,144 and must fit structural overhead.
        ///   - depth: Total container depth, including the root object; the caller supplies 1, 8 or 64.
        ///   - width: Root member count, including two numeric markers; the caller supplies 4, 32 or 256.
        ///   - unicode: Whether string leaves repeat literal Chinese/emoji scalars; remaining bytes use ASCII padding.
        ///   - variant: Index in `0..<4`, selecting an exact numeric lexeme and a one-digit consumption marker.
        /// - Throws: `invalidConfiguration` for an insufficient byte budget, `integrityFailure` for byte-count drift,
        ///   or an unexpected `JSONValueError` while validating the authored number spellings.
        /// The private caller enforces shape/index ranges. New strings, dictionaries and data belong to this fixture.
        init(bytes: Int, depth: Int, width: Int, unicode: Bool, variant: Int) throws {
            let lexemes = ["18446744073709551616", "1.2300e+900", "-0", "9007199254740993"]
            let lexeme = lexemes[variant]
            let keys = (0..<(width - 2)).map { String(format: "field%03d", $0) }
            let emptyFields = keys.enumerated().map { index, key in
                "\"\(key)\":" + String(repeating: "[", count: index == 0 ? depth - 1 : 0)
                    + "\"\"" + String(repeating: "]", count: index == 0 ? depth - 1 : 0)
            }
            let prefix = "{\"a_variant\":\(variant),"
            let suffix = ",\"z_number\":\(lexeme)}"
            let overhead = (prefix + emptyFields.joined(separator: ",") + suffix).utf8.count
            let budget = bytes - overhead
            guard budget >= keys.count else {
                throw FoundationBenchmarkError.invalidConfiguration("JSON fixture is too small for its shape")
            }
            var members: [String: JSONValue] = [
                "a_variant": .number(try JSONNumber(rawValue: String(variant))),
                "z_number": .number(try JSONNumber(rawValue: lexeme)),
            ]
            var encodedFields: [String] = []
            for (index, key) in keys.enumerated() {
                let length = budget / keys.count + (index < budget % keys.count ? 1 : 0)
                let unit = unicode ? "雪🐶" : "x"
                let unitBytes = unit.utf8.count
                let text = String(repeating: unit, count: length / unitBytes)
                    + String(repeating: "x", count: length % unitBytes)
                let levels = index == 0 ? depth - 1 : 0
                var value = JSONValue.string(text)
                for _ in 0..<levels { value = .array([value]) }
                members[key] = value
                encodedFields.append("\"\(key)\":" + String(repeating: "[", count: levels)
                    + "\"\(text)\"" + String(repeating: "]", count: levels))
            }
            source = Data((prefix + encodedFields.joined(separator: ",") + suffix).utf8)
            tree = .object(members)
            guard source.count == bytes else {
                throw FoundationBenchmarkError.integrityFailure("JSON fixture byte count drifted")
            }
        }
    }

    /// Parses a prepared document and consumes only root width and its small numeric marker inside timing.
    /// - Parameter fixture: Immutable valid source/tree pair created during setup under default JSON limits.
    /// - Returns: Root member count plus variant marker, with zero rejections.
    /// - Throws: Parser failures, or `integrityFailure` if the marker/root shape is missing.
    /// The parsed tree is local to this call; full equality checks remain in the workload's untimed verifier.
    @inline(never)
    private static func parse(_ fixture: Fixture) throws -> FoundationObservation {
        let value = try JSONValue.parse(fixture.source)
        guard case .object(let fields) = value,
              case .number(let marker) = fields["a_variant"], let variant = UInt64(marker.rawValue) else {
            throw FoundationBenchmarkError.integrityFailure("JSON parse lost its consumption marker")
        }
        return FoundationObservation(checksum: UInt64(fields.count) &+ variant)
    }

    /// Serializes a prepared tree and samples its byte count and canonical variant digit inside timing.
    /// - Parameter fixture: Valid tree whose sorted `a_variant` field places its single digit at byte 13.
    /// - Returns: Output byte count plus the variant digit's UTF-8 value, with zero rejections.
    /// - Throws: Errors from `JSONValue.serialized()` under its default byte/depth/node limits.
    /// The returned data is local and discarded after consumption; the untimed verifier checks every output byte.
    @inline(never)
    private static func serialize(_ fixture: Fixture) throws -> FoundationObservation {
        let bytes = try fixture.tree.serialized()
        return FoundationObservation(checksum: UInt64(bytes.count) &+ UInt64(bytes[13]))
    }

    private struct RejectionFixture {
        let source: Data
        let tree: JSONValue?
        let limits: JSONLimits
        let error: JSONValueError
    }

    /// Prepares separate parser/writer refusal populations with exact public error and offset expectations.
    /// - Returns: Five cases for malformed parsing and parse/write byte/depth limits, with four variants each.
    /// - Throws: Unexpected number or writer errors while preparing valid source evidence for rejected trees.
    /// Size cases use a 32-byte limit; depth cases submit 65 containers against the default limit of 64.
    /// Length-prefixed source fingerprints and retained trees are built before any operation is timed.
    private static func rejectionWorkloads() throws -> [FoundationWorkload] {
        let malformed: [RejectionFixture] = zip(["?", "null x", "[1,]", "{\"a\":}"], [0, 5, 3, 5]).map {
            RejectionFixture(source: Data($0.0.utf8), tree: nil, limits: .default,
                             error: .malformed(byteOffset: $0.1))
        }
        let size = (0..<4).map {
            RejectionFixture(source: Data((String(repeating: " ", count: 29 + $0) + "null").utf8),
                             tree: nil, limits: JSONLimits(maximumBytes: 32), error: .maximumBytesExceeded)
        }
        let depth = (0..<4).map {
            RejectionFixture(source: Data((String(repeating: "[", count: 65) + String($0)
                + String(repeating: "]", count: 65)).utf8), tree: nil, limits: .default,
                             error: .maximumDepthExceeded)
        }
        let writerSize = try (0..<4).map { index in
            let tree = JSONValue.string(String(repeating: "x", count: 33 + index))
            return RejectionFixture(source: try tree.serialized(), tree: tree,
                                    limits: JSONLimits(maximumBytes: 32), error: .maximumBytesExceeded)
        }
        let writerDepth = try (0..<4).map { index in
            var tree = JSONValue.number(try JSONNumber(rawValue: String(index)))
            for _ in 0..<65 { tree = .array([tree]) }
            return RejectionFixture(source: try tree.serialized(limits: JSONLimits(maximumDepth: 65)),
                                    tree: tree, limits: .default, error: .maximumDepthExceeded)
        }
        return [
            ("json.reject.parse.malformed", malformed), ("json.reject.parse.size", size),
            ("json.reject.parse.depth", depth), ("json.reject.serialize.size", writerSize),
            ("json.reject.serialize.depth", writerDepth),
        ].map { id, fixtures in
            var dimensions: [String: UInt64] = ["variants": 4, "expectedRejectionsPerOperation": 1]
            dimensions["maximumBytes"] = UInt64(fixtures[0].limits.maximumBytes)
            dimensions["maximumDepth"] = UInt64(fixtures[0].limits.maximumDepth)
            // Length prefixes make the fingerprint unambiguous for differently sized rejected documents.
            let fingerprint = fixtures.reduce(into: Data()) { data, item in
                data.append(contentsOf: "\(item.source.count):".utf8)
                data.append(item.source)
            }
            return FoundationWorkload(
                id: id, dimensions: dimensions, fixture: fingerprint,
                operation: { try reject(fixtures[Int($0 % 4)]) },
                expected: { FoundationObservation(checksum: errorChecksum(fixtures[Int($0 % 4)].error), rejections: 1) },
                verify: {
                    for item in fixtures {
                        do {
                            if let tree = item.tree { _ = try tree.serialized(limits: item.limits) }
                            else { _ = try JSONValue.parse(item.source, limits: item.limits) }
                            throw FoundationBenchmarkError.integrityFailure("JSON accepted a rejected fixture")
                        } catch let error as JSONValueError {
                            guard error == item.error else {
                                throw FoundationBenchmarkError.integrityFailure("JSON rejection type or offset drifted")
                            }
                        }
                    }
                }
            )
        }
    }

    /// Attempts a prepared invalid operation and turns its precise JSON error into measured refusal evidence.
    /// - Parameter fixture: Source plus explicit limits; a nonnil tree selects serialization instead of parsing.
    /// - Returns: One rejection and an error checksum, or zero checksum/rejections if the invalid input was accepted.
    /// - Throws: Non-`JSONValueError` failures; expected error equality is checked after timing by the harness.
    /// No partial output escapes a failed writer call, and this helper adds no mid-parse cancellation check.
    @inline(never)
    private static func reject(_ fixture: RejectionFixture) throws -> FoundationObservation {
        do {
            if let tree = fixture.tree { _ = try tree.serialized(limits: fixture.limits) }
            else { _ = try JSONValue.parse(fixture.source, limits: fixture.limits) }
            return FoundationObservation(checksum: 0)
        } catch let error as JSONValueError {
            return FoundationObservation(checksum: errorChecksum(error), rejections: 1)
        }
    }

    /// Encodes the finite public JSON error cases without retaining or formatting input content.
    /// - Parameter error: A parser/writer classification; malformed and duplicate-key offsets are nonnegative UTF-8 indices.
    /// - Returns: A distinct small category code with the byte offset shifted into higher bits where applicable.
    /// The fixture sizes bound offsets, and the calculation performs no allocation or I/O.
    private static func errorChecksum(_ error: JSONValueError) -> UInt64 {
        switch error {
        case .maximumBytesExceeded: return 1
        case .maximumDepthExceeded: return 2
        case .malformed(let offset): return 3 &+ (UInt64(offset) << 8)
        case .duplicateKey(let offset): return 4 &+ (UInt64(offset) << 8)
        case .maximumNodesExceeded: return 5
        case .invalidLimits: return 6
        case .invalidNumber: return 7
        }
    }
}
