// File: Tools/DiscordMediaBenchmarks/Sources/DiscordMediaBenchmarks/PhaseNineMLSWorkloads.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Crypto
import DiscordDAVE
import DiscordMLS
import Foundation

extension MediaCatalog {
    /// Finite dense/sparse group and cached-removal controls, plus one explicitly joined media/control wrapper.
    /// Returns thirteen unique version-four IDs without generating entropy, packages or groups; live initial
    /// membership is 4/8/16 for dense controls and one fewer after sparse-tree preparation.
    static var phaseNineMLSIDs: [String] {
        [4, 8, 16].flatMap { members in
            ["mls.v4.add1.dense.members\(members)", "mls.v4.remove1.dense.members\(members)",
                "mls.v4.remove3.dense.members\(members)", "mls.v4.remove1.sparse.members\(members)"]
        } + ["mls.v4.mixed.dense.members8"]
    }

    /// Times fresh commit preparation and acceptance by every remaining/removed peer on independent groups.
    /// Proposal admission, sparse-tree preparation and full exporter/authenticator/revocation checks are untimed.
    /// Mixed wrappers join one transition with 64 authenticated DAVE opens on an independent prefilled receiver;
    /// they measure combined scheduling/service, without isolating queue residence or manager secure-ready.
    /// - Parameters:
    ///   - id: Exact version-four MLS identity admitted by the catalog with matching arguments.
    ///   - members: Initial dense-tree member count, exactly 4, 8 or 16; sparse preparation removes member index one.
    ///   - removals: Zero for one cached Add and N-to-N+1 membership, one or three for cached Remove proposals.
    ///   - sparse: True only for a one-removal control; an untimed prior removal leaves an interior hole.
    ///   - mixed: True only for the dense eight-member one-removal case, joining 64 DAVE opens with each transition.
    /// - Returns: A per-batch case timing commit preparation/all-existing-peer acceptance; addition Welcome join
    ///   and complete agreement/revocation checks remain in untimed verification. Each batch owns 1...64 fixtures.
    /// Deferred setup uses native MLS entropy and closes every already-created group/package/media actor on failure.
    /// Native crypto/policy/cancellation errors and oracle integrity failures propagate. The caller must run each
    /// batch once, verify once, then await idempotent closure on success, failure or cancellation. The serial outer
    /// owner protects unchecked result storage. Mixed calls launch exactly two structured child jobs against
    /// disjoint MLS/media owners and join them before advancing; no fixture is concurrently verified or closed.
    static func phaseNineMLS(_ id: String, members: Int, removals: Int, sparse: Bool, mixed: Bool) -> MediaCase {
        MediaCase(id: id, transition: true, dimensions: ["fixtureVersion": 4,
            "startingMembers": UInt64(members - (sparse ? 1 : 0)), "initialTreeLeaves": UInt64(members),
            "endingMembers": UInt64(members - (sparse ? 1 : 0) - removals + (removals == 0 ? 1 : 0)),
            "cachedRemovalProposals": UInt64(removals), "startingBlankLeaves": sparse ? 1 : 0,
            "cachedAddProposals": removals == 0 ? 1 : 0, "welcomeJoinInsideTimer": 0,
            "proposalAdmissionInsideTimer": 0, "prepareCommitInsideTimer": 1, "allPeerAcceptanceInsideTimer": 1,
            "concurrentJobsPerCall": mixed ? 2 : 1, "authenticatedMediaFramesPerCall": mixed ? 64 : 0,
            "mediaReplayWindow": mixed ? 1_024 : 0, "mediaPrefillFrames": mixed ? 1_024 : 0]) { count, seed in
            let fixtures = SerialResults<PhaseNineMLSFixture>(capacity: count)
            let outcomes = SerialResults<[MLSCommitOutcome]>(capacity: count)
            let mediaResults = SerialResults<[Data]>(capacity: mixed ? count : 0)
            let media = mixed ? try await PhaseNineConcurrentMedia.make(seed: seed, count: count) : nil
            do {
                for index in 0..<count {
                    fixtures.values.append(try await PhaseNineMLSFixture.make(members: members, removals: removals,
                        sparse: sparse, seed: seed, index: index))
                }
                return MediaBatch(run: {
                    for (index, fixture) in fixtures.values.enumerated() {
                        if let media {
                            async let control = fixture.transition()
                            async let frames = media.open(index: index)
                            let joined = try await (control, frames)
                            outcomes.values.append(joined.0); mediaResults.values.append(joined.1)
                        } else { outcomes.values.append(try await fixture.transition()) }
                    }
                    return UInt64(outcomes.values.count)
                }, verify: {
                    try require(outcomes.values.count == count, "Stage-nine MLS transition count mismatch")
                    for (index, fixture) in fixtures.values.enumerated() {
                        try await fixture.verify(outcomes.values[index])
                    }
                    if let media {
                        try require(mediaResults.values.count == count && mediaResults.values.allSatisfy {
                            $0.count == 64 && $0.allSatisfy { $0 == media.payload }
                        }, "Stage-nine mixed media plaintext mismatch")
                        try await media.verify()
                    }
                }, close: {
                    for fixture in fixtures.values { await fixture.close() }
                    await media?.close(); fixtures.values.removeAll(); outcomes.values.removeAll(); mediaResults.values.removeAll()
                })
            } catch {
                for fixture in fixtures.values { await fixture.close() }
                await media?.close(); throw error
            }
        }
    }
}

