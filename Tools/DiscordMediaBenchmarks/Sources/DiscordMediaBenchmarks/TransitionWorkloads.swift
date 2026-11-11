// File: Tools/DiscordMediaBenchmarks/Sources/DiscordMediaBenchmarks/TransitionWorkloads.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Crypto
import DiscordCore
import DiscordDAVE
import DiscordMLS
import DiscordModels
import DiscordVoice
import Foundation

/// Serial runner owns all mutation; actors continue to own cryptographic state.
private final class MLSBatchState: @unchecked Sendable {
    var owners: [MLSKeyPackageOwner] = []
    var groups: [MLSGroup] = []
    var targets: [MLSKeyPackageOwner] = []
    var sources: [MLSGroup] = []
    var peers: [MLSGroup] = []
    var welcomes: [Data] = []
    var priorExports: [Data] = []
    var completed = 0

    /// Awaits every group/package closure then releases retained public fixture references; idempotent and task-free.
    func close() async {
        for group in groups { await group.close() }
        for owner in owners { await owner.close() }
        groups.removeAll(); owners.removeAll(); targets.removeAll(); sources.removeAll(); peers.removeAll()
        welcomes.removeAll(); priorExports.removeAll()
    }
}

extension MediaCatalog {
    /// Builds the public fixture external authority from scalar three, without credentials, I/O or fresh entropy.
    static func externalSender() throws -> MLSExternalSender {
        let key = try P256.Signing.PrivateKey(rawRepresentation: publicScalar(3))
        return try MLSExternalSender(signatureKey: key.publicKey.x963Representation,
            credential: MLSCredential(identity: Data("PUBLIC-BENCHMARK-GATEWAY".utf8)))
    }

    /// Prepares finite package/group sets for isolated create, Welcome join or two-to-three-member rekey wrappers.
    /// Setup failures close previously created owners; post-run verification checks complete state/exporter agreement.
    static func mls(_ id: String) -> MediaCase {
        let creation = id == "mls.group.create", joining = id == "mls.group.join"
        return MediaCase(id: id, transition: true, dimensions: ["startingMembers": creation ? 0 : joining ? 1 : 2,
            "endingMembers": creation ? 1 : joining ? 2 : 3]) { count, seed in
            let state = MLSBatchState()
            let policy = try MLSGroupPolicy(externalSender: externalSender(), expectedParticipants: [1, 2, 3], maximumMembers: 4)
            let groupIDs = (0..<count).map { Data("PUBLIC-BENCHMARK-GROUP-\(seed)-\($0)".utf8) }
            do {
                for index in 0..<count {
                    let aOwner = try MLSKeyPackageOwner(userID: 1, signaturePrivateKey: publicScalar(1))
                    state.owners.append(aOwner)
                    if creation { state.targets.append(aOwner); continue }
                    let a = try await aOwner.createGroup(groupID: groupIDs[index], policy: policy)
                    state.groups.append(a); state.sources.append(a)
                    let bOwner = try MLSKeyPackageOwner(userID: 2, signaturePrivateKey: publicScalar(2))
                    state.owners.append(bOwner)
                    let add = try MLSProposal.add(bOwner.keyPackage).externalMessage(groupID: groupIDs[index],
                        epoch: 0, signaturePrivateKey: publicScalar(3))
                    _ = try await a.cacheProposal(add)
                    let candidate = try await a.prepareCommit()
                    guard let welcome = candidate.welcome else { throw MediaBenchmarkError.integrityFailure("Missing MLS Welcome") }
                    _ = try await a.acceptCommit(candidate.commit)
                    if joining {
                        state.targets.append(bOwner); state.welcomes.append(welcome)
                    } else {
                        let b = try await bOwner.join(welcome: welcome, expectedGroupID: groupIDs[index], policy: policy)
                        state.groups.append(b); state.peers.append(b)
                        state.priorExports.append(try await a.export(label: "public-benchmark", context: Data(), length: 32))
                        let cOwner = try MLSKeyPackageOwner(userID: 3, signaturePrivateKey: publicScalar(4))
                        state.owners.append(cOwner)
                        let addition = try MLSProposal.add(cOwner.keyPackage).externalMessage(groupID: groupIDs[index],
                            epoch: 1, signaturePrivateKey: publicScalar(3))
                        _ = try await a.cacheProposal(addition); _ = try await b.cacheProposal(addition)
                    }
                }
                return MediaBatch(run: {
                    for index in 0..<count {
                        if creation {
                            state.groups.append(try await state.targets[index].createGroup(groupID: groupIDs[index], policy: policy))
                        } else if joining {
                            state.groups.append(try await state.targets[index].join(welcome: state.welcomes[index],
                                expectedGroupID: groupIDs[index], policy: policy))
                        } else {
                            let candidate = try await state.sources[index].prepareCommit()
                            let local = try await state.sources[index].acceptCommit(candidate.commit)
                            let remote = try await state.peers[index].acceptCommit(candidate.commit)
                            // Retained compact outcomes are checked after the batch timer.
                            state.welcomes.append(Data([local == .advanced ? 1 : 0, remote == .advanced ? 1 : 0]))
                        }
                        state.completed += 1
                    }
                    return UInt64(state.completed)
                }, verify: {
                    try require(state.completed == count, "MLS completed count mismatch")
                    for group in state.groups {
                        let snapshot = await group.snapshot()
                        try require(snapshot.epoch == (creation ? 0 : joining ? 1 : 2), "MLS epoch mismatch")
                        try require(snapshot.memberCount == (creation ? 1 : joining ? 2 : 3), "MLS member mismatch")
                        try require(!snapshot.hasTentativeCommit && snapshot.pendingProposalCount == 0 && !snapshot.isClosed,
                            "MLS retained candidate/proposals")
                    }
                    if !creation {
                        for index in 0..<count {
                            let other = joining ? state.groups[count + index] : state.peers[index]
                            let exported = try await state.sources[index].export(label: "public-benchmark", context: Data(), length: 32)
                            let peer = try await other.export(label: "public-benchmark", context: Data(), length: 32)
                            try require(exported == peer, "MLS exporter agreement failed")
                            if !joining {
                                try require(exported != state.priorExports[index] && state.welcomes[index] == Data([1, 1]),
                                    "MLS rekey/outcome mismatch")
                            }
                        }
                    }
                }, close: { await state.close() })
            } catch { await state.close(); throw error }
        }
    }

