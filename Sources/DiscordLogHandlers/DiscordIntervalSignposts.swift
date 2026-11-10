// File: Sources/DiscordLogHandlers/DiscordIntervalSignposts.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordLogging
import Foundation
#if canImport(os)
import os
#endif

/// Sanitized profiler-adapter configuration failures.
public enum DiscordIntervalSignpostError: Error, Sendable, Equatable {
    /// The active interval ceiling is outside `1...65_536`.
    case invalidConfiguration
}

/// Constant-size live-profiler accounting; counters saturate rather than wrap.
public struct DiscordIntervalSignpostSnapshot: Sendable, Equatable {
    /// Genuine begin callbacks accepted by the adapter, including starts still delivering.
    public let begunIntervals: UInt64
    /// Valid genuine terminal callbacks scheduled/delivering through paired ending closures.
    public let endedIntervals: UInt64
    /// Active-limit, malformed, unmatched or closed-admission endpoint rejections.
    public let droppedRecords: UInt64
    /// Starts closed without valid genuine ends; cleanup signposts never establish operation durations.
    public let incompleteIntervals: UInt64
    /// Terminal callbacks with no accepted matching begin, including mismatched ownership.
    public let unmatchedEndpoints: UInt64
    /// Active starts plus currently delivering begin/end callbacks; bounded by the configured ceiling.
    public let activeIntervals: Int
    /// Whether close has stopped admission and scheduled cleanup for every accepted start.
    public let isClosed: Bool
}

/// Bounded genuine lifecycle pairing for a synchronous, explicitly adopted profiler output.
///
/// A begin emitter returns the once-only ending closure associated with its real profiler state.
/// Its optional argument contains a valid actual terminal endpoint; nil means explicit incomplete
/// cleanup after invalid evidence or shutdown. These callbacks run outside the adapter lock and may
/// inspect snapshots, but must be prompt, nonthrowing and nonrecursive. Independent intervals may
/// emit concurrently. A racing terminal/close waits in its bounded start entry until begin returns;
/// no tasks, queues, clocks, files, diagnostic strings or global bootstrap are created by pairing.
///
/// The Apple convenience initializer stores actual `OSSignpostIntervalState` in each ending closure.
/// Instruments timestamps are live delivery times, including scheduling and observer delays; supplied
/// numeric offsets cannot backdate a signpost. Incomplete cleanup ends are explicitly labeled and
/// cannot qualify as completed operation measurements. Do not feed this adapter reconstructed scalar
/// samples or replay an end-of-run capture as historical Instruments intervals.
///
/// Applications stop/join producers and then call `close`. Close releases active endings synchronously
/// outside the lock; a begin callback already executing will perform its own incomplete cleanup when
/// it returns. `activeIntervals` exposes these in-flight starts. Joining producers makes close final.
public final class DiscordIntervalSignposts: @unchecked Sendable {
    /// Immutable active-state ceiling; no accepted start can allocate beyond this finite population.
    public let maximumActiveIntervals: Int
    private typealias Ending = @Sendable (DiscordIntervalEvent?) -> Void
    private final class Entry {
        let event: DiscordIntervalEvent
        var ending: Ending?
        var terminal: DiscordIntervalEvent?
        var terminalRequested = false
        var incompleteRequested = false

        /// Reserves one accepted actual begin before invoking any application emitter.
        /// - Parameter event: Valid finite begin used to verify its genuine terminal counterpart.
        init(event: DiscordIntervalEvent) { self.event = event }
    }
    private let lock = NSLock()
    private let beginEmitter: @Sendable (DiscordIntervalEvent) -> Ending
    private var active: [Entry] = []
    private var begun: UInt64 = 0
    private var ended: UInt64 = 0
    private var dropped: UInt64 = 0
    private var incomplete: UInt64 = 0
    private var unmatched: UInt64 = 0
    private var closed = false
    private var finishing = 0

