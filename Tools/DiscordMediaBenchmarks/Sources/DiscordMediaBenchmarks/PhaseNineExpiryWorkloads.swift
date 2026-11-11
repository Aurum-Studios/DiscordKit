// File: Tools/DiscordMediaBenchmarks/Sources/DiscordMediaBenchmarks/PhaseNineExpiryWorkloads.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Crypto
import DiscordDAVE
import DiscordVoiceCrypto
import Foundation

extension MediaCatalog {
    /// Measures one actual expiry/prune plus authenticated new-generation open on each independently prepared owner.
    /// Public ratchet/AEAD/framing APIs create near-boundary fixtures without exposing a transmit-counter override.
    /// Every owner first authenticates a full generation-zero window, a generation-one frame, and a still-live old
    /// frame at nine seconds. The timed open at eleven seconds expires generation zero; a withheld old nonce must
    /// then fail the normal modulo-generation/future bound. This endpoint includes authentication and pruning.
    /// - Parameters:
    ///   - id: Exact `dave.v4.expiry` identity matching the selected window.
    ///   - window: Complete generation-zero prefill and receive-window size, exactly 64, 1024 or 8192 positions.
    /// - Returns: A per-batch case whose 1...64 independently prefilled receivers each expire one generation once.
    /// Public seed material determines the fixture secret; it has no confidentiality value. The factory itself
    /// creates no owner. Deferred preparation closes every receiver if configuration, framing, authentication or
    /// cancellation fails. After successful preparation the caller must run once, verify once and await idempotent
    /// closure, including on operation/oracle failure. Sendable closures rely on this serial ownership for result
    /// arrays; receiver actors serialize each transform and suspend only at actor boundaries. A discarded batch
    /// closes its receivers without measuring an expiry. Native errors and integrity failures propagate unchanged.
    static func phaseNineExpiry(_ id: String, window: Int) -> MediaCase {
        MediaCase(id: id, transition: false, dimensions: ["fixtureVersion": 4, "payloadBytes": 80,
            "replayWindow": UInt64(window), "prefillFrames": UInt64(window), "continuousState": 0,
            "authenticatedFramesPerCall": 1, "generationExpiriesPerCall": 1, "generationRetentionSeconds": 10,
            "expiryOpenAtSeconds": 11, "startingGeneration": 1, "prefillGeneration": 0]) { count, seed in
            let owners = SerialResults<DAVEFrameCipher>(capacity: count)
            let results = SerialResults<Data>(capacity: count)
            let secret = Data(SHA256.hash(data: Data("PUBLIC-DAVE-EXPIRY-v4-\(seed)".utf8)).prefix(16))
            let payload = Data([0xf8]) + Data(repeating: 0x55, count: 79)
            let configuration = try DAVEFrameCipher.Configuration(replayWindow: window)
            var ratchet = try DAVEKeyRatchet(baseSecret: secret)
            let priorKey = try ratchet.key(for: 0), nextKey = try ratchet.key(for: 1)
            let generationStart: UInt32 = 1 << 24
            var prefill: [Data] = []
            for offset in 0..<window {
                prefill.append(try publicDAVEFrame(payload, key: priorKey,
                    nonce: generationStart - UInt32(window + 2) + UInt32(offset)))
            }
            let first = try publicDAVEFrame(payload, key: nextKey, nonce: generationStart)
            let stillLive = try publicDAVEFrame(payload, key: priorKey, nonce: generationStart - 2)
            let expired = try publicDAVEFrame(payload, key: priorKey, nonce: generationStart - 1)
            let timed = try publicDAVEFrame(payload, key: nextKey, nonce: generationStart + 1)
            do {
                for _ in 0..<count {
                    let receiver = try DAVEFrameCipher(baseSecret: secret, configuration: configuration)
                    owners.values.append(receiver)
                    for frame in prefill {
                        try require(try await receiver.open(frame, mediaType: .audio, now: 0) == payload,
                            "DAVE expiry prefill mismatch")
                    }
                    try require(try await receiver.open(first, mediaType: .audio, now: 0) == payload,
                        "DAVE expiry generation advance mismatch")
                    try require(try await receiver.open(stillLive, mediaType: .audio, now: 9) == payload,
                        "DAVE generation expired before deadline")
                }
                return MediaBatch(run: {
                    for receiver in owners.values {
                        results.values.append(try await receiver.open(timed, mediaType: .audio, now: 11))
                    }
                    return UInt64(results.values.count)
                }, verify: {
                    try require(results.values.count == count && results.values.allSatisfy { $0 == payload },
                        "DAVE expiry plaintext mismatch")
                    for receiver in owners.values {
                        do {
                            _ = try await receiver.open(expired, mediaType: .audio, now: 11)
                            throw MediaBenchmarkError.integrityFailure("DAVE expired generation accepted")
                        } catch let error as DAVEError {
                            // The generation byte resolves modulo 256 against the advanced oldest floor.
                            try require(error == .generationTooFarAhead, "DAVE expired generation classification mismatch")
                        }
                        do {
                            _ = try await receiver.open(timed, mediaType: .audio, now: 11)
                            throw MediaBenchmarkError.integrityFailure("DAVE expiry owner accepted replay")
                        } catch let error as DAVEError { try require(error == .replayedFrame, "DAVE expiry replay mismatch") }
                    }
                }, close: {
                    for receiver in owners.values { await receiver.close() }
                    owners.values.removeAll(); results.values.removeAll()
                })
            } catch {
                for receiver in owners.values { await receiver.close() }
                throw error
            }
        }
    }

    /// Constructs an all-encrypted codec-agnostic public fixture using the ordinary ratchet-derived key and nonce.
    /// The caller owns nonce uniqueness within each fixture key domain; no result protects real media.
    /// - Parameters:
    ///   - payload: Nonempty plaintext; this endpoint supplies exactly eighty bytes with no clear ranges.
    ///   - key: Exact sixteen-byte AES key derived for the generation encoded in the synchronization nonce.
    ///   - nonce: Caller-reserved uint32 synchronization nonce; its high byte encodes generation modulo 256.
    /// - Returns: Owned ciphertext, truncated eight-byte tag, minimal nonce footer and DAVE marker bytes.
    /// - Throws: Underlying AEAD size/key/nonce errors or DAVE framing errors; no partial frame is returned.
    /// This synchronous helper owns no actors or tasks, mutates no ratchet, and performs no cancellation check.
    /// Reusing the result across independent public-fixture receive owners does not create a transmit owner.
    private static func publicDAVEFrame(_ payload: Data, key: Data, nonce: UInt32) throws -> Data {
        let fullNonce = Data(repeating: 0, count: 8) + Data((0..<4).map { UInt8(truncatingIfNeeded: nonce >> ($0 * 8)) })
        let sealed = try TruncatedAESGCM.seal(payload: payload, key: key, nonce: fullNonce)
        return try DAVEFrameEnvelope.encode(interleaved: Data(sealed.dropLast(8)), tag: Data(sealed.suffix(8)),
            nonce: nonce, clearRanges: [])
    }
}
