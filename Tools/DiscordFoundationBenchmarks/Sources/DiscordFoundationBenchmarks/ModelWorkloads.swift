// File: Tools/DiscordFoundationBenchmarks/Sources/DiscordFoundationBenchmarks/ModelWorkloads.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordCore
import DiscordModels
import Foundation

/// Message projection and lossless writing cases. Prepared inputs are shared across timed batches;
/// complete field, nullability and exact-number checks run before and after measurement.
enum ModelWorkloads {
    /// Builds four distinct messages for each size, then exposes independent decode, encode and round-trip cases.
    /// Encoding uses the model's supported lossless `jsonValue().serialized()` API, rather than Foundation Codable.
    /// Fixture construction, parsing and canonical encoding are synchronous setup work outside the returned timers;
    /// closures retain immutable inputs and acquire no transport, task or cancellation ownership.
    /// - Returns: Nine ordered cases across small, medium and large messages, each with four index-selected variants,
    ///   dimension metadata, a complete fingerprint document and an untimed full semantic verifier.
    /// - Throws: JSON syntax/limit or model projection errors if an authored fixture becomes invalid. No partial
    ///   workload array escapes; callers can report the setup failure without running measurements.
    static func make() throws -> [FoundationWorkload] {
        var workloads: [FoundationWorkload] = []
        for size in MessageBenchmarkSize.cases {
            let fixtures = try (0..<4).map { try MessageBenchmarkFixture(size: size, variant: $0) }
            let document = try JSONValue.array(fixtures.map { .object($0.fields) }).serialized()
            let dimensions: [String: UInt64] = [
                "fixture_variants": UInt64(fixtures.count),
                "payload_bytes_min": UInt64(fixtures.map(\.data.count).min() ?? 0),
                "payload_bytes_max": UInt64(fixtures.map(\.data.count).max() ?? 0),
                "mentions": UInt64(size.mentions), "embeds": UInt64(size.embeds),
                "unknown_fields": UInt64(size.unknownFields), "unknown_depth": UInt64(size.unknownDepth),
                "unicode": size.unicode ? 1 : 0
            ]
            let verify: () throws -> Void = {
                for fixture in fixtures { try fixture.verify() }
            }
            workloads.append(FoundationWorkload(id: "model.message.decode.\(size.name)", dimensions: dimensions,
                fixture: document, operation: { index in
                    let model = try Message(data: fixtures[Int(index % 4)].data)
                    return FoundationObservation(checksum: messageDecodeChecksum(model))
                }, expected: { fixtures[Int($0 % 4)].decodeObservation }, verify: verify))
            workloads.append(FoundationWorkload(id: "model.message.encode.\(size.name)", dimensions: dimensions,
                fixture: document, operation: { index in
                    let data = try fixtures[Int(index % 4)].model.jsonValue().serialized()
                    return FoundationObservation(checksum: messageEncodedChecksum(data))
                }, expected: { fixtures[Int($0 % 4)].encodeObservation }, verify: verify))
            workloads.append(FoundationWorkload(id: "model.field-unknown.roundtrip.\(size.name)", dimensions: dimensions,
                fixture: document, operation: { index in
                    let model = try Message(data: fixtures[Int(index % 4)].data)
                    let encoded = try model.jsonValue().serialized()
                    return FoundationObservation(checksum: messagePresenceChecksum(model) &+ messageEncodedChecksum(encoded))
                }, expected: { fixtures[Int($0 % 4)].roundtripObservation }, verify: verify))
        }
        return workloads
    }
}

/// Fixed input dimensions distinguish ordinary messages, richer messages and a substantial bounded response.
private struct MessageBenchmarkSize {
    let name: String
    let contentUnits: Int
    let mentions: Int
    let embeds: Int
    let embedFields: Int
    let unknownFields: Int
    let unknownDepth: Int
    let unicode: Bool

    static let cases: [MessageBenchmarkSize] = [
        .init(name: "small", contentUnits: 32, mentions: 0, embeds: 0, embedFields: 0,
            unknownFields: 1, unknownDepth: 1, unicode: false),
        .init(name: "medium", contentUnits: 256, mentions: 4, embeds: 2, embedFields: 3,
            unknownFields: 16, unknownDepth: 8, unicode: true),
        .init(name: "large", contentUnits: 900, mentions: 32, embeds: 10, embedFields: 6,
            unknownFields: 64, unknownDepth: 16, unicode: true)
    ]
}

/// Independently authored wire fields and expectations; setup parses and serializes before timing starts.
private struct MessageBenchmarkFixture {
    let fields: [String: JSONValue]
    let data: Data
    let model: Message
    let decodeObservation: FoundationObservation
    let encodeObservation: FoundationObservation
    let roundtripObservation: FoundationObservation
    let variant: Int
    let size: MessageBenchmarkSize

