// File: Tools/DiscordFoundationBenchmarks/Sources/DiscordFoundationBenchmarks/BuilderWorkloads.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordCommandDSL
import DiscordCore
import DiscordDSL
import DiscordModels
import Foundation

/// Bounded, offline authoring workloads using the public message and component builders.
/// Prepared strings, safe templates and rich models are outside timing; construction, validation and a
/// small public JSON projection for checksum consumption are included in each measured operation.
enum BuilderWorkloads {
    /// Covers legacy row width, V2 layout width/depth, text contributions and deterministic admission failures.
    /// Creates safe text templates, embeds, expected wire trees and invalid-input descriptors before timing.
    /// Returned operations construct/validate responses synchronously; their public JSON projection/checksum cost
    /// is included in the measured batch, while complete expected-tree comparisons remain in `verify`.
    /// - Returns: Ten ordered cases: three admitted legacy sizes, three admitted V2 sizes and four exact limit
    ///   rejections. Each case retains four immutable variants and performs no transport or acknowledgement work.
    /// - Throws: Safe-content, exact-number, JSON serialization/limit or model errors if setup inputs become invalid.
    ///   No partial case array escapes and no tasks, registrations or external resources require cleanup.
    static func make() throws -> [FoundationWorkload] {
        var workloads: [FoundationWorkload] = []
        for size in BuilderBenchmarkSize.cases {
            let legacy = try (0..<4).map { try LegacyBuilderFixture(size: size, variant: $0) }
            let legacyFixture = try JSONValue.array(legacy.map(\.expectedJSON)).serialized()
            workloads.append(FoundationWorkload(id: "builder.message.legacy.\(size.name)", dimensions: [
                "fixture_variants": 4, "text_contributions": UInt64(size.texts), "embeds": UInt64(size.embeds),
                "rows": UInt64(size.rows), "buttons_per_row": UInt64(size.buttons),
                "component_nodes": UInt64(size.rows * (1 + size.buttons)), "component_depth": 2,
                "unicode": size.unicode ? 1 : 0
            ], fixture: legacyFixture, operation: { index in
                let response = try legacy[Int(index % 4)].build()
                return FoundationObservation(checksum: try legacyBuilderChecksum(response))
            }, expected: { legacy[Int($0 % 4)].observation }, verify: {
                for fixture in legacy {
                    guard try fixture.build().message.jsonValue() == fixture.expectedJSON
                    else { throw FoundationBenchmarkError.integrityFailure("Legacy builder changed field order or mention policy") }
                }
            }))

            let layouts = try (0..<4).map { try V2BuilderFixture(size: size, variant: $0) }
            let layoutFixture = try JSONValue.array(layouts.map(\.expectedJSON)).serialized()
            workloads.append(FoundationWorkload(id: "builder.components.v2.\(size.name)", dimensions: [
                "fixture_variants": 4, "sections": UInt64(size.sections),
                "text_displays_per_section": UInt64(size.displays),
                "component_nodes": UInt64(1 + size.sections * (2 + size.displays)),
                "component_depth": 3, "unicode": size.unicode ? 1 : 0
            ], fixture: layoutFixture, operation: { index in
                let response = try layouts[Int(index % 4)].build()
                return FoundationObservation(checksum: try v2BuilderChecksum(response))
            }, expected: { layouts[Int($0 % 4)].observation }, verify: {
                for fixture in layouts {
                    guard try fixture.build().message.jsonValue() == fixture.expectedJSON
                    else { throw FoundationBenchmarkError.integrityFailure("V2 builder changed layout, flags or mention policy") }
                }
            }))
        }
        for rejection in BuilderRejectionKind.allCases {
            let fixtures = try (0..<4).map { try BuilderRejectionFixture(kind: rejection, variant: $0) }
            let document = try JSONValue.array(fixtures.map(\.inputJSON)).serialized()
            workloads.append(FoundationWorkload(id: "builder.reject.\(rejection.rawValue)", dimensions: [
                "fixture_variants": 4, "rejections_per_operation": 1, "declared_limit": UInt64(rejection.limit),
                "submitted_count": UInt64(rejection.submitted)
            ], fixture: document, operation: { index in
                try fixtures[Int(index % 4)].reject()
            }, expected: { fixtures[Int($0 % 4)].observation }, verify: {
                for fixture in fixtures {
                    guard try fixture.reject() == fixture.observation
                    else { throw FoundationBenchmarkError.integrityFailure("Builder rejection accounting changed") }
                }
            }))
        }
        return workloads
    }
}