/// One independent real-entropy group graph; the serial batch exclusively retains its mutable outcome storage.
/// Unchecked Sendable permits one structured control child to own this graph while the caller awaits it.
/// It does not permit overlapping make/transition/verify/close access; MLS actor references retain crypto isolation.
private final class PhaseNineMLSFixture: @unchecked Sendable {
    var owners: [MLSKeyPackageOwner] = []
    var groups: [MLSGroup] = []
    var removedBeforeTiming: Set<Int> = []
    var timedRemovals: Set<Int> = []
    var epoch: UInt64 = 1
    var previousExport = Data()
    var joiningOwner: MLSKeyPackageOwner?
    var welcome: Data?
    var groupID = Data()
    var policy: MLSGroupPolicy?

    /// Creates a full dense tree in one Add commit, optionally removes an interior leaf, and caches timed removals.
    /// - Parameters:
    ///   - members: Exactly 4, 8 or 16 initial dense members; trusted catalog input, without a runtime range guard here.
    ///   - removals: Zero to cache one Add, one or three to cache that many Removes; sparse requires exactly one.
    ///   - sparse: Whether to authenticate an untimed removal at index one before caching the timed index-three removal.
    ///   - seed: Any public UInt64 descriptor seed, included in the fixture group ID rather than used as MLS entropy.
    ///   - index: Zero-based fixture position in a batch of at most 64, separating that batch's public group IDs.
    /// - Returns: Exclusive ownership of all packages/groups, pending proposals and prior exporter needed for one run.
    /// - Throws: Native MLS configuration, credential, proposal, commit, Welcome or cancellation errors, or an
    ///   integrity failure for an unexpected setup outcome. Every created owner is explicitly closed before rethrow.
    /// Signing scalars are public inputs; ephemeral/epoch keys use native randomness. This async factory suspends
    /// on actor calls, starts no detached work and must finish before the returned graph enters timed execution.
    static func make(members: Int, removals: Int, sparse: Bool, seed: UInt64, index: Int) async throws -> PhaseNineMLSFixture {
        let fixture = PhaseNineMLSFixture()
        do {
            let ownerCount = members + (removals == 0 ? 1 : 0)
            let policy = try MLSGroupPolicy(externalSender: MediaCatalog.externalSender(),
                expectedParticipants: Set((1...ownerCount).map(UInt64.init)), maximumMembers: ownerCount)
            let groupID = Data("PUBLIC-MLS-v4-\(seed)-\(index)".utf8)
            fixture.groupID = groupID; fixture.policy = policy
            for member in 0..<ownerCount {
                fixture.owners.append(try MLSKeyPackageOwner(userID: UInt64(member + 1),
                    signaturePrivateKey: MediaCatalog.publicScalar(UInt8(member + 11))))
            }
            let source = try await fixture.owners[0].createGroup(groupID: groupID, policy: policy)
            fixture.groups.append(source)
            for owner in fixture.owners.prefix(members).dropFirst() {
                let proposal = try MLSProposal.add(owner.keyPackage).externalMessage(groupID: groupID,
                    epoch: 0, signaturePrivateKey: MediaCatalog.publicScalar(3))
                _ = try await source.cacheProposal(proposal)
            }
            let candidate = try await source.prepareCommit()
            guard let welcome = candidate.welcome else { throw MediaBenchmarkError.integrityFailure("Missing stage-nine MLS Welcome") }
            try MediaCatalog.require(try await source.acceptCommit(candidate.commit) == .advanced, "Initial MLS commit failed")
            for owner in fixture.owners.prefix(members).dropFirst() {
                fixture.groups.append(try await owner.join(welcome: welcome, expectedGroupID: groupID, policy: policy))
            }
            if sparse {
                let removal = try MLSProposal.remove(1).externalMessage(groupID: groupID,
                    epoch: fixture.epoch, signaturePrivateKey: MediaCatalog.publicScalar(3))
                for group in fixture.groups { _ = try await group.cacheProposal(removal) }
                let thinning = try await source.prepareCommit()
                for (member, group) in fixture.groups.enumerated() {
                    try MediaCatalog.require(try await group.acceptCommit(thinning.commit) == (member == 1 ? .removed : .advanced),
                        "Sparse MLS preparation outcome mismatch")
                }
                fixture.removedBeforeTiming = [1]; fixture.epoch += 1
            }
            fixture.timedRemovals = sparse ? [3] : Set(1..<(removals + 1))
            if removals == 0 {
                fixture.joiningOwner = fixture.owners[members]
                let proposal = try MLSProposal.add(fixture.owners[members].keyPackage).externalMessage(groupID: groupID,
                    epoch: fixture.epoch, signaturePrivateKey: MediaCatalog.publicScalar(3))
                for group in fixture.groups { _ = try await group.cacheProposal(proposal) }
            }
            for member in fixture.timedRemovals.sorted() {
                let proposal = try MLSProposal.remove(UInt32(member)).externalMessage(groupID: groupID,
                    epoch: fixture.epoch, signaturePrivateKey: MediaCatalog.publicScalar(3))
                for (index, group) in fixture.groups.enumerated() where !fixture.removedBeforeTiming.contains(index) {
                    _ = try await group.cacheProposal(proposal)
                }
            }
            fixture.previousExport = try await source.export(label: "public-stage-nine", context: Data(), length: 32)
            return fixture
        } catch { await fixture.close(); throw error }
    }

