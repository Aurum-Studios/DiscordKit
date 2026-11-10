// File: Tools/DiscordFoundationBenchmarks/Tests/DiscordFoundationBenchmarksTests/ModelBuilderWorkloadTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordCore
import DiscordModels
import Foundation
import Testing
@testable import DiscordFoundationBenchmarks

/// Independent wire checks accompany every operation's checksum and complete semantic verification.
@Suite struct ModelBuilderWorkloadTests {
    /// Every prepared variant, including wrapping indexes, produces its independently prepared observable result.
    /// Runs full untimed verification for nineteen model/builder cases, then checks distinct checksums and exact
    /// rejection counts at ordinary and `UInt64.max` indexes. All work is synchronous and local; there are no timing
    /// thresholds, shared mutable fixtures, live Discord requests, credentials or resources needing cleanup.
    /// - Throws: Fixture setup/operation/semantic errors; unexpected errors fail the test instead of counting as rejections.
    @Test func workloadChecksumsAndSemanticVerification() throws {
        let models = try ModelWorkloads.make()
        let builders = try BuilderWorkloads.make()
        #expect(models.count == 9)
        #expect(builders.count == 10)
        #expect(Set((models + builders).map(\.id)).count == 19)
        for workload in models + builders {
            try workload.verify()
            #expect(Set((0..<4).map { workload.expected(UInt64($0)).checksum }).count == 4)
            for index in [UInt64(0), 1, 2, 3, 4, 15, UInt64.max] {
                let actual = try workload.operation(index)
                #expect(actual == workload.expected(index), "Unexpected result for \(workload.id), variant \(index % 4)")
                #expect(actual.rejections == (workload.id.hasPrefix("builder.reject.") ? 1 : 0))
            }
        }
    }