/// Fixed admitted dimensions stay within Discord's five rows/five buttons and forty V2 nodes.
private struct BuilderBenchmarkSize {
    let name: String
    let texts: Int
    let embeds: Int
    let rows: Int
    let buttons: Int
    let sections: Int
    let displays: Int
    let unicode: Bool

    static let cases: [BuilderBenchmarkSize] = [
        .init(name: "small", texts: 1, embeds: 0, rows: 1, buttons: 1, sections: 1, displays: 1, unicode: false),
        .init(name: "medium", texts: 8, embeds: 1, rows: 3, buttons: 3, sections: 4, displays: 2, unicode: true),
        .init(name: "large", texts: 32, embeds: 3, rows: 5, buttons: 5, sections: 7, displays: 3, unicode: true)
    ]
}

/// Immutable button inputs; factories and final contextual validation remain part of the operation.
private struct BenchmarkButton {
    let label: String
    let id: String

    /// Builds an independent expected primary-button tree without invoking the component builder under measurement.
    /// Label/custom-ID validation remains with the public model when the containing fixture is checked.
    /// - Returns: An enabled primary button with exact numeric type/style tokens and the stored label/identity.
    ///   The small dictionary is allocated synchronously during setup, with no handler registration or I/O.
    /// - Throws: `JSONValueError` if either fixed integer token can no longer be constructed.
    func jsonValue() throws -> JSONValue {
        .object(["type": try builderNumber(2), "style": try builderNumber(1),
            "label": .string(label), "custom_id": .string(id), "disabled": .bool(false)])
    }
}

/// A message combines finite text, prebuilt embeds and a legacy component grid with an explicit typed-user allowlist.
private struct LegacyBuilderFixture {
    let texts: [MessageContent]
    let embeds: [MessageEmbed]
    let rows: [[BenchmarkButton]]
    let ephemeral: Bool
    let expectedJSON: JSONValue
    let observation: FoundationObservation

    /// Prepares a legacy message's text/typed mention, rich models, unique button grid and independent wire result.
    /// All source/template and embed construction happens before timing; the final message builder is deferred to `build`.
    /// - Parameters:
    ///   - size: A fixed profile with 1/8/32 text contributions, 0/1/3 embeds and at most five rows of five buttons.
    ///     These profiles stay within message content, aggregate embed and sixty-four-contribution limits.
    ///   - variant: An index in `0...3`, varying explicit user ID, finite text suffix, button identities and visibility.
    /// - Throws: JSON-number or embed-model validation errors if a prepared expectation becomes invalid.
    ///   Setup is synchronous and retains only inert values; it does not reserve a Discord response or open resources.
    init(size: BuilderBenchmarkSize, variant: Int) throws {
        let user = UserID(rawValue: UInt64(400 + variant))
        ephemeral = variant % 2 == 1
        let suffix = String(repeating: "x", count: variant)
        var rendered = ["Status <@\(user.rawValue)>" + suffix]
        var texts: [MessageContent] = ["Status \(user: user)\(raw: suffix)"]
        for index in 1..<size.texts {
            let text = size.unicode ? "Snapshot \(index) 測定 café" : "Snapshot \(index)"
            rendered.append(text)
            texts.append(MessageContent(text))
        }
        self.texts = texts
        embeds = try (0..<size.embeds).map {
            try MessageEmbed(title: "Report \($0)", description: "Finite local fixture \(variant)")
        }
        rows = (0..<size.rows).map { row in
            (0..<size.buttons).map { column in
                BenchmarkButton(label: "Choice \(row) \(column)" + suffix, id: "v\(variant)-r\(row)-c\(column)")
            }
        }
        let content = rendered.joined(separator: "\n")
        var expected: [String: JSONValue] = ["content": .string(content),
            "allowed_mentions": benchmarkMentionPolicy(user),
            "components": .array(try rows.map { .object(["type": try builderNumber(1),
                "components": .array(try $0.map { try $0.jsonValue() })]) })]
        if !embeds.isEmpty { expected["embeds"] = .array(embeds.map { $0.jsonValue() }) }
        if ephemeral { expected["flags"] = try builderNumber(64) }
        expectedJSON = .object(expected)
        observation = FoundationObservation(checksum: UInt64(expected.count) &+ UInt64(content.utf8.count)
            &+ (UInt64(size.embeds) << 16) &+ (UInt64(size.rows) << 24) &+ (ephemeral ? 64 : 0))
    }

