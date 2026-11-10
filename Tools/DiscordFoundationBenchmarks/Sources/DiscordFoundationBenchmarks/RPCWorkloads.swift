// File: Tools/DiscordFoundationBenchmarks/Sources/DiscordFoundationBenchmarks/RPCWorkloads.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordRPC
import Foundation

/// Opaque IPC framing CPU work uses prepared bytes and never opens a desktop connection.
enum RPCWorkloads {
    /// Covers three payload scales, split headers/bodies and exact bounded rejection paths.
    /// - Returns: Seventeen cases: three encoders, nine incremental decoders and five distinct rejection paths,
    ///   each selecting among four prepared immutable variants by the operation's input modulo four.
    /// - Throws: No protocol errors during setup; the returned operation/verification closures propagate unexpected
    ///   framing errors and verification failures when executed.
    /// Payload generation, independent wire headers and fragmentation allocations precede timing. This factory
    /// neither opens IPC resources nor creates tasks; it models synchronous RPC v1 framing CPU work only.
    static func make() throws -> [FoundationWorkload] {
        var result: [FoundationWorkload] = []
        for size in [1_024, 16_384, 262_144] {
            let fixtures = prepare(size: size)
            result.append(encode(fixtures: fixtures, size: size))
            for fragment in [7, 256, 4_096] {
                result.append(decode(fixtures: fixtures, size: size, fragment: fragment))
            }
        }
        for kind in Rejection.allCases { result.append(rejection(kind)) }
        return result
    }

    /// Independent wire bytes prevent a matching encoder/decoder bug from constructing its own oracle.
    private struct Fixture {
        let frame: RPCFrame
        let wire: Data
    }

