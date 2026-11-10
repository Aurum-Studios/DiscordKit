// File: Tools/DiscordFoundationBenchmarks/Sources/DiscordFoundationBenchmarks/PermissionWorkloads.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBits
import DiscordCache
import DiscordCore
import DiscordModels
import Foundation

/// Permission arithmetic over prepared caller facts, without a cache or timing hooks in the resolver.
enum PermissionWorkloads {
    /// Builds representative count/width scales and independent precedence, bypass and refusal oracles.
    /// - Returns: Ten cases with four immutable variants each. Count/width growth is paired rather than Cartesian;
    ///   owner and administrator bypasses have their own populations instead of mixing with ordinary resolution.
    /// - Throws: Bitset validation failures if the authored fixture positions become invalid.
    /// All snapshots, expected sets and fingerprint bytes are prepared synchronously before timing. No cache,
    /// clock, task, transport or live authorization state is acquired by this development-only factory.
    static func make() throws -> [FoundationWorkload] {
        var result: [FoundationWorkload] = []
        for (count, width) in [(1, 64), (16, 256), (128, 4_096)] {
            for mode in [Mode.allow, .deny] {
                result.append(try workload(mode: mode, count: count, width: width))
            }
        }
        for mode in [Mode.administrator, .owner] {
            result.append(try workload(mode: mode, count: 16, width: 256))
        }
        result.append(try refusal(resourceLimit: true))
        result.append(try refusal(resourceLimit: false))
        return result
    }

    /// Fixed semantics keep bypass and ordinary arithmetic in distinct distributions.
    private enum Mode: String { case allow, deny, administrator, owner }

    /// Prepared values and exact expected sets are only allocated before batch timing.
    private struct Fixture {
        let guild: PermissionGuildState
        let member: PermissionMemberState
        let channel: PermissionChannelState
        let expectedRaw: UnsignedBitSet
        let expectedEffective: UnsignedBitSet
        let unrestricted: Bool
        let observation: FoundationObservation
    }

    /// Resolves complete snapshots; all width/count configuration and expected bitsets precede timing.
    /// - Parameters:
    ///   - mode: Fixed precedence or bypass semantics shared by all four variants in this population.
    ///   - count: Assigned role and overwrite count, selected from 1, 16 and 128; the everyone role is additional.
    ///   - width: Highest supplied permission width, selected from 64, 256 and 4,096 bits.
    /// - Returns: A workload whose operation consumes finite result features and whose verifier compares complete sets.
    /// - Throws: Bitset validation failures during fixture preparation. Operation or verification closures subsequently
    ///   throw `integrityFailure` if complete supplied facts unexpectedly fail resolution or disagree with the oracle.
    /// The aggregate input bound is explicitly raised to 16,777,216 bits for the largest prepared case. Resolution
    /// remains synchronous and caller-owned; the operation creates no asynchronous work or retained cache state.
    private static func workload(mode: Mode, count: Int, width: Int) throws -> FoundationWorkload {
        let variants = try (0..<4).map { try prepare(mode: mode, count: count, width: width, variant: $0) }
        // The largest case intentionally raises the aggregate cap above the public conservative default.
        let limits = PermissionResolutionLimits(maximumTotalBitWidth: 16_777_216)
        let id = "permission.\(mode.rawValue).r\(count).w\(width)"
        return FoundationWorkload(id: id,
            dimensions: ["role_count": UInt64(count + 1), "assigned_role_count": UInt64(count),
                "overwrite_count": UInt64(count), "bit_width": UInt64(width), "variant_count": 4,
                "maximum_total_bit_width": 16_777_216],
            fixture: fixtureBytes(variants), operation: { input in
                let fixture = variants[Int(input % 4)]
                guard case .resolved(let value) = PermissionResolver.resolve(guild: fixture.guild,
                    member: fixture.member, channel: fixture.channel, limits: limits) else {
                    throw FoundationBenchmarkError.integrityFailure(id)
                }
                return observation(raw: value.rawPermissions, effective: value.permissions,
                    unrestricted: value.unrestricted, width: width)
            }, expected: { variants[Int($0 % 4)].observation }, verify: {
                for fixture in variants {
                    guard case .resolved(let value) = PermissionResolver.resolve(guild: fixture.guild,
                        member: fixture.member, channel: fixture.channel, limits: limits),
                        value.rawPermissions == fixture.expectedRaw,
                        value.permissions == fixture.expectedEffective,
                        value.unrestricted == fixture.unrestricted,
                        value.includes(fixture.expectedEffective),
                        value.includes(try UnsignedBitSet(bits: [width + 1])) == fixture.unrestricted else {
                        throw FoundationBenchmarkError.integrityFailure(id)
                    }
                }
            })
    }

