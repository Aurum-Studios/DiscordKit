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
}
