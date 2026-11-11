// File: Tools/DiscordMediaBenchmarks/Sources/DiscordMediaBenchmarks/Workload.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Crypto
import Foundation

enum MediaBenchmarkError: Error, Equatable {
    case invalidConfiguration(String)
    case integrityFailure(String)
}

/// Only the serial runner mutates this storage; concurrency cases use actor-owned results instead.
final class SerialResults<Value: Sendable>: @unchecked Sendable {
    var values: [Value] = []
    /// Reserves finite result storage before timing; only the serial owner appends or clears it.
    init(capacity: Int) { values.reserveCapacity(capacity) }
}

/// Prepared fixtures own their public crypto/material until joined verification and explicit closure.
struct MediaBatch: Sendable {
    let run: @Sendable () async throws -> UInt64
    let verify: @Sendable () async throws -> Void
    let close: @Sendable () async -> Void

    /// Retains every bounded result for a complete untimed comparison against an independent prepared oracle.
    static func compared<Value: Equatable & Sendable>(count: Int, expected: Value,
        operation: @escaping @Sendable () throws -> Value) -> Self {
        let results = SerialResults<Value>(capacity: count)
        return Self(run: {
            for _ in 0..<count { results.values.append(try operation()) }
            return UInt64(results.values.count)
        }, verify: {
            guard results.values.count == count, results.values.allSatisfy({ $0 == expected }) else {
                throw MediaBenchmarkError.integrityFailure("Full result oracle mismatch")
            }
        }, close: { results.values.removeAll() })
    }
}

struct MediaCase: Sendable {
    let id: String
    let transition: Bool
    let dimensions: [String: UInt64]
    let prepare: @Sendable (_ count: Int, _ seed: UInt64) async throws -> MediaBatch
}

enum MediaCatalog {
    /// Lists without constructing codecs, random keys, actors or fixtures.
    static var ids: [String] {
        var result = [String]()
        for rate in [16_000, 44_100] {
            for channels in ["mono", "stereo"] { result.append("resample.bandlimited.\(rate).48000.\(channels)") }
        }
        for mode in ["celt", "silk", "hybrid"] {
            for frames in mode == "celt" ? [120, 240, 480, 960] : [480, 960] {
                for channels in ["mono", "stereo"] {
                    for action in ["encode", "decode", "conceal", "recover"] {
                        result.append("opus.\(action).\(mode).\(frames).\(channels)")
                    }
                }
            }
        }
        result += ["jitter.reorder.loss", "rtp.packetize.roundtrip"]
        for cipher in ["aes256gcm", "xchacha20poly1305"] {
            for action in ["seal", "open"] { result.append("transport.\(action).\(cipher)") }
        }
        result += ["dave.frame.seal", "dave.frame.open", "mls.group.create", "mls.group.join",
            "mls.epoch.rekey", "dave.transition.queue"]
        return result.sorted()
    }

    /// Resolves an exact finite ID without allocating its fixtures; rejects unsupported variants.
    static func selected(_ id: String) throws -> MediaCase {
        guard ids.contains(id) else { throw MediaBenchmarkError.invalidConfiguration("Unknown media case: \(id)") }
        let parts = id.split(separator: ".").map(String.init)
        if parts[0] == "resample" { return try resample(id, rate: Int(parts[2])!, channels: parts[4] == "mono" ? 1 : 2) }
        if parts[0] == "opus" { return try opus(id, action: parts[1], mode: parts[2], frames: Int(parts[3])!, channels: parts[4] == "mono" ? 1 : 2) }
        switch id {
        case "jitter.reorder.loss": return jitter(id)
        case "rtp.packetize.roundtrip": return rtp(id)
        case "dave.frame.seal", "dave.frame.open": return daveFrame(id, opening: parts[2] == "open")
        case "mls.group.create", "mls.group.join", "mls.epoch.rekey": return mls(id)
        case "dave.transition.queue": return daveQueue(id)
        default: return transport(id, opening: parts[1] == "open", aes: parts[2] == "aes256gcm")
        }
    }

    /// Produces bounded interleaved two-tone public PCM from a seed, with identical channels.
    static func samples(frames: Int, channels: Int, seed: UInt64) -> [Float] {
        (0..<(frames * channels)).map { index in
            let phase = Double(index / channels + Int(seed % 997)) * 2 * Double.pi * 440 / 48_000
            return Float(sin(phase) * 0.18 + sin(phase * 0.47) * 0.04)
        }
    }

    /// These scalars and symmetric inputs are public benchmark fixtures with no confidentiality value.
    static func publicScalar(_ value: UInt8) -> Data { Data(repeating: 0, count: 31) + Data([value]) }
    /// Fails an untimed semantic oracle without logging or exposing the retained public results.
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw MediaBenchmarkError.integrityFailure(message) }
    }
}
