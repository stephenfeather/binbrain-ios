// CatalogingSession.swift
// Bin Brain
//
// Tracks user-supervision counters that scope to a single cataloging sheet
// presentation — the .fullScreenCover that wraps ScannerView and the
// analysis/review flow. Counters are read at ingest time and emitted as
// `device_metadata.user_behavior` so supervision signals can be trained on.
//
// Lifecycle is owned by BinsListView / BinDetailView: instantiate with the
// view, call `recordRetake()` on the rejection-screen Retake tap and
// `recordQualityBypass()` on the Upload Anyway tap, snapshot via
// `snapshot()` when handing off to AnalysisViewModel.run, and call `reset()`
// from the cover's onDismiss.

import Foundation
import Observation

@Observable
@MainActor
final class CatalogingSession {
    /// Retake Photo taps observed in this cataloging sheet so far.
    private(set) var retakeCount: Int = 0
    /// Upload Anyway (quality-gate bypass) taps observed in this cataloging
    /// sheet so far — cumulative, includes the current photo if bypassed.
    private(set) var qualityBypassCount: Int = 0

    func recordRetake() {
        retakeCount += 1
    }

    func recordQualityBypass() {
        qualityBypassCount += 1
    }

    func reset() {
        retakeCount = 0
        qualityBypassCount = 0
    }

    /// Pure snapshot for threading into the pipeline. Safe to call from any
    /// actor because `UserBehaviorContext` is Sendable.
    func snapshot() -> UserBehaviorContext {
        UserBehaviorContext(
            retakeCount: retakeCount,
            qualityBypassCount: qualityBypassCount
        )
    }
}
