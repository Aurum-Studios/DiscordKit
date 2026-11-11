// File: Tools/DiscordMediaBenchmarks/Sources/DiscordMediaBenchmarks/PhaseEightWorkloads.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordMedia
import Foundation

extension MediaCatalog {
    /// Stage-eight endpoints keep plan construction, continuous processing and final flushing independent.
    static var phaseEightIDs: [String] {
        var result: [String] = []
        for (source, destination) in phaseEightRates {
            for layout in ["mono", "stereo"] {
                for chunks in ["regular", "irregular"] {
                    result.append("resample.v3.continuous.\(source).\(destination).\(layout).\(chunks)")
                }
                for endpoint in ["startup", "finish"] {
                    result.append("resample.v3.\(endpoint).\(source).\(destination).\(layout)")
                }
            }
        }
        for depth in [1, 8, 64, 1_024, 4_096] { result.append("pcm.v3.queue.occupancy\(depth)") }
        return result
    }

    /// Four ordinary audio ratios and a relatively-prime fallback control, all within public rate limits.
    static let phaseEightRates = [(16_000, 48_000), (44_100, 48_000), (48_000, 16_000),
        (48_000, 44_100), (48_000, 47_999)]

    /// Resolves version-three policy without constructing any owner or fixture.
    static func phaseEightSelected(_ id: String, parts: [String]) -> MediaCase {
        if parts[0] == "pcm" { return pcmQueueOccupancy(id, depth: Int(parts[3].dropFirst(9))!) }
        let source = Int(parts[3])!, destination = Int(parts[4])!, channels = parts[5] == "mono" ? 1 : 2
        if parts[2] == "continuous" {
            return phaseEightContinuousResample(id, source: source, destination: destination,
                channels: channels, irregular: parts[6] == "irregular")
        }
        return phaseEightResampleEndpoint(id, source: source, destination: destination,
            channels: channels, startup: parts[2] == "startup")
    }

    /// Measures only process on one prefilled stream; irregular chunks advance through 1, 127 and 509 frames.
    /// Complete PCM comparisons, duration carry, retained-history bounds and one final flush are untimed.
    static func phaseEightContinuousResample(_ id: String, source: Int, destination: Int,
        channels: Int, irregular: Bool) -> MediaCase {
        let chunkFrames = irregular ? [1, 127, 509] : [source / 50], prefill = 8
        return .continuous(id: id, dimensions: ["fixtureVersion": 3, "inputRate": UInt64(source),
            "outputRate": UInt64(destination), "channels": UInt64(channels), "prefillBlocks": UInt64(prefill),
            "prefillBlockFrames": UInt64(source / 50), "continuousState": 1,
            "chunkPatternLength": UInt64(chunkFrames.count), "minimumChunkFrames": UInt64(chunkFrames.min()!),
            "maximumChunkFrames": UInt64(chunkFrames.max()!), "startupInsideTimer": 0, "finishInsideTimer": 0]) { seed in
            let format = try PCMFormat(sampleRate: source, channelCount: channels)
            let state = SerialState(PhaseEightResamplerState(
                actual: try PCMBandlimitedResampler(inputFormat: format, outputSampleRate: destination),
                oracle: try PCMBandlimitedResampler(inputFormat: format, outputSampleRate: destination),
                firstFrame: seed % 997))
            for _ in 0..<prefill {
                let frames = source / 50
                let input = try PCMBuffer(format: format, samples: continuousSamples(frames: frames,
                    channels: channels, rate: source, firstFrame: state.value.firstFrame))
                let actual = try state.value.actual.process(input), expected = try state.value.oracle.process(input)
                try require(actual == expected, "Stage-eight resampler prefill mismatch")
                state.value.firstFrame += UInt64(frames); state.value.inputFrames += UInt64(frames)
                state.value.outputFrames += UInt64(actual.reduce(0) { $0 + $1.frameCount })
            }
            return MediaSession(prepare: { count, _ in
                var oracle = state.value.oracle, firstFrame = state.value.firstFrame
                var chunkIndex = state.value.chunkIndex, inputFrames: UInt64 = 0
                var inputs: [PCMBuffer] = [], expected: [[PCMBuffer]] = []
                for _ in 0..<count {
                    let frames = chunkFrames[chunkIndex % chunkFrames.count]
                    let input = try PCMBuffer(format: format, samples: continuousSamples(frames: frames,
                        channels: channels, rate: source, firstFrame: firstFrame))
                    inputs.append(input); expected.append(try oracle.process(input))
                    firstFrame += UInt64(frames); inputFrames += UInt64(frames); chunkIndex += 1
                }
                let preparedInputs = inputs, expectedOutputs = expected, nextOracle = oracle
                let nextFirstFrame = firstFrame, nextChunkIndex = chunkIndex, admittedInputFrames = inputFrames
                let results = SerialResults<[PCMBuffer]>(capacity: count)
                return MediaBatch(run: {
                    for input in preparedInputs { results.values.append(try state.value.actual.process(input)) }
                    return UInt64(results.values.count)
                }, verify: {
                    try require(results.values == expectedOutputs, "Stage-eight continuous PCM mismatch")
                    try require(results.values.flatMap { $0 }.flatMap(\.samples).allSatisfy(\.isFinite),
                        "Stage-eight continuous PCM is nonfinite")
                    state.value.oracle = nextOracle; state.value.firstFrame = nextFirstFrame
                    state.value.chunkIndex = nextChunkIndex; state.value.inputFrames += admittedInputFrames
                    state.value.outputFrames += UInt64(results.values.flatMap { $0 }.reduce(0) { $0 + $1.frameCount })
                }, close: { results.values.removeAll() })
            }, verify: {
                try require(state.value.actual.retainedFrameCount > 0
                    && state.value.actual.retainedFrameCount <= state.value.actual.maximumRetainedFrameCount,
                    "Stage-eight retained history absent or unbounded")
                let tail = try state.value.actual.finish(), expected = try state.value.oracle.finish()
                try require(tail == expected && tail.flatMap(\.samples).allSatisfy(\.isFinite),
                    "Stage-eight final PCM mismatch")
                state.value.outputFrames += UInt64(tail.reduce(0) { $0 + $1.frameCount })
                try require(state.value.outputFrames == state.value.inputFrames * UInt64(destination) / UInt64(source)
                    && state.value.actual.accountedRetainedBytes == 0, "Stage-eight stream duration/cleanup mismatch")
            }, close: { state.value.actual.reset(); state.value.oracle.reset() })
        }
    }

