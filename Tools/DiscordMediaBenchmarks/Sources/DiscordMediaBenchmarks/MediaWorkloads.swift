// File: Tools/DiscordMediaBenchmarks/Sources/DiscordMediaBenchmarks/MediaWorkloads.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordMedia
import DiscordVoice
import DiscordVoiceCodecs
import Foundation

extension MediaCatalog {
    /// Prepares a cold bandlimited process/finish wrapper and a full duration/PCM oracle outside timing.
    static func resample(_ id: String, rate: Int, channels: Int) throws -> MediaCase {
        let frames = rate / 50
        return MediaCase(id: id, transition: false, dimensions: ["inputRate": UInt64(rate), "outputRate": 48_000,
            "inputFrames": UInt64(frames), "channels": UInt64(channels)]) { count, seed in
            let input = try PCMBuffer(format: PCMFormat(sampleRate: rate, channelCount: channels),
                samples: samples(frames: frames, channels: channels, seed: seed))
            let prototype = try PCMBandlimitedResampler(inputFormat: input.format, outputSampleRate: 48_000)
            var oracle = prototype
            let expected = try oracle.process(input) + oracle.finish()
            try require(expected.reduce(0) { $0 + $1.frameCount } == frames * 48_000 / rate,
                "Resampler duration mismatch")
            try require(expected.flatMap(\.samples).allSatisfy(\.isFinite), "Nonfinite resampling output")
            return .compared(count: count, expected: expected) {
                var converter = prototype
                return try converter.process(input) + converter.finish()
            }
        }
    }

    /// Prepares a supported fixed Opus layout, complete packet/PCM oracle and independent initial/warmed copies.
    /// SILK/hybrid enable FEC; CELT recover deliberately exercises the documented concealment fallback.
    static func opus(_ id: String, action: String, mode name: String, frames: Int, channels: Int) throws -> MediaCase {
        let mode: OpusMode = name == "silk" ? .silk : name == "hybrid" ? .hybrid : .celt
        let bandwidth: OpusBandwidth = mode == .silk ? .wideband : .fullband
        let bitrate = mode == .celt ? 64_000 : 256_000
        return MediaCase(id: id, transition: false, dimensions: ["frameSamples": UInt64(frames),
            "frameIntervalNanoseconds": UInt64(frames) * 1_000_000_000 / 48_000, "channels": UInt64(channels),
            "inBandFEC": mode == .celt ? 0 : 1, "targetBitrate": UInt64(bitrate)]) { count, seed in
            let input = samples(frames: frames, channels: channels, seed: seed)
            let prototype = try OpusAudioEncoder(mode: mode, bandwidth: bandwidth, frameSampleCount: frames,
                channelCount: channels, targetBitrate: bitrate,
                enableInBandFEC: mode != .celt)
            var encoder = prototype
            let first = try encoder.encode(input)
            let second = try encoder.encode(samples(frames: frames, channels: channels, seed: seed &+ 1))
            try require(!first.data.isEmpty && first.shouldTransmit, "Encoded fixture missing")
            var decoder = try OpusAudioDecoder(channelCount: channels)
            let decoded = try decoder.decode(first.data)
            try require(decoded.reduce(0) { $0 + $1.frameSampleCount } == frames,
                "Opus fixture duration mismatch")
            try require(decoded.flatMap(\.samples).allSatisfy(\.isFinite), "Nonfinite decoded samples")
            if action == "encode" {
                return .compared(count: count, expected: first) {
                    var local = prototype; return try local.encode(input)
                }
            }
            if action == "decode" {
                let cold = try OpusAudioDecoder(channelCount: channels)
                return .compared(count: count, expected: decoded) {
                    var local = cold; return try local.decode(first.data)
                }
            }
            let warm = decoder
            let expected = action == "conceal" ? try decoder.conceal(frameSampleCount: frames)
                : try decoder.recover(second.data, frameSampleCount: frames)
            try require(expected.samples.count == frames * channels && expected.samples.allSatisfy(\.isFinite),
                "Recovery output mismatch")
            return .compared(count: count, expected: expected) {
                var local = warm
                return action == "conceal" ? try local.conceal(frameSampleCount: frames)
                    : try local.recover(second.data, frameSampleCount: frames)
            }
        }
    }

    /// Three admitted packets deliberately arrive out of order around one explicit loss slot.
    static func jitter(_ id: String) -> MediaCase {
        MediaCase(id: id, transition: false, dimensions: ["packets": 3, "playoutSlots": 4,
            "emulatedLossSlots": 1, "capacity": 8]) { count, seed in
            let start = UInt16(truncatingIfNeeded: seed)
            let payload = Data([0xf8, 0xff, 0xfe])
            let packets = try [0, 2, 3].map { offset in
                try RTPPacket(sequence: start &+ UInt16(offset), timestamp: UInt32(offset * 960), ssrc: 7, payload: payload)
            }
            let expected: [VoicePlayout] = [.packet(packets[0]), .missing(sequence: start &+ 1),
                .packet(packets[1]), .packet(packets[2])]
            return .compared(count: count, expected: expected) {
                var jitter = try VoiceJitterBuffer(ssrc: 7, nextSequence: start, capacity: 8)
                for packet in packets.reversed() { try jitter.insert(packet) }
                let output = (0..<4).map { _ in jitter.pop() }
                return output
            }
        }
    }

    /// Uses seeded wrapping RTP counters and a separately constructed exact packet oracle for full roundtrips.
    static func rtp(_ id: String) -> MediaCase {
        MediaCase(id: id, transition: false, dimensions: ["frameSamples": 960, "payloadBytes": 3]) { count, seed in
            let sequence = UInt16(truncatingIfNeeded: seed), timestamp = UInt32(truncatingIfNeeded: seed)
            let expected = try RTPPacket(marker: true, sequence: sequence, timestamp: timestamp, ssrc: 7,
                payload: Data([0xf8, 0xff, 0xfe]))
            return .compared(count: count, expected: expected) {
                var packetizer = OpusRTPPacketizer(ssrc: 7, sequence: sequence, timestamp: timestamp)
                let packet = try packetizer.packetize(Data([0xf8, 0xff, 0xfe]), marker: true)
                return try RTPPacket(bytes: packet.serialized())
            }
        }
    }
}
