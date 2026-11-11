// File: Tools/DiscordFoundationBenchmarks/Sources/DiscordFoundationBenchmarks/JSONDimensionWorkloads.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordCore
import Foundation

/// Version-two one-factor JSON controls retain exact byte budgets while varying one declared dimension.
enum JSONDimensionWorkloads {
    /// Constructs baseline plus independent byte/depth/width/string-count/escape/Unicode controls.
    /// - Returns: Twenty-four uniquely versioned parse/serialize cases, each with four immutable variants.
    /// - Throws: JSON construction or integrity errors; setup and complete equality checks are untimed.
    /// Existing `json.parse.*`, `json.serialize.*` and rejection identities are supplied by `JSONWorkloads` unchanged.
    static func make() throws -> [FoundationWorkload] {
        let shapes = [
            Shape(), Shape(bytes: 1_024), Shape(bytes: 262_144), Shape(depth: 8), Shape(depth: 32),
            Shape(width: 32), Shape(width: 128), Shape(strings: 1), Shape(strings: 128),
            Shape(escapePercent: 25), Shape(escapePercent: 100), Shape(unicode: true),
        ]
        return try shapes.flatMap { shape in
            let fixtures = try (0..<4).map { try Fixture(shape: shape, variant: $0) }
            let dimensions: [String: UInt64] = ["fixtureVersion": 2, "payloadBytes": UInt64(shape.bytes),
                "depth": UInt64(shape.depth), "width": UInt64(shape.width), "stringLeaves": UInt64(shape.strings),
                "escapePercent": UInt64(shape.escapePercent), "unicode": shape.unicode ? 1 : 0, "variants": 4]
            let label = "bytes\(shape.bytes).depth\(shape.depth).width\(shape.width).strings\(shape.strings)"
                + ".escape\(shape.escapePercent).\(shape.unicode ? "unicode" : "ascii")"
            let evidence = fixtures.reduce(into: Data()) { $0.append($1.source) }
            let verify = {
                for item in fixtures {
                    guard try JSONValue.parse(item.source) == item.tree, try item.tree.serialized() == item.source else {
                        throw FoundationBenchmarkError.integrityFailure("Version-two JSON source/tree mismatch")
                    }
                }
            }
            return [
                FoundationWorkload(id: "json.v2.parse.\(label)", dimensions: dimensions, fixture: evidence,
                    operation: { index in
                        guard case .object(let object) = try JSONValue.parse(fixtures[Int(index % 4)].source),
                              case .number(let marker) = object["a_variant"], let value = UInt64(marker.rawValue) else {
                            throw FoundationBenchmarkError.integrityFailure("Version-two JSON marker missing")
                        }
                        return FoundationObservation(checksum: UInt64(object.count) &+ value)
                    }, expected: { FoundationObservation(checksum: UInt64(shape.width) &+ ($0 % 4)) }, verify: verify),
                FoundationWorkload(id: "json.v2.serialize.\(label)", dimensions: dimensions, fixture: evidence,
                    operation: { index in
                        let bytes = try fixtures[Int(index % 4)].tree.serialized()
                        return FoundationObservation(checksum: UInt64(bytes.count) &+ UInt64(bytes[13]))
                    }, expected: { FoundationObservation(checksum: UInt64(shape.bytes) &+ 48 &+ ($0 % 4)) }, verify: verify),
            ]
        }
    }

    /// Defaults form the shared control; each additional catalog shape changes exactly one field.
    private struct Shape {
        var bytes = 16_384
        var depth = 2
        var width = 4
        var strings = 16
        var escapePercent = 0
        var unicode = false
    }

    private struct Fixture {
        let source: Data
        let tree: JSONValue

        /// Authors canonical source and an independent value tree with exact encoded payload size.
        /// - Parameters:
        ///   - shape: Finite catalog shape; root depth includes the required string-leaf array at depth two.
        ///   - variant: Index in `0..<4`, selecting the numeric marker and preserved lossless number lexeme.
        /// - Throws: Invalid byte budgets, number construction failures or exact-byte integrity failures.
        /// Escape percentage allocates the requested share of string-content bytes to two-byte quote escapes,
        /// rounded down independently per leaf. Remaining bytes use literal Unicode units or ASCII padding.
        init(shape: Shape, variant: Int) throws {
            let lexeme = ["18446744073709551616", "1.2300e+900", "-0", "9007199254740993"][variant]
            let prefix = "{\"a_variant\":\(variant),\"field000\":" + String(repeating: "[", count: shape.depth - 1)
            let extraFields = (1..<(shape.width - 2)).map { String(format: ",\"field%03d\":0", $0) }.joined()
            let suffix = String(repeating: "]", count: shape.depth - 1) + extraFields + ",\"z_number\":\(lexeme)}"
            let overhead = (prefix + Array(repeating: "\"\"", count: shape.strings).joined(separator: ",") + suffix).utf8.count
            let budget = shape.bytes - overhead
            guard budget >= shape.strings else {
                throw FoundationBenchmarkError.invalidConfiguration("Version-two JSON budget too small")
            }
            var strings: [JSONValue] = [], encoded: [String] = []
            for index in 0..<shape.strings {
                let length = budget / shape.strings + (index < budget % shape.strings ? 1 : 0)
                let quotes = length * shape.escapePercent / 100 / 2
                let remainder = length - quotes * 2
                let unit = shape.unicode ? "雪🐶" : "x"
                let plain = String(repeating: unit, count: remainder / unit.utf8.count)
                    + String(repeating: "x", count: remainder % unit.utf8.count)
                strings.append(.string(String(repeating: "\"", count: quotes) + plain))
                encoded.append("\"" + String(repeating: "\\\"", count: quotes) + plain + "\"")
            }
            var value = JSONValue.array(strings)
            for _ in 2..<shape.depth { value = .array([value]) }
            var members: [String: JSONValue] = ["a_variant": .number(try JSONNumber(rawValue: String(variant))),
                "field000": value, "z_number": .number(try JSONNumber(rawValue: lexeme))]
            for index in 1..<(shape.width - 2) { members[String(format: "field%03d", index)] = .number(try JSONNumber(rawValue: "0")) }
            source = Data((prefix + encoded.joined(separator: ",") + suffix).utf8)
            tree = .object(members)
            guard source.count == shape.bytes else {
                throw FoundationBenchmarkError.integrityFailure("Version-two JSON byte budget drifted")
            }
        }
    }
}