    /// Known positions independently define the result; no resolver output constructs the oracle.
    /// - Parameters:
    ///   - mode: Allow/deny precedence, assigned-role administrator bypass, or known-owner bypass to exercise.
    ///   - count: Positive number of assigned roles and channel overwrites; the matrix supplies 1, 16 or 128.
    ///   - width: Supplied maximum bit width, at least 64 for this matrix; variable high positions remain distinct.
    ///   - variant: An index in `0..<4`, varying identifiers and retained/overwritten high bits.
    /// - Returns: Complete guild/member/channel snapshots and an independent exact expected result. Owner expectations
    ///   retain an empty finite mask and an explicit unrestricted flag rather than inventing an all-permissions value.
    /// - Throws: `UnsignedBitSet.ValidationError` if fixture mask positions exceed supported construction bounds.
    /// All collection/mask allocation and oracle construction occur during setup, with no resolver call or I/O.
    private static func prepare(mode: Mode, count: Int, width: Int, variant: Int) throws -> Fixture {
        let guildID = GuildID(rawValue: UInt64(100 + variant))
        let everyone = RoleID(rawValue: guildID.rawValue)
        let user = UserID(rawValue: UInt64(200 + variant))
        let owner = UserID(rawValue: mode == .owner ? user.rawValue : UInt64(300 + variant))
        let marker = width - 5 - variant, probe = width - 9 - variant
        let common = [10, 11, 16, width - 1, marker, probe]
        let base = try UnsignedBitSet(bits: common)
        let roleBits = try UnsignedBitSet(bits: common + (mode == .administrator ? [3] : []))
        var roles = [everyone: base]
        var assigned: Set<RoleID> = []
        for index in 0..<count {
            let role = RoleID(rawValue: UInt64(1_000 + variant * 1_000 + index))
            roles[role] = roleBits
            assigned.insert(role)
        }
        let mask = try UnsignedBitSet(bits: [11, probe])
        var overwrites = [PermissionOverwrite(target: .member(user),
            allow: mode == .allow ? mask : .init(), deny: mask)]
        if count > 1 {
            // Everyone denial precedes selected-role restoration; member denial has final precedence.
            overwrites.append(.init(target: .role(everyone), deny: mask))
        }
        if count > 2 {
            let role = RoleID(rawValue: UInt64(1_000 + variant * 1_000))
            overwrites.append(.init(target: .role(role), allow: mask, deny: mask))
        }
        while overwrites.count < count {
            // Unassigned role overwrites must never grant administrator or remove viewing.
            overwrites.append(.init(target: .role(.init(rawValue: UInt64(100_000 + overwrites.count))),
                allow: try UnsignedBitSet(bits: [3]), deny: base))
        }
        let expectedPositions: [Int]
        switch mode {
        case .allow: expectedPositions = common
        case .deny: expectedPositions = [10, 16, width - 1, marker]
        case .administrator: expectedPositions = common + [3]
        case .owner: expectedPositions = []
        }
        let expected = try UnsignedBitSet(bits: expectedPositions)
        let unrestricted = mode == .administrator || mode == .owner
        return Fixture(guild: .init(id: guildID, ownerID: owner, roles: roles),
            member: .init(guildID: guildID, userID: user, roleIDs: assigned, timeoutActive: false),
            channel: .init(id: .init(rawValue: UInt64(500 + variant)), guildID: guildID,
                type: .init(.guildText), overwrites: overwrites),
            expectedRaw: expected, expectedEffective: expected, unrestricted: unrestricted,
            observation: observation(raw: expected, effective: expected, unrestricted: unrestricted, width: width))
    }

    /// Reads only finite result features inside timing; complete equality is checked by `verify` outside it.
    /// - Parameters:
    ///   - raw: Actual finite permissions before implicit restrictions, or the bypass result's observed finite mask.
    ///   - effective: Actual effective mask after the resolver's supported restrictions.
    ///   - unrestricted: Whether owner or administrator semantics allow arbitrary-width requirements.
    ///   - width: Prepared mask width, at least 64; selects the four independently varied marker positions.
    /// - Returns: A bounded numeric checksum with zero rejections. It samples widths, bypass, sending and marker bits;
    ///   it is an observable result sink rather than a full hash or an authorization decision.
    /// This performs a fixed number of nonmutating bit queries and includes that consumption cost in the timer.
    private static func observation(raw: UnsignedBitSet, effective: UnsignedBitSet,
                                    unrestricted: Bool, width: Int) -> FoundationObservation {
        var checksum = UInt64(raw.bitWidth) &* 65_537 &+ UInt64(effective.bitWidth)
        checksum = checksum &* 2 &+ (unrestricted ? 1 : 0)
        checksum = checksum &* 2 &+ (effective.contains(11) ? 1 : 0)
        for position in (width - 8)...(width - 5) {
            checksum = checksum &* 2 &+ (effective.contains(position) ? 1 : 0)
        }
        return FoundationObservation(checksum: checksum)
    }

