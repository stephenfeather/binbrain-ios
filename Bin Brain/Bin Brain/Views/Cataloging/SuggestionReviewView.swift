// SuggestionReviewView.swift
// Bin Brain
//
// Review screen where the user edits and confirms AI-suggested items.
// Navigation on completion is handled by the parent via onDone.

import SwiftUI
import UIKit

// MARK: - Helpers

/// Returns `true` when `data` is non-nil and decodable as a `UIImage`.
///
/// Pure function — no side effects. Exposed at file scope so tests can drive
/// it without constructing a view (matching the `formatMetricValue` pattern).
func shouldShowPhoto(_ data: Data?) -> Bool {
    guard let data else { return false }
    return UIImage(data: data) != nil
}

// MARK: - SuggestionReviewView

/// Review screen where the user edits and confirms AI-suggested items.
///
/// Presents each suggestion as an editable row with toggle, name, category,
/// quantity fields, and a confidence indicator. The user can include or exclude
/// items before confirming. On partial failure, a retry button is shown.
struct SuggestionReviewView: View {

    // MARK: - Properties

    /// The view model managing suggestion state and confirmation logic.
    @Bindable var viewModel: SuggestionReviewViewModel

    @Environment(\.toast) private var toast

    /// The bin identifier to associate confirmed items with.
    let binId: String

    /// The API client used for upsert network calls.
    let apiClient: APIClient

    /// Called after all items are confirmed successfully (failedIndices empty).
    let onDone: () -> Void

    /// Called when the user wants to retry with a larger vision model.
    /// `nil` hides the button (e.g. when already on the largest model).
    var onRetryWithLargerModel: (() -> Void)?

    /// The suggestion currently highlighted in the bbox overlay (`nil` = no highlight).
    @State private var selectedSuggestionId: Int?

    /// Decoded image cached to avoid re-running `UIImage(data:)` on every body evaluation.
    @State private var cachedPhoto: UIImage?

    // MARK: - Body

    var body: some View {
        ZStack {
            if viewModel.editableSuggestions.isEmpty {
                emptyState
            } else {
                suggestionList
            }

            if viewModel.isConfirming {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                ProgressView()
                    .scaleEffect(1.5)
                    .accessibilityLabel("Saving items")
            }
        }
        .navigationTitle("Review Items")
        .onAppear {
            cachedPhoto = viewModel.photoData.flatMap { UIImage(data: $0) }
        }
        .onChange(of: viewModel.photoData) { _, data in
            cachedPhoto = data.flatMap { UIImage(data: $0) }
        }
        .onChange(of: viewModel.editableSuggestions.map(\.id)) { _, _ in
            selectedSuggestionId = nil
        }
        .onChange(of: viewModel.isConfirming) { _, newValue in
            guard !newValue else { return }
            if viewModel.teachFailureCount > 0 {
                toast.show("\(viewModel.teachFailureCount) class teach request(s) failed")
            }
            if viewModel.failedIndices.isEmpty && !viewModel.editableSuggestions.isEmpty {
                onDone()
            }
        }
    }

    // MARK: - Pinned Photo with Bbox Overlay