    /// Times each independent constructor or prepared owner's finish directly, excluding the other endpoint.
    /// Constructor results remain retained until untimed semantic probes; finish owners are prepared independently.
    static func phaseEightResampleEndpoint(_ id: String, source: Int, destination: Int,
        channels: Int, startup: Bool) -> MediaCase {
        MediaCase(id: id, transition: false, dimensions: ["fixtureVersion": 3, "inputRate": UInt64(source),
            "outputRate": UInt64(destination), "channels": UInt64(channels), "inputFrames": UInt64(source / 50),
            "startupInsideTimer": startup ? 1 : 0, "processInsideTimer": 0,
            "finishInsideTimer": startup ? 0 : 1, "constructorResultsRetained": startup ? 1 : 0]) { count, seed in
            let format = try PCMFormat(sampleRate: source, channelCount: channels)
            let input = try PCMBuffer(format: format, samples: continuousSamples(frames: source / 50,
                channels: channels, rate: source, firstFrame: seed % 997))
            var oracle = try PCMBandlimitedResampler(inputFormat: format, outputSampleRate: destination)
            let prefix = try oracle.process(input), expectedTail = try oracle.finish()
            let expectedSignal = (prefix + expectedTail).flatMap(\.samples)
            try require((prefix + expectedTail).reduce(0) { $0 + $1.frameCount } == source / 50 * destination / source,
                "Stage-eight endpoint duration mismatch")
            if startup {
                let results = SerialResults<PCMBandlimitedResampler>(capacity: count)
                return MediaBatch(run: {
                    for _ in 0..<count {
                        results.values.append(try PCMBandlimitedResampler(inputFormat: format, outputSampleRate: destination))
                    }
                    return UInt64(results.values.count)
                }, verify: {
                    try require(results.values.count == count, "Stage-eight constructor count mismatch")
                    for index in results.values.indices {
                        try require(!results.values[index].isFinished && results.values[index].retainedFrameCount == 0,
                            "Stage-eight constructor unexpectedly retained signal")
                        let actual = try results.values[index].process(input) + results.values[index].finish()
                        try require(actual.flatMap(\.samples) == expectedSignal, "Stage-eight constructor PCM mismatch")
                    }
                }, close: { results.values.removeAll() })
            }
            var prepared: [PCMBandlimitedResampler] = []
            for _ in 0..<count {
                var owner = try PCMBandlimitedResampler(inputFormat: format, outputSampleRate: destination)
                try require(try owner.process(input) == prefix, "Stage-eight finish preparation mismatch")
                prepared.append(owner)
            }
            let owners = SerialState(prepared), results = SerialResults<[PCMBuffer]>(capacity: count)
            return MediaBatch(run: {
                for index in owners.value.indices { results.values.append(try owners.value[index].finish()) }
                return UInt64(results.values.count)
            }, verify: {
                try require(results.values.count == count && results.values.allSatisfy { $0 == expectedTail },
                    "Stage-eight finish PCM mismatch")
                for index in owners.value.indices {
                    try require(owners.value[index].isFinished && owners.value[index].accountedRetainedBytes == 0,
                        "Stage-eight finish retained history")
                    try require(try owners.value[index].finish().isEmpty, "Stage-eight finish not idempotent")
                }
            }, close: { results.values.removeAll(); owners.value.removeAll() })
        }
    }

