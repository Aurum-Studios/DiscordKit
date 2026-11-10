// File: Tools/DiscordFoundationBenchmarks/Sources/DiscordFoundationBenchmarks/BitsWorkloads.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBits
import DiscordCore
import Foundation

/// Identifier and arbitrary-width bitset work with native integers and position sets as oracles.
/// Operations are synchronous, reentrant over immutable fixtures, and rely on enclosing batch cancellation checks.
enum BitsWorkloads {
    /// Prepares identifier cases and bitset parse/write/algebra/mutation cases at three bounded widths.
    /// - Returns: Fourteen cases with four immutable variants each; bitset widths are 64, 256 and 4,096 bits.
    /// - Throws: Unexpected bitset construction failures during fixture preparation.
    /// Decimal oracles and fingerprints are allocated before timing; returned closures own their retained fixtures.
    static func make() throws -> [FoundationWorkload] {
        var workloads = identifierWorkloads()
        for width in [64, 256, 4_096] {
            let fixtures = try (0..<4).map { try BitFixture(width: width, variant: $0) }
            let dimensions: [String: UInt64] = ["bitWidth": UInt64(width), "variants": 4]
            let fingerprint = Data(fixtures.map { $0.leftDecimal + ":" + $0.rightDecimal }.joined(separator: "\n").utf8)
            let verify = {
                for fixture in fixtures { try fixture.verify() }
            }
            workloads.append(FoundationWorkload(
                id: "bits.parse.width\(width)", dimensions: dimensions, fixture: fingerprint,
                operation: { try parse(fixtures[Int($0 % 4)]) },
                expected: { input in
                    let fixture = fixtures[Int(input % 4)]
                    return FoundationObservation(checksum: positionChecksum(fixture.leftPositions, sample: fixture.sample))
                }, verify: verify
            ))
            workloads.append(FoundationWorkload(
                id: "bits.serialize.width\(width)", dimensions: dimensions, fixture: fingerprint,
                operation: { serialize(fixtures[Int($0 % 4)]) },
                expected: { input in
                    FoundationObservation(checksum: textChecksum(fixtures[Int(input % 4)].leftDecimal))
                }, verify: verify
            ))
            workloads.append(FoundationWorkload(
                id: "bits.algebra.width\(width)", dimensions: dimensions, fixture: fingerprint,
                operation: { algebra(fixtures[Int($0 % 4)]) },
                expected: { input in
                    let fixture = fixtures[Int(input % 4)]
                    return FoundationObservation(checksum:
                        positionChecksum(fixture.leftPositions.union(fixture.rightPositions), sample: fixture.sample)
                        &+ positionChecksum(fixture.leftPositions.intersection(fixture.rightPositions), sample: fixture.sample) &* 3
                        &+ positionChecksum(fixture.leftPositions.symmetricDifference(fixture.rightPositions), sample: fixture.sample) &* 5
                        &+ positionChecksum(fixture.leftPositions.subtracting(fixture.rightPositions), sample: fixture.sample) &* 7)
                }, verify: verify
            ))
            workloads.append(FoundationWorkload(
                id: "bits.mutate.width\(width)", dimensions: dimensions, fixture: fingerprint,
                operation: { try mutate(fixtures[Int($0 % 4)]) },
                expected: { input in
                    let fixture = fixtures[Int(input % 4)]
                    let positions = fixture.leftPositions.symmetricDifference([fixture.sample])
                    return FoundationObservation(checksum: positionChecksum(positions, sample: fixture.sample))
                }, verify: verify
            ))
        }
        return workloads
    }

    /// Prepares decimal parsing and formatting with zero, one, a realistic ID and the full unsigned boundary.
    /// - Returns: Two four-variant cases; parsing inputs include three leading zeroes and formatting is canonical.
    /// Expected timestamps use integer epoch arithmetic independently of the snowflake accessors.
    /// Setup and verification are offline and do not establish that a Discord resource exists.
    private static func identifierWorkloads() -> [FoundationWorkload] {
        let raw: [UInt64] = [0, 1, 175_928_847_299_117_063, UInt64.max]
        let strings = raw.map { "000" + String($0) }
        let values = raw.map { UserID(rawValue: $0) }
        let fingerprint = Data(strings.joined(separator: "\n").utf8)
        let dimensions: [String: UInt64] = ["bitWidth": 64, "variants": 4]
        let verify = {
            for index in raw.indices {
                guard UserID(strings[index])?.rawValue == raw[index],
                      values[index].description == String(raw[index]),
                      values[index].timestampMilliseconds == (raw[index] >> 22) + 1_420_070_400_000 else {
                    throw FoundationBenchmarkError.integrityFailure("Snowflake lost unsigned bits or timestamp precision")
                }
            }
        }
        return [
            FoundationWorkload(
                id: "identifier.parse.snowflake", dimensions: dimensions, fixture: fingerprint,
                operation: { try parseIdentifier(strings[Int($0 % 4)]) },
                expected: { input in
                    let value = raw[Int(input % 4)]
                    return FoundationObservation(checksum: value ^ ((value >> 22) + 1_420_070_400_000))
                }, verify: verify
            ),
            FoundationWorkload(
                id: "identifier.format.snowflake", dimensions: dimensions, fixture: fingerprint,
                operation: { formatIdentifier(values[Int($0 % 4)]) },
                expected: { FoundationObservation(checksum: textChecksum(String(raw[Int($0 % 4)]))) },
                verify: verify
            ),
        ]
    }

