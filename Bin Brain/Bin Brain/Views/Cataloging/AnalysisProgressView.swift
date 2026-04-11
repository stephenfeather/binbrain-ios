// AnalysisProgressView.swift
// Bin Brain
//
// Blocking progress screen shown during photo upload and AI analysis.
// Navigation on completion is handled by the parent — this view calls onComplete.

import SwiftUI

// MARK: - AnalysisProgressView

/// Blocking progress screen shown during upload + AI analysis.
///
/// Phase changes are observed automatically via `@Bindable`. When analysis
/// completes, `onComplete` is called with the resulting suggestions — navigation
/// is handled by the parent view. On failure, shows the error message and a
/// retry button that calls `onRetry`.
struct AnalysisProgressView: View {

    // MARK: - Properties

    @Bindable var viewModel: AnalysisViewModel

    /// Called with the final suggestion list when `phase` transitions to `.complete`.
    let onComplete: ([SuggestionItem]) -> Void

    /// Called when the user taps "Retry" after a `.failed` or `.qualityFailed` phase.
    let onRetry: () -> Void

    /// Called when the user taps "Upload Anyway" after a `.qualityFailed` phase.
    let onOverride: () -> Void

    // MARK: - Body

    var body: some View {
        VStack(spacing: 16) {
            switch viewModel.phase {
            case .idle, .processingImage:
                ProgressView()
                    .scaleEffect(3)
                    .padding(.bottom, 16)
                Text(viewModel.phase == .processingImage ? "Processing image..." : "Preparing...")

            case .qualityFailed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                    .padding(.bottom, 8)
                Text(message)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Retake Photo") { onRetry() }
                    .buttonStyle(.borderedProminent)
                Button("Upload Anyway") { onOverride() }
                    .foregroundStyle(.secondary)

            case .uploading:
                ProgressView()
                    .scaleEffect(3)
                    .padding(.bottom, 16)
                Text("Uploading photo...")

            case .analysing:
                ProgressView()
                    .scaleEffect(3)
                    .padding(.bottom, 16)
                Text("Analysing with AI...")

            case .complete:
                EmptyView()

            case .failed(let message):
                Text(message)
                    .multilineTextAlignment(.center)
                Button("Retry") { onRetry() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: viewModel.phase) { _, newPhase in
            if case .complete = newPhase {
                onComplete(viewModel.suggestions)
            }
        }
    }
}