    /// Includes cryptographic preparation plus all peer acceptance; package admission and semantic checks are excluded.
    /// - Returns: One outcome per owner live at the starting epoch, in original member-index order; owners removed
    ///   during sparse preparation are omitted. The optional Welcome remains retained for untimed recipient joining.
    /// - Throws: MLS preparation/acceptance or cancellation errors; a failure can leave already accepted peers
    ///   advanced, so recovery is explicit fixture closure rather than retrying this timed population.
    /// Call exactly once after make and before verify. The serial batch or its sole structured control child owns
    /// this unchecked storage throughout suspension; verification and closure must wait for the child to join.
    func transition() async throws -> [MLSCommitOutcome] {
        let candidate = try await groups[0].prepareCommit()
        welcome = candidate.welcome
        var results: [MLSCommitOutcome] = []
        for (index, group) in groups.enumerated() where !removedBeforeTiming.contains(index) {
            results.append(try await group.acceptCommit(candidate.commit))
        }
        return results
    }

    /// Requires every survivor to agree on epoch, exporter and authenticator, and every removed owner to be closed.
    /// - Parameter outcomes: Complete ordered results from this fixture's single transition, excluding prior removals.
    /// - Throws: Integrity failure for count/outcome/state/secret disagreement, or native MLS joining/export errors
    ///   and cancellation. No timing evidence should be emitted after a verification error.
    /// An addition consumes its retained package by joining the addressed Welcome and appends that group before
    /// comparison. This is a single-use untimed oracle; call after all timed jobs join and before close. It creates
    /// no child tasks, may suspend on actor calls, and leaves every owner available for awaited closure on failure.
    func verify(_ outcomes: [MLSCommitOutcome]) async throws {
        try MediaCatalog.require(outcomes.count == groups.count - removedBeforeTiming.count, "MLS acceptance population mismatch")
        let acceptingGroupCount = groups.count
        if let joiningOwner, let policy {
            guard let welcome else { throw MediaBenchmarkError.integrityFailure("MLS addition did not produce Welcome") }
            groups.append(try await joiningOwner.join(welcome: welcome, expectedGroupID: groupID, policy: policy))
            self.joiningOwner = nil
        }
        let export = try await groups[0].export(label: "public-stage-nine", context: Data(), length: 32)
        let authenticator = try await groups[0].epochAuthenticator()
        try MediaCatalog.require(export != previousExport, "MLS exporter did not advance")
        var outcomeIndex = 0
        for (index, group) in groups.enumerated() {
            let snapshot = await group.snapshot()
            let removed = timedRemovals.contains(index) || removedBeforeTiming.contains(index)
            if index < acceptingGroupCount && !removedBeforeTiming.contains(index) {
                try MediaCatalog.require(outcomes[outcomeIndex] == (removed ? .removed : .advanced), "MLS removal outcome mismatch")
                outcomeIndex += 1
            }
            try MediaCatalog.require(snapshot.pendingProposalCount == 0 && snapshot.pendingProposalBytes == 0
                && !snapshot.hasTentativeCommit && snapshot.isClosed == removed, "MLS pending/closed state mismatch")
            if removed {
                try MediaCatalog.require(snapshot.epoch == nil && snapshot.memberCount == 0, "Removed MLS owner retained epoch")
                do {
                    _ = try await group.export(label: "public-stage-nine", context: Data(), length: 32)
                    throw MediaBenchmarkError.integrityFailure("Removed MLS owner retained exporter")
                } catch let error as MLSError { try MediaCatalog.require(error == .closed, "MLS removed exporter classification mismatch") }
            } else {
                try MediaCatalog.require(snapshot.epoch == epoch + 1
                    && snapshot.memberCount == groups.count - removedBeforeTiming.count - timedRemovals.count,
                    "MLS survivor epoch/member mismatch")
                try MediaCatalog.require(try await group.export(label: "public-stage-nine", context: Data(), length: 32) == export,
                    "MLS exporter disagreement")
                try MediaCatalog.require(try await group.epochAuthenticator() == authenticator, "MLS authenticator disagreement")
            }
        }
    }

