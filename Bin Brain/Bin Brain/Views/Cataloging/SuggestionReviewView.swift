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
///
/// TODO(post-Swift2_010): remove `shouldShowPhoto` — no production callers
/// after decode moved to `SuggestionReviewViewModel.pinnedImage`. A dedicated
/// cleanup task should drop this helper AND its tests at
/// `SuggestionReviewViewModelTests.swift` (`testShouldShowPhoto*`).
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
    ///
    /// The VM owns `binId` — read it via `viewModel.binId` in the Confirm /
    /// Retry closures. The view no longer carries a `let binId: String`
    /// because that ephemeral parent-view input was the root cause of the
    /// empty-binId bug (Swift2_012): on SwiftUI re-renders of the
    /// `navigationDestination` closure, `binId: capturedBinId ?? ""` could
    /// re-read a nilled `@State`. Sourcing from the VM gives a stable value.
    @Bindable var viewModel: SuggestionReviewViewModel

    @Environment(\.toast) private var toast

    /// The API client used for upsert network calls.
    let apiClient: APIClient

    /// Called after all items are confirmed successfully (failedIndices empty).
    let onDone: () -> Void

    /// Called when the user wants to retry with a larger vision model.
    /// `nil` hides the button (e.g. when already on the largest model).
    var onRetryWithLargerModel: (() -> Void)?

    /// The suggestion currently highlighted in the bbox overlay (`nil` = no highlight).
    @State private var selectedSuggestionId: Int?

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
        .onChange(of: viewModel.confirmationErrorMessage) { _, newValue in
            // Surface confirm-path failures via the existing toast channel.
            // Swift2_013: empty binId, network failure, 401/429/4xx/5xx, and
            // partial-failure summaries all flow through here. Clearing after
            // show prevents a stale message from re-firing on re-render.
            guard let message = newValue else { return }
            toast.show(message, duration: 4.0)
            viewModel.confirmationErrorMessage = nil
        }
    }

    // MARK: - Pinned Photo with Bbox Overlay

    @ViewBuilder
    private var pinnedPhoto: some View {
        if let uiImage = viewModel.pinnedImage {
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
                            await viewModel.retryRemaining(binId: viewModel.binId, apiClient: apiClient)
                        }
                    }
                    .disabled(viewModel.isConfirming)
                } else if viewModel.canConfirm {
                    // Swift2_020 — `confirmButtonTitle` shows the ignored count
                    // under three-state so users see what they are skipping.
                    // Still tappable with ignored rows present; the label is
                    // the guardrail (not a hard block) per the plan's rationale
                    // against forcing per-row engagement when the user simply
                    // doesn't care about some items.
                    Button(viewModel.confirmButtonTitle) {
                        Task {
                            await viewModel.confirm(binId: viewModel.binId, apiClient: apiClient)
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
                // Swift2_020 — three-state chip replaces the legacy Toggle when
                // the feature flag is on. The Toggle path stays available so
                // a Settings flip (no code release) reverts to the default-on
                // UX without losing any other row behaviour.
                if viewModel.threeStateEnabled {
                    outcomeChip(for: s)
                    Text(s.editedName)
                        .font(.headline)
                        .foregroundStyle(isPreliminary ? .secondary : .primary)
                    Spacer(minLength: 0)
                } else {
                    Toggle(isOn: suggestion.included) {
                        Text(s.editedName)
                            .font(.headline)
                            .foregroundStyle(isPreliminary ? .secondary : .primary)
                    }
                }

                if !isPreliminary {
                    Text(String(format: "%.0f%%", s.confidence * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if s.bbox != nil {
                    Button {
                        let newId = selectedSuggestionId == s.id ? nil : s.id
                        selectedSuggestionId = newId
                    } label: {
                        Image(systemName: selectedSuggestionId == s.id
                              ? "viewfinder.circle.fill" : "viewfinder.circle")
                            .foregroundStyle(selectedSuggestionId == s.id
                                             ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(selectedSuggestionId == s.id
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
                    viewModel.noteUserEdit(id: s.id)
                }

            TextField("Category", text: suggestion.editedCategory)
                .textFieldStyle(.roundedBorder)
                .onChange(of: s.editedCategory) { _, _ in
                    viewModel.noteUserEdit(id: s.id)
                }

            TextField("Quantity", text: suggestion.editedQuantity)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.decimalPad)
                .onChange(of: s.editedQuantity) { _, _ in
                    viewModel.noteUserEdit(id: s.id)
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

    // MARK: - Swift2_020 Three-State Chip

    /// Tappable chip that cycles the row's `OutcomeState` on each tap.
    ///
    /// Don't-rely-on-color: renders a distinct SF Symbol per state on top of
    /// the color fill so users without color perception still read the state
    /// from the icon shape. A brief `.easeInOut(0.15)` envelope wraps
    /// `cycleOutcome` and `.contentTransition(.symbolEffect(.replace))`
    /// swaps the glyph with the system's SF-Symbol replace effect — no
    /// spring, no bounce, quick enough to read as a state swap rather than
    /// an animation.
    private func outcomeChip(for suggestion: EditableSuggestion) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                viewModel.cycleOutcome(id: suggestion.id)
            }
        } label: {
            Image(systemName: Self.chipIcon(for: suggestion.outcomeState))
                .font(.title2)
                .foregroundStyle(.white)
                .padding(6)
                .background(
                    Circle()
                        .fill(Self.chipColor(for: suggestion.outcomeState))
                )
                .overlay(
                    Circle()
                        .strokeBorder(.primary.opacity(0.15), lineWidth: 0.5)
                )
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.chipAccessibilityLabel(
            name: suggestion.editedName,
            state: suggestion.outcomeState
        ))
        .accessibilityHint(Self.chipAccessibilityHint(current: suggestion.outcomeState))
    }

    private static func chipIcon(for state: OutcomeState) -> String {
        switch state {
        case .ignored: return "circle"
        case .accepted: return "checkmark"
        case .rejected: return "xmark"
        }
    }

    private static func chipColor(for state: OutcomeState) -> Color {
        switch state {
        case .ignored: return .yellow
        case .accepted: return .green
        case .rejected: return .red
        }
    }

    private static func chipAccessibilityLabel(name: String, state: OutcomeState) -> String {
        switch state {
        case .ignored: return "\(name), ignored"
        case .accepted: return "\(name), accepted"
        case .rejected: return "\(name), rejected"
        }
    }

    private static func chipAccessibilityHint(current: OutcomeState) -> String {
        switch current.next() {
        case .ignored: return "Double-tap to ignore"
        case .accepted: return "Double-tap to accept"
        case .rejected: return "Double-tap to reject"
        }
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
