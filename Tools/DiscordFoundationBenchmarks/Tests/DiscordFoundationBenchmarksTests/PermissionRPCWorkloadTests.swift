// File: Tools/DiscordFoundationBenchmarks/Tests/DiscordFoundationBenchmarksTests/PermissionRPCWorkloadTests.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBits
import DiscordCache
import DiscordCore
import DiscordModels
import DiscordRPC
import Foundation
import Testing
@testable import DiscordFoundationBenchmarks

/// Pure CPU workload oracles do not require a cache, IPC transport or live Discord process.
@Suite struct PermissionRPCWorkloadTests {
    /// Prepared four-way input selection preserves exact outputs and refusal counts, including wrapping inputs.
    /// - Throws: Fixture construction, full semantic verification or unexpected measured-operation errors.
    /// Exercises all ten permission and seventeen framing cases, their declared scale dimensions and both rejected
    /// and admitted populations. Input values spanning four variants and UInt64.max qualify modulo selection without
    /// running a clock or asserting machine-dependent speed. Every operation owns only synchronous local values.
    @Test func workloadObservationsMatchIndependentOracles() throws {
        let permissions = try PermissionWorkloads.make()
        let rpc = try RPCWorkloads.make()
        #expect(permissions.count == 10)
        #expect(rpc.count == 17)
        let workloads = permissions + rpc
        #expect(Set(workloads.map(\.id)).count == workloads.count)
        for workload in workloads {
            #expect(!workload.fixture.isEmpty)
            #expect(workload.dimensions["variant_count"] == 4)
            try workload.verify()
            for input in [UInt64(0), 1, 2, 3, 4, 7, UInt64.max] {
                let observed = try workload.operation(input)
                #expect(observed == workload.expected(input))
                #expect(observed.rejections == (workload.id.contains(".reject.") ? 1 : 0))
            }
        }
        #expect(Set(permissions.compactMap { $0.dimensions["bit_width"] }) == [64, 256, 4_096])
        #expect(Set(rpc.compactMap { $0.dimensions["payload_bytes"] }) == [1_024, 16_384, 262_144])
        #expect(Set(rpc.compactMap { $0.dimensions["fragment_bytes"] }) == [7, 256, 4_096])
    }

    /// Independently authored role/member precedence proves high-bit preservation and bypass semantics.
    /// - Throws: Bitset construction failures for authored positions; unexpected resolver branches record test issues.
    /// Uses a separate literal snapshot to prove everyone denial, role restoration and final member precedence,
    /// retaining unknown bits 72/133. Owner/admin checks then require unbounded inclusion despite missing irrelevant
    /// role or timeout facts, while the ordinary result must reject an absent high bit. No cache or server is consulted.
    @Test func permissionPrecedenceAndBypassHaveKnownResults() throws {
        let guildID = GuildID(rawValue: 99), userID = UserID(rawValue: 7)
        let roleID = RoleID(rawValue: 2)
        let guild = PermissionGuildState(id: guildID, ownerID: .init(rawValue: 8), roles: [
            .init(rawValue: 99): try UnsignedBitSet(bits: [10, 11, 16, 72]),
            roleID: try UnsignedBitSet(bits: [16, 133]),
        ])
        let member = PermissionMemberState(guildID: guildID, userID: userID,
            roleIDs: [roleID], timeoutActive: false)
        let channel = PermissionChannelState(id: .init(rawValue: 100), guildID: guildID,
            type: .init(.guildText), overwrites: [
                .init(target: .role(.init(rawValue: 99)), deny: try UnsignedBitSet(bits: [11, 72])),
                .init(target: .role(roleID), allow: try UnsignedBitSet(bits: [11, 72]),
                    deny: try UnsignedBitSet(bits: [133])),
                .init(target: .member(userID), allow: try UnsignedBitSet(bits: [133]),
                    deny: try UnsignedBitSet(bits: [11])),
            ])
        guard case .resolved(let ordinary) = PermissionResolver.resolve(guild: guild, member: member, channel: channel) else {
            Issue.record("Complete permission snapshot was unexpectedly refused")
            return
        }
        let exact = try UnsignedBitSet(bits: [10, 16, 72, 133])
        #expect(ordinary.rawPermissions == exact)
        #expect(ordinary.permissions == exact)
        #expect(!ordinary.unrestricted)
        #expect(!ordinary.includes(try UnsignedBitSet(bits: [500])))

        let owner = PermissionMemberState(guildID: guildID, userID: .init(rawValue: 8),
            roleIDs: nil, timeoutActive: nil)
        guard case .resolved(let owned) = PermissionResolver.resolve(guild: guild, member: owner) else {
            Issue.record("Known owner did not bypass incomplete role facts")
            return
        }
        #expect(owned.unrestricted && owned.rawPermissions.isEmpty)
        #expect(owned.includes(try UnsignedBitSet(bits: [4_096])))

        let adminGuild = PermissionGuildState(id: guildID, ownerID: nil,
            roles: [roleID: try UnsignedBitSet(bits: [3, 133])])
        let administrator = PermissionMemberState(guildID: guildID, userID: userID,
            roleIDs: [roleID, .init(rawValue: 999)], timeoutActive: nil)
        guard case .resolved(let admin) = PermissionResolver.resolve(guild: adminGuild, member: administrator) else {
            Issue.record("Known administrator did not bypass incomplete nonadmin facts")
            return
        }
        #expect(admin.unrestricted)
        #expect(admin.rawPermissions == (try UnsignedBitSet(bits: [3, 133])))
        #expect(admin.includes(try UnsignedBitSet(bits: [4_096])))
    }

    /// Literal little-endian bytes and every two-part split independently qualify the benchmark's framing oracle.
    /// - Throws: Unexpected encoder/decoder setup, append or EOF errors for the valid four-byte opaque payload.
    /// Exhaustive split positions include empty first/second fragments. Exact malformed-opcode, size and truncated-EOF
    /// failures are asserted independently, including decoder reuse after append failures reset buffered state.
    /// All frames and decoder buffers are test-local; no transport, connection, timing assertion or live IPC is involved.
    @Test func rpcLiteralWireAndPreciseFailures() throws {
        let payload = Data([10, 20, 30, 40])
        let frame = RPCFrame(opcode: .frame, payload: payload)
        let literal = Data([1, 0, 0, 0, 4, 0, 0, 0, 10, 20, 30, 40])
        #expect(try frame.encoded(maximumPayloadBytes: 4) == literal)
        for split in 0...literal.count {
            var decoder = try RPCFrameDecoder(maximumPayloadBytes: 4)
            let first = try decoder.append(Data(literal.prefix(split)))
            let second = try decoder.append(Data(literal.dropFirst(split)))
            #expect(first + second == [frame])
            try decoder.finish()
        }
        var decoder = try RPCFrameDecoder(maximumPayloadBytes: 4)
        #expect(throws: RPCFailure.malformedFrame) {
            try decoder.append(Data([5, 0, 0, 0, 0, 0, 0, 0]))
        }
        #expect(throws: RPCFailure.frameTooLarge) {
            try decoder.append(Data([1, 0, 0, 0, 5, 0, 0, 0]))
        }
        #expect(throws: RPCFailure.frameTooLarge) {
            try RPCFrame(opcode: .frame, payload: Data(count: 5)).encoded(maximumPayloadBytes: 4)
        }
        _ = try decoder.append(Data([1]))
        #expect(throws: RPCFailure.malformedFrame) { try decoder.finish() }
    }
}