    /// Constructs and validates one legacy response in source order from the prepared text, embeds and button rows.
    /// Safe templates render during lowering, deriving one explicit user allowlist with broad parsing disabled.
    /// - Returns: A complete JSON-only immediate-message value with the fixture's public/ephemeral visibility.
    ///   The operation includes builder lowering and existing model/JSON budget validation, with no network request,
    ///   acknowledgement, task, registration or resource ownership; it is safe to repeat on the same immutable fixture.
    /// - Throws: Safe-content, JSON limit or model validation errors for unexpected fixture/implementation changes.
    func build() throws -> MessageResponse {
        try MessageResponse(visibility: ephemeral ? .ephemeral : .public) {
            for text in texts { Text(text) }
            for embed in embeds { Embed(embed) }
            Components(mode: .legacy) {
                for row in rows {
                    Component.actionRow {
                        for button in row { Component.button(button.label, customID: button.id) }
                    }
                }
            }
        }
    }
}

/// Prepared display templates retain their safe typed mention segments until the timed builder lowers them.
private struct V2BenchmarkSection {
    let displays: [MessageContent]
    let button: BenchmarkButton
    let expectedJSON: JSONValue
}

/// V2 container/section layouts exercise depth three and aggregate mention deduplication across display nodes.
private struct V2BuilderFixture {
    let sections: [V2BenchmarkSection]
    let color: Int
    let ephemeral: Bool
    let expectedJSON: JSONValue
    let observation: FoundationObservation

    /// Prepares a depth-three container/section layout and its independent expected flags, mentions and wire tree.
    /// Each section has one unique accessory button; repeated typed-user displays must deduplicate to one allowlisted ID.
    /// - Parameters:
    ///   - size: A fixed profile with 1/4/7 sections and 1/2/3 displays per section, yielding at most 36 total nodes.
    ///     Section width and total nodes remain within the public component grammar's three/forty bounds.
    ///   - variant: A fixed index in `0...3`, varying display content, IDs, RGB color and public/ephemeral visibility.
    /// - Throws: Exact-number construction errors while preparing expected wire tokens. Setup allocates only finite,
    ///   immutable authoring data, runs outside timers and performs no I/O, handler registration or acknowledgement.
    init(size: BuilderBenchmarkSize, variant: Int) throws {
        let user = UserID(rawValue: UInt64(500 + variant))
        color = 0x123450 + variant
        ephemeral = variant % 2 == 1
        let suffix = String(repeating: "x", count: variant)
        sections = try (0..<size.sections).map { section in
            let button = BenchmarkButton(label: "Details \(section)" + suffix, id: "v\(variant)-section\(section)")
            let rendered = (0..<size.displays).map { display in
                let prefix = size.unicode ? "測定 café \(section) \(display)" : "View \(section) \(display)"
                return prefix + " <@\(user.rawValue)>" + suffix
            }
            let displays: [MessageContent] = (0..<size.displays).map { display in
                let prefix = size.unicode ? "測定 café \(section) \(display)" : "View \(section) \(display)"
                return "\(raw: prefix) \(user: user)\(raw: suffix)"
            }
            return V2BenchmarkSection(displays: displays, button: button, expectedJSON: .object([
                "type": try builderNumber(9), "accessory": try button.jsonValue(),
                "components": .array(try rendered.map { .object(["type": try builderNumber(10), "content": .string($0)]) })
            ]))
        }
        let flags: UInt64 = (1 << 15) | (ephemeral ? 64 : 0)
        expectedJSON = .object(["allowed_mentions": benchmarkMentionPolicy(user),
            "flags": .number(try JSONNumber(rawValue: String(flags))),
            "components": .array([.object(["type": try builderNumber(17),
                "accent_color": .number(try JSONNumber(rawValue: String(color))), "spoiler": .bool(false),
                "components": .array(sections.map(\.expectedJSON))])])])
        observation = FoundationObservation(checksum: UInt64(color) &+ flags &+ 3)
    }

