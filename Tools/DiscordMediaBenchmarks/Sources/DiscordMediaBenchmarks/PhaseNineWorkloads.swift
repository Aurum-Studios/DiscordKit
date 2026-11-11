// File: Tools/DiscordMediaBenchmarks/Sources/DiscordMediaBenchmarks/PhaseNineWorkloads.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Crypto
import DiscordDAVE
import Foundation

extension MediaCatalog {
    /// Independent authenticated, reordered/replayed and failed-authentication populations at full replay occupancy.
    /// Returns thirty-one unique version-four IDs including expiry, MLS and accounting controls, without constructing
    /// actors, keys, codecs or fixtures. The outer catalog sorts these IDs and preserves all earlier identities.
    static var phaseNineIDs: [String] {
        [64, 1_024, 8_192].flatMap { window in
            ["steady", "reorderDuplicate", "authenticationFailure"].map {
                "dave.v4.open.\($0).replay\(window)"
            } + ["dave.v4.expiry.replay\(window)"]
        } + phaseNineMLSIDs + phaseNineAccountingIDs
    }

    /// Exact version-four catalog selection does not construct cryptographic fixtures.
    /// - Parameters:
    ///   - id: One exact identity already admitted by `MediaCatalog.selected` from the finite version-four catalog.
    ///   - parts: The same identity split on periods, retaining its validated action, size and policy components.
    /// - Returns: Deferred preparation and endpoint policy for that identity; no cryptographic owner exists yet.
    /// This internal dispatcher assumes the catalog guard has run. Malformed or mismatched components violate
    /// that precondition rather than producing a recoverable configuration error. Deferred closures propagate
    /// fixture, operation and oracle errors and own their explicit cleanup; dispatch itself performs no I/O or suspension.
    static func phaseNineSelected(_ id: String, parts: [String]) -> MediaCase {
        if parts[0] == "rtp" || parts[0] == "jitter" { return phaseNineAccounting(id,
            payloadBytes: Int(parts[4].dropFirst(7))!, jitter: parts[0] == "jitter") }
        if parts[0] == "mls" { return phaseNineMLS(id, members: Int(parts[4].dropFirst(7))!,
            removals: parts[2] == "remove3" ? 3 : parts[2] == "add1" ? 0 : 1,
            sparse: parts[3] == "sparse", mixed: parts[2] == "mixed") }
        if parts[2] == "expiry" { return phaseNineExpiry(id, window: Int(parts[3].dropFirst(6))!) }
        return phaseNineDAVE(id, window: Int(parts[4].dropFirst(6))!, policy: parts[3])
    }