    /// Rotates a full FIFO at fixed occupancy, including two public actor hops per timed wrapper call.
    /// Full FIFO/reference comparison and byte-budget checks occur outside timing; closure releases all PCM.
    static func pcmQueueOccupancy(_ id: String, depth: Int) -> MediaCase {
        let frames = 960, channels = 2, blockBytes = frames * channels * MemoryLayout<Float>.stride
        return .continuous(id: id, dimensions: ["fixtureVersion": 3, "continuousState": 1,
            "queueOccupancy": UInt64(depth), "maximumBlocks": UInt64(depth), "inputFrames": UInt64(frames),
            "inputRate": 48_000, "channels": UInt64(channels), "blockBytes": UInt64(blockBytes),
            "retainedPCMBytes": UInt64(depth * blockBytes), "readsPerCall": 1, "writesPerCall": 1]) { seed in
            let format = try PCMFormat(sampleRate: 48_000, channelCount: channels)
            let queue = try PCMFrameQueue(maximumBlocks: depth, maximumBytes: depth * blockBytes)
            let state = SerialState(PhaseEightQueueState(queue: queue, nextIndex: seed % 997))
            do {
                for _ in 0..<depth {
                    let input = try queueBuffer(format: format, frames: frames, index: state.value.nextIndex)
                    try await queue.write(input); state.value.expected.append(input); state.value.nextIndex += 1
                }
            } catch { await queue.finish(discardingBuffered: true); throw error }
            return MediaSession(prepare: { count, _ in
                var expected = state.value.expected, nextIndex = state.value.nextIndex
                var inputs: [PCMBuffer] = [], expectedOutputs: [PCMBuffer?] = []
                for _ in 0..<count {
                    let input = try queueBuffer(format: format, frames: frames, index: nextIndex)
                    inputs.append(input); expectedOutputs.append(expected.removeFirst()); expected.append(input)
                    nextIndex += 1
                }
                let preparedInputs = inputs, expectedResults = expectedOutputs, nextExpected = expected, next = nextIndex
                let results = SerialResults<PCMBuffer?>(capacity: count)
                return MediaBatch(run: {
                    for input in preparedInputs {
                        results.values.append(try await queue.read()); try await queue.write(input)
                    }
                    return UInt64(results.values.count)
                }, verify: {
                    try require(results.values == expectedResults, "PCM queue FIFO mismatch")
                    let bytes = await queue.accountedBytes
                    try require(bytes == depth * blockBytes, "PCM queue occupancy/accounting mismatch")
                    state.value.expected = nextExpected; state.value.nextIndex = next
                }, close: { results.values.removeAll() })
            }, verify: {
                await queue.finish()
                var drained: [PCMBuffer] = []
                while let buffer = try await queue.read() { drained.append(buffer) }
                let bytes = await queue.accountedBytes, finished = await queue.isFinished
                try require(drained == state.value.expected && drained.count == depth && bytes == 0 && finished,
                    "PCM queue final drain/accounting mismatch")
                state.value.expected.removeAll()
            }, close: { await queue.finish(discardingBuffered: true); state.value.expected.removeAll() })
        }
    }

    /// Distinct stereo blocks expose FIFO mistakes without spending trigonometric fixture work on queue tests.
    private static func queueBuffer(format: PCMFormat, frames: Int, index: UInt64) throws -> PCMBuffer {
        let value = Float(index % 8_192 + 1) / 16_384
        return try PCMBuffer(format: format, samples: (0..<frames).flatMap { _ in [value, -value] })
    }
}

private struct PhaseEightResamplerState: Sendable {
    var actual: PCMBandlimitedResampler
    var oracle: PCMBandlimitedResampler
    var firstFrame: UInt64
    var chunkIndex = 0
    var inputFrames: UInt64 = 0
    var outputFrames: UInt64 = 0
}

private struct PhaseEightQueueState: Sendable {
    let queue: PCMFrameQueue
    var nextIndex: UInt64
    var expected: [PCMBuffer] = []
}
