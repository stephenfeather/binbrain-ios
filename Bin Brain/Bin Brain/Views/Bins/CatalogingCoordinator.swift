// CatalogingCoordinator.swift
// Bin Brain
//
// Shared cataloging state and actions used by BinDetailView and BinsListView.
// Centralises the ~210 LOC of duplicated plumbing so neither view owns it.

import OSLog
import SwiftUI
import SwiftData

private let logger = Logger(subsystem: "com.binbrain.app", category: "CatalogingCoordinator")

// MARK: - CatalogingStep

/// Steps in the cataloging navigation stack: scan/photo → analysis → review.
enum CatalogingStep: Hashable {
    case analysis
    case review
}

// MARK: - CaptureProxy

/// Reference-type container for the scanner's capture action.
///
/// Stored inside the coordinator (which is `@State`) so the same instance
/// persists across renders. The shutter button closure captures the proxy by
/// reference, so it always reads the current `action` at tap time — avoiding
/// the stale-closure issue that arises with `@State var (() -> Void)?`.
final class CaptureProxy {
    var action: (() -> Void)?
}

// MARK: - CatalogingCoordinator

/// Owns the shared state and lifecycle for the cataloging flow used by both
/// `BinDetailView` and `BinsListView`. Both views hold one as `@State` and
/// delegate cataloging actions to it.
///
/// View-specific extras (e.g. `BinsListView`'s `scannerViewModel`,
/// `showShutterButton`, `capturedBinId`) remain in the view; the coordinator
/// handles everything the two flows share.
@Observable
@MainActor
final class CatalogingCoordinator {

    // MARK: - Navigation

    var path: [CatalogingStep] = []

    // MARK: - Child view models

    var analysisViewModel = AnalysisViewModel()
    var reviewViewModel = SuggestionReviewViewModel()
    var catalogingSession = CatalogingSession()

    // MARK: - Capture

    let captureProxy = CaptureProxy()
    var capturedPhotoData: Data?
    var capturedCameraContext: CameraCaptureContext?

    // MARK: - Live barcode overlay

    var liveBarcodePayload: String?
    var liveBarcodeSymbology: String?

    // MARK: - Error / retry

    /// Non-nil when /ingest (or /suggest) failed after the user navigated to
    /// the preliminary review screen. Drives the retry alert in `reviewView`.
    var ingestErrorMessage: String?

    // MARK: - Mode A early-navigate state

    /// `true` once preliminary on-device chips have been loaded and navigation
    /// to `.review` happened early (Mode A). Shapes how `onComplete` merges.
    var navigatedOnPreliminary = false

    // MARK: - Model escalation

    static let modelEscalation = ["qwen3-vl:2b", "qwen3-vl:4b", "qwen3-vl:8b"]
    /// Top-K chips to surface as preliminary (Mode A, Phase 1).
    static let preliminaryTopK = 10
    var currentModelIndex = 0

    // MARK: - Computed

    var liveBarcode: BarcodeResult? {
        liveBarcodePayload.map { payload in
            BarcodeResult(
                payload: payload,
                symbology: liveBarcodeSymbology ?? "unknown",
                boundingBox: nil
            )
        }
    }

    var nextModelAvailable: Bool {
        currentModelIndex + 1 < Self.modelEscalation.count
    }

    // MARK: - Actions

    /// Escalates to the next larger vision model and re-runs suggestion.
    func escalateModelAndReSuggest(apiClient: APIClient) {
        guard nextModelAvailable else { return }
        currentModelIndex += 1
        let nextModel = Self.modelEscalation[currentModelIndex]
        path = [.analysis]
        navigatedOnPreliminary = false
        let currentBinId = reviewViewModel.binId
        reviewViewModel = SuggestionReviewViewModel()
        reviewViewModel.binId = currentBinId
        Task {
            do { _ = try await apiClient.selectModel(nextModel) }
            catch {
                logger.error("selectModel(\(nextModel, privacy: .public)) failed: \(error.localizedDescription, privacy: .public); falling through to reSuggest with current model")
            }
            await analysisViewModel.reSuggest(apiClient: apiClient)
        }
    }

    /// Resets all coordinator-owned cataloging state.
    ///
    /// Views may need to reset additional view-specific state around this call
    /// (e.g. `BinsListView`'s `scannerViewModel`, `showShutterButton`,
    /// `capturedBinId`, and `reviewViewModel.binId`).
    func resetCataloging() {
        path = []
        analysisViewModel.reset()
        catalogingSession.reset()
        reviewViewModel = SuggestionReviewViewModel()
        captureProxy.action = nil
        capturedPhotoData = nil
        capturedCameraContext = nil
        ingestErrorMessage = nil
        liveBarcodePayload = nil
        liveBarcodeSymbology = nil
        currentModelIndex = 0
        navigatedOnPreliminary = false
    }

    /// Launches the initial analysis for a freshly captured photo.
    ///
    /// The caller must have already set `capturedPhotoData` and advanced
    /// `path` to `.analysis` before invoking this method.
    func startAnalysis(
        binId: String,
        apiClient: APIClient,
        sessionManager: SessionManager,
        modelContext: ModelContext,
        cameraContext: CameraCaptureContext?
    ) {
        guard let data = capturedPhotoData else { return }
        let prescannedBarcode = liveBarcode
        Task {
            let sessionId = await resolveSessionId(apiClient: apiClient, sessionManager: sessionManager)
            await analysisViewModel.run(
                jpegData: data,
                binId: binId,
                apiClient: apiClient,
                sessionId: sessionId,
                sessionManager: sessionManager,
                context: modelContext,
                cameraContext: cameraContext,
                userBehavior: catalogingSession.snapshot(),
                prescannedBarcode: prescannedBarcode
            )
        }
    }

    /// Overrides the quality gate and re-runs analysis on the retained photo.
    ///
    /// Sets `navigatedOnPreliminary = false` before launching the task.
    func startOverrideQualityGate(
        binId: String,
        apiClient: APIClient,
        sessionManager: SessionManager,
        modelContext: ModelContext
    ) {
        guard let data = capturedPhotoData else { return }
        navigatedOnPreliminary = false
        let prescannedBarcode = liveBarcode
        Task {
            let sessionId = await resolveSessionId(apiClient: apiClient, sessionManager: sessionManager)
            await analysisViewModel.overrideQualityGate(
                jpegData: data,
                binId: binId,
                apiClient: apiClient,
                sessionId: sessionId,
                sessionManager: sessionManager,
                context: modelContext,
                userBehavior: catalogingSession.snapshot(),
                prescannedBarcode: prescannedBarcode
            )
        }
    }

    /// Re-runs analysis on the retained `capturedPhotoData` after an ingest failure.
    func retryIngest(
        binId: String,
        apiClient: APIClient,
        sessionManager: SessionManager,
        modelContext: ModelContext
    ) {
        guard let data = capturedPhotoData else { return }
        ingestErrorMessage = nil
        Task {
            let sessionId = await resolveSessionId(apiClient: apiClient, sessionManager: sessionManager)
            await analysisViewModel.run(
                jpegData: data,
                binId: binId,
                apiClient: apiClient,
                sessionId: sessionId,
                sessionManager: sessionManager,
                context: modelContext,
                cameraContext: capturedCameraContext,
                userBehavior: catalogingSession.snapshot(),
                prescannedBarcode: liveBarcode
            )
        }
    }

    // MARK: - Private

    private func resolveSessionId(apiClient: APIClient, sessionManager: SessionManager) async -> UUID? {
        do {
            return try await sessionManager.activeSessionId(apiClient: apiClient)
        } catch {
            logger.error("activeSessionId failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
