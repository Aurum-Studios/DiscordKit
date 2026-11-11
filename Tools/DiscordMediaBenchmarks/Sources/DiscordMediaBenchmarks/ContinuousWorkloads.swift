// File: Tools/DiscordMediaBenchmarks/Sources/DiscordMediaBenchmarks/ContinuousWorkloads.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordMedia
import DiscordVoiceCodecs
import Foundation

extension MediaCatalog {
    /// Produces contiguous interleaved two-tone PCM at the actual source rate with distinct stereo channels.
    /// - Parameters:
    ///   - frames: Bounded positive frame count for one 20 ms catalog block.
    ///   - channels: One or two channels; right-channel phase differs while remaining normalized.
    ///   - rate: Source frames per second, one of the catalog's 16,000, 44,100 or 48,000 rates.
    ///   - firstFrame: Absolute stream offset, advanced across prefill and every population batch.
    /// - Returns: Exactly `frames * channels` finite samples; construction occurs outside batch timers.
    static func continuousSamples(frames: Int, channels: Int, rate: Int, firstFrame: UInt64) -> [Float] {
        (0..<(frames * channels)).map { index in
            let time = Double(firstFrame + UInt64(index / channels)) / Double(rate)
            let phase = Double(index % channels) * 0.3
            return Float(sin(time * 2 * .pi * 440 + phase) * 0.18 + sin(time * 2 * .pi * 206.8 + phase) * 0.04)
        }
    }

    /// Builds a population-long FIR stream with eight untimed prefill blocks and one final untimed flush.
    /// - Parameters:
    ///   - id: Version-two finite continuous-resampling identity.
    ///   - rate: Source rate of 16,000 or 44,100 frames per second; output is 48,000.
    ///   - channels: One or two channels, preserved through the stream.
    /// - Returns: Serial process-only batches; filter history and phase survive batch boundaries.
    /// Each output is compared with an independently owned continuous reference outside timing; total duration,
    /// finite signal and retained-history bounds are checked before final closure. No device or pacing is involved.
    static func continuousResample(_ id: String, rate: Int, channels: Int) -> MediaCase {
        let frames = rate / 50, prefill = 8
        return .continuous(id: id, dimensions: ["fixtureVersion": 2, "inputRate": UInt64(rate),
            "outputRate": 48_000, "inputFrames": UInt64(frames), "channels": UInt64(channels),
            "prefillBlocks": UInt64(prefill), "continuousState": 1, "finishInsideTimer": 0]) { seed in
            let format = try PCMFormat(sampleRate: rate, channelCount: channels)
            let initial = try PCMBandlimitedResampler(inputFormat: format, outputSampleRate: 48_000)
            let state = SerialState(ResamplerState(actual: initial, oracle: initial, firstFrame: seed % 997))
            for _ in 0..<prefill {
                let input = try PCMBuffer(format: format, samples: continuousSamples(frames: frames,
                    channels: channels, rate: rate, firstFrame: state.value.firstFrame))
                let actual = try state.value.actual.process(input), expected = try state.value.oracle.process(input)
                try require(actual == expected, "Continuous resampler prefill mismatch")
                state.value.firstFrame += UInt64(frames); state.value.inputFrames += UInt64(frames)
                state.value.outputFrames += UInt64(actual.reduce(0) { $0 + $1.frameCount })
            }
            return MediaSession(prepare: { count, _ in
                var inputs: [PCMBuffer] = [], expected: [[PCMBuffer]] = []
                var oracle = state.value.oracle, firstFrame = state.value.firstFrame
                for _ in 0..<count {
                    let input = try PCMBuffer(format: format, samples: continuousSamples(frames: frames,
                        channels: channels, rate: rate, firstFrame: firstFrame))
                    inputs.append(input); expected.append(try oracle.process(input))
                    firstFrame += UInt64(frames)
                }
                let preparedInputs = inputs, expectedOutputs = expected
                let nextOracle = oracle, nextFirstFrame = firstFrame
                let results = SerialResults<[PCMBuffer]>(capacity: count)
                return MediaBatch(run: {
                    for input in preparedInputs { results.values.append(try state.value.actual.process(input)) }
                    return UInt64(results.values.count)
                }, verify: {
                    try require(results.values == expectedOutputs, "Continuous resampler output mismatch")
                    try require(results.values.flatMap { $0 }.flatMap(\.samples).allSatisfy(\.isFinite),
                        "Continuous resampler nonfinite output")
                    state.value.oracle = nextOracle; state.value.firstFrame = nextFirstFrame
                    state.value.inputFrames += UInt64(count * frames)
                    state.value.outputFrames += UInt64(results.values.flatMap { $0 }.reduce(0) { $0 + $1.frameCount })
                }, close: { results.values.removeAll() })
            }, verify: {
                try require(state.value.actual.retainedFrameCount > 0
                    && state.value.actual.retainedFrameCount <= state.value.actual.maximumRetainedFrameCount,
                    "Continuous resampler history absent or unbounded")
                let tail = try state.value.actual.finish(), expected = try state.value.oracle.finish()
                try require(tail == expected, "Continuous resampler flush mismatch")
                state.value.outputFrames += UInt64(tail.reduce(0) { $0 + $1.frameCount })
                try require(state.value.outputFrames == state.value.inputFrames * 48_000 / UInt64(rate),
                    "Continuous resampler stream duration mismatch")
            }, close: {
                state.value.actual.reset(); state.value.oracle.reset()
            })
        }
    }