    /// Installs a portable explicit emitter seam without emitting or starting background work.
    /// - Parameters:
    ///   - maximumActiveIntervals: Concurrent start/state ceiling in `1...65_536`; defaults to 1,024.
    ///   - begin: Prompt concurrent-safe callback for an accepted genuine begin. It returns a prompt
    ///     once-only ending closure owning that profiler state. A nonnil ending argument is a valid
    ///     genuine end; nil requires incomplete cleanup, never a successful synthetic terminal.
    ///     Both callbacks execute outside internal locks and must not recursively call `record`/`close`.
    /// - Throws: `DiscordIntervalSignpostError.invalidConfiguration` before invoking the emitter.
    public init(maximumActiveIntervals: Int = 1_024,
                begin: @escaping @Sendable (DiscordIntervalEvent) -> (@Sendable (DiscordIntervalEvent?) -> Void)) throws {
        guard (1...65_536).contains(maximumActiveIntervals) else {
            throw DiscordIntervalSignpostError.invalidConfiguration
        }
        self.maximumActiveIntervals = maximumActiveIntervals
        self.beginEmitter = begin
        active.reserveCapacity(maximumActiveIntervals)
    }

    /// Accepts genuine lifecycle endpoints and pairs one terminal with its previously accepted begin.
    /// - Parameter event: Original detailed hook event; numeric timestamps are validated, never backdated.
    ///   Missing, duplicate, invalid or mismatched observations update explicit rejection/loss counters.
    ///   Real emitter callbacks execute outside locks; their costs remain visible in enclosing owners.
    ///
    /// This bounded synchronous operation does not throw or affect operation outcomes. Producers must
    /// preserve per-interval begin/end order. Snapshot inspection from an emitter is supported.
    public func record(_ event: DiscordIntervalEvent) {
        switch event.kind {
        case .began: begin(event)
        case .ended: end(event)
        }
    }