    /// Joins explicit closure for all group/package owners, including already removed owners.
    /// Releases retained exports, Welcome, policy and joining references after every actor acknowledges closure.
    /// Call only after execution/verification children have joined; unchecked storage has no concurrent protection.
    /// Idempotent and nonthrowing even when called after partial preparation or prior closure. It starts no tasks
    /// and performs no cancellation check, allowing the harness to finish cleanup while its parent is cancelled.
    func close() async {
        for group in groups { await group.close() }
        for owner in owners { await owner.close() }
        groups.removeAll(); owners.removeAll(); previousExport.removeAll(); welcome = nil; joiningOwner = nil; policy = nil
    }
}

/// Independent prefilled DAVE domain competing with MLS for host CPU and executor scheduling, without network pacing.
/// Immutable frame arrays and actor references are Sendable. The serial caller still owns each frame slice once;
/// concurrent/repeated opens of the same slice would change replay outcomes and are outside this workload contract.
private struct PhaseNineConcurrentMedia: Sendable {
    let sender: DAVEFrameCipher
    let receiver: DAVEFrameCipher
    let frames: [[Data]]
    let payload: Data

    /// Prepares all unique media nonces and verifies a complete production-default replay window before timing.
    /// - Parameters:
    ///   - seed: Any public UInt64 descriptor seed used to derive this nonconfidential fixture secret.
    ///   - count: Exactly 1...64 joined calls; prepares sixty-four unique frames for each call after 1024 prefill opens.
    /// - Returns: Exclusive cleanup ownership of sender/receiver actors plus immutable complete frame slices/payload.
    /// - Throws: Configuration, nonce, encryption, authentication, cancellation or prefill-oracle errors; both actors
    ///   are closed before rethrow. Native DAVE policy and budgets are preserved without test-only counter overrides.
    /// Actor calls suspend during setup. No runtime I/O or detached task is started; successful callers must close
    /// the result after all media/control children join, even if a later operation fails.
    static func make(seed: UInt64, count: Int) async throws -> Self {
        let secret = Data(SHA256.hash(data: Data("PUBLIC-MLS-MEDIA-v4-\(seed)".utf8)).prefix(16))
        let sender = try DAVEFrameCipher(baseSecret: secret), receiver = try DAVEFrameCipher(baseSecret: secret)
        let payload = Data([0xf8]) + Data(repeating: 0x44, count: 79)
        do {
            for _ in 0..<1_024 {
                let frame = try await sender.seal(payload, codec: .opus)
                try MediaCatalog.require(try await receiver.open(frame, mediaType: .audio, now: 0) == payload,
                    "Mixed DAVE prefill mismatch")
            }
            var frames: [[Data]] = []
            for _ in 0..<count {
                var batch: [Data] = []
                for _ in 0..<64 { batch.append(try await sender.seal(payload, codec: .opus)) }
                frames.append(batch)
            }
            return Self(sender: sender, receiver: receiver, frames: frames, payload: payload)
        } catch { await sender.close(); await receiver.close(); throw error }
    }

