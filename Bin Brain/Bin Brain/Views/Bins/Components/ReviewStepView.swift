// ReviewStepView.swift
// Bin Brain
//
// Reusable review-step destination shared by BinDetailView and BinsListView.

import SwiftUI
import SwiftData

// MARK: - ReviewStepView

/// Wraps `SuggestionReviewView` with the shared cataloging-coordinator logic.
///
/// Both `BinDetailView` and `BinsListView` push this view as the `.review`
/// destination in their `NavigationStack`. Host-specific cancel behavior
/// (dismissing `showCamera` vs `showCataloging`) is handled by the parent's
/// `.alert` — the parent keeps the "Analysis Failed" alert so its Cancel
/// button can perform host-specific cleanup without triggering a reload.
///
/// `onDone` encapsulates the full completion path (path reset + flag clear +
/// reload) for each host.
struct ReviewStepView: View {

    let coordinator: CatalogingCoordinator
    let onDone: () -> Void

    @Environment(\.apiClient) private var apiClient
    @Environment(\.modelContext) private var modelContext
    @Environment(\.outcomeQueueManager) private var outcomeQueueManager

    var body: some View {
        SuggestionReviewView(
            viewModel: coordinator.reviewViewModel,
            apiClient: apiClient,
            onDone: onDone,
            onRetryWithLargerModel: coordinator.nextModelAvailable ? {
                coordinator.escalateModelAndReSuggest(apiClient: apiClient)
            } : nil
        )
        // Swift2_018 — inject the durable outcomes queue + context so
        // confirm() persists each outcomes POST instead of firing it as a
        // one-shot detached Task. Both must be set before confirm() runs.
        .onAppear {
            coordinator.reviewViewModel.outcomeQueueManager = outcomeQueueManager
            coordinator.reviewViewModel.outcomeQueueContext = modelContext
        }
        // Observe phase on the active visible view so server suggestions
        // always land (AnalysisProgressView.onChange is unreliable when
        // that view is in the NavigationStack background).
        .onChange(of: coordinator.analysisViewModel.phase) { _, newPhase in
            guard coordinator.navigatedOnPreliminary else { return }
            switch newPhase {
            case .complete:
                coordinator.reviewViewModel.photoData = coordinator.analysisViewModel.lastUploadedPhotoData
                coordinator.reviewViewModel.applyServerSuggestions(
                    coordinator.analysisViewModel.suggestions,
                    photoId: coordinator.analysisViewModel.lastPhotoId,
                    visionModel: coordinator.analysisViewModel.lastVisionModel,
                    promptVersion: coordinator.analysisViewModel.lastPromptVersion
                )
            case .failed(let message):
                // Route to parent's alert; the parent owns the binId source
                // needed for the Retry path and the host flag for Cancel.
                coordinator.ingestErrorMessage = message
            default:
                break
            }
        }
    }
}
