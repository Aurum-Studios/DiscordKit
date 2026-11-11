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

/// One serial population owns these resources across all of its bounded batches.
struct MediaSession: Sendable {
    let prepare: @Sendable (_ count: Int, _ seed: UInt64) async throws -> MediaBatch
    let verify: @Sendable () async throws -> Void
    let close: @Sendable () async -> Void
}

/// Mutable value storage exclusively owned by the serial population, never shared across populations.
final class SerialState<Value: Sendable>: @unchecked Sendable {
    var value: Value
    /// Takes ownership of prepared state without copying it inside each timed operation.
    /// - Parameter value: Independently constructed state; only one serial runner may mutate this box.
    init(_ value: Value) { self.value = value }
}

struct MediaCase: Sendable {
    let id: String
    let transition: Bool
    let dimensions: [String: UInt64]
    let prepare: @Sendable (_ count: Int, _ seed: UInt64) async throws -> MediaBatch
    let preparePopulation: (@Sendable (_ seed: UInt64) async throws -> MediaSession)?

    /// Describes an existing independently prepared batch or a versioned population-owned stream.
    /// - Parameters:
    ///   - id: Unique finite catalog identity; old identities keep their original preparation policy.
    ///   - transition: Whether the distribution uses MLS transition rather than media batch semantics.
    ///   - dimensions: Immutable public fixture policy and size metadata.
    ///   - preparePopulation: Optional per-population owner factory, absent for all legacy cases.
    ///   - prepare: Standalone finite-batch factory used by legacy harness paths and direct fixture tests.
    /// Preparation is untimed and must release any created resources when it throws.
    init(id: String, transition: Bool, dimensions: [String: UInt64],
        preparePopulation: (@Sendable (_ seed: UInt64) async throws -> MediaSession)? = nil,
        prepare: @escaping @Sendable (_ count: Int, _ seed: UInt64) async throws -> MediaBatch) {
        self.id = id; self.transition = transition; self.dimensions = dimensions
        self.preparePopulation = preparePopulation; self.prepare = prepare
    }

    /// Wraps a serial streaming owner with an independently closable standalone test batch.
    /// - Parameters:
    ///   - id: New versioned identity; may not replace an existing cold/per-batch identity.
    ///   - dimensions: Public policy sizes including prefill and fixture version.
    ///   - factory: Builds one new owner for each warmup/measured population or standalone batch.
    /// - Returns: A media case whose harness owner survives batch verification and result release.
    /// Preparation failures close the owner; verification checks the whole session before final closure.
    static func continuous(id: String, dimensions: [String: UInt64],
        factory: @escaping @Sendable (_ seed: UInt64) async throws -> MediaSession) -> Self {
        Self(id: id, transition: false, dimensions: dimensions, preparePopulation: factory) { count, seed in
            let session = try await factory(seed)
            do {
                let batch = try await session.prepare(count, seed)
                return MediaBatch(run: batch.run, verify: {
                    try await batch.verify(); try await session.verify()
                }, close: { await batch.close(); await session.close() })
            } catch { await session.close(); throw error }
        }
    }
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
        for rate in [16_000, 44_100] {
            for channels in ["mono", "stereo"] { result.append("resample.v2.continuous.\(rate).48000.\(channels)") }
        }
        for mode in ["celt", "silk", "hybrid"] {
            for channels in ["mono", "stereo"] {
                for action in ["encode", "decode"] { result.append("opus.v2.continuous.\(action).\(mode).960.\(channels)") }
            }
        }
        for window in [1_024, 8_192] { result.append("dave.v2.frame.open.replay\(window)") }
        result += phaseEightIDs
        return result.sorted()
    }

    /// Resolves an exact finite ID without allocating its fixtures; rejects unsupported variants.
    static func selected(_ id: String) throws -> MediaCase {
        guard ids.contains(id) else { throw MediaBenchmarkError.invalidConfiguration("Unknown media case: \(id)") }
        let parts = id.split(separator: ".").map(String.init)
        if parts.count > 1, parts[1] == "v3" { return phaseEightSelected(id, parts: parts) }
        if parts.count > 1, parts[1] == "v2" {
            switch parts[0] {
            case "resample": return continuousResample(id, rate: Int(parts[3])!, channels: parts[5] == "mono" ? 1 : 2)
            case "opus": return continuousOpus(id, action: parts[3], mode: parts[4], channels: parts[6] == "mono" ? 1 : 2)
            default: return steadyDAVE(id, window: Int(parts[4].dropFirst(6))!)
            }
        }
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