    /// Lowers one explicit V2 container with ordered sections, display templates and accessory buttons.
    /// The existing builder/model enforces layout, identity uniqueness, aggregate mentions and complete JSON budgets.
    /// - Returns: A validated JSON-only immediate response setting the V2 flag plus the fixture's visibility flag.
    ///   Repeated synchronous calls share immutable inputs but construct independent results and start no tasks,
    ///   handlers, transport activity or acknowledgement ownership.
    /// - Throws: Safe-content, JSON-budget or public model validation errors if an admitted fixture stops being valid.
    func build() throws -> MessageResponse {
        try MessageResponse(visibility: ephemeral ? .ephemeral : .public) {
            Components(mode: .v2) {
                Component.container(accentColor: color) {
                    for section in sections {
                        Component.section(accessory: .button(section.button.label, customID: section.button.id)) {
                            for text in section.displays { Component.textDisplay(text) }
                        }
                    }
                }
            }
        }
    }
}

/// Public limits whose complete-message constructors must reject the entire authored request.
private enum BuilderRejectionKind: String, CaseIterable {
    case messageContributions = "message-contributions"
    case componentCount = "component-count"
    case rowWidth = "row-width"
    case messageSize = "message-size"

    /// Inclusive public bound for the selected admission rule, expressed in contributions, nodes, buttons or scalars.
    /// This constant lookup neither constructs a declaration nor runs validation.
    var limit: Int {
        switch self { case .messageContributions: 64; case .componentCount: 40; case .rowWidth: 5; case .messageSize: 2_000 }
    }
    /// Exact finite input count, one above the selected public bound; setup keeps every rejection at that boundary.
    var submitted: Int { limit + 1 }
}

/// Setup retains all finite invalid inputs; only the authoring/validation attempt and error classification are timed.
private struct BuilderRejectionFixture {
    let kind: BuilderRejectionKind
    let texts: [MessageContent]
    let buttons: [BenchmarkButton]
    let separatorCount: Int
    let inputJSON: JSONValue
    let observation: FoundationObservation

    /// Retains one finite invalid declaration and a complete descriptor without attempting its final message builder.
    /// Message-size variants have exactly 2,001 Unicode scalars; the other rules submit 65 contributions,
    /// 41 components or six row buttons. All source rendering used for fingerprinting occurs before measurement.
    /// - Parameters:
    ///   - kind: The single public bound to exceed; unrelated field/layout inputs remain valid.
    ///   - variant: An index in `0...3`, varying actual text/button inputs while preserving the exact offending count.
    /// - Throws: Safe-content rendering or exact-number construction errors while preparing descriptor data.
    ///   Construction is synchronous and inert, with no handler, response, transport or cleanup ownership.
    init(kind: BuilderRejectionKind, variant: Int) throws {
        self.kind = kind
        let suffix = String(repeating: "x", count: variant)
        switch kind {
        case .messageContributions:
            texts = (0..<kind.submitted).map { MessageContent("Fragment \($0)" + suffix) }
            buttons = []; separatorCount = 0
        case .componentCount:
            texts = [MessageContent("Overflow" + suffix)]; buttons = []; separatorCount = kind.submitted - 1
        case .rowWidth:
            texts = []
            buttons = (0..<kind.submitted).map { BenchmarkButton(label: "Choice \($0)" + suffix, id: "v\(variant)-\($0)") }
            separatorCount = 0
        case .messageSize:
            texts = [MessageContent(String(repeating: variant % 2 == 0 ? "a" : "界", count: kind.submitted - variant) + suffix)]
            buttons = []; separatorCount = 0
        }
        inputJSON = .object(["kind": .string(kind.rawValue),
            "submitted_count": try builderNumber(UInt64(kind.submitted)),
            "variant": try builderNumber(UInt64(variant)),
            "texts": .array(try texts.map { .string(try $0.render().content) }),
            "buttons": .array(try buttons.map { try $0.jsonValue() }),
            "separator_count": try builderNumber(UInt64(separatorCount)),
            "suffix": .string(suffix)])
        observation = FoundationObservation(checksum: UInt64(kind.submitted + variant), rejections: 1)
    }

