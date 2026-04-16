// SuggestionReviewView.swift
// Bin Brain
//
// Review screen where the user edits and confirms AI-suggested items.
// Navigation on completion is handled by the parent via onDone.

import SwiftUI

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

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
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
            List {
                ForEach(viewModel.editableSuggestions.indices, id: \.self) { idx in
                    suggestionRow(at: idx)
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

    private func suggestionRow(at idx: Int) -> some View {
        let suggestion = viewModel.editableSuggestions[idx]
        let isPreliminary = suggestion.origin == .preliminary
        return VStack(alignment: .leading, spacing: 8) {
            if isPreliminary {
                Text("Preliminary — confirming with AI")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Preliminary suggestion, confirming with AI")
            }
            HStack {
                Toggle(
                    isOn: $viewModel.editableSuggestions[idx].included
                ) {
                    Text(suggestion.editedName)
                        .font(.headline)
                        .foregroundStyle(isPreliminary ? .secondary : .primary)
                }

                if !isPreliminary {
                    Text(String(format: "%.0f%%", suggestion.confidence * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if suggestion.isMatched {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text("Matched to catalogue")
                        .font(.caption)
                    if suggestion.visionName != suggestion.editedName {
                        Text("(vision: \(suggestion.visionName))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if let score = suggestion.match?.score {
                        Spacer()
                        Text(String(format: "%.0f%% similar", score * 100))
                            .font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
            }

            TextField("Name", text: $viewModel.editableSuggestions[idx].editedName)
                .textFieldStyle(.roundedBorder)
                .onChange(of: viewModel.editableSuggestions[idx].editedName) { _, _ in
                    viewModel.markEditedIfPreliminary(index: idx)
                }

            TextField("Category", text: $viewModel.editableSuggestions[idx].editedCategory)
                .textFieldStyle(.roundedBorder)
                .onChange(of: viewModel.editableSuggestions[idx].editedCategory) { _, _ in
                    viewModel.markEditedIfPreliminary(index: idx)
                }

            TextField("Quantity", text: $viewModel.editableSuggestions[idx].editedQuantity)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.decimalPad)
                .onChange(of: viewModel.editableSuggestions[idx].editedQuantity) { _, _ in
                    viewModel.markEditedIfPreliminary(index: idx)
                }

            Toggle(isOn: $viewModel.editableSuggestions[idx].teach) {
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
}
