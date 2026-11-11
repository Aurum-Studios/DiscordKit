// File: Tools/DiscordMediaBenchmarks/Sources/DiscordMediaBenchmarks/CryptoWorkloads.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Crypto
import DiscordDAVE
import DiscordVoice
import DiscordVoiceCrypto
import Foundation

extension MediaCatalog {
    /// Prepares public symmetric fixture domains with one live sender and distinct replay-owning receiver.
    /// Only seal or open is timed; every retained plaintext is checked before both owners close.
    static func transport(_ id: String, opening: Bool, aes: Bool) -> MediaCase {
        MediaCase(id: id, transition: false, dimensions: ["payloadBytes": 160, "headerBytes": 12]) { count, seed in
            let mode: VoiceEncryptionMode = aes ? .aeadAES256GCMRTPSize : .aeadXChaCha20Poly1305RTPSize
            let key = Data(SHA256.hash(data: Data("PUBLIC-MEDIA-BENCHMARK-KEY-\(seed)".utf8)))
            let sender = try VoiceTransportCipher(mode: mode, key: key)
            let receiver = try VoiceTransportCipher(mode: mode, key: key)
            let payload = Data((0..<160).map { UInt8(truncatingIfNeeded: $0 + Int(seed % 255)) })
            let header = try RTPPacket(sequence: 1, timestamp: 0, ssrc: 7, payload: Data()).serialized()
            let prepared = SerialResults<Data>(capacity: count)
            let results = SerialResults<Data>(capacity: count)
            do {
                if opening {
                    for _ in 0..<count { prepared.values.append(try await sender.seal(payload: payload, authenticatedHeader: header)) }
                }
                return MediaBatch(run: {
                    for index in 0..<count {
                        let value = opening ? try await receiver.open(sealedPayload: prepared.values[index], authenticatedHeader: header)
                            : try await sender.seal(payload: payload, authenticatedHeader: header)
                        results.values.append(value)
                    }
                    return UInt64(results.values.count)
                }, verify: {
                    try require(results.values.count == count, "Transport batch count mismatch")
                    for value in results.values {
                        let opened = opening ? value : try await receiver.open(sealedPayload: value, authenticatedHeader: header)
                        try require(opened == payload, "Transport roundtrip mismatch")
                    }
                }, close: {
                    await sender.close(); await receiver.close()
                    prepared.values.removeAll(); results.values.removeAll()
                })
            } catch { await sender.close(); await receiver.close(); throw error }
        }
    }

    /// Prepares independent public-fixture DAVE sender/receiver owners; full authenticated roundtrips are untimed.
    static func daveFrame(_ id: String, opening: Bool) -> MediaCase {
        MediaCase(id: id, transition: false, dimensions: ["payloadBytes": 80]) { count, seed in
            let secret = Data(SHA256.hash(data: Data("PUBLIC-DAVE-SECRET-\(seed)".utf8)).prefix(16))
            let sender = try DAVEFrameCipher(baseSecret: secret), receiver = try DAVEFrameCipher(baseSecret: secret)
            let payload = Data([0xf8]) + Data(repeating: 0x55, count: 79)
            let prepared = SerialResults<Data>(capacity: count), results = SerialResults<Data>(capacity: count)
            do {
                if opening { for _ in 0..<count { prepared.values.append(try await sender.seal(payload, codec: .opus)) } }
                return MediaBatch(run: {
                    for index in 0..<count {
                        let value = opening ? try await receiver.open(prepared.values[index], mediaType: .audio, now: 1)
                            : try await sender.seal(payload, codec: .opus)
                        results.values.append(value)
                    }
                    return UInt64(results.values.count)
                }, verify: {
                    try require(results.values.count == count, "DAVE batch count mismatch")
                    for value in results.values {
                        let opened = opening ? value : try await receiver.open(value, mediaType: .audio, now: 1)
                        try require(opened == payload, "DAVE roundtrip mismatch")
                    }
                }, close: {
                    await sender.close(); await receiver.close()
                    prepared.values.removeAll(); results.values.removeAll()
                })
            } catch { await sender.close(); await receiver.close(); throw error }
        }
    }
}
