// File: Tools/DiscordFoundationBenchmarks/Tests/DiscordFoundationBenchmarksTests/JSONDimensionWorkloadTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordCore
import Foundation
import Testing
@testable import DiscordFoundationBenchmarks

@Suite struct JSONDimensionWorkloadTests {
    /// Requires each version-two control to alter one declared dimension while retaining canonical exact-size bytes.
    /// - Throws: Fixture/parser/writer errors or missing required dimensions and members.
    /// Every variant's actual depth, width, string count, escapes and Unicode are inspected independently of timing.
    @Test func independentDimensionsMatchActualSource() throws {
        let workloads = try JSONDimensionWorkloads.make()
        #expect(workloads.count == 24 && Set(workloads.map(\.id)).count == 24)
        let baseline = try #require(workloads.first)
        let varying = ["payloadBytes", "depth", "width", "stringLeaves", "escapePercent", "unicode"]
        var changed: Set<String> = []
        for workload in workloads {
            let differences = varying.filter { workload.dimensions[$0] != baseline.dimensions[$0] }
            #expect(differences.count <= 1)
            changed.formUnion(differences)
            try workload.verify()
            let bytes = Int(try #require(workload.dimensions["payloadBytes"]))
            let depth = Int(try #require(workload.dimensions["depth"]))
            for variant in 0..<4 {
                let source = workload.fixture.subdata(in: (variant * bytes)..<((variant + 1) * bytes))
                guard case .object(let object) = try JSONValue.parse(source) else {
                    Issue.record("Version-two fixture root must be an object"); continue
                }
                #expect(object.count == Int(try #require(workload.dimensions["width"])))
                var leaves = try #require(object["field000"])
                for _ in 2..<depth {
                    guard case .array(let items) = leaves else {
                        Issue.record("Version-two nested container missing"); break
                    }
                    #expect(items.count == 1)
                    leaves = try #require(items.first)
                }
                guard case .array(let strings) = leaves else {
                    Issue.record("Version-two string array missing"); continue
                }
                #expect(strings.count == Int(try #require(workload.dimensions["stringLeaves"])))
                for leaf in strings {
                    guard case .string(let text) = leaf else { Issue.record("Nonstring fixture leaf"); continue }
                    let quotes = text.utf8.filter { $0 == 34 }.count
                    let encodedContentBytes = text.utf8.count + quotes
                    let percentage = Int(try #require(workload.dimensions["escapePercent"]))
                    #expect(quotes == encodedContentBytes * percentage / 100 / 2)
                    #expect(text.contains("\"") == (percentage != 0))
                    #expect(text.contains("雪🐶") == (workload.dimensions["unicode"] == 1))
                }
                #expect(try workload.operation(UInt64(variant)) == workload.expected(UInt64(variant)))
            }
            for input in [UInt64(4), 63, UInt64.max] {
                #expect(try workload.operation(input) == workload.expected(input))
            }
        }
        #expect(changed == Set(varying))
    }

    /// Resolving every old JSON identity retains its exact fixture bytes, dimensions and expected observations.
    /// - Throws: Construction/selection errors; this guards against silently reusing old names for new shapes.
    @Test func oldJSONIdentitiesKeepExactFixtures() throws {
        let old = try JSONWorkloads.make()
        #expect(old.count == 17)
        for legacy in old {
            let selected = try FoundationWorkloads.selected(legacy.id)
            #expect(selected.fixture == legacy.fixture && selected.dimensions == legacy.dimensions)
            #expect(try selected.operation(3) == legacy.expected(3))
        }
    }

    /// Varies numeric density and key length at fixed document bytes, root width, depth and string count.
    /// - Throws: Missing dimensions, fixture selection or parser/operation errors.
    /// Every exact numeric spelling and literal key length is inspected; version-two case selection stays byte-identical.
    @Test func densityControlsHaveIndependentExactOracles() throws {
        let workloads = try JSONDimensionWorkloads.makeDensityControls()
        #expect(workloads.count == 10 && Set(workloads.map(\.id)).count == 10)
        let baseline = try #require(workloads.first)
        let varying = ["numericLeaves", "variableKeyBytes"]
        var changed: Set<String> = []
        for workload in workloads {
            let differences = varying.filter { workload.dimensions[$0] != baseline.dimensions[$0] }
            #expect(differences.count <= 1)
            changed.formUnion(differences)
            for fixed in ["payloadBytes", "depth", "width", "stringLeaves", "variants"] {
                #expect(workload.dimensions[fixed] == baseline.dimensions[fixed])
            }
            let keyBytes = Int(try #require(workload.dimensions["variableKeyBytes"]))
            let numbers = Int(try #require(workload.dimensions["numericLeaves"])) - 1
            try workload.verify()
            #expect(workload.fixture.count == 16_384 * 4)
            for variant in 0..<4 {
                let source = workload.fixture.subdata(in: (variant * 16_384)..<((variant + 1) * 16_384))
                guard case .object(let object) = try JSONValue.parse(source) else {
                    Issue.record("Density fixture root must be an object"); continue
                }
                #expect(object.count == 4)
                let variableKeys = object.keys.filter { $0 != "a_variant" }.sorted()
                #expect(variableKeys.count == 3 && variableKeys.allSatisfy { $0.utf8.count == keyBytes })
                guard case .array(let leaves) = object["b" + String(repeating: "x", count: keyBytes - 1)],
                      case .array(let numeric) = object["c" + String(repeating: "x", count: keyBytes - 1)],
                      case .string(let padding) = object["d" + String(repeating: "x", count: keyBytes - 1)] else {
                    Issue.record("Density fixture arrays or padding missing"); continue
                }
                #expect(leaves == Array(repeating: .string(String(repeating: "x", count: 32)), count: 16))
                #expect(!padding.isEmpty && padding.utf8.allSatisfy { $0 == 120 })
                #expect(numeric.count == numbers)
                let lexemes = ["18446744073709551616", "1.2300e+900", "-0", "9007199254740993"]
                for (index, value) in numeric.enumerated() {
                    guard case .number(let token) = value else { Issue.record("Nonnumeric density leaf"); continue }
                    #expect(token.rawValue == lexemes[(index + variant) % 4])
                }
                #expect(try workload.operation(UInt64(variant)) == workload.expected(UInt64(variant)))
            }
            let selected = try FoundationWorkloads.selected(workload.id)
            #expect(selected.fixture == workload.fixture && selected.dimensions == workload.dimensions)
        }
        #expect(changed == Set(varying))
        for original in try JSONDimensionWorkloads.make() {
            let selected = try FoundationWorkloads.selected(original.id)
            #expect(selected.fixture == original.fixture && selected.dimensions == original.dimensions)
        }
    }
}
