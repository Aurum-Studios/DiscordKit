// File: Tools/VoiceSessionQualification/Sources/VoiceSessionQualification/AttributedQualification.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import DiscordDAVE
import DiscordMLS
import DiscordMedia
import DiscordNIOTransport
import DiscordTransport
import DiscordVoice
import DiscordVoiceCrypto
import Foundation

/// Carries the original failed operation together with observed receipts after joined cleanup.
/// The executable rethrows `operationError`; this wrapper never changes its classification.
struct AttributedRunFailure: Error {
    let operationError: any Error
    let cleanup: BenchmarkCleanup
}

extension VoiceSessionQualification {
    /// Preserves production media ownership while observing declared overlapping public boundaries.
    /// - Parameters:
    ///   - configuration: Validated finite local profile and unchanged media/pacing geometry.
    ///   - statistics: Bounded observation owner; warmup observations remain excluded.
    ///   - measuredTick: Optional synchronous regression hook after measured playout and before
    ///     terminal tick accounting. Nil performs no extra work. A thrown error follows the
    ///     ordinary failure path and receives joined native closure receipts.
    /// - Returns: Native success/failure accounting after awaited resource closure.
    /// - Throws: Original setup/operation failures wrapped with observed cleanup once native
    ///   owners exist. Early fixture failures precede ownership and propagate unchanged.
    static func runAttributed(configuration: QualificationConfiguration, statistics: RunStatistics,
        measuredTick: (@Sendable (Int) throws -> Void)? = nil) async throws -> QualificationReport {
        let capture = AttributionCapture(statistics: statistics)
        var contention = CPUContention(workers: 0)
        let clock = ContinuousClock()
        let origin = clock.now
        let now: @Sendable () -> TimeInterval = { seconds(origin.duration(to: clock.now)) }
        let context = TransportContext(clock: clock, deadline: clock.now.advanced(by: .seconds(10)))
        let externalKey = Data(repeating: 1, count: 32)
        let fixtureOwner = try MLSKeyPackageOwner(userID: 99)
        let sender: MLSExternalSender
        do {
            let leaf = try MLSLeafNode.generate(identity: Data("localhost-fixture-external".utf8),
                signaturePrivateKey: externalKey, encryptionKey: fixtureOwner.keyPackage.leafNode.encryptionKey)
            sender = try MLSExternalSender(signatureKey: leaf.signatureKey, credential: leaf.credential)
        } catch {
            await fixtureOwner.close()
            throw error
        }
        await fixtureOwner.close()
        let firstCredentials = try credentials(1), secondCredentials = try credentials(2)
        let group = Data([0, 0, 0, 0, 0, 0, 0, 6])
        let firstDAVE = try DAVEVoiceSession(identity: firstCredentials.identity, groupID: group,
            signaturePrivateKey: Data(repeating: 2, count: 32), externalSender: sender, maximumParticipants: 2, now: now)
        let secondDAVE: DAVEVoiceSession
        do {
            secondDAVE = try DAVEVoiceSession(identity: secondCredentials.identity, groupID: group,
                signaturePrivateKey: Data(repeating: 3, count: 32), externalSender: sender, maximumParticipants: 2, now: now)
        } catch {
            await firstDAVE.close()
            throw error
        }
        var firstSocket: NIODatagramTransport?
        var secondSocket: NIODatagramTransport?
        var firstMedia: VoiceMediaPipeline<ContinuousClock>?
        var secondMedia: VoiceMediaPipeline<ContinuousClock>?
        var cipher: VoiceTransportCipher?
        do {
            try await establish(firstDAVE, secondDAVE, sender: sender, externalKey: externalKey)
            let firstUDP = try await NIODatagramTransport.bind(maximumDatagramBytes: 4_096,
                maximumPendingDatagrams: 8, maximumPendingBytes: 32_768, context: context)
            firstSocket = firstUDP
            let secondUDP = try await NIODatagramTransport.bind(maximumDatagramBytes: 4_096,
                maximumPendingDatagrams: 8, maximumPendingBytes: 32_768, context: context)
            secondSocket = secondUDP
            // Every same-key transmitter shares one counter authority; no counter domain is reset.
            let transportCipher = try VoiceTransportCipher(mode: .aeadXChaCha20Poly1305RTPSize,
                key: Data(repeating: 23, count: 32), maximumReceiveStreams: 2)
            cipher = transportCipher
            let first = try VoiceMediaPipeline(clock: clock, transport: AttributedTransport(base: firstUDP, capture: capture), peer: secondUDP.localAddress,
                cipher: transportCipher, transformer: AttributedTransformer(base: firstDAVE, capture: capture), ssrc: 111,
                encoder: AttributedEncoder(base: try configuration.encoder(), capture: capture),
                maximumReceiveStreams: 1, maximumBufferedBytes: 16_384)
            firstMedia = first
            let second = try VoiceMediaPipeline(clock: clock, transport: AttributedTransport(base: secondUDP, capture: capture), peer: firstUDP.localAddress,
                cipher: transportCipher, transformer: AttributedTransformer(base: secondDAVE, capture: capture), ssrc: 222,
                encoder: AttributedEncoder(base: try configuration.encoder(), capture: capture),
                maximumReceiveStreams: 1, maximumBufferedBytes: 16_384)
            secondMedia = second
            try await first.registerReceiveStream(ssrc: 222, channelCount: configuration.channels, packetSampleCount: configuration.frameSamples,
                capacity: 64, maximumBytes: 16_384)
            try await second.registerReceiveStream(ssrc: 111, channelCount: configuration.channels, packetSampleCount: configuration.frameSamples,
                capacity: 64, maximumBytes: 16_384)
            guard try await firstDAVE.authorizeGateway(suspended(firstCredentials)).phase == .ready,
                  try await secondDAVE.authorizeGateway(suspended(secondCredentials)).phase == .ready else {
                throw QualificationFailure.invariant
            }
            await first.setAuthorized(true); await second.setAuthorized(true)
            contention = CPUContention(workers: configuration.contentionWorkers)
            let format = try PCMFormat(sampleRate: 48_000, channelCount: configuration.channels)
            let tone = try PCMBuffer(format: format, samples: (0..<(configuration.frameSamples * configuration.channels)).map {
                Float(sin(Double($0 / configuration.channels) * 2 * .pi * 440 / 48_000) * 0.2)
            })
            let silence = try PCMBuffer(format: format, samples: Array(repeating: 0, count: tone.samples.count))
            let frameCount = configuration.frameCount, warmupFrames = configuration.warmupFrames
            let delay = configuration.playoutDelayFrames
            var firstQueue = ImpairmentQueue(), secondQueue = ImpairmentQueue()
            var policy = SendCadencePolicy()
            var expectedSent: UInt64 = 0, actualSent: UInt64 = 0, cadenceMisses: UInt64 = 0
            var timings: [Double] = []; timings.reserveCapacity(frameCount)
            var rssMeasurements: [ResidentMeasurement] = []
            rssMeasurements.reserveCapacity(Int(ceil(configuration.seconds)) + 3)
            var overruns = 0, underruns = 0, decoded = 0, warmupDecoded = 0, peakBuffered = 0, maximumPending = 0
            let coldRSS = try residentBytes()
            var rssInitial: UInt64 = 0, rssHigh: UInt64 = 0
            var startedAt = ""
            let warmupStart = clock.now
            var warmupElapsed = 0.0, measuredElapsed = 0.0
            var start = warmupStart
            for index in 0..<(warmupFrames + frameCount + delay) {
                if index == warmupFrames {
                    try await clock.sleep(until: warmupStart.advanced(by: .seconds(2)), tolerance: .zero)
                    warmupElapsed = seconds(warmupStart.duration(to: clock.now))
                    rssInitial = try residentBytes(); rssHigh = rssInitial
                    startedAt = ISO8601DateFormatter().string(from: Date())
                    start = clock.now
                    rssMeasurements.append(.init(elapsedSeconds: 0, residentBytes: rssInitial))
                }
                let warming = index < warmupFrames
                let measuredIndex = index - warmupFrames
                let measuring = !warming && measuredIndex < frameCount
                capture.setEnabled(measuring)
                let tick = warming ? index : measuredIndex
                let deadline = (warming ? warmupStart : start).advanced(by: .nanoseconds(Int64(tick) * configuration.frameNanoseconds))
                try await clock.sleep(until: deadline, tolerance: .zero)
                let operationStart = clock.now
                if measuredIndex == frameCount { measuredElapsed = seconds(start.duration(to: operationStart)) }
                if measuring {
                    let late = deadline.duration(to: operationStart)
                    capture.record(late, workload: .voicePacingLate)
                    if late > .nanoseconds(configuration.frameNanoseconds) { underruns += 1 }
                }
                do {
                    let operationContext = TransportContext(clock: clock, deadline: clock.now.advanced(by: .seconds(2)))
                    if warming || measuring {
                        let active = warming || configuration.active(frame: measuredIndex)
                        let expected = warming ? true : policy.expectsTransmission(active: active, configuration: configuration)
                        if measuring && expected { expectedSent += 2 }
                        async let firstSent = first.send(active ? tone : silence, context: operationContext)
                        async let secondSent = second.send(active ? tone : silence, context: operationContext)
                        let sent = try await (firstSent, secondSent)
                        if measuring {
                            actualSent += (sent.0 ? 1 : 0) + (sent.1 ? 1 : 0)
                            cadenceMisses += (sent.0 != expected ? 1 : 0) + (sent.1 != expected ? 1 : 0)
                        }
                        // Read exactly the emitted packets; intentionally suppressed intervals cannot block a receive.
                        if sent.1 {
                            guard let datagram = try await firstUDP.receiveDatagram(context: operationContext) else { throw QualificationFailure.invariant }
                            if warming { try await receiveAttributed(first, datagram: datagram, capture: capture) }
                            else { try firstQueue.enqueue(datagram, tick: tick, ordinal: measuredIndex + 1, configuration: configuration) }
                        }
                        if sent.0 {
                            guard let datagram = try await secondUDP.receiveDatagram(context: operationContext) else { throw QualificationFailure.invariant }
                            if warming { try await receiveAttributed(second, datagram: datagram, capture: capture) }
                            else { try secondQueue.enqueue(datagram, tick: tick, ordinal: measuredIndex + 1, configuration: configuration) }
                        }
                    }
                    if !warming {
                        for datagram in firstQueue.ready(tick: tick) { try await receiveAttributed(first, datagram: datagram, capture: capture) }
                        for datagram in secondQueue.ready(tick: tick) { try await receiveAttributed(second, datagram: datagram, capture: capture) }
                    }
                    let buffered = await first.snapshot().bufferedBytes + second.snapshot().bufferedBytes
                    if !warming { peakBuffered = max(peakBuffered, buffered) }
                    if warming || tick >= delay {
                        let a = try await playoutAttributed(first, ssrc: 222, capture: capture)
                        let b = try await playoutAttributed(second, ssrc: 111, capture: capture)
                        for pcm in [a, b] {
                            guard let pcm, pcm.pcm.frameCount == configuration.frameSamples,
                                  pcm.pcm.format.channelCount == configuration.channels,
                                  pcm.pcm.samples.allSatisfy(\.isFinite) else { throw QualificationFailure.invariant }
                            if warming { warmupDecoded += pcm.pcm.frameCount } else { decoded += pcm.pcm.frameCount }
                        }
                    }
                    if measuring {
                        try measuredTick?(measuredIndex)
                        let duration = operationStart.duration(to: clock.now)
                        let milliseconds = seconds(duration) * 1_000
                        timings.append(milliseconds)
                        capture.record(duration, workload: .voiceTick)
                        if duration > .nanoseconds(configuration.frameNanoseconds) { overruns += 1 }
                    }
                } catch {
                    if measuring { capture.record(operationStart.duration(to: clock.now), workload: .voiceTick, error: error) }
                    throw error
                }
                if measuring, measuredIndex > 0, (measuredIndex * configuration.frameSamples) / 48_000 != ((measuredIndex - 1) * configuration.frameSamples) / 48_000 {
                    let resident = try residentBytes()
                    rssHigh = max(rssHigh, resident)
                    rssMeasurements.append(.init(elapsedSeconds: seconds(start.duration(to: clock.now)), residentBytes: resident))
                    maximumPending = max(maximumPending, await firstDAVE.snapshot().pendingOperationCount + secondDAVE.snapshot().pendingOperationCount)
                }
            }
            capture.setEnabled(false)
            try await clock.sleep(until: start.advanced(by: .seconds(configuration.seconds)), tolerance: .zero)
            if measuredElapsed == 0 { measuredElapsed = seconds(start.duration(to: clock.now)) }
            let elapsed = seconds(start.duration(to: clock.now))
            let firstSnapshot = await first.snapshot(), secondSnapshot = await second.snapshot()
            let rssFinal = try residentBytes(); rssHigh = max(rssHigh, rssFinal)
            rssMeasurements.append(.init(elapsedSeconds: elapsed, residentBytes: rssFinal))
            await first.close(); await second.close(); await transportCipher.close()
            await firstDAVE.close(); await secondDAVE.close()
            await firstUDP.close(); await secondUDP.close()
            let closedWorkers = await contention.close()
            let closedA = await first.snapshot(), closedB = await second.snapshot()
            let daveA = await firstDAVE.snapshot(), daveB = await secondDAVE.snapshot()
            let eofA = try await firstUDP.receiveDatagram(context: .init(clock: clock)) == nil
            let eofB = try await secondUDP.receiveDatagram(context: .init(clock: clock)) == nil
            let rssAfterClose = try residentBytes()
            timings.sort()
            let firstMinuteRSS = rssMeasurements.filter { $0.elapsedSeconds <= 60 }.map(\.residentBytes).sorted()
            let lastMinuteRSS = rssMeasurements.filter { $0.elapsedSeconds >= max(0, elapsed - 60) }.map(\.residentBytes).sorted()
            let lifetimeSent = UInt64(warmupFrames * 2) + actualSent
            let dropped = firstQueue.dropped + secondQueue.dropped
            let successful = firstSnapshot.sentPackets + secondSnapshot.sentPackets == lifetimeSent
                && firstSnapshot.receivedPackets + secondSnapshot.receivedPackets == lifetimeSent - UInt64(dropped)
                && actualSent == expectedSent && cadenceMisses == 0
                && firstSnapshot.bufferedBytes == 0 && secondSnapshot.bufferedBytes == 0
                && firstQueue.pending.isEmpty && secondQueue.pending.isEmpty
                && closedA.closed && closedB.closed && daveA.isClosed && daveB.isClosed && eofA && eofB
                && closedWorkers == configuration.contentionWorkers
            let evidence = AttributedEvidence(frameSampleCount: configuration.frameSamples, channelCount: configuration.channels,
                mode: configuration.mode, dtxEnabled: configuration.dtx, signal: configuration.signal,
                frameIntervalMilliseconds: configuration.frameMilliseconds,
                emulation: "deterministic receiver-side drop/hold/reorder after real localhost UDP receipt; warmup unimpeded",
                emulatedLossEvery: configuration.lossEvery, emulatedReorderEvery: configuration.reorderEvery,
                emulatedJitterMilliseconds: configuration.jitterMilliseconds, playoutDelayFrames: delay, drainFrames: delay,
                emulatedDroppedPackets: dropped, emulatedDelayedPackets: firstQueue.delayed + secondQueue.delayed,
                emulatedReorderSelections: firstQueue.reordered + secondQueue.reordered,
                pendingEmulationCapacityDatagrams: ImpairmentQueue.capacity * 2,
                peakPendingEmulationDatagrams: firstQueue.peakCount + secondQueue.peakCount,
                peakPendingEmulationBytes: firstQueue.peakBytes + secondQueue.peakBytes,
                expectedSentPackets: expectedSent, intentionallySuppressedFrames: policy.suppressed * 2,
                silenceRefreshPackets: policy.refreshes * 2, talkspurtRestarts: policy.restarts * 2,
                policyCadenceMissCount: cadenceMisses,
                policyMaximumExpectedDispatchGapMilliseconds: Double(policy.maximumExpectedGapFrames) * configuration.frameMilliseconds,
                maximumDispatchGapBeyondExpectedMilliseconds: max(0,
                    max(firstSnapshot.maximumSendIntervalMilliseconds, secondSnapshot.maximumSendIntervalMilliseconds)
                    - Double(policy.maximumExpectedGapFrames) * configuration.frameMilliseconds),
                rawSendIntervalOverrunCount: firstSnapshot.sendIntervalOverrunCount + secondSnapshot.sendIntervalOverrunCount,
                maximumSendIntervalMilliseconds: max(firstSnapshot.maximumSendIntervalMilliseconds, secondSnapshot.maximumSendIntervalMilliseconds),
                encodedFrameCount: firstSnapshot.encodedFrameCount + secondSnapshot.encodedFrameCount,
                encodingDeadlineMissCount: firstSnapshot.encodingDeadlineMissCount + secondSnapshot.encodingDeadlineMissCount,
                maximumEncodingDurationMilliseconds: max(firstSnapshot.maximumEncodingDurationMilliseconds, secondSnapshot.maximumEncodingDurationMilliseconds),
                contentionWorkers: configuration.contentionWorkers, closedContentionWorkers: closedWorkers,
                attributionScopes: Self.attributionScopes)
            var report = QualificationReport(startedAt: startedAt, requestedSeconds: configuration.seconds, elapsedSeconds: measuredElapsed,
                warmupFramesPerDirection: warmupFrames, warmupElapsedSeconds: warmupElapsed,
                warmupDecodedSampleFrames: warmupDecoded,
                lifetimeTotalSentPackets: firstSnapshot.sentPackets + secondSnapshot.sentPackets,
                lifetimeTotalReceivedPackets: firstSnapshot.receivedPackets + secondSnapshot.receivedPackets,
                framesPerDirection: frameCount, totalSentPackets: actualSent,
                totalReceivedPackets: firstSnapshot.receivedPackets + secondSnapshot.receivedPackets - UInt64(warmupFrames * 2),
                decodedSampleFrames: decoded, concealedPackets: firstSnapshot.concealedPackets + secondSnapshot.concealedPackets,
                processingP50Milliseconds: percentile(timings, 0.5), processingP95Milliseconds: percentile(timings, 0.95),
                processingP99Milliseconds: percentile(timings, 0.99), processingMaximumMilliseconds: timings.last ?? 0,
                processingBudgetOverruns: overruns, scheduleUnderruns: underruns, peakBufferedMediaBytes: peakBuffered,
                finalBufferedMediaBytes: firstSnapshot.bufferedBytes + secondSnapshot.bufferedBytes,
                rssInitialBytes: rssInitial, rssFinalBytes: rssFinal, rssSampledHighBytes: rssHigh,
                coldRSSBytes: coldRSS, rssGrowthAfterWarmupBytes: Int64(rssFinal) - Int64(rssInitial),
                rssFirstMinuteMedianBytes: firstMinuteRSS[firstMinuteRSS.count / 2],
                rssLastMinuteMedianBytes: lastMinuteRSS[lastMinuteRSS.count / 2], rssAfterResourceCloseBytes: rssAfterClose,
                rssMeasurements: rssMeasurements, timingSampleAccountedBytes: timings.capacity * MemoryLayout<Double>.stride,
                configuredMediaBufferCapacityBytes: 32_768, configuredUDPPendingPayloadCapacityBytes: 65_536,
                sampledMaximumPendingDAVEOperations: maximumPending, closedMediaOwners: [closedA.closed, closedB.closed].filter { $0 }.count,
                closedDAVEOwners: [daveA.isClosed, daveB.isClosed].filter { $0 }.count,
                closedDatagramOwners: [eofA, eofB].filter { $0 }.count, successful: successful, attributed: evidence)
            report.schemaVersion = 3
            return report
        } catch {
            capture.setEnabled(false)
            await firstMedia?.close(); await secondMedia?.close(); await cipher?.close()
            await firstDAVE.close(); await secondDAVE.close()
            await firstSocket?.close(); await secondSocket?.close()
            let closedWorkers = await contention.close()
            var remaining = contention.tasks.count - closedWorkers
            for media in [firstMedia, secondMedia].compactMap({ $0 }) {
                let snapshot = await media.snapshot()
                if !snapshot.closed || snapshot.bufferedBytes != 0 { remaining += 1 }
            }
            for dave in [firstDAVE, secondDAVE] {
                let snapshot = await dave.snapshot()
                if !snapshot.isClosed || snapshot.pendingOperationCount != 0 { remaining += 1 }
            }
            for socket in [firstSocket, secondSocket].compactMap({ $0 }) {
                if await !observesClosedDatagram(socket) { remaining += 1 }
            }
            throw AttributedRunFailure(operationError: error,
                cleanup: BenchmarkCleanup(completed: remaining == 0, remainingOwners: UInt64(remaining),
                    reason: remaining == 0 ? nil : "Observed media, DAVE, UDP or contention closure receipts remain incomplete."))
        }
    }

