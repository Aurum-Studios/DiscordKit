// File: Tools/VoiceSessionQualification/Sources/VoiceSessionQualification/Attribution.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordTransport
import DiscordVoice
import DiscordVoiceCodecs
import Foundation

/// Fixed population collector with no media, identifier history, logging or export callbacks.
final class AttributionCapture: @unchecked Sendable {
    static let workloads: [BenchmarkWorkload] = [.voiceTick, .voicePacingLate, .voiceEncode,
        .voiceEncrypt, .voiceSend, .voiceReceiveDecrypt, .voiceDecode]
    private let lock = NSLock()
    private var enabled = false
    let statistics: RunStatistics
    /// Retains one preallocated finite population collector before any measured media work.
    init(statistics: RunStatistics) { self.statistics = statistics }
    /// Switches collection only between joined warmup, measured and drain ticks.
    func setEnabled(_ value: Bool) { lock.lock(); enabled = value; lock.unlock() }
    /// Records a completed public interval once, excluding warmup/drain and preserving cancellation or failure.
    func record(_ duration: Duration, workload: BenchmarkWorkload, error: (any Error)? = nil) {
        lock.lock(); let measuring = enabled; lock.unlock()
        guard measuring else { return }
        let outcome: BenchmarkOutcome
        if let error {
            if error is CancellationError { outcome = .cancelled }
            else if error as? TransportFailure == .deadlineExceeded { outcome = .timedOut }
            else { outcome = .failure }
        } else { outcome = .success }
        statistics.record(duration, workload: workload, outcome: outcome)
    }
}

/// Encoder wrapper measures only the synchronous production codec call, including DTX decisions.
struct AttributedEncoder: OpusPCMEncoding {
    var base: OpusAudioEncoder
    let capture: AttributionCapture
    /// Returns the exclusively owned production encoder's immutable 48kHz frame geometry.
    var frameSampleCount: Int { base.frameSampleCount }
    /// Returns the exclusively owned production encoder's immutable interleaved layout.
    var channelCount: Int { base.channelCount }
    /// Times one synchronous production encode; the completed timestamp precedes histogram collection.
    mutating func encode(_ samples: [Float]) throws -> OpusAudioEncodedPacket {
        let clock = ContinuousClock(), start = ContinuousClock.now
        do {
            let result = try base.encode(samples)
            capture.record(start.duration(to: clock.now), workload: .voiceEncode)
            return result
        } catch {
            capture.record(start.duration(to: clock.now), workload: .voiceEncode, error: error)
            throw error
        }
    }
    /// Discards owned codec history when the production pipeline closes.
    mutating func reset() { base.reset() }
}

/// Measures DAVE sealing only; concrete transport AEAD is inside the enclosing pipeline boundary.
struct AttributedTransformer: VoiceFrameTransformer {
    let base: any VoiceFrameTransformer
    let capture: AttributionCapture
    /// Observes DAVE sealing alone, propagating the original error without retry or plaintext fallback.
    func seal(_ opus: Data, ssrc: UInt32) async throws -> Data {
        let clock = ContinuousClock(), start = ContinuousClock.now
        do {
            let result = try await base.seal(opus, ssrc: ssrc)
            capture.record(start.duration(to: clock.now), workload: .voiceEncrypt)
            return result
        } catch {
            capture.record(start.duration(to: clock.now), workload: .voiceEncrypt, error: error)
            throw error
        }
    }
    /// Forwards authenticated DAVE opening; its duration belongs to the enclosing receive public boundary.
    func open(_ frame: Data, ssrc: UInt32) async throws -> Data { try await base.open(frame, ssrc: ssrc) }
}

/// Measures the actual UDP adapter send; receive waits remain in the direct tick interval.
struct AttributedTransport: DatagramTransport {
    let base: any DatagramTransport
    let capture: AttributionCapture
    /// Times the actual UDP adapter send after encryption, with the caller's unchanged cancellation/deadline.
    func sendDatagram<C: Clock>(_ datagram: Datagram, context: TransportContext<C>) async throws where C.Duration == Duration {
        let clock = ContinuousClock(), start = ContinuousClock.now
        do {
            try await base.sendDatagram(datagram, context: context)
            capture.record(start.duration(to: clock.now), workload: .voiceSend)
        } catch {
            capture.record(start.duration(to: clock.now), workload: .voiceSend, error: error)
            throw error
        }
    }
    /// Forwards one bounded pull receive; receive waiting is part of the direct tick.
    func receiveDatagram<C: Clock>(context: TransportContext<C>) async throws -> Datagram? where C.Duration == Duration {
        try await base.receiveDatagram(context: context)
    }
    /// Awaits the exact adapter owner's shutdown without creating another resource owner.
    func close() async { await base.close() }
}

/// Deterministic bounded receive-side network impairment emulation, after real UDP delivery.
struct ImpairmentQueue {
    struct Pending { var due: Int; var ordinal: Int; var datagram: Datagram }
    static let capacity = 64
    private(set) var pending: [Pending] = []
    private(set) var dropped = 0
    private(set) var delayed = 0
    private(set) var reordered = 0
    private(set) var peakBytes = 0
    private(set) var peakCount = 0

    /// Reserves the finite queue ceiling before any measured packet arrives.
    init() { pending.reserveCapacity(Self.capacity) }

