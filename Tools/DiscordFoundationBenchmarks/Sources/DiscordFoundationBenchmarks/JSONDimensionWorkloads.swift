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

    /// Adds independent numeric-leaf density and key-length controls without changing version-two fixtures.
    /// - Returns: Ten version-three parse/serialize cases with exact 16 KiB documents and four variants each.
    /// - Throws: Invalid exact-byte budgets or source/tree disagreement during untimed verification.
    /// Root width, depth and string count remain fixed. Padding adjusts only the final string's length so that
    /// increasing numeric tokens or key bytes does not simultaneously increase the total document byte count.
    static func makeDensityControls() throws -> [FoundationWorkload] {
        try [(numbers: 16, keyBytes: 8), (1, 8), (128, 8), (16, 1), (16, 64)].flatMap { shape in
            let fixtures = try (0..<4).map {
                try DensityFixture(numbers: shape.numbers, keyBytes: shape.keyBytes, variant: $0)
            }
            let label = "bytes16384.keys\(shape.keyBytes).numbers\(shape.numbers)"
            let dimensions: [String: UInt64] = ["fixtureVersion": 3, "payloadBytes": 16_384,
                "depth": 2, "width": 4, "stringLeaves": 17, "numericLeaves": UInt64(shape.numbers + 1),
                "variableKeyBytes": UInt64(shape.keyBytes), "variants": 4]
            let verify = {
                for fixture in fixtures {
                    guard try JSONValue.parse(fixture.source) == fixture.tree,
                          try fixture.tree.serialized() == fixture.source else {
                        throw FoundationBenchmarkError.integrityFailure("Version-three JSON source/tree mismatch")
                    }
                }
            }
            let evidence = fixtures.reduce(into: Data()) { $0.append($1.source) }
            return [
                FoundationWorkload(id: "json.v3.parse.\(label)", dimensions: dimensions, fixture: evidence,
                    operation: { index in
                        let fixture = fixtures[Int(index % 4)]
                        guard case .object(let object) = try JSONValue.parse(fixture.source),
                              case .number(let marker) = object["a_variant"], let value = UInt64(marker.rawValue),
                              case .array(let numbers) = object[fixture.numberKey],
                              case .number(let first) = numbers.first,
                              case .number(let last) = numbers.last else {
                            throw FoundationBenchmarkError.integrityFailure("Version-three JSON marker/numbers missing")
                        }
                        let firstBytes = first.rawValue.utf8, lastBytes = last.rawValue.utf8
                        return FoundationObservation(checksum: UInt64(object.count) &+ value
                            &+ UInt64(numbers.count) &* 65_537 &+ UInt64(firstBytes.count) &* 257
                            &+ UInt64(firstBytes.first ?? 0) &+ UInt64(lastBytes.count) &* 65_521
                            &+ UInt64(lastBytes.last ?? 0))
                    }, expected: { FoundationObservation(checksum: fixtures[Int($0 % 4)].parseChecksum) }, verify: verify),
                FoundationWorkload(id: "json.v3.serialize.\(label)", dimensions: dimensions, fixture: evidence,
                    operation: { index in
                        let bytes = try fixtures[Int(index % 4)].tree.serialized()
                        return FoundationObservation(checksum: UInt64(bytes.count) &+ UInt64(bytes[13]))
                    }, expected: { FoundationObservation(checksum: 16_384 &+ 48 &+ ($0 % 4)) }, verify: verify),
            ]
        }
    }

    private struct DensityFixture {
        let source: Data
        let tree: JSONValue
        let numberKey: String
        let parseChecksum: UInt64

        /// Authors canonical wire bytes and an independent tree with fixed structure and an exact byte budget.
        /// - Parameters:
        ///   - numbers: Number of exact numeric tokens in the second array, selected from 1, 16 and 128.
        ///   - keyBytes: Encoded ASCII length of each of three variable keys, selected from 1, 8 and 64.
        ///   - variant: Index in `0..<4`, rotating lossless decimal spellings and the root marker.
        /// - Throws: Number validation errors or an insufficient exact document byte budget.
        /// The numeric marker key stays `a_variant`; the other keys begin with b/c/d and remain canonically ordered.
        init(numbers: Int, keyBytes: Int, variant: Int) throws {
            let keys = ["b", "c", "d"].map { $0 + String(repeating: "x", count: keyBytes - 1) }
            let lexemes = ["18446744073709551616", "1.2300e+900", "-0", "9007199254740993"]
            let numericText = (0..<numbers).map { lexemes[($0 + variant) % lexemes.count] }
            numberKey = keys[1]
            let first = numericText[0].utf8, last = numericText[numericText.count - 1].utf8
            parseChecksum = 4 &+ UInt64(variant) &+ UInt64(numbers) &* 65_537
                &+ UInt64(first.count) &* 257 &+ UInt64(first.first ?? 0)
                &+ UInt64(last.count) &* 65_521 &+ UInt64(last.last ?? 0)
            let strings = Array(repeating: String(repeating: "x", count: 32), count: 16)
            let prefix = "{\"a_variant\":\(variant),\"\(keys[0])\":["
                + strings.map { "\"" + $0 + "\"" }.joined(separator: ",")
                + "],\"\(keys[1])\":[" + numericText.joined(separator: ",") + "],\"\(keys[2])\":\""
            let padding = 16_384 - prefix.utf8.count - 2
            guard padding > 0 else {
                throw FoundationBenchmarkError.invalidConfiguration("Version-three JSON budget too small")
            }
            let tail = String(repeating: "x", count: padding)
            source = Data((prefix + tail + "\"}").utf8)
            tree = .object(["a_variant": .number(try JSONNumber(rawValue: String(variant))),
                keys[0]: .array(strings.map(JSONValue.string)),
                keys[1]: .array(try numericText.map { .number(try JSONNumber(rawValue: $0)) }),
                keys[2]: .string(tail)])
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