    /// Prepares an exact wire tree, its canonical bytes, a projected message and independent expected checksums.
    /// This setup deliberately allocates complete trees and reference copies before any measurement begins.
    /// - Parameters:
    ///   - size: One of the three fixed size profiles; its nonnegative widths and depth keep the complete document
    ///     within default JSON limits, including the optional fetched reference.
    ///   - variant: An internal index in `0...3`, varying IDs, content length, field presence and a future discriminator.
    /// - Throws: Exact-number, JSON serialization/bounds or message projection errors if fixture assumptions change.
    ///   Construction is synchronous, retains only immutable values and performs no I/O or response admission.
    init(size: MessageBenchmarkSize, variant: Int) throws {
        self.size = size
        self.variant = variant
        let id = UInt64(18_000_000_000_000_000_000) + UInt64(variant)
        let unit = size.unicode ? "é界" : "a"
        let content = String(repeating: unit, count: size.contentUnits) + String(repeating: "z", count: variant)
        let author = try Self.author(id: 17, name: "author", variant: variant)
        let mentions = try (0..<size.mentions).map {
            try Self.author(id: UInt64(100 + $0), name: "member\($0)", variant: variant)
        }
        let embeds = try (0..<size.embeds).map { index -> JSONValue in
            let rows = try (0..<size.embedFields).map { row -> JSONValue in
                .object(["name": .string("Metric \(row)"),
                    "value": .string(String(repeating: size.unicode ? "測定" : "value", count: 16)),
                    "inline": .bool(row % 2 == 0),
                    "future_fraction": .number(try JSONNumber(rawValue: "1.23000000000000000001e1000"))])
            }
            return .object(["title": .string("Report \(index)"), "type": .string("rich"),
                "description": .string(String(repeating: "bounded response ", count: 12)),
                "fields": .array(rows)])
        }
        var fields: [String: JSONValue] = [
            "id": .string(String(id)), "channel_id": .string("18446744073709551615"),
            "author": author, "content": .string(content),
            "timestamp": .string("2026-10-16T17:00:00.123456Z"), "edited_timestamp": .null,
            "tts": .bool(false), "mention_everyone": .bool(false), "mentions": .array(mentions),
            "mention_roles": .array([.string("999")]), "attachments": .array([]),
            "embeds": .array(embeds), "pinned": .bool(variant % 2 == 0),
            "type": .number(try JSONNumber(rawValue: variant == 3 ? "999" : "0")),
            "nonce": .number(try JSONNumber(rawValue: "123456789012345678901234567890\(variant)"))
        ]
        var unknown: JSONValue = .number(try JSONNumber(rawValue: "-0.00000000000000000012300e-1000"))
        for depth in 0..<size.unknownDepth { unknown = .object(["level\(depth)": unknown]) }
        fields["future_exact"] = unknown
        if size.unknownFields > 1 {
            for index in 1..<size.unknownFields {
                fields["future_\(index)"] = .object(["enabled": .bool(index % 2 == 0),
                    "label": .string("future \(variant) \(index)"), "empty": .array([])])
            }
        }
        switch variant {
        case 0: break
        case 1: fields["referenced_message"] = .null
        default:
            var reference = fields
            reference["id"] = .string(String(id - 100))
            reference["content"] = .string("Earlier reply \(variant)")
            // A fetched reference is a complete message with an absent reference of its own.
            fields["referenced_message"] = .object(reference)
        }
        self.fields = fields
        data = try JSONValue.object(fields).serialized()
        model = try Message(data: data)
        // Expectations come from the authored wire shape, rather than running the measured operations.
        let decode = id &+ UInt64(fields.count) &+ (UInt64(size.mentions) << 8) &+ (UInt64(size.embeds) << 16)
        let encoded = messageEncodedChecksum(data)
        let presence = id &+ UInt64(Self.presenceCode(variant)) &+ (UInt64(size.unknownFields) << 8)
        decodeObservation = FoundationObservation(checksum: decode)
        encodeObservation = FoundationObservation(checksum: encoded)
        roundtripObservation = FoundationObservation(checksum: presence &+ encoded)
    }

    /// Authors a minimal message-specific user with a nullable avatar and an exact future integer field.
    /// The returned tree is fixture setup data; the public model later validates it without a user lookup.
    /// - Parameters:
    ///   - id: Complete unsigned snowflake, written as a decimal string without numeric rounding.
    ///   - name: Finite local username text; fixture callers provide short nonempty names.
    ///   - variant: A fixed index in `0...3`; zero omits `global_name`, one writes null and two/three write a value.
    /// - Returns: An author object preserving the selected presence state and the integer token `9007199254740993`.
    /// - Throws: `JSONValueError` if the fixed future integer token can no longer be constructed.
    private static func author(id: UInt64, name: String, variant: Int) throws -> JSONValue {
        var fields: [String: JSONValue] = ["id": .string(String(id)), "username": .string(name),
            "avatar": .null, "future_author": .number(try JSONNumber(rawValue: "9007199254740993"))]
        if variant == 1 { fields["global_name"] = .null }
        if variant >= 2 { fields["global_name"] = .string("Display \(variant)") }
        return .object(fields)
    }