    @ViewBuilder
    private var pinnedPhoto: some View {
        if let uiImage = cachedPhoto {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 240)
                .overlay {
                    GeometryReader { geo in
                        Canvas { ctx, size in
                            for suggestion in viewModel.editableSuggestions {
                                guard let bbox = suggestion.bbox,
                                      let rect = bboxRect(bbox, imageSize: uiImage.size, frameSize: size)
                                else { continue }
                                let isSelected = selectedSuggestionId == suggestion.id
                                ctx.stroke(
                                    Path(rect),
                                    with: .color(isSelected ? .yellow : Color(white: 1, opacity: 0.55)),
                                    lineWidth: isSelected ? 3 : 1.5
                                )
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .accessibilityHidden(true)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.top, 8)
                .accessibilityLabel("Photo being classified")
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            pinnedPhoto
            Image(systemName: "eye.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No items detected.")
                .font(.headline)
            Text("Try retaking the photo, or use a larger model for better accuracy.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            if let onRetryWithLargerModel {
                Button {
                    onRetryWithLargerModel()
                } label: {
                    Label("Try a larger model", systemImage: "arrow.trianglehead.2.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Done") { onDone() }
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Suggestion List

    private var suggestionList: some View {
        VStack {
            pinnedPhoto
            List {
                ForEach($viewModel.editableSuggestions) { $suggestion in
                    suggestionRow(for: $suggestion)
                }
            }

            // Footer buttons
            VStack(spacing: 12) {
                if !viewModel.failedIndices.isEmpty {
                    Text("Some items failed to save. Tap to retry.")
                        .foregroundStyle(.red)
                        .font(.callout)

                    Button("Retry remaining (\(viewModel.failedIndices.count))") {
                        Task {
                            await viewModel.retryRemaining(binId: binId, apiClient: apiClient)
                        }
                    }
                    .disabled(viewModel.isConfirming)
                } else if viewModel.canConfirm {
                    Button("Confirm") {
                        Task {
                            await viewModel.confirm(binId: binId, apiClient: apiClient)
                        }
                    }
                    // Finding #16 — block confirm when nothing is included so the
                    // view never reaches the single-tick true→false isConfirming
                    // flip that strands the sheet.
                    .disabled(viewModel.isConfirming)
                } else {
                    // Finding #21 — when everything is excluded (or the classifier
                    // returned only garbage, e.g. pencil-on-carpet top-K), the
                    // user needs a forward action that doesn't try to call /items.
                    // Dismiss fires onDone() with the current (empty) suggestion
                    // set so the parent returns to bin detail.
                    Button("Dismiss") {
                        onDone()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Dismiss without saving any items")
                }
            }
            .padding()
        }
    }

    // MARK: - Suggestion Row

    private func suggestionRow(for suggestion: Binding<EditableSuggestion>) -> some View {
        let s = suggestion.wrappedValue
        let isPreliminary = s.origin == .preliminary
        return VStack(alignment: .leading, spacing: 8) {
            if isPreliminary {
                Text("Preliminary — confirming with AI")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Preliminary suggestion, confirming with AI")
            }
            HStack {
                Toggle(isOn: suggestion.included) {
                    Text(s.editedName)
                        .font(.headline)
                        .foregroundStyle(isPreliminary ? .secondary : .primary)
                }

                if !isPreliminary {
                    Text(String(format: "%.0f%%", suggestion.confidence * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if suggestion.bbox != nil {
                    Button {
                        let newId = selectedSuggestionId == suggestion.id ? nil : suggestion.id
                        selectedSuggestionId = newId
                    } label: {
                        Image(systemName: selectedSuggestionId == suggestion.id
                              ? "viewfinder.circle.fill" : "viewfinder.circle")
                            .foregroundStyle(selectedSuggestionId == suggestion.id
                                             ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(selectedSuggestionId == suggestion.id
                                        ? "Deselect bounding box" : "Highlight bounding box")
                }
            }

            if s.isMatched {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text("Matched to catalogue")
                        .font(.caption)
                    if s.visionName != s.editedName {
                        Text("(vision: \(s.visionName))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if let score = s.match?.score {
                        Spacer()
                        Text(String(format: "%.0f%% similar", score * 100))
                            .font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
            }

            TextField("Name", text: suggestion.editedName)
                .textFieldStyle(.roundedBorder)
                .onChange(of: s.editedName) { _, _ in
                    viewModel.markEditedIfPreliminary(id: s.id)
                }

            TextField("Category", text: suggestion.editedCategory)
                .textFieldStyle(.roundedBorder)
                .onChange(of: s.editedCategory) { _, _ in
                    viewModel.markEditedIfPreliminary(id: s.id)
                }

            TextField("Quantity", text: suggestion.editedQuantity)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.decimalPad)
                .onChange(of: s.editedQuantity) { _, _ in
                    viewModel.markEditedIfPreliminary(id: s.id)
                }

            Toggle(isOn: suggestion.teach) {
                Label("Teach for future detection", systemImage: "brain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .tint(.green)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, isPreliminary ? 8 : 0)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.secondary)
                .opacity(isPreliminary ? 1 : 0)
        )
        .accessibilityElement(children: .contain)
        .accessibilityHint(isPreliminary ? "Preliminary — will be confirmed by the server" : "")
    }

    // MARK: - Bbox Geometry

    /// Maps normalized `[x1, y1, x2, y2]` bbox coords to display-space `CGRect`.
    ///
    /// The image renders with `.aspectRatio(contentMode: .fit)` centered inside
    /// `frameSize`, so letterbox offsets are applied before scaling.
    private func bboxRect(_ bbox: [Float], imageSize: CGSize, frameSize: CGSize) -> CGRect? {
        guard bbox.count == 4, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let scale = min(frameSize.width / imageSize.width, frameSize.height / imageSize.height)
        let renderedW = imageSize.width * scale
        let renderedH = imageSize.height * scale
        let ox = (frameSize.width - renderedW) / 2
        let oy = (frameSize.height - renderedH) / 2
        // Clamp to [0,1] to guard against VLM output that slightly exceeds the image boundary.
        let c0 = CGFloat(min(max(bbox[0], 0), 1))
        let c1 = CGFloat(min(max(bbox[1], 0), 1))
        let c2 = CGFloat(min(max(bbox[2], 0), 1))
        let c3 = CGFloat(min(max(bbox[3], 0), 1))
        let x1 = ox + c0 * renderedW
        let y1 = oy + c1 * renderedH
        let x2 = ox + c2 * renderedW
        let y2 = oy + c3 * renderedH
        guard x2 > x1, y2 > y1 else { return nil }
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }
}
