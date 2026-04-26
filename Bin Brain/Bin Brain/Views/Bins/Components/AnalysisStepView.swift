// AnalysisStepView.swift
// Bin Brain
//
// Reusable analysis-step destination shared by BinDetailView and BinsListView.

import SwiftUI
import SwiftData

// MARK: - AnalysisStepView

/// Wraps `AnalysisProgressView` with the shared cataloging-coordinator logic.
///
/// Both `BinDetailView` and `BinsListView` push this view as the `.analysis`
/// destination in their `NavigationStack`. The only host-specific difference is
/// the binId source: pass `binIdProvider: { binId }` (always non-nil) from
/// `BinDetailView`, or `binIdProvider: { capturedBinId }` (may be nil) from
/// `BinsListView`. The guard inside `onOverride` handles the nil case safely.
struct AnalysisStepView: View {

    let coordinator: CatalogingCoordinator
    /// Returns the bin ID for quality-gate override; nil causes the override to be a no-op.
    let binIdProvider: () -> String?

    @Environment(\.apiClient) private var apiClient
    @Environment(\.sessionManager) private var sessionManager
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        AnalysisProgressView(
            viewModel: coordinator.analysisViewModel,
            onComplete: { suggestions in
                coordinator.reviewViewModel.photoData = coordinator.analysisViewModel.lastUploadedPhotoData
                if coordinator.navigatedOnPreliminary {
                    coordinator.reviewViewModel.applyServerSuggestions(
                        suggestions,
                        photoId: coordinator.analysisViewModel.lastPhotoId,
                        visionModel: coordinator.analysisViewModel.lastVisionModel,
                        promptVersion: coordinator.analysisViewModel.lastPromptVersion
                    )
                } else {
                    coordinator.reviewViewModel.loadSuggestions(
                        suggestions,
                        photoId: coordinator.analysisViewModel.lastPhotoId,
                        visionModel: coordinator.analysisViewModel.lastVisionModel,
                        promptVersion: coordinator.analysisViewModel.lastPromptVersion
                    )
                    coordinator.path.append(.review)
                }
            },
            onRetry: {
                // Finding #4-UX-2: "Retake Photo" must return to the camera so
                // the user can capture a fresh frame.
                coordinator.catalogingSession.recordRetake()
                coordinator.analysisViewModel.reset()
                coordinator.navigatedOnPreliminary = false
                coordinator.capturedPhotoData = nil
                coordinator.path.removeAll()
            },
            onOverride: {
                coordinator.catalogingSession.recordQualityBypass()
                guard let binId = binIdProvider() else { return }
                coordinator.startOverrideQualityGate(
                    binId: binId,
                    apiClient: apiClient,
                    sessionManager: sessionManager,
                    modelContext: modelContext
                )
            },
            onPreliminaryReady: { classifications, ocr in
                coordinator.reviewViewModel.photoData = coordinator.analysisViewModel.lastUploadedPhotoData
                coordinator.reviewViewModel.loadPreliminaryFromOnDevice(
                    classifications: classifications,
                    ocr: ocr,
                    topK: CatalogingCoordinator.preliminaryTopK
                )
                coordinator.navigatedOnPreliminary = true
                coordinator.path.append(.review)
            }
        )
    }
}
