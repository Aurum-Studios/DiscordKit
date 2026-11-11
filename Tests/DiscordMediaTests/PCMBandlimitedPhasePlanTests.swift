// File: Tests/DiscordMediaTests/PCMBandlimitedPhasePlanTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Foundation
import Testing
@testable import DiscordMedia

@Suite("Bounded immutable bandlimited phase plans")
struct PCMBandlimitedPhasePlanTests {
    /// Checks both sides of the exact byte cap, common rational periods and costly fallback pairs.
    /// The 448-phase fixture uses 261,632 bytes; a 449-phase fixture would require 262,216.
    /// - Parameters:
    ///   - sourceRate: Validated input-clock rate.
    ///   - destinationRate: Validated output-clock rate.
    ///   - phases: Expected stored phases; zero means identity or direct coefficient evaluation.
    @Test(arguments: [
        (48_000, 48_000, 0), (16_000, 48_000, 3), (48_000, 16_000, 1),
        (44_100, 48_000, 160), (48_000, 44_100, 147),
        (44_700, 44_800, 448), (44_800, 44_900, 0),
        (44_101, 48_000, 0), (48_000, 44_101, 0),
        (192_000, 8_000, 1), (192_000, 8_001, 0), (8_000, 192_000, 24)
    ])
    func phasePlanPayloadIsBounded(sourceRate: Int, destinationRate: Int, phases: Int) throws {
        for channels in [1, 2] {
            let format = try PCMFormat(sampleRate: sourceRate, channelCount: channels)
            var converter = try PCMBandlimitedResampler(inputFormat: format, outputSampleRate: destinationRate)
            let expectedBytes = phases * (2 * converter.lookaheadFrames + 1) * MemoryLayout<Double>.stride
            #expect(converter.accountedPhasePlanBytes == expectedBytes)
            #expect(converter.accountedPhasePlanBytes <= PCMBandlimitedResampler.maximumPhasePlanBytes)
            #expect(converter.accountedRetainedBytes == 0)
            converter.reset()
            #expect(converter.accountedPhasePlanBytes == expectedBytes)
            #expect(try converter.finish().isEmpty)
            #expect(converter.accountedPhasePlanBytes == expectedBytes)
        }
    }

    /// Compares all common-plan residues and both sides of the plan cap to the original direct FIR.
    /// Integer quotient/remainder reference indexing avoids streaming state and floating positions.
    /// Varying blocks additionally exercises history compaction, saturation and the finish tail.
    /// - Parameters:
    ///   - sourceRate: Source rate selecting a complete table or bounded direct fallback.
    ///   - destinationRate: Destination rate determining exact phase residues.
    ///   - channels: Distinct mono/stereo channel layouts.
    @Test(arguments: [
        (16_000, 48_000, 1), (16_000, 48_000, 2),
        (48_000, 16_000, 1), (48_000, 16_000, 2),
        (44_100, 48_000, 1), (44_100, 48_000, 2),
        (48_000, 44_100, 1), (48_000, 44_100, 2),
        (44_700, 44_800, 2), (44_800, 44_900, 2),
        (44_101, 48_000, 2), (48_000, 44_101, 2),
        (192_000, 8_001, 2)
    ])
    func phasePlansMatchDirectEvaluationExactly(sourceRate: Int, destinationRate: Int, channels: Int) throws {
        let format = try PCMFormat(sampleRate: sourceRate, channelCount: channels)
        let samples = fixture(frames: 1_103, channels: channels)
        let expected = directConvolution(samples: samples, format: format, destinationRate: destinationRate)
        #expect(try convert(samples: samples, format: format, destinationRate: destinationRate, chunks: [1_103]) == expected)
        #expect(try convert(samples: samples, format: format, destinationRate: destinationRate, chunks: [1, 37, 149, 3]) == expected)
    }

