// File: Tools/DiscordFoundationBenchmarks/Tests/DiscordFoundationBenchmarksTests/JSONBitsWorkloadTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBits
import DiscordCore
import Foundation
import Testing
@testable import DiscordFoundationBenchmarks

/// Confirms that measured results and prebuilt fixture semantics agree with independent oracles.
@Suite struct JSONBitsWorkloadTests {
    /// Checks every JSON/bit workload against its untimed oracle, including repeated and wrapping input indices.
    /// - Throws: Fixture setup, semantic verification or measured-operation errors; mismatched observations fail assertions.
    /// All synchronous calls use prepared local fixtures and make no elapsed-time performance assertion.
    @Test func operationsMatchExpectedObservations() throws {
        let workloads = try JSONWorkloads.make() + BitsWorkloads.make()
        #expect(Set(workloads.map(\.id)).count == workloads.count)
        for workload in workloads {
            try workload.verify()
            for input in [UInt64](arrayLiteral: 0, 1, 2, 3, 4, 7, 63, UInt64.max) {
                #expect(try workload.operation(input) == workload.expected(input), "\(workload.id), input \(input)")
            }
        }
    }

    /// Inspects each exact-size wire variant independently for width, nested depth, Unicode and lossless numbers.
    /// - Throws: Fixture/parser/writer errors or failed required dimension/leaf extraction.
    /// Source slicing excludes rejection fingerprints; canonical byte equality checks run outside any benchmark timer.
    @Test func jsonSizesShapesAndNumericLexemes() throws {
        let workloads = try JSONWorkloads.make().filter { $0.id.hasPrefix("json.parse.") }
        #expect(workloads.count == 6)
        #expect(Set(workloads.compactMap { $0.dimensions["payloadBytes"] }) == [1_024, 16_384, 262_144])
        #expect(Set(workloads.compactMap { $0.dimensions["depth"] }) == [1, 8, 64])
        let lexemes = ["18446744073709551616", "1.2300e+900", "-0", "9007199254740993"]
        for workload in workloads {
            let bytes = try #require(workload.dimensions["payloadBytes"].map(Int.init))
            let width = try #require(workload.dimensions["width"].map(Int.init))
            let depth = try #require(workload.dimensions["depth"].map(Int.init))
            let unicode = workload.dimensions["unicode"] == 1
            #expect(workload.fixture.count == bytes * 4)
            for variant in 0..<4 {
                let source = workload.fixture.subdata(in: (variant * bytes)..<((variant + 1) * bytes))
                let tree = try JSONValue.parse(source)
                guard case .object(let object) = tree else {
                    Issue.record("Expected a JSON object fixture")
                    continue
                }
                #expect(object.count == width)
                #expect(object["a_variant"] == .number(try JSONNumber(rawValue: String(variant))))
                #expect(object["z_number"] == .number(try JSONNumber(rawValue: lexemes[variant])))
                var value = try #require(object["field000"])
                for _ in 1..<depth {
                    guard case .array(let values) = value else {
                        Issue.record("Missing a configured nested container")
                        break
                    }
                    #expect(values.count == 1)
                    value = try #require(values.first)
                }
                guard case .string(let text) = value else {
                    Issue.record("Expected the nested string leaf")
                    continue
                }
                #expect(text.contains("雪🐶") == unicode)
                #expect(try tree.serialized() == source)
            }
        }
    }

    /// Requires all malformed/byte/depth refusals to expose exact category/offset checksums and one rejection each.
    /// - Throws: Unexpected setup or operation errors; each case's verifier additionally checks the precise JSON error value.
    @Test func rejectedJSONHasExactErrorObservations() throws {
        let workloads = try JSONWorkloads.make().filter { $0.id.hasPrefix("json.reject.") }
        #expect(workloads.count == 5)
        for workload in workloads {
            for input in 0..<4 {
                let checksum: UInt64
                if workload.id.hasSuffix("malformed") {
                    checksum = [3, 1_283, 771, 1_283][input]
                } else {
                    checksum = workload.id.hasSuffix("size") ? 1 : 2
                }
                #expect(try workload.operation(UInt64(input)) == FoundationObservation(checksum: checksum, rejections: 1))
            }
            try workload.verify()
        }
    }

    /// Verifies decimal fixtures against independently specified membership patterns through and beyond their top bit.
    /// - Throws: Setup, required dimension extraction or decimal validation errors.
    /// The 64-bit fixtures additionally use native unsigned arithmetic as an independent decimal oracle.
    @Test func bitsetDecimalFixturesRetainEveryPosition() throws {
        let workloads = try BitsWorkloads.make().filter { $0.id.hasPrefix("bits.parse.") }
        #expect(workloads.count == 3)
        #expect(Set(workloads.compactMap { $0.dimensions["bitWidth"] }) == [64, 256, 4_096])
        for workload in workloads {
            let width = try #require(workload.dimensions["bitWidth"].map(Int.init))
            let variants = String(decoding: workload.fixture, as: UTF8.self).split(separator: "\n")
            #expect(variants.count == 4)
            for (variant, line) in variants.enumerated() {
                let decimals = line.split(separator: ":")
                #expect(decimals.count == 2)
                let left = try UnsignedBitSet(decimalString: String(decimals[0]))
                let right = try UnsignedBitSet(decimalString: String(decimals[1]))
                #expect(left.bitWidth == width)
                for bit in 0...width {
                    #expect(left.contains(bit) == (bit < width && ((bit + variant) % 7 == 0 || bit == width - 1)))
                    #expect(right.contains(bit) == (bit < width && ((bit + variant) % 11 == 0 || bit == width - 2)))
                }
                if width == 64 {
                    var oracle: UInt64 = 0
                    for bit in 0..<64 where (bit + variant) % 7 == 0 || bit == 63 { oracle |= 1 << bit }
                    #expect(String(decimals[0]) == String(oracle))
                }
            }
        }
    }

    /// Checks zero-padded snowflakes retain zero, realistic values and `UInt64.max` with exact integer timestamps.
    /// - Throws: Fixture preparation or failed required identifier extraction; all assertions are offline and synchronous.
    @Test func identifiersIncludeUnsignedBoundaryAndLeadingZeros() throws {
        let workloads = try BitsWorkloads.make().filter { $0.id.hasPrefix("identifier.") }
        #expect(workloads.count == 2)
        let parse = try #require(workloads.first { $0.id == "identifier.parse.snowflake" })
        let strings = String(decoding: parse.fixture, as: UTF8.self).split(separator: "\n")
        let expected: [UInt64] = [0, 1, 175_928_847_299_117_063, UInt64.max]
        for (index, text) in strings.enumerated() {
            #expect(text.hasPrefix("000"))
            let identifier = try #require(UserID(String(text)))
            #expect(identifier.rawValue == expected[index])
            #expect(identifier.timestampMilliseconds == (expected[index] >> 22) + 1_420_070_400_000)
        }
    }
}
