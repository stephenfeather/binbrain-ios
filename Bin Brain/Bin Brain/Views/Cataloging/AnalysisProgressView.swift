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

    /// Called once, when on-device Vision extraction finishes (Stage 3 of
    /// `ImagePipeline` succeeded) — *before* the ~40 s server call completes.
    /// Carries both `VNClassifyImageRequest` classifications AND
    /// `VNRecognizeTextRequest` OCR results so the parent can render
    /// preliminary chips in `SuggestionReviewView` via
    /// `SuggestionReviewViewModel.loadPreliminaryFromOnDevice(...)`.
    ///
    /// `nil` (default) preserves the pre-Mode-A blocking-progress behavior.
    var onPreliminaryReady: (([ClassificationResult], [OCRResult]) -> Void)?

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
                // Swift2_004 S5: show the rejected photo full-width so the user
                // can judge blur/exposure by eye, with the specific gate metrics
                // below so the decision to "Upload Anyway" is informed.
                if let data = viewModel.lastRejectedPhotoData,
                   let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 400)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.bottom, 4)
                        .accessibilityLabel("Rejected photo preview")
                }
                if let metrics = viewModel.lastQualityFailure?.metrics {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(metrics.label): \(formatMetricValue(metrics.measured))")
                            .font(.system(.caption, design: .monospaced))
                        Text("threshold: \(formatMetricValue(metrics.threshold)) (\(metrics.thresholdLabel))")
                            .font(.system(.caption, design: .monospaced))
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                    .padding(.horizontal)
                    .accessibilityLabel(
                        "Quality check: \(metrics.label) measured \(formatMetricValue(metrics.measured)), threshold \(formatMetricValue(metrics.threshold))"
                    )
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
                Button("Continue Anyway") { onOverride() }
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
            onPreliminaryReady(viewModel.preliminaryClassifications, viewModel.preliminaryOCR)
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

// MARK: - Metric Value Formatting

/// Formats a raw gate metric value for the quality-failure readout.
///
/// - Integer-valued doubles ≥ 1 render without a decimal point ("1024", "64", "2").
/// - Values in [0.0001, 1) or non-integer values ≥ 1 render to 4 decimal places.
/// - Values < 0.0001 render to 6 decimal places in fixed-point form (no scientific notation);
///   values that round to zero at that precision display as "0.000000".
///
/// Exposed `internal` (not `private`) so `QualityGatesTests` can cover the
/// formatting logic without spinning up a full view hierarchy.
func formatMetricValue(_ value: Double) -> String {
    if value >= 1, value == value.rounded() {
        return String(format: "%.0f", value)
    } else if value >= 0.0001 {
        return String(format: "%.4f", value)
    } else {
        return String(format: "%.6f", value)
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
