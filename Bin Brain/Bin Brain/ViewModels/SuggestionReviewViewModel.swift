// SuggestionReviewViewModel.swift
// Bin Brain
//
// Manages the review + confirmation step of the cataloging workflow.
// SuggestionReviewView drives this ViewModel by calling loadSuggestions()
// and then confirm() or retryRemaining().

import Foundation
import Observation
import OSLog

// MARK: - EditableSuggestion

/// A mutable wrapper around a `SuggestionItem` for the review UI.
///
/// Each suggestion starts with `included = true` and fields pre-filled
/// from the matched catalogue item when available, falling back to the
/// raw vision label. The user can toggle inclusion, edit the name,
/// category, and quantity before confirming.
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
    /// The raw vision label before any match substitution (read-only).
    let visionName: String
    /// The catalogue match details, if a similar item was found (read-only).
    let match: SuggestionMatch?
    /// Whether the pre-filled name/category came from a catalogue match.
    var isMatched: Bool { match != nil }
    /// Whether the user wants to teach this item name as a YOLO-World class.
    var teach: Bool
}

// MARK: - SuggestionReviewViewModel

/// Manages the review + confirmation step of the cataloging workflow.
///
/// Call `loadSuggestions(_:)` to populate from `AnalysisViewModel.suggestions`.
/// Then call `confirm(binId:apiClient:)` to upsert all included items.
private let logger = Logger(subsystem: "com.binbrain.app", category: "SuggestionReview")

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
    /// When a suggestion has a catalogue `match`, the matched item's name and
    /// category are used as defaults (since the catalogue entry is more accurate
    /// than the raw vision label). The original vision name is preserved in
    /// `visionName` for reference.
    ///
    /// Each item starts with `included = true`. Calling this method clears
    /// any previous `failedIndices`.
    ///
    /// - Parameter suggestions: The suggestion items returned by vision inference.
    func loadSuggestions(_ suggestions: [SuggestionItem]) {
        editableSuggestions = suggestions.enumerated().map { idx, item in
            let name = item.match?.name ?? item.name
            let category = item.match?.category ?? item.category ?? ""
            return EditableSuggestion(
                id: idx,
                included: true,
                editedName: name,
                editedCategory: category,
                editedQuantity: "",
                confidence: item.confidence,
                visionName: item.name,
                match: item.match,
                teach: true
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
        logger.debug("confirm: \(self.editableSuggestions.count) total, \(includedIndices.count) included")
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

        // Confirm taught items as YOLO-World classes (fire-and-forget).
        for idx in includedIndices where editableSuggestions[idx].teach {
            let s = editableSuggestions[idx]
            let category = s.editedCategory.isEmpty ? nil : s.editedCategory
            do {
                _ = try await apiClient.confirmClass(className: s.editedName, category: category)
            } catch {
                logger.error("confirmClass failed for '\(s.editedName)': \(error.localizedDescription)")
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
