// File: Tools/VoiceSessionQualification/Sources/VoiceSessionQualification/QualificationConfiguration.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordVoiceCodecs
import Foundation

/// Bounded profile admission runs before opening keys, sockets or contention tasks.
struct QualificationConfiguration: Equatable, Sendable {
    var seconds = 600.0
    var output: String?
    var commonReport: String?
    var attributed = false
    var seed: UInt64 = 1
    var frameSamples = 960
    var channels = 1
    var mode = "celt"
    var dtx = false
    var signal = "tone"
    var lossEvery = 0
    var reorderEvery = 0
    var jitterMilliseconds = 0
    var contentionWorkers = 0

    /// Rounds the requested finite wall interval upward to nanoseconds for exact profile identity.
    var requestedNanoseconds: UInt64 { UInt64((seconds * 1_000_000_000).rounded(.up)) }
    /// Uses bounded fixture byte budgets proven to encode the admitted channel and frame geometries.
    var targetBitrate: Int { mode == "celt" ? 96_000 : 256_000 }
    /// Returns the exact selected 48kHz frame duration used by pacing and deadline checks.
    var frameNanoseconds: Int64 { Int64(frameSamples) * 1_000_000_000 / 48_000 }
    /// Expresses the selected frame duration in milliseconds without rounding short frames.
    var frameMilliseconds: Double { Double(frameSamples) / 48 }
    /// Rounds offered measured frames upward to cover the requested wall interval.
    var frameCount: Int { Int(ceil(seconds * 48_000 / Double(frameSamples))) }
    /// Returns the exact frame count for the fixed two-second uninterrupted warmup.
    var warmupFrames: Int { 96_000 / frameSamples }
    /// Rounds maximum emulated delay upward to complete selected frame intervals.
    var jitterFrames: Int { Int(ceil(Double(jitterMilliseconds) / frameMilliseconds)) }
    /// Provides sufficient fixed playout delay for every configured bounded hold.
    var playoutDelayFrames: Int { max(jitterFrames, reorderEvery > 0 ? 1 : 0) }
    /// Maps only the previously admitted finite mode name to the production codec mode.
    var opusMode: OpusMode { mode == "silk" ? .silk : (mode == "hybrid" ? .hybrid : .celt) }
    /// Selects wideband SILK or fullband CELT/hybrid without runtime format changes.
    var bandwidth: OpusBandwidth { mode == "silk" ? .wideband : .fullband }