    /// Canonical sorted numeric facts make the fixture digest cover roles, masks and overwrite targets.
    /// - Parameter variants: Prepared complete fixtures; ownership and overwrite lists must be present, as guaranteed
    ///   by `prepare`. Empty input is accepted and produces empty data.
    /// - Returns: UTF-8 newline-separated facts, with role identifiers sorted numerically and overwrite order retained.
    /// Decimal conversion of arbitrary-width masks is intentionally setup work. The returned value owns its bytes;
    /// no payload logging, external writes, resolver calls or timed instrumentation occur here.
    private static func fixtureBytes(_ variants: [Fixture]) -> Data {
        var lines: [String] = []
        for fixture in variants {
            lines.append("guild:\(fixture.guild.id.rawValue):owner:\(fixture.guild.ownerID!.rawValue):member:\(fixture.member.userID.rawValue)")
            for id in fixture.guild.roles.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                lines.append("role:\(id.rawValue):\(fixture.guild.roles[id]!)")
            }
            for overwrite in fixture.channel.overwrites! {
                switch overwrite.target {
                case .role(let id): lines.append("overwrite-role:\(id.rawValue):\(overwrite.allow):\(overwrite.deny)")
                case .member(let id): lines.append("overwrite-member:\(id.rawValue):\(overwrite.allow):\(overwrite.deny)")
                case .unknown(let type, let id): lines.append("overwrite-unknown:\(type):\(id)")
                }
            }
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// Resolver refusals are observed as exact indeterminacy values, never accepted as resolved zero.
    /// - Parameter resourceLimit: True selects two supplied roles against a one-role cap; false selects an unknown
    ///   overwrite discriminator with otherwise complete facts and the normal 1,024-role cap.
    /// - Returns: Four prepared rejected variants with one rejection per call. The timed closure classifies observed
    ///   indeterminacy; the untimed verifier requires the exact `resourceLimit` or `inconsistentOverwrites` reason.
    /// - Throws: Bitset fixture-construction failures. Verification subsequently throws `integrityFailure` if a
    ///   refusal changes type or the resolver admits a fixture.
    /// No cache state or server response is involved; these refusals describe only caller-supplied bounded facts.
    private static func refusal(resourceLimit: Bool) throws -> FoundationWorkload {
        let variants = try (0..<4).map { try prepare(mode: .allow, count: 1, width: 64, variant: $0) }
        let reason: PermissionIndeterminacy = resourceLimit ? .resourceLimit : .inconsistentOverwrites
        let id = resourceLimit ? "permission.reject.resource-limit" : "permission.reject.unknown-overwrite"
        let channels = variants.enumerated().map { index, fixture in
            PermissionChannelState(id: fixture.channel.id, guildID: fixture.guild.id,
                type: .init(.guildText), overwrites: resourceLimit ? fixture.channel.overwrites : [
                    .init(target: .unknown(type: 90 + index, id: UInt64(index)))])
        }
        let limits = PermissionResolutionLimits(maximumRoles: resourceLimit ? 1 : 1_024)
        let expected = FoundationObservation(checksum: resourceLimit ? 1 : 2, rejections: 1)
        var bytes = fixtureBytes(variants)
        bytes.append(contentsOf: "\n\(id):maximum-roles:\(limits.maximumRoles):unknown-types:90,91,92,93".utf8)
        let operation: (UInt64) throws -> FoundationObservation = { input in
            let index = Int(input % 4), fixture = variants[index]
            switch PermissionResolver.resolve(guild: fixture.guild, member: fixture.member,
                channel: channels[index], limits: limits) {
            case .indeterminate(.resourceLimit): return FoundationObservation(checksum: 1, rejections: 1)
            case .indeterminate(.inconsistentOverwrites): return FoundationObservation(checksum: 2, rejections: 1)
            case .indeterminate: return FoundationObservation(checksum: 3, rejections: 1)
            case .resolved: return FoundationObservation(checksum: 0)
            }
        }
        return FoundationWorkload(id: id,
            dimensions: ["role_count": 2, "assigned_role_count": 1, "overwrite_count": 1,
                "bit_width": 64, "variant_count": 4, "maximum_roles": UInt64(limits.maximumRoles)],
            fixture: bytes, operation: operation, expected: { _ in expected }, verify: {
                for index in 0..<4 {
                    let fixture = variants[index]
                    guard PermissionResolver.resolve(guild: fixture.guild, member: fixture.member,
                        channel: channels[index], limits: limits) == .indeterminate(reason) else {
                        throw FoundationBenchmarkError.integrityFailure(id)
                    }
                }
            })
    }
}