    /// Payload contents and opcodes vary across four deterministic inputs without timed preparation.
    /// - Parameter size: Positive payload byte count, selected from 1,024, 16,384 and 262,144; it fits UInt32 framing.
    /// - Returns: Four opaque frames and independently encoded little-endian opcode/length headers with exact bodies.
    /// Every payload position is generated deterministically, and the fixtures own their Data values. Construction
    /// costs scale with payload bytes and stay outside measurement; no production encoder constructs the wire oracle.
    private static func prepare(size: Int) -> [Fixture] {
        (0..<4).map { variant in
            let opcode: RPCOpcode = [.frame, .ping, .pong, .close][variant]
            let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ variant &* 53) })
            let frame = RPCFrame(opcode: opcode, payload: payload)
            var wire = Data([UInt8(opcode.rawValue), 0, 0, 0])
            let length = UInt32(size)
            for shift in stride(from: 0, to: 32, by: 8) {
                wire.append(UInt8(truncatingIfNeeded: length >> shift))
            }
            wire.append(payload)
            return Fixture(frame: frame, wire: wire)
        }
    }

    /// Encodes a prepared frame; checksum sampling is included and full wire equality remains outside timing.
    /// - Parameters:
    ///   - fixtures: The four variants returned by `prepare`, with independent wire expectations.
    ///   - size: Exact positive payload byte count, also used as the encoder's inclusive local payload cap.
    /// - Returns: An encoding workload whose dimension counts exclude the eight-byte header from `payload_bytes`
    ///   and include it in `wire_bytes`; all full wire comparisons run in the verifier.
    /// The timed closure allocates the encoder's returned Data and reads a bounded set of output features. Its
    /// encoding errors propagate; the verifier throws `integrityFailure` on unequal bytes. No transport is owned.
    private static func encode(fixtures: [Fixture], size: Int) -> FoundationWorkload {
        let id = "rpc.encode.p\(size)"
        return FoundationWorkload(id: id,
            dimensions: ["payload_bytes": UInt64(size), "wire_bytes": UInt64(size + 8), "variant_count": 4],
            fixture: fixtures.reduce(into: Data()) { $0.append($1.wire) }, operation: { input in
                let wire = try fixtures[Int(input % 4)].frame.encoded(maximumPayloadBytes: size)
                return wireObservation(wire)
            }, expected: { wireObservation(fixtures[Int($0 % 4)].wire) }, verify: {
                for fixture in fixtures {
                    guard try fixture.frame.encoded(maximumPayloadBytes: size) == fixture.wire else {
                        throw FoundationBenchmarkError.integrityFailure(id)
                    }
                }
            })
    }

    /// Pre-splits every variant so measured work only initializes and feeds the actual incremental decoder.
    /// - Parameters:
    ///   - fixtures: Four complete frames with independently authored wire bytes and expected decoded values.
    ///   - size: Exact positive payload size and inclusive decoder payload cap.
    ///   - fragment: Positive maximum fragment length, selected from 7, 256 and 4,096 bytes. The final fragment
    ///     may be shorter, and a value larger than the frame produces a single complete-frame append.
    /// - Returns: A synchronous incremental-decoding workload with actual prepared fragment counts. Each operation
    ///   owns a fresh decoder, consumes every returned frame and checks EOF at a frame boundary before discarding it.
    /// Fragment Data allocations happen during setup. Decoder initialization, buffering, frame emission and checksum
    /// consumption remain timed; protocol errors propagate and the untimed verifier requires one exact expected frame.
    private static func decode(fixtures: [Fixture], size: Int, fragment: Int) -> FoundationWorkload {
        let fragments: [[Data]] = fixtures.map { fixture in
            stride(from: 0, to: fixture.wire.count, by: fragment).map { offset in
                Data(fixture.wire[offset..<min(offset + fragment, fixture.wire.count)])
            }
        }
        let id = "rpc.decode.p\(size).f\(fragment)"
        return FoundationWorkload(id: id,
            dimensions: ["payload_bytes": UInt64(size), "wire_bytes": UInt64(size + 8),
                "fragment_bytes": UInt64(fragment), "fragment_count": UInt64(fragments[0].count),
                "variant_count": 4],
            fixture: fixtures.reduce(into: Data()) { $0.append($1.wire) }, operation: { input in
                var decoder = try RPCFrameDecoder(maximumPayloadBytes: size)
                var checksum: UInt64 = 0
                for bytes in fragments[Int(input % 4)] {
                    for frame in try decoder.append(bytes) { checksum = checksum &+ frameChecksum(frame) }
                }
                try decoder.finish()
                return FoundationObservation(checksum: checksum)
            }, expected: { FoundationObservation(checksum: frameChecksum(fixtures[Int($0 % 4)].frame)) }, verify: {
                for index in fixtures.indices {
                    var decoder = try RPCFrameDecoder(maximumPayloadBytes: size)
                    var frames: [RPCFrame] = []
                    for bytes in fragments[index] { frames.append(contentsOf: try decoder.append(bytes)) }
                    try decoder.finish()
                    guard frames == [fixtures[index].frame] else {
                        throw FoundationBenchmarkError.integrityFailure(id)
                    }
                }
            })
    }

    /// Samples a bounded number of observable output bytes rather than hashing full payloads inside timing.
    /// - Parameter wire: Encoder output or independent expected wire bytes; empty and header-only values are safe.
    /// - Returns: A zero-rejection observation incorporating length, first header byte, byte eight when present and
    ///   final wire byte. Empty input yields zero; full output correctness is established separately by wire equality.
    /// This performs constant-count read-only byte queries and uses wrapping checksum arithmetic deliberately.
    private static func wireObservation(_ wire: Data) -> FoundationObservation {
        let header = UInt64(wire.first ?? 0)
        let firstPayload = wire.count > 8 ? UInt64(wire[wire.startIndex + 8]) : 0
        return FoundationObservation(checksum: UInt64(wire.count) &* 65_537 &+
            header &* 65_521 &+ firstPayload &* 257 &+ UInt64(wire.last ?? 0))
    }

    /// Frame count contributes one positive checksum term per emitted result, with payload/opcode evidence.
    /// - Parameter frame: A decoder-emitted frame or its independently prepared expected value; payload may be empty.
    /// - Returns: A wrapping numeric term based on payload length, opcode and endpoint bytes, plus one per frame.
    /// The sink never formats or scans opaque payload contents. Complete payload equality is checked outside timing;
    /// this bounded read-only sampling keeps decoder output observable without adding a second linear payload pass.
    private static func frameChecksum(_ frame: RPCFrame) -> UInt64 {
        UInt64(frame.payload.count) &* 65_537 &+ UInt64(frame.opcode.rawValue) &* 65_521 &+
            UInt64(frame.payload.first ?? 0) &* 257 &+ UInt64(frame.payload.last ?? 0) &+ 1
    }

    /// Distinct error causes remain separate populations and carry exact expected rejection counts.
    private enum Rejection: String, CaseIterable {
        case malformed = "malformed-opcode"
        case announcedSize = "announced-size"
        case appendSize = "append-size"
        case truncated = "truncated"
        case encodeSize = "encode-size"

        /// Exact public failure expected for this malformed/oversized input class, with no peer diagnostics retained.
        /// Truncation is an EOF framing error; both announced and supplied size excesses are size errors.
        var error: RPCFailure {
            switch self {
            case .malformed, .truncated: .malformedFrame
            case .announcedSize, .appendSize, .encodeSize: .frameTooLarge
            }
        }

        /// Independent compact expectation: one denotes malformed framing and two denotes payload/input size refusal.
        /// The timed operation classifies its actual thrown error separately and counts one rejection.
        var errorCode: UInt64 { error == .malformedFrame ? 1 : 2 }
    }

    /// Every malformed fixture has four variants and is checked against its precise public error case.
    /// - Parameter kind: Unknown opcode, excessive announced payload, excessive append chunk, incomplete header at
    ///   EOF, or excessive encoder payload. Each class is measured separately against a fixed sixteen-byte cap.
    /// - Returns: A workload with actual minimum/maximum input byte dimensions and exactly one expected rejection
    ///   per operation. Successful admission remains observable as zero rejections and fails later accounting.
    /// Decoder/frame storage is operation-local and released on return. The timed closure classifies public errors;
    /// the untimed verifier requires the exact expected `RPCFailure` case and throws `integrityFailure` on admission.
    /// Unexpected non-RPC errors propagate. No invalid bytes are sent to a desktop process or copied into diagnostics.
    private static func rejection(_ kind: Rejection) -> FoundationWorkload {
        let variants: [Data] = (0..<4).map { variant in
            switch kind {
            case .malformed: return Data([UInt8(5 + variant), 0, 0, 0, 0, 0, 0, 0])
            case .announcedSize: return Data([1, 0, 0, 0, UInt8(17 + variant), 0, 0, 0])
            case .appendSize: return Data(repeating: UInt8(variant), count: 25 + variant)
            case .truncated: return Data([UInt8(1), 0, 0, 0, 4, 0, 0, 0].prefix(variant + 1))
            case .encodeSize: return Data(repeating: UInt8(variant), count: 17 + variant)
            }
        }
        let id = "rpc.reject.\(kind.rawValue)"
        let operation: (UInt64) throws -> FoundationObservation = { input in
            let bytes = variants[Int(input % 4)]
            do {
                switch kind {
                case .encodeSize:
                    _ = try RPCFrame(opcode: .frame, payload: bytes).encoded(maximumPayloadBytes: 16)
                default:
                    var decoder = try RPCFrameDecoder(maximumPayloadBytes: 16)
                    _ = try decoder.append(bytes)
                    try decoder.finish()
                }
            } catch let error as RPCFailure {
                // Error classification is observable measured work; expected equality is checked outside timing.
                let code: UInt64
                switch error {
                case .malformedFrame: code = 1
                case .frameTooLarge: code = 2
                default: code = 3
                }
                return FoundationObservation(checksum: code, rejections: 1)
            }
            return FoundationObservation(checksum: 0)
        }
        return FoundationWorkload(id: id,
            dimensions: ["maximum_payload_bytes": 16, "variant_count": 4,
                "minimum_input_bytes": UInt64(variants.map(\.count).min()!),
                "maximum_input_bytes": UInt64(variants.map(\.count).max()!)],
            fixture: variants.reduce(into: Data()) { $0.append($1) }, operation: operation,
            expected: { _ in FoundationObservation(checksum: kind.errorCode, rejections: 1) }, verify: {
                for bytes in variants {
                    do {
                        switch kind {
                        case .encodeSize:
                            _ = try RPCFrame(opcode: .frame, payload: bytes).encoded(maximumPayloadBytes: 16)
                        default:
                            var decoder = try RPCFrameDecoder(maximumPayloadBytes: 16)
                            _ = try decoder.append(bytes)
                            try decoder.finish()
                        }
                    } catch let error as RPCFailure where error == kind.error {
                        continue
                    }
                    throw FoundationBenchmarkError.integrityFailure(id)
                }
            })
    }
}
