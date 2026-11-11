// File: Tools/DiscordMediaBenchmarks/Sources/DiscordMediaBenchmarks/SteadyDAVEWorkloads.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Crypto
import DiscordDAVE
import Foundation

extension MediaCatalog {
    /// Preloads an entire replay window, then retains the same receive owner across all population batches.
    /// - Parameters:
    ///   - id: Version-two finite open identity; legacy `dave.frame.open` keeps its per-batch empty replay state.
    ///   - window: Exactly 1,024 (production default) or 8,192 (supported maximum) accepted nonce positions.
    /// - Returns: Serial authenticated-open batches with untimed seal, prefill, plaintext verification and close.
    /// The public fixture key never protects real media. A logical 20 ms clock advances with unique frames;
    /// this is a replay-window CPU workload, without pacing, sender transitions or live Discord qualification.
    static func steadyDAVE(_ id: String, window: Int) -> MediaCase {
        .continuous(id: id, dimensions: ["fixtureVersion": 2, "payloadBytes": 80,
            "replayWindow": UInt64(window), "prefillFrames": UInt64(window), "continuousState": 1,
            "frameIntervalNanoseconds": 20_000_000]) { seed in
            let secret = Data(SHA256.hash(data: Data("PUBLIC-DAVE-STEADY-v2-\(seed)".utf8)).prefix(16))
            let configuration = try DAVEFrameCipher.Configuration(replayWindow: window)
            let sender = try DAVEFrameCipher(baseSecret: secret, configuration: configuration)
            let receiver = try DAVEFrameCipher(baseSecret: secret, configuration: configuration)
            let payload = Data([0xf8]) + Data(repeating: 0x55, count: 79)
            let position = SerialState(UInt64(0)), lastOpened = SerialState(Data())
            do {
                for _ in 0..<window {
                    let frame = try await sender.seal(payload, codec: .opus)
                    position.value += 1
                    let opened = try await receiver.open(frame, mediaType: .audio, now: Double(position.value) / 50)
                    try require(opened == payload, "DAVE replay prefill plaintext mismatch")
                    lastOpened.value = frame
                }
                return MediaSession(prepare: { count, _ in
                    var frames: [Data] = []
                    for _ in 0..<count { frames.append(try await sender.seal(payload, codec: .opus)) }
                    let prepared = frames
                    let results = SerialResults<Data>(capacity: count)
                    return MediaBatch(run: {
                        for frame in prepared {
                            position.value += 1
                            results.values.append(try await receiver.open(frame, mediaType: .audio,
                                now: Double(position.value) / 50))
                            lastOpened.value = frame
                        }
                        return UInt64(results.values.count)
                    }, verify: {
                        try require(results.values.count == count && results.values.allSatisfy { $0 == payload },
                            "DAVE steady plaintext mismatch")
                    }, close: { results.values.removeAll() })
                }, verify: {
                    do {
                        _ = try await receiver.open(lastOpened.value, mediaType: .audio, now: Double(position.value) / 50)
                        throw MediaBenchmarkError.integrityFailure("DAVE steady receiver accepted a replay")
                    } catch let error as DAVEError {
                        try require(error == .replayedFrame, "DAVE steady replay classification mismatch")
                    }
                }, close: { await sender.close(); await receiver.close(); lastOpened.value.removeAll() })
            } catch { await sender.close(); await receiver.close(); throw error }
        }
    }
}
