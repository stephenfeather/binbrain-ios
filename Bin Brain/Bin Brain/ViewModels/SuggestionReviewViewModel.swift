// SuggestionReviewViewModel.swift
// Bin Brain
//
// Manages the review + confirmation step of the cataloging workflow.
// SuggestionReviewView drives this ViewModel by calling loadSuggestions()
// and then confirm() or retryRemaining().

import Foundation
import Observation

// MARK: - EditableSuggestion

/// A mutable wrapper around a `SuggestionItem` for the review UI.
///
/// Each suggestion starts with `included = true` and fields pre-filled
/// from the original `SuggestionItem`. The user can toggle inclusion,
/// edit the name, category, and quantity before confirming.
struct EditableSuggestion: Identifiable {
    /// The index in the original suggestions array, used as a stable identifier.
    let id: Int
    /// Whether the user wants to save this item during confirmation.
    var included: Bool
    /// The item name, editable by the user.
    var editedName: String
    /// The item category, editable by the user. Empty string represents nil.
    var editedCategory: String
    /// The item quantity as a string. Empty string represents nil quantity.
    var editedQuantity: String
    /// The confidence score from the original suggestion (read-only).
    let confidence: Double
}

// MARK: - SuggestionReviewViewModel

/// Manages the review + confirmation step of the cataloging workflow.
///
/// Call `loadSuggestions(_:)` to populate from `AnalysisViewModel.suggestions`.
/// Then call `confirm(binId:apiClient:)` to upsert all included items.
@Observable
final class SuggestionReviewViewModel {

    // MARK: - State

    /// The list of editable suggestions presented to the user.
    ///
    /// Not `private(set)` because the view binds directly to individual fields
    /// (name, category, quantity, included) via `@Bindable`.
    var editableSuggestions: [EditableSuggestion] = []

    /// Whether a confirm or retry operation is currently in progress.
    private(set) var isConfirming: Bool = false

    /// Indices (into `editableSuggestions`) of included items that failed or were not yet attempted.
    private(set) var failedIndices: [Int] = []

    // MARK: - Setup

    /// Populates `editableSuggestions` from a raw `SuggestionItem` array.
    ///
    /// Each item starts with `included = true` and fields pre-filled from the suggestion.
    /// Calling this method clears any previous `failedIndices`.
    ///
    /// - Parameter suggestions: The suggestion items returned by vision inference.
    func loadSuggestions(_ suggestions: [SuggestionItem]) {
        editableSuggestions = suggestions.enumerated().map { idx, item in
            EditableSuggestion(
                id: idx,
                included: true,
                editedName: item.name,
                editedCategory: item.category ?? "",
                editedQuantity: "",
                confidence: item.confidence
            )
        }
        failedIndices = []
    }

    // MARK: - Actions

    /// Upserts all included suggestions sequentially.
    ///
    /// Stops on the first failure and sets `failedIndices` to the failed index
    /// plus all remaining included indices that were not yet attempted.
    ///
    /// - Parameters:
    ///   - binId: The bin identifier to associate items with.
    ///   - apiClient: The `APIClient` instance for network calls.
    func confirm(binId: String, apiClient: APIClient) async {
        isConfirming = true
        failedIndices = []
        let includedIndices = editableSuggestions.indices.filter { editableSuggestions[$0].included }
        print("[Review] confirm: \(editableSuggestions.count) total, \(includedIndices.count) included")
        for idx in includedIndices {
            let s = editableSuggestions[idx]
            let quantity = Double(s.editedQuantity)
            let category = s.editedCategory.isEmpty ? nil : s.editedCategory
            let confidence = editableSuggestions[idx].confidence
            do {
                _ = try await apiClient.upsertItem(
                    name: s.editedName,
                    category: category,
                    quantity: quantity,
                    confidence: confidence,
                    binId: binId
                )
            } catch {
                failedIndices = includedIndices.filter { $0 >= idx }
                isConfirming = false
                return
            }
        }
        isConfirming = false
    }

    /// Resumes upsert from the first previously failed index.
    ///
    /// Stops on the first failure and updates `failedIndices` with the
    /// failed index plus all remaining indices.
    ///
    /// - Parameters:
    ///   - binId: The bin identifier to associate items with.
    ///   - apiClient: The `APIClient` instance for network calls.
    func retryRemaining(binId: String, apiClient: APIClient) async {
        isConfirming = true
        let toRetry = failedIndices
        failedIndices = []
        for idx in toRetry {
            let s = editableSuggestions[idx]
            let quantity = Double(s.editedQuantity)
            let category = s.editedCategory.isEmpty ? nil : s.editedCategory
            let confidence = editableSuggestions[idx].confidence
            do {
                _ = try await apiClient.upsertItem(
                    name: s.editedName,
                    category: category,
                    quantity: quantity,
                    confidence: confidence,
                    binId: binId
                )
            } catch {
                failedIndices = toRetry.filter { $0 >= idx }
                isConfirming = false
                return
            }
        }
        isConfirming = false
    }
}
