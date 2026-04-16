// AnalysisProgressView.swift
// Bin Brain
//
// Blocking progress screen shown during photo upload and AI analysis.
// Navigation on completion is handled by the parent — this view calls onComplete.

import SwiftUI
import UIKit

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

    /// Called once, when on-device `VNClassifyImageRequest` classifications
    /// become available (Stage 3 of `ImagePipeline` succeeded) — *before* the
    /// ~40 s server call completes. The parent uses this to render preliminary
    /// chips in `SuggestionReviewView` and navigate early, delivering the
    /// Mode A perceived-latency win.
    ///
    /// `nil` (default) preserves the pre-Mode-A blocking-progress behavior.
    var onPreliminaryReady: (([ClassificationResult]) -> Void)?

    // MARK: - Private state

    @State private var didFirePreliminary = false

    /// Timestamp when phase became `.analysing`. Drives the elapsed-time
    /// label during the long `/suggest` wait (Finding #18).
    @State private var analysingStartedAt: Date?

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
                // Finding #4-UX: show the rejected photo so the user can judge
                // whether to retry or force-accept. Bytes are the raw capture,
                // not the optimized upload — what the camera actually saw.
                if let data = viewModel.lastRejectedPhotoData,
                   let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 240, maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.orange.opacity(0.6), lineWidth: 2)
                        )
                        .padding(.bottom, 4)
                        .accessibilityLabel("Rejected photo preview")
                }
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
                // Finding #18 — /suggest can take 149 s+ on a cold model load.
                // Show a sustained indicator with an elapsed timer so the user
                // can tell the app is working, not frozen.
                ProgressView()
                    .scaleEffect(3)
                    .padding(.bottom, 16)
                Text("Classifying item…")
                    .foregroundStyle(.secondary)
                AnalysisElapsedLabel(startedAt: analysingStartedAt ?? Date())
                    .font(.caption)
                    .foregroundStyle(.tertiary)

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
        .onChange(of: viewModel.preliminaryClassifications.isEmpty) { _, isEmpty in
            guard !isEmpty,
                  !didFirePreliminary,
                  let onPreliminaryReady else { return }
            didFirePreliminary = true
            onPreliminaryReady(viewModel.preliminaryClassifications)
        }
        .onChange(of: viewModel.phase) { _, newPhase in
            if case .idle = newPhase { didFirePreliminary = false }
        }
        .onChange(of: viewModel.phase) { _, newPhase in
            // Finding #18 — start/stop the elapsed-time label around the
            // /suggest wait.
            switch newPhase {
            case .analysing: analysingStartedAt = Date()
            case .complete, .failed, .qualityFailed, .idle:
                analysingStartedAt = nil
            default: break
            }
        }
    }
}

// MARK: - AnalysisElapsedLabel

/// Renders a live-updating elapsed-time string driven by `TimelineView`.
/// Separated so the rest of `AnalysisProgressView` doesn't rebuild every
/// second (Finding #18).
private struct AnalysisElapsedLabel: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = Int(max(0, context.date.timeIntervalSince(startedAt)))
            Text("\(elapsed)s elapsed — cold model loads can take up to 3 minutes")
        }
    }
}