    /// Keeps at most 64 complete adapter-bounded datagrams; never creates network loss claims.
    mutating func enqueue(_ datagram: Datagram, tick: Int, ordinal: Int, configuration: QualificationConfiguration) throws {
        if configuration.lossEvery > 0 && ordinal.isMultiple(of: configuration.lossEvery) {
            dropped += 1; return
        }
        var delay = configuration.jitterFrames == 0 ? 0 : ordinal % (configuration.jitterFrames + 1)
        if configuration.reorderEvery > 0 && ordinal.isMultiple(of: configuration.reorderEvery) {
            delay = max(delay, 1); reordered += 1
        }
        if delay > 0 { delayed += 1 }
        guard pending.count < Self.capacity else { throw QualificationFailure.invariant }
        pending.append(.init(due: tick + delay, ordinal: ordinal, datagram: datagram))
        peakCount = max(peakCount, pending.count)
        peakBytes = max(peakBytes, pending.reduce(0) { $0 + $1.datagram.bytes.count })
    }

    /// Sends later packets first at equal deadlines so a one-frame hold actually reorders a stream.
    mutating func ready(tick: Int) -> [Datagram] {
        let ready = pending.filter { $0.due <= tick }.sorted {
            $0.due == $1.due ? $0.ordinal > $1.ordinal : $0.due < $1.due
        }
        pending.removeAll { $0.due <= tick }
        return ready.map(\.datagram)
    }
}

/// Owned bounded CPU contenders; cancellation and value awaiting are mandatory on every exit.
struct CPUContention {
    var tasks: [Task<UInt64, Never>]
    /// Starts only the admitted bounded number of cancellation-aware CPU workers.
    init(workers: Int) {
        tasks = (0..<workers).map { worker in Task.detached(priority: .userInitiated) {
            var checksum = UInt64(worker + 1)
            while !Task.isCancelled {
                for _ in 0..<65_536 { checksum = checksum &* 6_364_136_223_846_793_005 &+ 1 }
                await Task.yield()
            }
            return checksum
        } }
    }
    /// Cancels every contention task and awaits each terminal value before reporting closure.
    func close() async -> Int {
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.value }
        return tasks.count
    }
}

/// Additional native schema-three evidence. Raw dispatch gaps retain production counter semantics.
struct AttributedEvidence: Codable {
    /// Returns the exclusively owned production encoder's immutable 48kHz frame geometry.
    var frameSampleCount: Int
    /// Returns the exclusively owned production encoder's immutable interleaved layout.
    var channelCount: Int
    var mode: String
    var dtxEnabled: Bool
    var signal: String
    var frameIntervalMilliseconds: Double
    var emulation: String
    var emulatedLossEvery: Int
    var emulatedReorderEvery: Int
    var emulatedJitterMilliseconds: Int
    var playoutDelayFrames: Int
    var drainFrames: Int
    var emulatedDroppedPackets: Int
    var emulatedDelayedPackets: Int
    var emulatedReorderSelections: Int
    var pendingEmulationCapacityDatagrams: Int
    var peakPendingEmulationDatagrams: Int
    var peakPendingEmulationBytes: Int
    var expectedSentPackets: UInt64
    var intentionallySuppressedFrames: UInt64
    var silenceRefreshPackets: UInt64
    var talkspurtRestarts: UInt64
    var policyCadenceMissCount: UInt64
    var policyMaximumExpectedDispatchGapMilliseconds: Double
    var maximumDispatchGapBeyondExpectedMilliseconds: Double
    var rawSendIntervalOverrunCount: UInt64
    var maximumSendIntervalMilliseconds: Double
    var encodedFrameCount: UInt64
    var encodingDeadlineMissCount: UInt64
    var maximumEncodingDurationMilliseconds: Double
    var contentionWorkers: Int
    var closedContentionWorkers: Int
    var attributionScopes: [String: String]
}

/// Independent expected-cadence policy for this tool's fixed 200ms hangover and 400ms refresh.
/// It compares transmission decisions with frame/media time, so suppression never counts as loss.
struct SendCadencePolicy {
    var inactiveSamples = 0
    var samplesSinceRefresh = 0
    var previousActive = true
    var frame = 0
    var previousTransmissionFrame = -1
    var maximumExpectedGapFrames = 1
    var suppressed: UInt64 = 0
    var refreshes: UInt64 = 0
    var restarts: UInt64 = 0
    /// Advances one media frame through the independent fixed DTX cadence, retaining only numeric counters.
    mutating func expectsTransmission(active: Bool, configuration: QualificationConfiguration) -> Bool {
        var transmit = true
        if configuration.dtx && !active {
            inactiveSamples += configuration.frameSamples
            let hangover = (9_600 + configuration.frameSamples - 1) / configuration.frameSamples * configuration.frameSamples
            if inactiveSamples > hangover {
                samplesSinceRefresh += configuration.frameSamples
                transmit = samplesSinceRefresh >= 19_200
                if transmit { refreshes += 1 }
            }
        } else { inactiveSamples = 0 }
        if active && !previousActive { restarts += 1 }
        if transmit {
            maximumExpectedGapFrames = max(maximumExpectedGapFrames, frame - previousTransmissionFrame)
            previousTransmissionFrame = frame
            samplesSinceRefresh = 0
        } else { suppressed += 1 }
        previousActive = active
        frame += 1
        return transmit
    }
}
