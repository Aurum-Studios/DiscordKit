// File: Tools/DiscordMediaBenchmarks/Sources/DiscordMediaBenchmarks/PhaseNineAccountingWorkloads.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordVoice
import Foundation

extension MediaCatalog {
    /// Matched packet geometry separates the serialization-for-accounting control from full jitter insert/playout.
    /// Returns six unique version-four IDs crossing two endpoints with three payload sizes; no packet is allocated.
    static var phaseNineAccountingIDs: [String] {
        [80, 1_200, 16_000].flatMap { bytes in
            ["rtp.v4.accounting.serialize.payload\(bytes)", "jitter.v4.accounting.insertPop.payload\(bytes)"]
        }
    }

    /// Eight immutable packets have two CSRCs, eight extension bytes and four padding bytes each.
    /// RTP controls serialize only to obtain byte counts. Jitter controls insert the identical packets in reverse
    /// order and pop all eight; constructor, accounting, dictionary and complete playout retention are included.
    /// Full wire lengths and FIFO outputs are checked untimed; the packet's internal exact-length helper remains private.
    /// - Parameters:
    ///   - id: Exact version-four RTP or jitter accounting identity corresponding to the endpoint and payload size.
    ///   - payloadBytes: Payload per packet, exactly 80, 1200 or 16000 bytes; complete wire size adds 36 bytes.
    ///   - jitter: True to time construction plus eight reverse inserts and ordered pops; false to serialize for lengths.
    /// - Returns: A finite per-batch case with independent prepared packets and retained complete result oracles.
    /// Deferred preparation accepts 1...64 calls and uses the public seed's low sixteen bits for wrapping sequences.
    /// Packet/configuration errors propagate during preparation or execution; oracle mismatch throws integrityFailure.
    /// No actors, tasks or external resources are created. Sendable closures retain immutable packet fixtures plus
    /// serial result storage: run once, verify, then close without overlapping those operations. Idempotent closure
    /// releases results, and the harness must invoke it after errors or cancellation. This synchronous native work
    /// has no internal cancellation suspension; harness cancellation is checked between bounded batches.
    static func phaseNineAccounting(_ id: String, payloadBytes: Int, jitter: Bool) -> MediaCase {
        MediaCase(id: id, transition: false, dimensions: ["fixtureVersion": 4, "packetsPerCall": 8,
            "payloadBytes": UInt64(payloadBytes), "contributingSources": 2, "extensionBytes": 8, "paddingBytes": 4,
            "serializedBytesPerPacket": UInt64(36 + payloadBytes), "jitterCapacity": jitter ? 8 : 0,
            "jitterInsertAndPopInsideTimer": jitter ? 1 : 0, "serializationOnlyForLength": jitter ? 0 : 1]) { count, seed in
            let start = UInt16(truncatingIfNeeded: seed)
            let ext = try RTPExtension(profile: 0xbede, bytes: Data(repeating: 0x55, count: 8))
            let packets = try (0..<8).map { offset in
                try RTPPacket(sequence: start &+ UInt16(offset), timestamp: UInt32(offset * 960), ssrc: 7,
                    contributingSources: [11, 12], headerExtension: ext,
                    payload: Data(repeating: UInt8(offset + 1), count: payloadBytes), paddingCount: 4)
            }
            let expectedBytes = 36 + payloadBytes
            try require(packets.allSatisfy { $0.serialized().count == expectedBytes }, "RTP accounting fixture length mismatch")
            if jitter {
                let expected = packets.map(VoicePlayout.packet)
                return .compared(count: count, expected: expected) {
                    var owner = try VoiceJitterBuffer(ssrc: 7, nextSequence: start, capacity: 8)
                    for packet in packets.reversed() { try owner.insert(packet) }
                    return (0..<8).map { _ in owner.pop() }
                }
            }
            return .compared(count: count, expected: Array(repeating: expectedBytes, count: 8)) {
                packets.map { $0.serialized().count }
            }
        }
    }
}