    /// Parses one caller-authored public fixture JSON control before the timed transition wrapper begins.
    static func jsonControl(_ opcode: UInt8, _ body: String) throws -> VoiceGatewayFrame {
        try VoiceGatewayFrame(.text("{\"op\":\(opcode),\"d\":\(body)}"))
    }

    /// Concurrent caller scheduling and the real public adapter admission queue are included in each batch.
    static func daveQueue(_ id: String) -> MediaCase {
        MediaCase(id: id, transition: true, dimensions: ["maximumPendingOperations": 65,
            "protocolVersion": 1, "initialEpoch": 0]) { count, seed in
            var rendezvous = try VoiceJoinRendezvous(guildID: GuildID(rawValue: 3), userID: UserID(rawValue: 1),
                channelID: ChannelID(rawValue: 4))
            let state = try VoiceState(data: Data("{\"guild_id\":\"3\",\"user_id\":\"1\",\"channel_id\":\"4\",\"session_id\":\"PUBLIC-BENCHMARK-SESSION-\(seed)\",\"deaf\":false,\"mute\":false,\"self_deaf\":false,\"self_mute\":false,\"self_video\":false,\"suppress\":false,\"request_to_speak_timestamp\":null}".utf8))
            let server = try GatewayVoiceServerUpdate(data: Data("{\"guild_id\":\"3\",\"token\":\"PUBLIC-NON-CREDENTIAL\",\"endpoint\":\"voice.invalid\"}".utf8))
            _ = try rendezvous.receive(state: state, generation: 0)
            guard let credentials = try rendezvous.receive(server: server, generation: 0) else {
                throw MediaBenchmarkError.integrityFailure("Public rendezvous fixture incomplete")
            }
            let sender = try externalSender()
            let session = try DAVEVoiceSession(identity: credentials.identity, groupID: Data("PUBLIC-BENCHMARK-GROUP-\(seed)".utf8),
                signaturePrivateKey: publicScalar(1), externalSender: sender, maximumParticipants: 4,
                maximumPendingOperations: 65, now: { 1 })
            do {
                _ = try await session.start(protocolVersion: 1)
                let external = try VoiceGatewayFrame(.binary(Data([0, 1, 25]) + sender.encoded()))
                _ = try await session.receive(external, now: 1)
                _ = try await session.receive(jsonControl(21, "{\"transition_id\":0,\"protocol_version\":1}"), now: 1)
                let prepare = try jsonControl(21, "{\"transition_id\":7,\"protocol_version\":1}")
                let execute = try jsonControl(22, "{\"transition_id\":7}")
                let results = SerialResults<UInt64>(capacity: count)
                return MediaBatch(run: {
                    let observations = try await withThrowingTaskGroup(of: UInt64.self, returning: [UInt64].self) { group in
                        for _ in 0..<count {
                            group.addTask {
                                let commands = try await session.receive(prepare, now: 1)
                                return commands.count == 1 && commands[0].opcode == 23 ? 1 : 0
                            }
                        }
                        var values: [UInt64] = []; values.reserveCapacity(count)
                        for try await value in group { values.append(value) }
                        return values
                    }
                    results.values = observations
                    return UInt64(observations.count)
                }, verify: {
                    try require(results.values.count == count && results.values.allSatisfy { $0 == 1 }, "DAVE transition acknowledgment mismatch")
                    _ = try await session.receive(execute, now: 1)
                    let snapshot = await session.snapshot()
                    try require(snapshot.pendingOperationCount == 0 && !snapshot.operationIsActive && !snapshot.isClosed,
                        "DAVE admission queue failed to drain")
                }, close: { await session.close(); results.values.removeAll() })
            } catch { await session.close(); throw error }
        }
    }
}