    /// Computes the independent expected contribution from the reference and author-name presence states.
    /// - Parameter variant: Prepared variant index in `0...3`; its two fields share the same absent/null/value state.
    /// - Returns: The reference code plus three times the name code, using distinct codes 2, 5 and 11.
    ///   This constant setup calculation neither accesses model results nor performs I/O.
    private static func presenceCode(_ variant: Int) -> Int {
        switch variant {
        case 0: 2 + 3 * 2
        case 1: 5 + 3 * 5
        default: 11 + 3 * 11
        }
    }

    /// Checks the entire original tree as well as typed fields and the semantics of all three presence states.
    /// Reconstructs and serializes complete models outside timing, including nested unknown numbers and references.
    /// The check is synchronous and owns only temporary local values; it does not suspend or support mid-parse cancellation.
    /// - Throws: `FoundationBenchmarkError.integrityFailure` for changed semantics/checksums, or JSON/model errors
    ///   when a previously prepared fixture can no longer be projected or written. Failure aborts the enclosing run.
    func verify() throws {
        let decoded = try Message(data: data)
        guard decoded.rawFields == fields, decoded.jsonValue() == .object(fields),
              try Message(data: decoded.jsonValue().serialized()) == decoded,
              decoded.channelID.rawValue == UInt64.max, decoded.editedTimestamp == .null,
              decoded.mentions.count == size.mentions, decoded.embeds.count == size.embeds,
              decoded.author.rawFields["future_author"] == .number(try JSONNumber(rawValue: "9007199254740993")),
              decoded.nonce == .value(.integer(try JSONNumber(rawValue: "123456789012345678901234567890\(variant)"))),
              decoded.rawFields["future_exact"] == fields["future_exact"],
              messageDecodeChecksum(decoded) == decodeObservation.checksum,
              messagePresenceChecksum(decoded) &+ messageEncodedChecksum(data) == roundtripObservation.checksum
        else { throw FoundationBenchmarkError.integrityFailure("Message model changed its known or unknown fields") }
        switch variant {
        case 0:
            guard decoded.referencedMessage == .absent, decoded.author.globalName == .absent
            else { throw FoundationBenchmarkError.integrityFailure("Absent model fields became present") }
        case 1:
            guard decoded.referencedMessage == .null, decoded.author.globalName == .null
            else { throw FoundationBenchmarkError.integrityFailure("Explicit model null became absent") }
        default:
            guard case .value(let reference) = decoded.referencedMessage,
                  reference.content == "Earlier reply \(variant)", reference.referencedMessage == .absent,
                  decoded.author.globalName == .value("Display \(variant)")
            else { throw FoundationBenchmarkError.integrityFailure("Present model fields changed") }
        }
        if variant == 3 {
            guard decoded.type.rawValue == 999, decoded.type.knownValue == nil
            else { throw FoundationBenchmarkError.integrityFailure("Unknown message discriminator was normalized") }
        }
    }
}

/// Consumes a few typed results without placing complete semantic equality checks inside the measurement.
/// - Parameter model: A successfully projected benchmark message; IDs and collection counts are already validated.
/// - Returns: A wrapping sum of the complete unsigned ID, root field count and shifted mention/embed counts.
///   Reads a fixed number of immutable properties without serializing, traversing nested fields or performing I/O.
private func messageDecodeChecksum(_ model: Message) -> UInt64 {
    model.id.rawValue &+ UInt64(model.rawFields.count) &+ (UInt64(model.mentions.count) << 8) &+ (UInt64(model.embeds.count) << 16)
}

/// Data count and endpoint bytes make serialization observable; complete tree equality is checked outside timing.
/// - Parameter data: Canonical serialized message bytes. Empty data is accepted and contributes zero endpoint bytes.
/// - Returns: A wrapping sum of byte count and shifted first/last bytes, using constant-sized collection reads.
///   This deliberately small checksum is not a content digest or a substitute for the untimed semantic verifier.
private func messageEncodedChecksum(_ data: Data) -> UInt64 {
    UInt64(data.count) &+ (UInt64(data.first ?? 0) << 8) &+ (UInt64(data.last ?? 0) << 16)
}

/// Distinct omitted/null/value codes make presence projection observable without comparing retained JSON trees.
/// - Parameter model: A message from this file's fixture factory: fifteen base known fields, an optional
///   `referenced_message` and only the declared future sibling fields. Other shapes violate this private helper's assumptions.
/// - Returns: A wrapping ID/presence/unknown-count sum. Root dictionary counts and two field discriminants are read;
///   nested unknown trees are preserved by the measured model/writer and checked fully by the untimed verifier.
///   The helper is synchronous, does not mutate retained values and acquires no external resources.
private func messagePresenceChecksum(_ model: Message) -> UInt64 {
    let reference: UInt64
    switch model.referencedMessage { case .absent: reference = 2; case .null: reference = 5; case .value: reference = 11 }
    let name: UInt64
    switch model.author.globalName { case .absent: name = 2; case .null: name = 5; case .value: name = 11 }
    // The unknown field count is fixed by the prepared input, but read from the actual retained model.
    let unknownCount = model.rawFields.count - 15 - (reference == 2 ? 0 : 1)
    return model.id.rawValue &+ reference &+ (3 * name) &+ (UInt64(unknownCount) << 8)
}