    /// Each joined wrapper owns its bounded frame slice; calls are sequential so one receiver remains exclusive.
    /// - Parameter index: Valid zero-based prepared slice index, consumed once in increasing order by the batch.
    /// - Returns: All sixty-four authenticated plaintexts in prepared nonce order, retained for untimed comparison.
    /// - Throws: Native DAVE replay, authentication, policy or cancellation errors; earlier opens may already have
    ///   advanced the receiver. An invalid index violates the trusted batch precondition rather than throwing.
    /// Suspends at each actor open while the disjoint MLS control child may execute. After failure, join both jobs
    /// and close the domain; retrying a partially consumed slice would change the measured replay population.
    func open(index: Int) async throws -> [Data] {
        var results: [Data] = []
        for frame in frames[index] { results.append(try await receiver.open(frame, mediaType: .audio, now: 0)) }
        return results
    }

    /// Confirms the completed domain still rejects its final accepted nonce.
    /// - Throws: Integrity failure if replay is accepted or misclassified; non-DAVE errors propagate unchanged.
    /// Call after every nonempty prepared slice has completed and all children have joined. This untimed actor
    /// probe may suspend, consumes no new nonce, and retains the domain for explicit close on success or failure.
    func verify() async throws {
        do {
            _ = try await receiver.open(frames.last!.last!, mediaType: .audio, now: 0)
            throw MediaBenchmarkError.integrityFailure("Mixed media accepted final replay")
        } catch let error as DAVEError { try MediaCatalog.require(error == .replayedFrame, "Mixed media replay mismatch") }
    }

    /// Releases both cryptographic owners after joined media/control completion.
    /// Awaits sender then receiver closure, retaining no detached cleanup work. Call after children join; repeated
    /// closure is safe. Nonthrowing cleanup proceeds under parent cancellation, without reopening either key domain.
    func close() async { await sender.close(); await receiver.close() }
}
