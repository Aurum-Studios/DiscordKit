// File: Tools/DiscordBenchmarkSupport/Sources/DiscordBenchmarkSupport/Provenance.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Provenance recorded outside measured intervals. Missing values remain unavailable;
/// the process driver supplies build receipts instead of guessing compiler or source identity.
public struct BenchmarkProvenance: Codable, Equatable, Sendable {
    public var machineIdentity: String?
    public var cpuModel: String?
    public var architecture: String?
    public var cpuAllocation: String?
    public var memoryBytes: UInt64?
    public var compiler: String?
    public var optimization: String?
    public var operatingSystem: String?
    public var sdk: String?
    public var target: String?
    public var sourceRevision: String?
    public var dirtyFingerprint: String?
    public var dependencyHashes: [String: String]
    public var fixtureHashes: [String: String]
    public var executableHash: String?
    public var buildFlags: [String]?
    public var unavailabilityReasons: [String: String]

    /// Creates an explicit capture receipt; nil means unknown, never an inferred identity.
    /// - Parameters:
    ///   - machineIdentity: Stable host/model or runner identity, excluding credentials.
    ///   - cpuModel: Native CPU model, or nil when the host does not expose it.
    ///   - architecture: Native architecture, independent of the compilation target.
    ///   - cpuAllocation: Effective CPU count, affinity and quota allocation description.
    ///   - memoryBytes: Effective physical/container allocation in bytes.
    ///   - compiler: Exact compiler version supplied by an authoritative build receipt.
    ///   - optimization: Actual optimization configuration, such as release -O.
    ///   - operatingSystem: Native OS version, not a guessed deployment target.
    ///   - sdk: SDK/build environment identity, including explicit not-applicable when appropriate.
    ///   - target: Exact compilation target triple.
    ///   - sourceRevision: Source revision; comparisons deliberately permit changes.
    ///   - dirtyFingerprint: SHA-256 of dirty content, or an explicit clean fingerprint.
    ///   - dependencyHashes: Dependency-resolution receipts indexed by finite package identity.
    ///   - fixtureHashes: Fixture/input SHA-256 receipts indexed by finite fixture identity.
    ///   - executableHash: SHA-256 of the executable actually invoked.
    ///   - buildFlags: Exact build flags, including an explicitly empty list when known.
    ///   - unavailabilityReasons: Reasons for every missing receipt; no probe runs implicitly.
    public init(machineIdentity: String? = nil, cpuModel: String? = nil, architecture: String? = nil,
        cpuAllocation: String? = nil, memoryBytes: UInt64? = nil, compiler: String? = nil,
        optimization: String? = nil, operatingSystem: String? = nil, sdk: String? = nil,
        target: String? = nil, sourceRevision: String? = nil, dirtyFingerprint: String? = nil,
        dependencyHashes: [String: String] = [:], fixtureHashes: [String: String] = [:],
        executableHash: String? = nil, buildFlags: [String]? = nil,
        unavailabilityReasons: [String: String] = [:]) {
        self.machineIdentity = machineIdentity; self.cpuModel = cpuModel; self.architecture = architecture
        self.cpuAllocation = cpuAllocation; self.memoryBytes = memoryBytes; self.compiler = compiler
        self.optimization = optimization; self.operatingSystem = operatingSystem; self.sdk = sdk
        self.target = target; self.sourceRevision = sourceRevision; self.dirtyFingerprint = dirtyFingerprint
        self.dependencyHashes = dependencyHashes; self.fixtureHashes = fixtureHashes
        self.executableHash = executableHash; self.buildFlags = buildFlags
        self.unavailabilityReasons = unavailabilityReasons
        for field in missingFields() where self.unavailabilityReasons[field] == nil {
            self.unavailabilityReasons[field] = "No authoritative capture receipt supplied."
        }
    }

