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

    /// The bin identifier to associate confirmed items with.
    let binId: String

    /// The API client used for upsert network calls.
    let apiClient: APIClient

    /// Called after all items are confirmed successfully (failedIndices empty).
    let onDone: () -> Void

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
                ProgressView()
                    .scaleEffect(1.5)
            }
        }
        .navigationTitle("Review Items")
        .onChange(of: viewModel.isConfirming) { _, newValue in
            if !newValue && viewModel.failedIndices.isEmpty && !viewModel.editableSuggestions.isEmpty {
                onDone()
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Text("No items detected. Try retaking the photo.")
                .multilineTextAlignment(.center)
            Button("Done") { onDone() }
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
                } else {
                    Button("Confirm") {
                        Task {
                            await viewModel.confirm(binId: binId, apiClient: apiClient)
                        }
                    }
                    .disabled(viewModel.isConfirming)
                }
            }
            .padding()
        }
    }

    // MARK: - Suggestion Row

    private func suggestionRow(at idx: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(
                    isOn: $viewModel.editableSuggestions[idx].included
                ) {
                    Text(viewModel.editableSuggestions[idx].editedName)
                        .font(.headline)
                }

                Text(String(format: "%.0f%%", viewModel.editableSuggestions[idx].confidence * 100))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Name", text: $viewModel.editableSuggestions[idx].editedName)
                .textFieldStyle(.roundedBorder)

            TextField("Category", text: $viewModel.editableSuggestions[idx].editedCategory)
                .textFieldStyle(.roundedBorder)

            TextField("Quantity", text: $viewModel.editableSuggestions[idx].editedQuantity)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.decimalPad)
        }
        .padding(.vertical, 4)
    }
}
