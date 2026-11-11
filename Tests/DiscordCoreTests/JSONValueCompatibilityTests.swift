// File: Tests/DiscordCoreTests/JSONValueCompatibilityTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Foundation
import Testing
@testable import DiscordCore

/// Independent Foundation fixtures and generated invalid inputs protect the bounded JSON wire contract.
@Suite struct JSONValueCompatibilityTests {
    /// Compares every ASCII scalar and varied Unicode content against Foundation's exact string encoding.
    /// - Throws: Unexpected encoding, parsing, or serialization failures.
    @Test func generatedStringWireCompatibility() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var samples = ["", "plain ASCII", String(repeating: "unescaped_ascii_", count: 1_024),
                       "/", "\\", "\"", "雪🐶", "é", "e\u{0301}", "\u{2028}\u{2029}", "\u{10FFFF}"]
        for byte in UInt8(0)...UInt8(127) {
            samples.append("prefix" + String(Unicode.Scalar(byte)) + "suffix")
        }
        for offset in 0..<32 {
            var sample = ""
            for index in 0..<128 {
                sample.unicodeScalars.append(Unicode.Scalar(UInt8((index * 37 + offset) % 128)))
            }
            samples.append(sample)
        }
        for sample in samples {
            let independentBytes = try encoder.encode(sample)
            let parsed = try JSONValue.parse(independentBytes)
            guard case .string(let content) = parsed else {
                Issue.record("Expected a scalar string from the independent Foundation fixture.")
                continue
            }
            // Swift string equality is canonical: compare UTF-8 to also protect exact scalar content.
            #expect(Array(content.utf8) == Array(sample.utf8))
            let actualBytes = try JSONValue.string(sample).serialized()
            #expect(actualBytes == independentBytes)
            #expect(Array(try decoder.decode(String.self, from: actualBytes).utf8) == Array(sample.utf8))
        }
    }

    /// Uses Foundation-authored mixed documents with independently constructed expected trees across width/depth sweeps.
    /// - Throws: Unexpected fixture encoding, numeric validation, parsing, or serialization failures.
    @Test func generatedDocumentDifferential() throws {
        for width in [0, 1, 8, 64] {
            for depth in [0, 1, 4] {
                var foundation: [String: Any] = [:]
                var expected: [String: JSONValue] = [:]
                for index in 0..<width {
                    let key = "key_\(index)"
                    let text = "value \(index) 雪 e\u{0301}\n/"
                    let flag = index.isMultiple(of: 2)
                    var independent: Any = [text, NSNull(), index, flag] as [Any]
                    var value = JSONValue.array([.string(text), .null,
                        .number(try JSONNumber(rawValue: String(index))), .bool(flag)])
                    for _ in 0..<depth {
                        independent = ["nested": independent]
                        value = .object(["nested": value])
                    }
                    foundation[key] = independent
                    expected[key] = value
                }
                let independentBytes = try JSONSerialization.data(withJSONObject: foundation, options: [.sortedKeys])
                let tree = JSONValue.object(expected)
                #expect(try JSONValue.parse(independentBytes) == tree)
                let actualBytes = try tree.serialized()
                let independentReadBack = try JSONSerialization.jsonObject(with: actualBytes) as? NSDictionary
                #expect(independentReadBack?.isEqual(to: foundation) == true)
                #expect(try tree.serialized() == actualBytes)
            }
        }
    }

    /// Generates malformed strings independently through truncation, forbidden control bytes, escapes, and invalid UTF-8.
    /// - Throws: Unexpected Foundation fixture encoding failures.
    @Test func generatedMalformedStringDifferential() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for content in ["", "ASCII", "quoted \" and \\", "雪🐶", "\n\t\u{0000}"] {
            let complete = try encoder.encode(content)
            for count in 0..<complete.count {
                let malformed = Data(complete.prefix(count))
                #expect(throws: DecodingError.self) { try decoder.decode(String.self, from: malformed) }
                #expect(throws: JSONValueError.self) { try JSONValue.parse(malformed) }
            }
        }
        for prefixLength in [0, 1, 17, 127] {
            for control in UInt8(0)...UInt8(31) {
                let malformed = Data([34] + Array(repeating: UInt8(65), count: prefixLength) + [control, 34])
                #expect(throws: DecodingError.self) { try decoder.decode(String.self, from: malformed) }
                #expect(throws: JSONValueError.malformed(byteOffset: prefixLength + 1)) {
                    try JSONValue.parse(malformed)
                }
            }
        }
        for escape in [UInt8(33), 39, 48, 97, 113, 120, 127] {
            let malformed = Data([34, 92, escape, 34])
            #expect(throws: DecodingError.self) { try decoder.decode(String.self, from: malformed) }
            #expect(throws: JSONValueError.malformed(byteOffset: 0)) { try JSONValue.parse(malformed) }
        }
        let invalidUTF8Sequences: [[UInt8]] = [[0xFF], [0x80], [0xC0, 0xAF], [0xE2, 0x82],
                                              [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80]]
        for invalidUTF8 in invalidUTF8Sequences {
            let malformed = Data([34, 65] + invalidUTF8 + [34])
            #expect(throws: DecodingError.self) { try decoder.decode(String.self, from: malformed) }
            #expect(throws: JSONValueError.malformed(byteOffset: 0)) { try JSONValue.parse(malformed) }
        }
    }

    /// Pins UTF-8 error positions on fast-path boundaries and on Unicode/escape fallback failures.
    @Test func exactMalformedOffsets() {
        let cases: [(Data, Int)] = [
            (Data([91, 34, 65, 10, 34, 93]), 3),
            (Data([91, 34, 65, 0xC0, 0xAF, 34, 93]), 1),
            (Data([91, 34, 65, 92]), 4),
            (Data([91, 34, 65]), 1),
            (Data(#"["ok", "\q"]"#.utf8), 7),
            (Data(#"["é","\uD800"]"#.utf8), 6),
            (Data(#"["ASCII" "next"]"#.utf8), 9),
        ]
        for (source, offset) in cases {
            #expect(throws: JSONValueError.malformed(byteOffset: offset)) { try JSONValue.parse(source) }
        }
    }

    /// Requires canonical-equivalent key rejection for literal and escaped spellings at the exact second key offset.
    @Test func canonicalEquivalentDuplicateOffsets() {
        let spellings = [#""é""#, #""é""#, #""\u00e9""#, #""e\u0301""#]
        for first in spellings {
            for second in spellings {
                let prefix = "{\(first):0,"
                #expect(throws: JSONValueError.duplicateKey(byteOffset: prefix.utf8.count)) {
                    try JSONValue.parse(prefix + second + ":1}")
                }
            }
        }
    }

    /// Generates distinct arbitrary-precision number spellings without routing them through bounded Foundation numbers.
    /// - Throws: Unexpected number validation, parsing, or serialization failures.
    @Test func generatedExactNumericLexemes() throws {
        for sign in ["", "-"] {
            for integer in ["0", "1", String(repeating: "9", count: 256)] {
                for fraction in ["", ".0", ".2300"] {
                    for exponent in ["", "e+000", "E-999999999999999999999"] {
                        let lexeme = sign + integer + fraction + exponent
                        let source = Data(("[" + lexeme + "]").utf8)
                        let expected = JSONValue.array([.number(try JSONNumber(rawValue: lexeme))])
                        #expect(try JSONValue.parse(source) == expected)
                        #expect(try expected.serialized() == source)
                    }
                }
            }
        }
    }

    /// Checks exact escaped-byte budgets and matching depth/node boundaries for both string handling paths.
    /// - Throws: Unexpected Foundation encoding, parsing, or serialization failures at permitted boundaries.
    @Test func stringResourceBoundaries() throws {
        let encoder = JSONEncoder()
        for content in ["", "ASCII", "\u{007F}", "/", "雪🐶", "\n\n"] {
            let encoded = try encoder.encode(content)
            let exact = JSONLimits(maximumBytes: encoded.count)
            let tooSmall = JSONLimits(maximumBytes: encoded.count - 1)
            #expect(try JSONValue.parse(encoded, limits: exact) == .string(content))
            #expect(try JSONValue.string(content).serialized(limits: exact) == encoded)
            #expect(throws: JSONValueError.maximumBytesExceeded) { try JSONValue.parse(encoded, limits: tooSmall) }
            #expect(throws: JSONValueError.maximumBytesExceeded) {
                try JSONValue.string(content).serialized(limits: tooSmall)
            }
        }
        for depth in [1, 2, 64, 128] {
            for content in ["ASCII", "雪/\n"] {
                let token = String(decoding: try encoder.encode(content), as: UTF8.self)
                let source = String(repeating: "[", count: depth) + token + String(repeating: "]", count: depth)
                let limits = JSONLimits(maximumDepth: depth, maximumNodes: depth + 1)
                let tree = try JSONValue.parse(source, limits: limits)
                #expect(try tree.serialized(limits: limits) == Data(source.utf8))
                #expect(throws: JSONValueError.maximumDepthExceeded) {
                    try JSONValue.parse("[" + source + "]", limits: limits)
                }
                #expect(throws: JSONValueError.maximumDepthExceeded) {
                    try JSONValue.array([tree]).serialized(limits: limits)
                }
                let insufficientNodes = JSONLimits(maximumDepth: depth, maximumNodes: depth)
                #expect(throws: JSONValueError.maximumNodesExceeded) {
                    try JSONValue.parse(source, limits: insufficientNodes)
                }
                #expect(throws: JSONValueError.maximumNodesExceeded) {
                    try tree.serialized(limits: insufficientNodes)
                }
            }
        }
    }
}