    /// Retains one fully prefilled receiver across a complete bounded population; fixture creation is untimed.
    /// A reorder call opens two unique frames in reverse order then rejects a duplicate; a failure call rejects
    /// a corrupted tag before accepting that exact nonce's valid frame. All complete results are checked untimed.
    /// - Parameters:
    ///   - id: Exact `dave.v4.open` identity matching the supplied replay window and policy.
    ///   - window: Full prefill and receive-window size, exactly 64, 1024 or 8192 authenticated nonce positions.
    ///   - policy: Exactly `steady`, `reorderDuplicate` or `authenticationFailure`, as admitted by the catalog.
    /// - Returns: A continuous case whose warmup/measured populations own separate sender/receiver actors.
    /// Each deferred batch admits 1...64 wrappers. Preparation seals unique public-fixture nonces without advancing
    /// receive state; discarded preparation can leave sender gaps. The serial owner must run each batch once,
    /// verify it, release its results, then verify/close the population. Sendable closures rely on that ordering
    /// for their unchecked serial storage; independent populations share no mutable storage. Actor calls suspend
    /// between opens and honor ordinary cancellation and verification budgets, including the 131072 failure cap.
    /// Deferred errors propagate without replacing quotas. Preparation failure closes both actors; callers must
    /// await batch/population closure on later failure or cancellation. Closure is idempotent and starts no tasks.
    static func phaseNineDAVE(_ id: String, window: Int, policy: String) -> MediaCase {
        let reordered = policy == "reorderDuplicate", failures = policy == "authenticationFailure"
        return .continuous(id: id, dimensions: ["fixtureVersion": 4, "payloadBytes": 80,
            "replayWindow": UInt64(window), "prefillFrames": UInt64(window), "continuousState": 1,
            "authenticatedFramesPerCall": reordered ? 2 : 1, "duplicateRejectionsPerCall": reordered ? 1 : 0,
            "authenticationFailuresPerCall": failures ? 1 : 0, "frameIntervalNanoseconds": 20_000_000]) { seed in
            let secret = Data(SHA256.hash(data: Data("PUBLIC-DAVE-v4-\(seed)".utf8)).prefix(16))
            let configuration = try DAVEFrameCipher.Configuration(replayWindow: window)
            let sender = try DAVEFrameCipher(baseSecret: secret, configuration: configuration)
            let receiver = try DAVEFrameCipher(baseSecret: secret, configuration: configuration)
            let payload = Data([0xf8]) + Data(repeating: 0x55, count: 79)
            let clock = SerialState(UInt64(0)), lastFrame = SerialState(Data())
            do {
                for _ in 0..<window {
                    let frame = try await sender.seal(payload, codec: .opus)
                    clock.value += 1
                    try require(try await receiver.open(frame, mediaType: .audio,
                        now: Double(clock.value) / 50) == payload, "Stage-nine DAVE prefill mismatch")
                    lastFrame.value = frame
                }
                return MediaSession(prepare: { count, _ in
                    var frames: [[Data]] = []
                    for _ in 0..<count {
                        let first = try await sender.seal(payload, codec: .opus)
                        if reordered {
                            frames.append([try await sender.seal(payload, codec: .opus), first])
                        } else if failures {
                            let envelope = try DAVEFrameEnvelope(frame: first)
                            var tag = envelope.tag; tag[0] ^= 1
                            let corrupt = try DAVEFrameEnvelope.encode(interleaved: envelope.interleaved,
                                tag: tag, nonce: envelope.nonce, clearRanges: envelope.clearRanges)
                            frames.append([corrupt, first])
                        } else { frames.append([first]) }
                    }
                    let prepared = frames, results = SerialResults<Data>(capacity: count * (reordered ? 2 : 1))
                    let errors = SerialResults<DAVEError>(capacity: count)
                    return MediaBatch(run: {
                        for sequence in prepared {
                            clock.value += 1
                            let now = Double(clock.value) / 50
                            if failures {
                                do { _ = try await receiver.open(sequence[0], mediaType: .audio, now: now) }
                                catch let error as DAVEError { errors.values.append(error) }
                                results.values.append(try await receiver.open(sequence[1], mediaType: .audio, now: now))
                            } else {
                                for frame in sequence {
                                    results.values.append(try await receiver.open(frame, mediaType: .audio, now: now))
                                }
                                if reordered {
                                    do { _ = try await receiver.open(sequence[0], mediaType: .audio, now: now) }
                                    catch let error as DAVEError { errors.values.append(error) }
                                }
                            }
                            lastFrame.value = sequence[0]
                        }
                        return UInt64(prepared.count)
                    }, verify: {
                        try require(results.values.count == count * (reordered ? 2 : 1)
                            && results.values.allSatisfy { $0 == payload }, "Stage-nine DAVE plaintext mismatch")
                        try require(errors.values.count == ((reordered || failures) ? count : 0)
                            && errors.values.allSatisfy { $0 == (failures ? .authenticationFailed : .replayedFrame) },
                            "Stage-nine DAVE rejection mismatch")
                    }, close: { results.values.removeAll(); errors.values.removeAll() })
                }, verify: {
                    do {
                        _ = try await receiver.open(lastFrame.value, mediaType: .audio, now: Double(clock.value) / 50)
                        throw MediaBenchmarkError.integrityFailure("Stage-nine DAVE accepted replay after population")
                    } catch let error as DAVEError { try require(error == .replayedFrame, "Stage-nine final replay mismatch") }
                }, close: { await sender.close(); await receiver.close(); lastFrame.value.removeAll() })
            } catch { await sender.close(); await receiver.close(); throw error }
        }
    }
}