    private struct BitFixture {
        let leftPositions: Set<Int>
        let rightPositions: Set<Int>
        let leftDecimal: String
        let rightDecimal: String
        let left: UnsignedBitSet
        let right: UnsignedBitSet
        let sample: Int
        let width: Int

        /// Builds deterministic overlapping position sets and independently calculated decimal spellings.
        /// - Parameters:
        ///   - width: Highest possible occupied position plus one; the private caller supplies 64, 256 or 4,096.
        ///   - variant: Index in `0..<4`, shifting the periodic membership patterns and selecting a sampled low bit.
        /// - Throws: Unexpected `UnsignedBitSet.ValidationError` constructing positions under the default allocation limit.
        /// The caller enforces ranges. Position sets, strings and source bitsets remain immutable after construction.
        init(width: Int, variant: Int) throws {
            self.width = width
            sample = variant
            leftPositions = Set((0..<width).filter { ($0 + variant) % 7 == 0 || $0 == width - 1 })
            rightPositions = Set((0..<width).filter { ($0 + variant) % 11 == 0 || $0 == width - 2 })
            leftDecimal = BitsWorkloads.decimal(positions: leftPositions)
            rightDecimal = BitsWorkloads.decimal(positions: rightPositions)
            left = try UnsignedBitSet(bits: leftPositions.sorted())
            right = try UnsignedBitSet(bits: rightPositions.sorted())
        }

        /// Checks every bit and canonical decimal spelling without a timed full scan.
        /// - Throws: `integrityFailure` for decimal/algebra/copy independence mismatch, or unexpected bitset validation errors.
        /// Widths are bounded by the fixture's prepared range; all temporary result sets are local to this call.
        func verify() throws {
            guard left.description == leftDecimal, right.description == rightDecimal,
                  try UnsignedBitSet(decimalString: leftDecimal) == left,
                  try UnsignedBitSet(decimalString: rightDecimal) == right else {
                throw FoundationBenchmarkError.integrityFailure("Bitset decimal conversion disagreed with decimal-digit oracle")
            }
            var changed = left
            try changed.set(sample, to: !leftPositions.contains(sample))
            let results: [(UnsignedBitSet, Set<Int>)] = [
                (left.union(right), leftPositions.union(rightPositions)),
                (left.intersection(right), leftPositions.intersection(rightPositions)),
                (left.symmetricDifference(right), leftPositions.symmetricDifference(rightPositions)),
                (left.subtracting(right), leftPositions.subtracting(rightPositions)),
                (changed, leftPositions.symmetricDifference([sample])),
            ]
            for (result, positions) in results {
                guard result.bitWidth == (positions.max().map { $0 + 1 } ?? 0),
                      (0...width).allSatisfy({ result.contains($0) == positions.contains($0) }) else {
                    throw FoundationBenchmarkError.integrityFailure("Bitset algebra disagreed with position-set oracle")
                }
            }
            guard left.description == leftDecimal else {
                throw FoundationBenchmarkError.integrityFailure("Copy-on-write mutation changed its source")
            }
        }
    }

    /// Computes base-ten digits by elementary doubling, independently of bitset parsing/writing.
    /// - Parameter positions: Nonnegative occupied bit positions from a bounded prepared fixture.
    /// - Returns: Canonical ASCII decimal digits, or `"0"` for an empty set.
    /// Work is proportional to the highest position times decimal width; its local digit array is setup-only.
    private static func decimal(positions: Set<Int>) -> String {
        guard let highest = positions.max() else { return "0" }
        var digits = [UInt8](repeating: 0, count: 1)
        for bit in stride(from: highest, through: 0, by: -1) {
            var carry: UInt8 = positions.contains(bit) ? 1 : 0
            for index in digits.indices {
                let value = digits[index] * 2 + carry
                digits[index] = value % 10
                carry = value / 10
            }
            if carry > 0 { digits.append(carry) }
        }
        return String(decoding: digits.reversed().map { $0 + 48 }, as: UTF8.self)
    }

    /// Parses one prepared decimal spelling and consumes its width and selected membership bit inside timing.
    /// - Parameter fixture: Immutable bitset inputs whose decimal spelling is within the default digit limit.
    /// - Returns: A minimal checksum with zero rejections; full position equality is verified outside timing.
    /// - Throws: `UnsignedBitSet.ValidationError` if the prepared spelling becomes invalid or exceeds its limits.
    @inline(never)
    private static func parse(_ fixture: BitFixture) throws -> FoundationObservation {
        let value = try UnsignedBitSet(decimalString: fixture.leftDecimal)
        return FoundationObservation(checksum: bitChecksum(value, sample: fixture.sample))
    }