    /// Observes EOF after awaited socket closure even when the operation task is cancelled.
    /// - Parameter socket: An owned UDP adapter whose `close()` has already completed.
    /// - Returns: True only for observed EOF; read failures or the bounded one-second
    ///   diagnostic deadline return false. The fresh cancellation scope is explicitly
    ///   owned and awaited here, starts no producer and cannot outlive this receipt.
    private static func observesClosedDatagram(_ socket: NIODatagramTransport) async -> Bool {
        let receipt = Task {
            let clock = ContinuousClock()
            do {
                return try await socket.receiveDatagram(context: .init(clock: clock,
                    deadline: clock.now.advanced(by: .seconds(1)))) == nil
            } catch { return false }
        }
        return await receipt.value
    }

    /// Full receive public boundary includes transport AEAD, DAVE open, RTP/Opus validation and jitter insertion.
    private static func receiveAttributed(_ media: VoiceMediaPipeline<ContinuousClock>, datagram: Datagram,
        capture: AttributionCapture) async throws {
        let clock = ContinuousClock(), start = ContinuousClock.now
        do {
            try await media.receive(datagram)
            capture.record(start.duration(to: clock.now), workload: .voiceReceiveDecrypt)
        } catch {
            capture.record(start.duration(to: clock.now), workload: .voiceReceiveDecrypt, error: error)
            throw error
        }
    }