    /// Shares immutable plans while copies independently append different PCM, finish and reset.
    /// The unfinished copy retains its exact history and samples after the other resets/reuses.
    /// - Parameter sourceRate: A table-backed rate and a relatively prime fallback rate.
    @Test(arguments: [44_100, 44_101])
    func divergentCopiesKeepIndependentAudioAndLifecycle(sourceRate: Int) throws {
        let format = try PCMFormat(sampleRate: sourceRate, channelCount: 2)
        let prefix = fixture(frames: 211, channels: 2)
        let leftSuffix = fixture(frames: 389, channels: 2)
        let rightSuffix = leftSuffix.map { -$0 }
        var left = try PCMBandlimitedResampler(inputFormat: format, outputSampleRate: 48_000)
        let sharedOutput = try left.process(PCMBuffer(format: format, samples: prefix)).flatMap(\.samples)
        var right = left
        let planBytes = right.accountedPhasePlanBytes
        let rightRetained = right.accountedRetainedBytes
        let leftOutput = try left.process(PCMBuffer(format: format, samples: leftSuffix)).flatMap(\.samples)
        let leftTail = try left.finish().flatMap(\.samples)
        #expect(sharedOutput + leftOutput + leftTail == directConvolution(
            samples: prefix + leftSuffix, format: format, destinationRate: 48_000
        ))
        left.reset()
        _ = try left.process(PCMBuffer(format: format, samples: rightSuffix))
        #expect(!right.isFinished)
        #expect(right.accountedRetainedBytes == rightRetained)
        #expect(right.accountedPhasePlanBytes == planBytes)
        let rightOutput = try right.process(PCMBuffer(format: format, samples: rightSuffix)).flatMap(\.samples)
        let rightTail = try right.finish().flatMap(\.samples)
        #expect(sharedOutput + rightOutput + rightTail == directConvolution(
            samples: prefix + rightSuffix, format: format, destinationRate: 48_000
        ))
        #expect(!left.isFinished)
        #expect(right.isFinished)
        #expect(left.accountedPhasePlanBytes == planBytes)
        #expect(right.accountedPhasePlanBytes == planBytes)
    }

    /// Supplies signed full-scale discontinuities and channel-distinct values for FIR comparisons.
    /// - Parameters:
    ///   - frames: Positive bounded fixture length.
    ///   - channels: One or two interleaved samples per frame.
    /// - Returns: Finite normalized PCM, with discontinuities exposing clipping/endpoint behavior.
    private func fixture(frames: Int, channels: Int) -> [Float] {
        (0..<frames).flatMap { frame in
            (0..<channels).map { channel in
                if frame < 80 { return channel == 0 ? Float(1) : Float(-1) }
                if frame < 160 { return channel == 0 ? Float(-1) : Float(1) }
                return Float((frame * 17 + channel * 31) % 257 - 128) / 128
            }
        }
    }

    /// Evaluates the pre-plan FIR directly over a whole signal with exact integer phase arithmetic.
    /// The reference has no table, streaming history, pending count or compaction state.
    /// - Parameters:
    ///   - samples: Complete normalized interleaved input.
    ///   - format: Source layout and clock.
    ///   - destinationRate: Destination clock.
    /// - Returns: Exact duration-floor frames with the original coefficient/reduction order.
    private func directConvolution(samples: [Float], format: PCMFormat, destinationRate: Int) -> [Float] {
        let channels = format.channelCount
        let frames = samples.count / channels
        let cutoff = 0.9 * min(1, Double(destinationRate) / Double(format.sampleRate))
        let radius = Int(ceil(32 / cutoff))
        var output: [Float] = []
        for frame in 0..<(frames * destinationRate / format.sampleRate) {
            let phase = frame * format.sampleRate
            let center = phase / destinationRate
            let fraction = Double(phase % destinationRate) / Double(destinationRate)
            var coefficientSum = 0.0
            var left = 0.0
            var right = 0.0
            for offset in (-radius + 1)...radius {
                let distance = Double(offset) - fraction
                let angle = Double.pi * distance / Double(radius)
                let window = 0.42 + 0.5 * cos(angle) + 0.08 * cos(2 * angle)
                let argument = Double.pi * cutoff * distance
                let sinc = abs(argument) < 1e-12 ? 1 : sin(argument) / argument
                let coefficient = cutoff * sinc * window
                let index = max(0, min(frames - 1, center + offset)) * channels
                coefficientSum += coefficient
                left += Double(samples[index]) * coefficient
                if channels == 2 { right += Double(samples[index + 1]) * coefficient }
            }
            output.append(Float(max(-1, min(1, left / coefficientSum))))
            if channels == 2 { output.append(Float(max(-1, min(1, right / coefficientSum)))) }
        }
        return output
    }

    /// Processes a full signal using a repeating block pattern and appends its explicit finish tail.
    /// - Parameters:
    ///   - samples: Complete normalized interleaved input.
    ///   - format: Source layout and clock.
    ///   - destinationRate: Destination clock.
    ///   - chunks: Positive repeating block sizes within the 120ms cap.
    /// - Returns: Concatenated streaming output in original frame/channel order.
    /// - Throws: Propagates PCM fixture or converter validation errors.
    private func convert(samples: [Float], format: PCMFormat, destinationRate: Int, chunks: [Int]) throws -> [Float] {
        var converter = try PCMBandlimitedResampler(inputFormat: format, outputSampleRate: destinationRate)
        let frames = samples.count / format.channelCount
        var output: [Float] = []
        var start = 0
        var step = 0
        while start < frames {
            let count = min(chunks[step % chunks.count], frames - start)
            let lower = start * format.channelCount
            let upper = (start + count) * format.channelCount
            output.append(contentsOf: try converter.process(
                PCMBuffer(format: format, samples: Array(samples[lower..<upper]))
            ).flatMap(\.samples))
            #expect(converter.retainedFrameCount <= converter.maximumRetainedFrameCount)
            start += count
            step += 1
        }
        output.append(contentsOf: try converter.finish().flatMap(\.samples))
        return output
    }
}