    /// Captures inexpensive native process facts after measurement without spawning tools.
    /// CPU quota, compiler/build/source hashes and SDK remain explicitly unavailable until
    /// supplied by the driver. A visible CPU count alone does not establish a CPU allocation.
    /// - Returns: A conservative snapshot; unsupported native probes return nil with a reason.
    public static func capture() -> Self {
        let info = ProcessInfo.processInfo
        var architecture: String?
        var native = utsname()
        if uname(&native) == 0 {
            architecture = withUnsafeBytes(of: &native.machine) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        #if canImport(Darwin)
        let cpu = systemString("machdep.cpu.brand_string")
        #else
        let cpuText = try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8)
        let cpu = cpuText?.split(separator: "\n").first { $0.hasPrefix("model name") || $0.hasPrefix("Hardware") }
            .flatMap { line in line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } }
        #endif
        return Self(cpuModel: cpu, architecture: architecture, operatingSystem: info.operatingSystemVersionString,
            unavailabilityReasons: ["cpuAllocation": "Visible active CPUs: \(info.activeProcessorCount); affinity and quota require driver receipt.",
                "machineIdentity": "A hardware model is not a stable runner identity; driver receipt required.",
                "memoryBytes": "Visible physical bytes: \(info.physicalMemory); effective allocation requires driver receipt."])
    }

    /// Lists absent mandatory provenance independently of any caller-authored reason dictionary.
    /// - Returns: Stable field names used to reject incomplete comparisons, without filesystem work.
    public func missingFields() -> [String] {
        var fields: [String] = []
        let strings: [(String, String?)] = [("machineIdentity", machineIdentity), ("cpuModel", cpuModel),
            ("architecture", architecture), ("cpuAllocation", cpuAllocation), ("compiler", compiler),
            ("optimization", optimization), ("operatingSystem", operatingSystem), ("sdk", sdk),
            ("target", target), ("sourceRevision", sourceRevision), ("dirtyFingerprint", dirtyFingerprint),
            ("executableHash", executableHash)]
        for (field, value) in strings where value == nil || value?.isEmpty == true || value == "unavailable" {
            fields.append(field)
        }
        if memoryBytes == nil || memoryBytes == 0 { fields.append("memoryBytes") }
        if buildFlags == nil { fields.append("buildFlags") }
        if !Self.validHash(executableHash), !fields.contains("executableHash") { fields.append("executableHash") }
        if !Self.validHash(dirtyFingerprint), !fields.contains("dirtyFingerprint") { fields.append("dirtyFingerprint") }
        if !Self.validHashes(dependencyHashes) { fields.append("dependencyHashes") }
        if !Self.validHashes(fixtureHashes) { fields.append("fixtureHashes") }
        return fields
    }

    /// Checks SHA-256 receipt syntax without interpreting paths or fetching dependencies.
    /// - Parameter hashes: Nonempty finite receipt names mapped to lowercase or uppercase hex digests.
    /// - Returns: False for absent/empty/placeholder hashes and malformed SHA-256 values.
    static func validHashes(_ hashes: [String: String]) -> Bool {
        !hashes.isEmpty && hashes.allSatisfy { !$0.key.isEmpty && validHash($0.value) }
    }

    /// Recognizes exactly one SHA-256 hexadecimal digest; a placeholder is never a receipt.
    /// - Parameter hash: Candidate digest, which may be unavailable.
    /// - Returns: True only for 64 ASCII hexadecimal characters.
    static func validHash(_ hash: String?) -> Bool {
        guard let hash, hash.utf8.count == 64 else { return false }
        return hash.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    #if canImport(Darwin)
    /// Reads one bounded native sysctl string; unsupported keys remain unavailable.
    /// - Parameter key: Fixed native key, never a user-supplied command.
    /// - Returns: Native value without its trailing NUL, or nil after probe failure.
    private static func systemString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0, size <= 16_384 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    #endif
}

/// Checked integer nanosecond conversions for development reports. Clock regressions are errors;
/// the runtime scalar timing clamp remains independently unchanged.
public enum BenchmarkTime {
    /// Converts finite nonnegative seconds to integer nanoseconds by rounding down.
    /// - Parameter seconds: Elapsed seconds; negative, nonfinite and overflowing values are invalid.
    /// - Returns: Representable integer nanoseconds; subnanosecond fractions are discarded.
    /// - Throws: `BenchmarkReportError.invalidTime` for invalid or out-of-range input.
    public static func nanoseconds(seconds: Double) throws -> UInt64 {
        let scaled = seconds * 1_000_000_000
        guard seconds.isFinite, seconds >= 0, scaled.isFinite, scaled < Double(UInt64.max) else {
            throw BenchmarkReportError.invalidTime
        }
        return UInt64(scaled)
    }

    /// Converts an exact Swift duration without floating-point range or precision loss.
    /// - Parameter duration: Nonnegative duration whose integer nanoseconds fit UInt64.
    /// - Returns: Integer nanoseconds, truncating fractional nanoseconds toward zero.
    /// - Throws: `BenchmarkReportError.invalidTime` on negative duration or checked arithmetic overflow.
    public static func nanoseconds(duration: Duration) throws -> UInt64 {
        let parts = duration.components
        guard parts.seconds >= 0, parts.attoseconds >= 0 else { throw BenchmarkReportError.invalidTime }
        let (whole, overflow) = UInt64(parts.seconds).multipliedReportingOverflow(by: 1_000_000_000)
        let (result, additionOverflow) = whole.addingReportingOverflow(UInt64(parts.attoseconds / 1_000_000_000))
        guard !overflow, !additionOverflow else { throw BenchmarkReportError.invalidTime }
        return result
    }

    /// Validates two run-relative offsets before subtraction; domains cannot be mixed.
    /// - Parameters:
    ///   - start: Integer offset from the run's monotonic origin.
    ///   - end: Integer terminal offset, at or after start.
    ///   - startDomain: Nonempty run-local clock identifier for start.
    ///   - endDomain: Clock identifier for end; must exactly match start.
    /// - Returns: Exact elapsed nanoseconds.
    /// - Throws: `BenchmarkReportError.invalidTime` for regression or mixed/empty domains.
    public static func interval(start: UInt64, end: UInt64, startDomain: String, endDomain: String) throws -> UInt64 {
        guard !startDomain.isEmpty, startDomain == endDomain, end >= start else { throw BenchmarkReportError.invalidTime }
        return end - start
    }
}
