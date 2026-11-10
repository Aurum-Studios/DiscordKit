// File: Sources/DiscordTransport/OperationTimingOutputs.swift
// Created by Carson Rau.
// Copyright (c) 2026 Aurum Studios.
// https://aurum-studios.com

import DiscordLogging

extension OperationTimingSample {
    /// Bridges a completed scalar sample to optional content-free outputs without inventing endpoints.
    ///
    /// This mapping preserves the legacy phase, outcome and regression-clamped elapsed value exactly.
    /// A duration outside signed nanosecond range is explicitly invalid in the output. No clock,
    /// correlation identity, observer, task or output backend is created.
    public var observation: DiscordTimingObservation {
        /// Returns a checked scalar value; it cannot be used to reconstruct historical profiler intervals.
        get {
            let mappedPhase: DiscordTimingObservation.Phase = switch phase {
            case .gatewayLocalQueue: .gatewayLocalQueue
            case .gatewaySharedAdmission: .gatewaySharedAdmission
            case .gatewayReceiveToAdmission: .gatewayReceiveToAdmission
            case .gatewayReceiveToAcknowledgement: .gatewayReceiveToAcknowledgement
            case .gatewayAdmissionToAcknowledgement: .gatewayAdmissionToAcknowledgement
            case .gatewayRunJoined: .gatewayRunJoined
            case .interactionInitialResponse: .interactionInitialResponse
            case .interactionOriginalEdit: .interactionOriginalEdit
            case .interactionAcknowledgementToOriginalEdit: .interactionAcknowledgementToOriginalEdit
            case .httpAdmission: .httpAdmission
            case .httpHeaders: .httpHeaders
            case .httpBody: .httpBody
            case .httpCoalescedSubscriber: .httpCoalescedSubscriber
            case .httpExecutionJoined: .httpExecutionJoined
            }
            let mappedOutcome: DiscordTimingObservation.Outcome = switch outcome {
            case .succeeded: .succeeded
            case .failed: .failed
            case .cancelled: .cancelled
            case .uncertain: .uncertain
            }
            return DiscordTimingObservation(phase: mappedPhase, outcome: mappedOutcome, elapsed: elapsed)
        }
    }
}