    /// Parses exact pairs and rejects duplicate, unsupported or unbounded profiles.
    static func parse(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        var result = Self()
        guard arguments.count.isMultiple(of: 2) else { throw QualificationFailure.invalidArguments }
        var seen: Set<String> = []
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let key = arguments[index], value = arguments[index + 1]
            guard seen.insert(key).inserted, !value.isEmpty else { throw QualificationFailure.invalidArguments }
            switch key {
            case "--seconds":
                guard let parsed = Double(value), parsed.isFinite, (0.02...3600).contains(parsed) else { throw QualificationFailure.invalidArguments }
                result.seconds = parsed
            case "--output": result.output = value
            case "--common-report": result.commonReport = value; result.attributed = true
            case "--seed":
                guard let parsed = UInt64(value) else { throw QualificationFailure.invalidArguments }
                result.seed = parsed; result.attributed = true
            case "--profile":
                guard value == "attributed" else { throw QualificationFailure.invalidArguments }
                result.attributed = true
            case "--mode": result.mode = value; result.attributed = true
            case "--signal": result.signal = value; result.attributed = true
            case "--dtx":
                guard value == "on" || value == "off" else { throw QualificationFailure.invalidArguments }
                result.dtx = value == "on"; result.attributed = true
            default:
                guard let parsed = Int(value) else { throw QualificationFailure.invalidArguments }
                switch key {
                case "--frame-samples": result.frameSamples = parsed
                case "--channels": result.channels = parsed
                case "--loss-every": result.lossEvery = parsed
                case "--reorder-every": result.reorderEvery = parsed
                case "--jitter-ms": result.jitterMilliseconds = parsed
                case "--contention-workers": result.contentionWorkers = parsed
                default: throw QualificationFailure.invalidArguments
                }
                result.attributed = true
            }
        }
        if result.attributed {
            if !seen.contains("--seed"), let value = environment["DK_BENCHMARK_SEED"] {
                guard let parsed = UInt64(value) else { throw QualificationFailure.invalidArguments }
                result.seed = parsed
            }
            if !seen.contains("--seconds"), let value = environment["DK_BENCHMARK_DURATION_SECONDS"] {
                guard let parsed = Double(value), parsed.isFinite, (0.02...3600).contains(parsed) else { throw QualificationFailure.invalidArguments }
                result.seconds = parsed
            }
            if let value = environment["DK_BENCHMARK_WARMUP_SECONDS"], Double(value) != 2 {
                throw QualificationFailure.invalidArguments
            }
        }
        guard [120, 240, 480, 960].contains(result.frameSamples), (1...2).contains(result.channels),
              ["celt", "silk", "hybrid"].contains(result.mode), ["tone", "talkspurts", "silence"].contains(result.signal),
              result.mode == "celt" || [480, 960].contains(result.frameSamples),
              (0...1000).contains(result.lossEvery), (0...1000).contains(result.reorderEvery),
              (0...100).contains(result.jitterMilliseconds), (0...4).contains(result.contentionWorkers)
        else { throw QualificationFailure.invalidArguments }
        if let destination = environment["DK_BENCHMARK_ENVELOPE"] {
            guard !destination.isEmpty else { throw QualificationFailure.invalidArguments }
            if result.commonReport == nil { result.commonReport = destination }
        }
        if let output = result.output, let common = result.commonReport {
            guard URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath()
                != URL(fileURLWithPath: common).standardizedFileURL.resolvingSymlinksInPath()
            else { throw QualificationFailure.invalidArguments }
        }
        // Codec admission also checks mode-specific bitrate/byte geometry before resources exist.
        _ = try result.encoder()
        return result
    }

    /// Builds one exclusively owned real codec; no resource, network or task is started.
    func encoder() throws -> OpusAudioEncoder {
        try OpusAudioEncoder(mode: opusMode, bandwidth: bandwidth, frameSampleCount: frameSamples,
            channelCount: channels, targetBitrate: targetBitrate, dtx: dtx ? OpusDTXPolicy() : nil)
    }

    /// Returns the deterministic activity state; one-second tone/silence alternation restarts talkspurts.
    func active(frame: Int) -> Bool {
        signal == "tone" || (signal == "talkspurts" && (frame * frameSamples / 48_000).isMultiple(of: 2))
    }

    /// Full profile dimensions prevent numerical comparison across incompatible policies.
    func identity() -> ReportIdentity {
        var value = ReportIdentity(scenario: "voice.local-duplex", profile: "attributed-\(mode)-\(signal)", profileVersion: 1, seed: seed,
            inputSizes: ["requestedFramesPerDirection": UInt64(frameCount), "warmupFramesPerDirection": UInt64(warmupFrames),
                "frameSamples": UInt64(frameSamples), "channels": UInt64(channels), "bitrate": UInt64(targetBitrate),
                "requestedDurationNanoseconds": requestedNanoseconds,
                "dtx": dtx ? 1 : 0, "lossEvery": UInt64(lossEvery), "reorderEvery": UInt64(reorderEvery),
                "jitterMilliseconds": UInt64(jitterMilliseconds), "contentionWorkers": UInt64(contentionWorkers),
                "playoutDelayFrames": UInt64(playoutDelayFrames)],
            instrumentation: "public-boundary-attribution-aggregate", scheduler: "continuous-clock-fixed-frame",
            concurrency: 2, requestedWarmupNanoseconds: 2_000_000_000, repetitions: 1)
        value.catalogVersion = 9
        return value
    }
}