    /// Returns coherent pairing and loss counters without calling the emitter.
    /// - Returns: Current counts, including start callbacks that are still delivering across a close.
    public func snapshot() -> DiscordIntervalSignpostSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return DiscordIntervalSignpostSnapshot(begunIntervals: begun, endedIntervals: ended,
            droppedRecords: dropped, incompleteIntervals: incomplete, unmatchedEndpoints: unmatched,
            activeIntervals: active.count + finishing, isClosed: closed)
    }

    /// Closes admission and invokes incomplete cleanup once for every still-active profiler state.
    ///
    /// Repeated calls are harmless. Ending callbacks execute outside the lock. A begin emitter already
    /// running is marked for cleanup and will close its returned state before its `record` call returns.
    /// This method creates no tasks and does not wait for producers; stop/join them before close when
    /// shutdown requires all callbacks to have finished. Later endpoints count as dropped observations.
    public func close() {
        var endings: [Ending] = []
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        var starting: [Entry] = []
        for entry in active {
            if let ending = entry.ending {
                endings.append(ending)
                finishing += 1
                Self.increment(&incomplete)
            } else {
                entry.incompleteRequested = true
                starting.append(entry)
            }
        }
        active = starting
        lock.unlock()
        for ending in endings { deliver(ending, terminal: nil) }
    }

    /// Reserves bounded state, emits outside the lock, then resolves any racing end or shutdown.
    /// - Parameter event: Genuine begin with representable same-domain timing validity.
    private func begin(_ event: DiscordIntervalEvent) {
        lock.lock()
        guard !closed, event.validity == .valid,
              let timestamp = event.timestampNanoseconds, timestamp >= 0,
              active.count + finishing < maximumActiveIntervals,
              !active.contains(where: { $0.event.context.operationID == event.context.operationID }) else {
            Self.increment(&dropped)
            lock.unlock()
            return
        }
        let entry = Entry(event: event)
        active.append(entry)
        Self.increment(&begun)
        lock.unlock()
        let ending = beginEmitter(event)
        var finish = false
        var terminal: DiscordIntervalEvent?
        lock.lock()
        if entry.incompleteRequested || entry.terminalRequested {
            finish = true
            terminal = entry.incompleteRequested ? nil : entry.terminal
            remove(entry)
            finishing += 1
            if terminal == nil { Self.increment(&incomplete) } else { Self.increment(&ended) }
        } else { entry.ending = ending }
        lock.unlock()
        if finish { deliver(ending, terminal: terminal) }
    }

    /// Pairs a genuine terminal or marks its accepted start for incomplete cleanup.
    /// - Parameter event: Actual terminal endpoint; no scalar duration can create a missing begin.
    private func end(_ event: DiscordIntervalEvent) {
        var ending: Ending?
        var terminal: DiscordIntervalEvent?
        lock.lock()
        guard !closed else { Self.increment(&dropped); lock.unlock(); return }
        guard let entry = active.first(where: { $0.event.context.operationID == event.context.operationID }),
              !entry.terminalRequested else {
            Self.increment(&dropped)
            Self.increment(&unmatched)
            lock.unlock()
            return
        }
        let original = entry.event
        guard original.context == event.context, original.operation == event.operation, original.stage == event.stage else {
            Self.increment(&dropped)
            Self.increment(&unmatched)
            lock.unlock()
            return
        }
        let valid: Bool
        if let start = original.timestampNanoseconds, let finish = event.timestampNanoseconds,
           start >= 0, finish >= start {
            valid = event.validity == .valid && event.outcome != nil
                && event.elapsedNanoseconds == finish - start
        } else { valid = false }
        terminal = valid ? event : nil
        if !valid { Self.increment(&dropped) }
        if let ready = entry.ending {
            ending = ready
            remove(entry)
            finishing += 1
            if valid { Self.increment(&ended) } else { Self.increment(&incomplete) }
        } else {
            entry.terminalRequested = true
            entry.terminal = terminal
        }
        lock.unlock()
        if let ending { deliver(ending, terminal: terminal) }
    }

    /// Completes one externally emitted ending before releasing its capacity reservation.
    /// - Parameters:
    ///   - ending: Once-only state finalizer, invoked outside every adapter lock.
    ///   - terminal: Genuine valid end, or nil for explicit incomplete shutdown/invalid cleanup.
    ///
    /// Capacity remains reserved during callback execution, including a callback that overlaps close.
    /// This bounds actual live profiler state rather than only entries waiting for an end.
    private func deliver(_ ending: Ending, terminal: DiscordIntervalEvent?) {
        ending(terminal)
        lock.lock()
        finishing -= 1
        lock.unlock()
    }

    /// Releases one reserved entry while the caller holds the pairing lock.
    /// - Parameter entry: Identity-stable accepted start; no callbacks or finalizers execute here.
    private func remove(_ entry: Entry) {
        if let index = active.firstIndex(where: { $0 === entry }) {
            active.swapAt(index, active.count - 1)
            active.removeLast()
        }
    }

    /// Saturates one lock-owned accounting counter without changing observed operation behavior.
    /// - Parameter counter: Counter incremented for one accepted/rejected lifecycle action.
    private static func increment(_ counter: inout UInt64) {
        if counter < .max { counter += 1 }
    }
}