    /// Fixtures retain all three optional-field states, future numeric spelling and a fetched complete reference.
    /// Payload growth is proved from actual per-operation documents, not workload names.
    /// Projects every variant from canonical fixture arrays under default JSON limits and checks exact numeric tokens,
    /// complete round trips, typed fields, four unique IDs and monotonic size scaling across the three profiles.
    /// This synchronous offline test allocates complete trees for independent assertions and performs no timed measurement.
    /// - Throws: JSON/model errors or failed required-value expectations when a fixture/dimension is missing or invalid.
    @Test func modelWirePresencePrecisionAndSizeScaling() throws {
        let workloads = try ModelWorkloads.make().filter { $0.id.hasPrefix("model.message.decode.") }
        var maxima: [Int] = []
        for workload in workloads {
            guard case .array(let variants) = try JSONValue.parse(workload.fixture) else {
                Issue.record("Model fixture is not a variant array"); continue
            }
            #expect(variants.count == 4)
            var sizes: [Int] = []
            var ids = Set<UInt64>()
            for (variant, value) in variants.enumerated() {
                let data = try value.serialized()
                let message = try Message(data: data)
                ids.insert(message.id.rawValue)
                sizes.append(data.count)
                #expect(message.channelID.rawValue == UInt64.max)
                #expect(message.editedTimestamp == .null)
                #expect(message.author.avatar == .null)
                #expect(message.author.discriminator == .absent)
                #expect(message.author.rawFields["future_author"] == .number(try JSONNumber(rawValue: "9007199254740993")))
                #expect(message.nonce == .value(.integer(try JSONNumber(rawValue: "123456789012345678901234567890\(variant)"))))
                #expect(message.mentions.count == Int(try #require(workload.dimensions["mentions"])))
                #expect(message.embeds.count == Int(try #require(workload.dimensions["embeds"])))
                let exact = try #require(message.rawFields["future_exact"])
                #expect(try Self.onlyNumericLeaf(exact) == "-0.00000000000000000012300e-1000")
                #expect(try Message(data: message.jsonValue().serialized()).jsonValue() == value)
                switch variant {
                case 0:
                    #expect(message.referencedMessage == .absent)
                    #expect(message.author.globalName == .absent)
                case 1:
                    #expect(message.referencedMessage == .null)
                    #expect(message.author.globalName == .null)
                default:
                    guard case .value(let reference) = message.referencedMessage else {
                        Issue.record("Fetched message reference disappeared"); continue
                    }
                    #expect(reference.content == "Earlier reply \(variant)")
                    #expect(reference.referencedMessage == .absent)
                    #expect(message.author.globalName == .value("Display \(variant)"))
                }
                if variant == 3 {
                    #expect(message.type.rawValue == 999)
                    #expect(message.type.knownValue == nil)
                }
            }
            #expect(ids.count == 4)
            #expect(workload.dimensions["payload_bytes_min"] == UInt64(try #require(sizes.min())))
            #expect(workload.dimensions["payload_bytes_max"] == UInt64(try #require(sizes.max())))
            maxima.append(try #require(sizes.max()))
        }
        guard maxima.count == 3 else { Issue.record("Missing model size tier"); return }
        #expect(maxima[0] < maxima[1] && maxima[1] < maxima[2])
    }

    /// Expected wire fixtures independently satisfy public component grammar and exact global count/depth limits.
    /// Mention allowlists opt in one typed identity while disabling broad parsing and reply-author notifications.
    /// Validates all admitted legacy/V2 variants with the public component validator, checks visibility/V2 flag
    /// combinations and derives dimensions from serialized descendants/accessories. It checks authored policy only;
    /// no acknowledgement, transport, handler registration, permission lookup or notification delivery occurs.
    /// - Throws: Fixture JSON/model/grammar errors or failed required-dimension expectations. No elapsed-time assertions
    ///   or external mutable state make the test depend on execution order or other parallel tests.
    @Test func builderWireGrammarDimensionsAndSafeMentions() throws {
        let workloads = try BuilderWorkloads.make().filter { !$0.id.hasPrefix("builder.reject.") }
        for workload in workloads {
            guard case .array(let variants) = try JSONValue.parse(workload.fixture) else {
                Issue.record("Builder fixture is not a variant array"); continue
            }
            #expect(variants.count == 4)
            for (variant, value) in variants.enumerated() {
                guard case .object(let fields) = value, case .array(let componentValues) = fields["components"],
                      case .object(let mentions) = fields["allowed_mentions"] else {
                    Issue.record("Builder fixture omitted its wire policy or components"); continue
                }
                let v2 = workload.id.hasPrefix("builder.components.v2.")
                let components = try componentValues.map { try MessageComponent(jsonValue: $0) }
                try MessageComponent.validateMessage(components, componentsV2: v2)
                let dimensions = Self.componentDimensions(componentValues)
                #expect(dimensions.count == Int(try #require(workload.dimensions["component_nodes"])))
                #expect(dimensions.depth == Int(try #require(workload.dimensions["component_depth"])))
                #expect(dimensions.count <= 40)
                #expect(mentions["parse"] == .array([]))
                #expect(mentions["replied_user"] == .bool(false))
                #expect(mentions["users"] == .array([.string(String((v2 ? 500 : 400) + variant))]))
                #expect(mentions["roles"] == nil)
                let expectedFlags = UInt64(v2 ? 1 << 15 : 0) | (variant % 2 == 1 ? 64 : 0)
                if expectedFlags == 0 { #expect(fields["flags"] == nil) }
                else { #expect(fields["flags"] == .number(try JSONNumber(rawValue: String(expectedFlags)))) }
                if v2 {
                    #expect(fields["content"] == nil)
                    #expect(fields["embeds"] == nil)
                } else {
                    guard case .string(let content) = fields["content"] else {
                        Issue.record("Legacy builder fixture omitted content"); continue
                    }
                    #expect(content.unicodeScalars.count <= 2_000)
                    #expect(content.contains("<@\(400 + variant)>"))
                    #expect(content.split(separator: "\n").count == Int(try #require(workload.dimensions["text_contributions"])))
                    #expect(componentValues.count == Int(try #require(workload.dimensions["rows"])))
                }
            }
        }
    }

    /// Rejection descriptors retain actual invalid inputs and prove each boundary is exceeded by exactly one.
    /// Checks four distinct local variants per rejection family: sixty-five text contributions, forty-one nodes,
    /// six row buttons and exactly 2,001 Unicode scalars. This inspects setup descriptors independently of measured
    /// rejection checksums and does not attempt a Discord request, reserve a response or start asynchronous work.
    /// - Throws: Builder fixture setup, descriptor JSON/number errors or missing required-dimension expectations.
    @Test func builderRejectionsAreAtDeclaredBoundaries() throws {
        for workload in try BuilderWorkloads.make().filter({ $0.id.hasPrefix("builder.reject.") }) {
            let limit = try #require(workload.dimensions["declared_limit"])
            #expect(workload.dimensions["submitted_count"] == limit + 1)
            guard case .array(let variants) = try JSONValue.parse(workload.fixture) else {
                Issue.record("Missing rejection descriptors"); continue
            }
            #expect(variants.count == 4)
            #expect(Set(variants).count == 4)
            for value in variants {
                guard case .object(let descriptor) = value, case .array(let texts) = descriptor["texts"],
                      case .array(let buttons) = descriptor["buttons"], case .string(let kind) = descriptor["kind"] else {
                    Issue.record("Incomplete rejection descriptor"); continue
                }
                switch kind {
                case "message-contributions": #expect(texts.count == 65)
                case "row-width": #expect(buttons.count == 6)
                case "component-count":
                    #expect(texts.count == 1)
                    #expect(descriptor["separator_count"] == .number(try JSONNumber(rawValue: "40")))
                case "message-size":
                    guard case .string(let text) = texts.first else { Issue.record("Missing oversized text"); continue }
                    #expect(text.unicodeScalars.count == 2_001)
                default: Issue.record("Unexpected builder rejection kind")
                }
            }
        }
    }

    /// Finds the exact numeric token at the bottom of a prepared single-child unknown-field chain.
    /// - Parameter value: A local fixture number or a nonempty object chain with exactly one child per level;
    ///   fixture construction bounds the depth to sixteen, and arbitrary multi-child trees are outside this helper's contract.
    /// - Returns: The leaf's original numeric spelling without arithmetic interpretation, normalization or copying a full tree.
    /// - Throws: A failed required-value expectation for an empty object, or `FoundationBenchmarkError.integrityFailure`
    ///   for another leaf type. Recursion is synchronous, linear in the prepared depth and acquires no resources.
    private static func onlyNumericLeaf(_ value: JSONValue) throws -> String {
        switch value {
        case .number(let number): number.rawValue
        case .object(let fields): try onlyNumericLeaf(try #require(fields.values.first))
        default: throw FoundationBenchmarkError.integrityFailure("Unknown numeric fixture changed shape")
        }
    }

    /// Counts component descendants and section accessories using the serialized wire tree as an independent oracle.
    /// - Parameter values: Finite component JSON trees from bounded parsed fixtures. Nonobject entries and malformed
    ///   child-array fields are ignored; this helper computes dimensions while the public model separately validates grammar.
    /// - Returns: Total object-node count and maximum component depth, counting roots as depth one and an empty list
    ///   as `(0, 0)`. Each descendant/accessory is visited once, with temporary child arrays at each recursion level.
    ///   The helper is synchronous, read-only and local; it performs no serialization, timing, I/O or task creation.
    private static func componentDimensions(_ values: [JSONValue]) -> (count: Int, depth: Int) {
        var total = 0, maximum = 0
        for value in values {
            guard case .object(let fields) = value else { continue }
            total += 1
            var descendants: [JSONValue] = []
            if case .array(let children) = fields["components"] { descendants += children }
            if let accessory = fields["accessory"] { descendants.append(accessory) }
            let nested = componentDimensions(descendants)
            total += nested.count
            maximum = max(maximum, 1 + nested.depth)
        }
        return (total, maximum)
    }
}
