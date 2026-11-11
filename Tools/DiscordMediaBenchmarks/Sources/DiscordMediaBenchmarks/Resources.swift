// File: Tools/DiscordMediaBenchmarks/Sources/DiscordMediaBenchmarks/Resources.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordBenchmarkSupport
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Process-scoped probes sampled outside batch timers; unsupported current RSS remains absent.
struct MediaProcessSample {
    let cpu: UInt64?
    let peak: UInt64?
    let resident: UInt64?

    /// Reads native process CPU/lifetime peak RSS and supported current RSS without touching batch state.
    /// - Returns: Native counters, or nil per unsupported/failed probe; current RSS is unavailable on this Linux path.
    /// Darwin task/malloc ownership is process-scoped; no task, file, network or allocation-event probe is installed.
    static func capture() -> Self {
        var usage = rusage()
        #if canImport(Darwin)
        let status = getrusage(RUSAGE_SELF, &usage)
        let peak = status == 0 ? UInt64(max(0, usage.ru_maxrss)) : nil
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let taskStatus = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let resident = taskStatus == KERN_SUCCESS ? UInt64(info.resident_size) : nil
        #else
        let status = getrusage(__rusage_who_t(RUSAGE_SELF.rawValue), &usage)
        let peak = status == 0 ? UInt64(max(0, usage.ru_maxrss)) * 1_024 : nil
        let resident: UInt64? = nil
        #endif
        let seconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        return Self(cpu: status == 0 ? try? BenchmarkTime.nanoseconds(seconds: seconds) : nil, peak: peak, resident: resident)
    }

    /// Converts process snapshots to explicit gauges after the measured population has stopped.
    /// - Parameter before: Baseline sampled before population setup; CPU delta also spans its baseline resource probes.
    /// - Returns: Nonnegative CPU delta, after-population current RSS and process-lifetime peak RSS, retaining unavailable reasons.
    /// Does not attribute process-wide memory to a single call or subtract warmup from lifetime peak RSS.
    func gauges(since before: Self) -> [String: BenchmarkGauge] {
        let delta = cpu.flatMap { end in before.cpu.flatMap { start in end >= start ? end - start : nil } }
        /// Builds one unit/method/scope-qualified gauge without converting probe absence to zero.
        /// - Parameters:
        ///   - value: Observed native value or nil after unsupported/failed capture.
        ///   - unit: Quantity unit, fixed to nanoseconds or bytes by callers.
        ///   - method: Actual native measurement method, retained even when unavailable.
        ///   - scope: Process and time boundary used to interpret this observation.
        /// - Returns: A shared gauge carrying a reason whenever value is nil; no measurement or I/O occurs.
        func gauge(_ value: UInt64?, unit: String, method: String, scope: String) -> BenchmarkGauge {
            .init(value: value, unit: unit, method: method, scope: scope,
                unavailableReason: value == nil ? "Native probe unsupported or failed." : nil)
        }
        return ["processCPU": gauge(delta, unit: "nanoseconds", method: "getrusage user+system delta", scope: "measured-population-and-baseline-resource-probes"),
            "processResidentBytes": gauge(resident, unit: "bytes", method: "native task_info", scope: "after-measured-population"),
            "processPeakResidentBytes": gauge(peak, unit: "bytes", method: "getrusage ru_maxrss", scope: "process-lifetime")]
    }
}