#if canImport(os)
@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension DiscordIntervalSignposts {
    /// Adopts Apple's live Instruments signposts with bounded genuine begin/end state.
    /// - Parameters:
    ///   - maximumActiveIntervals: Concurrent profiler-state ceiling in `1...65_536`; defaults to 1,024.
    ///   - subsystem: Application-chosen stable unified-logging subsystem; defaults to `DiscordKit`.
    ///   - category: Application-chosen stable profiler category; defaults to `Intervals`.
    /// - Throws: `DiscordIntervalSignpostError.invalidConfiguration` before emitting any signpost.
    ///
    /// Each real begin generates an Apple signpost ID and retains its returned interval state in the
    /// paired ending closure. Names and terminal labels are fixed, with no payloads or dynamic strings.
    /// Valid genuine ends receive `completed`; shutdown/invalid evidence receives `incomplete` and must
    /// be excluded when analyzing operation duration. OS timestamps reflect live callback delivery,
    /// not the hook's supplied monotonic offset. Construction performs no bootstrap or file I/O.
    /// See Apple's [performance recording guidance](https://developer.apple.com/documentation/os/recording-performance-data).
    public convenience init(maximumActiveIntervals: Int = 1_024,
                            subsystem: String = "DiscordKit", category: String = "Intervals") throws {
        let signposter = OSSignposter(subsystem: subsystem, category: category)
        try self.init(maximumActiveIntervals: maximumActiveIntervals, begin: { event in
            let context = event.context
            let state = AppleIntervalState(signposter.beginInterval("DiscordInterval", id: signposter.makeSignpostID(),
                "operation=\(Self.operationCode(event.operation), privacy: .public) stage=\(Self.stageCode(event.stage), privacy: .public) clock=\(context.clockDomain, privacy: .public) namespace=\(context.operationID.namespace, privacy: .public) id=\(context.operationID.value, privacy: .public) parentNamespace=\(context.parentID?.namespace ?? 0, privacy: .public) parent=\(context.parentID?.value ?? 0, privacy: .public) attemptPresent=\(context.attempt == nil ? 0 : 1, privacy: .public) attempt=\(context.attempt ?? 0, privacy: .public)"))
            return { terminal in
                if terminal == nil { signposter.endInterval("DiscordInterval", state.value, "incomplete") }
                else {
                    signposter.endInterval("DiscordInterval", state.value,
                        "completed outcome=\(Self.outcomeCode(terminal?.outcome), privacy: .public)")
                }
            }
        })
    }

    /// Maps finite owner families to public numeric metadata without constructing per-event strings.
    /// - Parameter operation: Genuine detailed owner family.
    /// - Returns: One-based stable code: REST, exchange, subscriber, Gateway dispatch, interaction response.
    private static func operationCode(_ operation: DiscordIntervalOperation) -> Int {
        switch operation {
        case .rest: 1
        case .httpExchange: 2
        case .httpSubscriber: 3
        case .gatewayDispatch: 4
        case .interactionResponse: 5
        }
    }

    /// Maps finite measured boundaries to numeric metadata without dynamic formatting.
    /// - Parameter stage: Genuine lifecycle boundary.
    /// - Returns: One-based stable code in order: operation, admission, headers, body, subscriber,
    ///   local queue, handler, initial response, original edit.
    private static func stageCode(_ stage: DiscordIntervalStage) -> Int {
        switch stage {
        case .operation: 1
        case .admission: 2
        case .headers: 3
        case .body: 4
        case .subscriber: 5
        case .localQueue: 6
        case .handler: 7
        case .initialResponse: 8
        case .originalEdit: 9
        }
    }

    /// Maps terminal classification to finite numeric metadata without serializing application data.
    /// - Parameter outcome: Genuine terminal result; nil is represented explicitly as zero.
    /// - Returns: Zero for absent; one succeeded, two failed, three cancelled, four uncertain.
    private static func outcomeCode(_ outcome: DiscordIntervalOutcome?) -> Int {
        switch outcome {
        case nil: 0
        case .succeeded: 1
        case .failed: 2
        case .cancelled: 3
        case .uncertain: 4
        }
    }
}

/// Transfers Apple state only to its once-only ending closure; pairing prevents concurrent use.
@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
private final class AppleIntervalState: @unchecked Sendable {
    let value: OSSignpostIntervalState

    /// Retains one genuine Apple begin state until exactly one completion or incomplete cleanup.
    /// - Parameter value: State returned by the live signpost begin, never reconstructed from samples.
    init(_ value: OSSignpostIntervalState) { self.value = value }
}
#endif