    /// Attempts the prepared complete-message builder and classifies only its specifically expected validation error.
    /// Count/layout overflow expects `invalidValue`; the 2,001-scalar message expects `limitExceeded`.
    /// - Returns: The variant's observable checksum with exactly one rejection after the expected failure.
    ///   Error classification and builder admission are included in timing; no response is submitted and the immutable
    ///   fixture can be retried without cleanup, actor suspension or cancellation ownership.
    /// - Throws: `FoundationBenchmarkError.integrityFailure` if the invalid input is admitted. Any unexpected
    ///   safe-content/JSON/model error propagates rather than being counted as the intended rejection.
    func reject() throws -> FoundationObservation {
        do {
            switch kind {
            case .messageContributions, .messageSize:
                _ = try MessageResponse { for text in texts { Text(text) } }
            case .componentCount:
                _ = try MessageResponse {
                    Components(mode: .v2) {
                        Component.textDisplay(texts[0])
                        for index in 0..<separatorCount { Component.separator(divider: index % 2 == 0) }
                    }
                }
            case .rowWidth:
                _ = try MessageResponse {
                    Components(mode: .legacy) {
                        Component.actionRow { for button in buttons { Component.button(button.label, customID: button.id) } }
                    }
                }
            }
        } catch DiscordError.validation(.invalidValue) where kind != .messageSize {
            return observation
        } catch DiscordError.validation(.limitExceeded) where kind == .messageSize {
            return observation
        }
        throw FoundationBenchmarkError.integrityFailure("Builder admitted an input beyond its declared limit")
    }
}

/// Independently constructed mention JSON is shared by expected wire trees, never by timed builder lowering.
/// - Parameter user: The single typed-user identity expected in the prepared message's aggregate allowlist.
/// - Returns: A local expected policy disabling broad parsing/reply notifications and retaining that exact string ID.
///   The helper allocates a small tree during setup; it does not establish delivery permissions or send notifications.
private func benchmarkMentionPolicy(_ user: UserID) -> JSONValue {
    .object(["parse": .array([]), "users": .array([.string(user.description)]), "replied_user": .bool(false)])
}

/// Consumes the public projection's root, text length and aggregate counts, leaving full equality outside timing.
/// - Parameter response: An admitted legacy benchmark response with present text/components and optional embeds/flags.
/// - Returns: A wrapping sum of root width, content UTF-8 length, shifted embed/row counts and visibility flags.
///   The public `jsonValue` validation/projection and these few reads are deliberately included in measured work;
///   no full tree comparison or digest is performed here, and no external state is mutated.
/// - Throws: `FoundationBenchmarkError.integrityFailure` for missing observable fields, or public model errors
///   from the response projection. Failure aborts measurement rather than substituting a checksum.
private func legacyBuilderChecksum(_ response: MessageResponse) throws -> UInt64 {
    guard case .object(let fields) = try response.message.jsonValue(), case .string(let content) = fields["content"],
          case .array(let rows) = fields["components"]
    else { throw FoundationBenchmarkError.integrityFailure("Legacy builder omitted required observable fields") }
    let embeds: Int
    if case .array(let values) = fields["embeds"] { embeds = values.count } else { embeds = 0 }
    let flags: UInt64
    if case .value(let value) = response.message.flags { flags = value.rawValue } else { flags = 0 }
    return UInt64(fields.count) &+ UInt64(content.utf8.count) &+ (UInt64(embeds) << 16) &+ (UInt64(rows.count) << 24) &+ flags
}

/// Reads the varied public container color and flags without recursively comparing component content.
/// - Parameter response: An admitted V2 benchmark response whose first top-level component is its colored container.
/// - Returns: A wrapping sum of root width, exact RGB integer and full response flags. Public projection/validation
///   cost is included in timing; only the first container's color is read after projection and no I/O occurs.
/// - Throws: `FoundationBenchmarkError.integrityFailure` for a missing/malformed color, layout or flags, or model
///   errors from projection. These fail the run instead of being classified as expected admission rejections.
private func v2BuilderChecksum(_ response: MessageResponse) throws -> UInt64 {
    guard case .object(let fields) = try response.message.jsonValue(), case .array(let components) = fields["components"],
          case .object(let container) = components.first, case .number(let number) = container["accent_color"],
          let color = UInt64(number.rawValue), case .value(let flags) = response.message.flags
    else { throw FoundationBenchmarkError.integrityFailure("V2 builder omitted container color or flags") }
    return UInt64(fields.count) &+ color &+ flags.rawValue
}

/// Converts bounded unsigned fixture integers through the same exact-token type used by the wire model.
/// - Parameter value: A complete `UInt64`, converted to canonical unsigned decimal without a floating-point bridge.
/// - Returns: The exact numeric JSON value, allocated synchronously for setup/expected trees without model validation.
/// - Throws: `JSONValueError` if canonical unsigned decimal unexpectedly fails the exact-number grammar.
private func builderNumber(_ value: UInt64) throws -> JSONValue {
    .number(try JSONNumber(rawValue: String(value)))
}