    /// Builds continuously advancing CELT/SILK/hybrid encoder or decoder state at 20 ms per call.
    /// - Parameters:
    ///   - id: New finite version-two identity, leaving all legacy codec layouts unchanged.
    ///   - action: `encode` or `decode`, selecting only that public wrapper inside timing.
    ///   - name: `celt`, `silk` or `hybrid`; SILK/hybrid retain the existing FEC and bitrate policy.
    ///   - channels: One or two channels, preserved across all prefill and measured calls.
    /// - Returns: A population owner warmed by eight contiguous frames; no timed per-call state copy/reset.
    /// Untimed reference owners prepare complete packet/PCM oracles. Input construction and packet production for
    /// decode stay outside timing. State is independently recreated for warmup and measurement and released at close.
    static func continuousOpus(_ id: String, action: String, mode name: String, channels: Int) -> MediaCase {
        let mode: OpusMode = name == "silk" ? .silk : name == "hybrid" ? .hybrid : .celt
        let bitrate = mode == .celt ? 64_000 : 256_000, prefill = 8, frames = 960
        return .continuous(id: id, dimensions: ["fixtureVersion": 2, "frameSamples": 960,
            "frameIntervalNanoseconds": 20_000_000, "channels": UInt64(channels), "prefillFrames": UInt64(prefill),
            "continuousState": 1, "targetBitrate": UInt64(bitrate), "inBandFEC": mode == .celt ? 0 : 1]) { seed in
            let encoder = try OpusAudioEncoder(mode: mode, bandwidth: mode == .silk ? .wideband : .fullband,
                frameSampleCount: frames, channelCount: channels, targetBitrate: bitrate, enableInBandFEC: mode != .celt)
            let decoder = try OpusAudioDecoder(channelCount: channels)
            let state = SerialState(CodecState(actualEncoder: encoder, oracleEncoder: encoder,
                actualDecoder: decoder, oracleDecoder: decoder, firstFrame: seed % 997))
            for _ in 0..<prefill {
                let input = continuousSamples(frames: frames, channels: channels, rate: 48_000,
                    firstFrame: state.value.firstFrame)
                let packet = try state.value.actualEncoder.encode(input), expected = try state.value.oracleEncoder.encode(input)
                try require(packet == expected, "Continuous Opus prefill packet mismatch")
                let actual = try state.value.actualDecoder.decode(packet.data)
                let reference = try state.value.oracleDecoder.decode(expected.data)
                try require(actual == reference, "Continuous Opus prefill PCM mismatch")
                state.value.firstFrame += UInt64(frames)
            }
            return MediaSession(prepare: { count, _ in
                var inputs: [[Float]] = [], packets: [OpusAudioEncodedPacket] = [], decoded: [[OpusAudioDecodedFrame]] = []
                var oracleEncoder = state.value.oracleEncoder, oracleDecoder = state.value.oracleDecoder
                var firstFrame = state.value.firstFrame
                for _ in 0..<count {
                    let input = continuousSamples(frames: frames, channels: channels, rate: 48_000,
                        firstFrame: firstFrame)
                    inputs.append(input)
                    let packet = try oracleEncoder.encode(input)
                    packets.append(packet)
                    if action == "decode" { decoded.append(try oracleDecoder.decode(packet.data)) }
                    firstFrame += UInt64(frames)
                }
                let preparedInputs = inputs, expectedPackets = packets, expectedPCM = decoded
                let nextOracleEncoder = oracleEncoder, nextOracleDecoder = oracleDecoder, nextFirstFrame = firstFrame
                let encodedResults = SerialResults<OpusAudioEncodedPacket>(capacity: count)
                let decodedResults = SerialResults<[OpusAudioDecodedFrame]>(capacity: count)
                return MediaBatch(run: {
                    for index in 0..<count {
                        if action == "encode" {
                            encodedResults.values.append(try state.value.actualEncoder.encode(preparedInputs[index]))
                        } else { decodedResults.values.append(try state.value.actualDecoder.decode(expectedPackets[index].data)) }
                    }
                    return UInt64(action == "encode" ? encodedResults.values.count : decodedResults.values.count)
                }, verify: {
                    if action == "encode" {
                        try require(encodedResults.values == expectedPackets, "Continuous Opus packet mismatch")
                    } else {
                        try require(decodedResults.values == expectedPCM, "Continuous Opus PCM mismatch")
                        for output in decodedResults.values {
                            try require(output.reduce(0) { $0 + $1.frameSampleCount } == frames
                                && output.flatMap(\.samples).allSatisfy(\.isFinite), "Continuous Opus signal/duration mismatch")
                        }
                    }
                    state.value.oracleEncoder = nextOracleEncoder; state.value.oracleDecoder = nextOracleDecoder
                    state.value.firstFrame = nextFirstFrame
                }, close: { encodedResults.values.removeAll(); decodedResults.values.removeAll() })
            }, verify: {}, close: {
                // Release the streaming buffers before the population relinquishes its owners.
                state.value.actualEncoder = encoder; state.value.oracleEncoder = encoder
                state.value.actualDecoder = decoder; state.value.oracleDecoder = decoder
            })
        }
    }
}

private struct ResamplerState: Sendable {
    var actual: PCMBandlimitedResampler
    var oracle: PCMBandlimitedResampler
    var firstFrame: UInt64
    var inputFrames: UInt64 = 0
    var outputFrames: UInt64 = 0
}

private struct CodecState: Sendable {
    var actualEncoder: OpusAudioEncoder
    var oracleEncoder: OpusAudioEncoder
    var actualDecoder: OpusAudioDecoder
    var oracleDecoder: OpusAudioDecoder
    var firstFrame: UInt64
}