    /// Formats a prepared arbitrary-width value and samples the canonical decimal output inside timing.
    /// - Parameter fixture: Immutable source value at one of the declared finite widths.
    /// - Returns: Decimal byte-count/endpoint checksum with zero rejections.
    /// Decimal conversion owns its temporary storage; no serialized string survives this call.
    @inline(never)
    private static func serialize(_ fixture: BitFixture) -> FoundationObservation {
        FoundationObservation(checksum: textChecksum(fixture.left.description))
    }

    /// Measures union, intersection, symmetric difference and subtraction as one fixed operation class.
    /// - Parameter fixture: Prepared left/right operands and low-bit sample; operands are unchanged.
    /// - Returns: A weighted sum of four minimal result checksums with zero rejections.
    /// Result storage is local; complete per-position algebra checks belong to the untimed verifier.
    @inline(never)
    private static func algebra(_ fixture: BitFixture) -> FoundationObservation {
        FoundationObservation(checksum:
            bitChecksum(fixture.left.union(fixture.right), sample: fixture.sample)
            &+ bitChecksum(fixture.left.intersection(fixture.right), sample: fixture.sample) &* 3
            &+ bitChecksum(fixture.left.symmetricDifference(fixture.right), sample: fixture.sample) &* 5
            &+ bitChecksum(fixture.left.subtracting(fixture.right), sample: fixture.sample) &* 7)
    }

    /// Toggles one prepared low bit on a value copy, including copy-on-write mutation cost inside timing.
    /// - Parameter fixture: Immutable left operand and sample in `0..<4`, below the default maximum bit index.
    /// - Returns: The mutated copy's minimal checksum with zero rejections; the fixture's source is preserved.
    /// - Throws: Unexpected allocation-boundary or index validation errors from `UnsignedBitSet.set`.
    @inline(never)
    private static func mutate(_ fixture: BitFixture) throws -> FoundationObservation {
        var value = fixture.left
        try value.set(fixture.sample, to: !value.contains(fixture.sample))
        return FoundationObservation(checksum: bitChecksum(value, sample: fixture.sample))
    }

    /// Parses an unsigned decimal snowflake and consumes all identifier bits plus its integer timestamp.
    /// - Parameter text: Prepared nonempty ASCII decimal digits, optionally zero-padded, within `UInt64` range.
    /// - Returns: Raw identifier XOR timestamp checksum, with zero rejections.
    /// - Throws: `integrityFailure` if the prepared valid identifier is rejected; no resource lookup occurs.
    @inline(never)
    private static func parseIdentifier(_ text: String) throws -> FoundationObservation {
        guard let value = UserID(text) else {
            throw FoundationBenchmarkError.integrityFailure("Valid identifier was rejected")
        }
        return FoundationObservation(checksum: value.rawValue ^ value.timestampMilliseconds)
    }

    /// Formats every unsigned identifier bit into canonical decimal without provider or network work.
    /// - Parameter value: Prepared typed identifier, including zero and `UInt64.max` boundary values.
    /// - Returns: Formatted byte-count/endpoint checksum with zero rejections; temporary string storage is local.
    @inline(never)
    private static func formatIdentifier(_ value: UserID) -> FoundationObservation {
        FoundationObservation(checksum: textChecksum(value.description))
    }

    /// Consumes constant-sized result features without scanning an arbitrary-width set.
    /// - Parameters:
    ///   - value: Local measured operation result; it is read without mutation or retained references.
    ///   - sample: Prepared bit position in `0..<4`; membership outside a value's width would also be false.
    /// - Returns: Width plus a fixed positive membership contribution, including zero for the empty/unset case.
    private static func bitChecksum(_ value: UnsignedBitSet, sample: Int) -> UInt64 {
        UInt64(value.bitWidth) &+ (value.contains(sample) ? 65_537 : 0)
    }

    /// Computes the untimed position-set oracle for the measured width/membership checksum.
    /// - Parameters:
    ///   - positions: Independently derived nonnegative result positions; may be empty.
    ///   - sample: Same prepared low-bit probe used by the measured operation.
    /// - Returns: Highest position plus one and the fixed membership contribution; empty/unset returns zero.
    /// Finding the maximum scans the bounded set and is intentionally excluded from measurement.
    private static func positionChecksum(_ positions: Set<Int>, sample: Int) -> UInt64 {
        UInt64(positions.max().map { $0 + 1 } ?? 0) &+ (positions.contains(sample) ? 65_537 : 0)
    }

    /// Samples finite UTF-8 output evidence without hashing the whole formatted decimal string.
    /// - Parameter text: Canonical nonempty decimal output; an empty input is supported as zero evidence.
    /// - Returns: Wrapping byte count plus weighted endpoint byte values; the text is not retained.
    private static func textChecksum(_ text: String) -> UInt64 {
        UInt64(text.utf8.count) &+ UInt64(text.utf8.first ?? 0) &* 257 &+ UInt64(text.utf8.last ?? 0)
    }
}
