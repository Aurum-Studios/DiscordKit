// File: Tools/DiscordTimingBenchmarks/Sources/DiscordTimingBenchmarks/Resources.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Best-effort process gauges; missing syscalls never become fabricated zero observations.
struct TimingProcessSample: Sendable {
    let cpuNanoseconds: UInt64?
    let residentBytes: UInt64?
    let peakBytes: UInt64?
    let liveBlocks: UInt64?
    let liveBytes: UInt64?

    /// Samples CPU, current/peak RSS and Darwin live allocator indicators outside operation timers.
    /// - Returns: Actual native counters; Linux live allocator/current RSS are explicitly unavailable.
    ///   Allocation indicators describe live process footprint, not allocation events per operation.
    static func capture() -> Self {
        var usage = rusage()
        #if canImport(Darwin)
        let status = getrusage(RUSAGE_SELF, &usage)
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        var mallocInfo = malloc_statistics_t()
        malloc_zone_statistics(nil, &mallocInfo)
        let resident = result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
        let blocks: UInt64? = UInt64(mallocInfo.blocks_in_use)
        let bytes: UInt64? = UInt64(mallocInfo.size_in_use)
        let peak = status == 0 ? UInt64(max(0, usage.ru_maxrss)) : nil
        #else
        let status = getrusage(__rusage_who_t(RUSAGE_SELF.rawValue), &usage)
        let resident: UInt64? = nil, blocks: UInt64? = nil, bytes: UInt64? = nil
        let peak = status == 0 ? UInt64(max(0, usage.ru_maxrss)) * 1_024 : nil
        #endif
        let seconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let cpu = status == 0 ? try? BenchmarkTime.nanoseconds(seconds: seconds) : nil
        return Self(cpuNanoseconds: cpu, residentBytes: resident, peakBytes: peak, liveBlocks: blocks, liveBytes: bytes)
    }

    /// Makes scope-correct shared gauges, retaining unavailable resource observations as explicit nil.
    /// - Parameter start: Counter sample immediately before measured cohort submission.
    /// - Returns: CPU delta, final RSS/lifetime peak, live allocator indicators and unavailable event counts.
    func gauges(since start: Self) -> [String: BenchmarkGauge] {
        let cpu: UInt64?
        if let current = cpuNanoseconds, let previous = start.cpuNanoseconds, current >= previous {
            cpu = current - previous
        } else { cpu = nil }
        return [
            "processCPU": Self.gauge(cpu, unit: "nanoseconds", method: "getrusage user+system delta", scope: "native-CPU-read-to-native-CPU-read-including-baseline-resource-probes"),
            "processResidentBytes": Self.gauge(residentBytes, unit: "bytes", method: "native task_info", scope: "after-measured-cohort"),
            "processPeakResidentBytes": Self.gauge(peakBytes, unit: "bytes", method: "getrusage ru_maxrss", scope: "process-lifetime"),
            "liveAllocationBlocks": Self.gauge(liveBlocks, unit: "blocks", method: "malloc_zone_statistics", scope: "after-measured-cohort-process-live"),
            "liveAllocationBytes": Self.gauge(liveBytes, unit: "bytes", method: "malloc_zone_statistics", scope: "after-measured-cohort-process-live"),
            "allocationEvents": .init(value: nil, unit: "events", method: "unavailable", scope: "measured-cohort",
                unavailableReason: "No portable allocation-event probe is installed; live malloc gauges are not event counts."),
        ]
    }

    /// Preserves an unsupported syscall result with its declared method, unit and process scope.
    /// - Parameters:
    ///   - value: Observed native counter or nil when unsupported/failed.
    ///   - unit: Explicit fixed quantity unit.
    ///   - method: Native probe actually attempted; availability remains independently explicit.
    ///   - scope: Honest time/process scope of this observation.
    /// - Returns: A shared valid gauge without synthetic defaults.
    private static func gauge(_ value: UInt64?, unit: String, method: String, scope: String) -> BenchmarkGauge {
        .init(value: value, unit: unit, method: method, scope: scope,
            unavailableReason: value == nil ? "Native probe is unsupported on this platform or failed." : nil)
    }
}