    /// Public playout includes jitter pop, decode/PLC and PCM saturation; there are no device sinks.
    private static func playoutAttributed(_ media: VoiceMediaPipeline<ContinuousClock>, ssrc: UInt32,
        capture: AttributionCapture) async throws -> VoicePCMPlayout? {
        let clock = ContinuousClock(), start = ContinuousClock.now
        do {
            let result = try await media.playout(ssrc: ssrc)
            capture.record(start.duration(to: clock.now), workload: .voiceDecode)
            return result
        } catch {
            capture.record(start.duration(to: clock.now), workload: .voiceDecode, error: error)
            throw error
        }
    }

    /// Declares observed overlapping endpoints without inventing an isolated jitter or outer-AEAD timer.
    static var attributionScopes: [String: String] { [
        "voice.tick": "direct gross duplex tick after explicit main wait; includes internal pacing, UDP receipt, impairment delivery, playout, buffer snapshots and PCM correctness guards",
        "voice.pacingLate": "scheduled tick deadline to actual start; missed interval count reported separately",
        "voice.encode": "synchronous production Opus encode, including DTX decisions; no pacing/encryption",
        "voice.encrypt": "DAVE seal only; concrete transport AEAD remains inside integrated tick",
        "voice.send": "actual UDP adapter send only; encryption and receive excluded",
        "voice.receiveDecrypt": "public pipeline receive: transport AEAD, DAVE open, RTP/Opus validation, jitter insertion and actor scheduling",
        "voice.decode": "public pipeline playout: jitter selection, Opus decode/PLC, PCM saturation and actor scheduling; no sinks",
    ] }
}
