// SuggestionReviewViewModel.swift
// Bin Brain
//
// Manages the review + confirmation step of the cataloging workflow.
// SuggestionReviewView drives this ViewModel by calling loadSuggestions()
// and then confirm() or retryRemaining().

import Foundation
import Observation
import OSLog
import UIKit

// MARK: - ChipOrigin

/// Provenance of a `SuggestionReviewViewModel` chip.
///
/// Drives visual "preliminary" styling in `SuggestionReviewView` and the
/// merge rules in `SuggestionReviewViewModel.merge(preliminary:server:)`.
/// See `thoughts/shared/designs/coreml-mode-a-merge-ux.md` §2a.
enum ChipOrigin: Equatable {
    /// On-device `VNClassifyImageRequest` top-K result shown pre-server-response.
    case preliminary
    /// Produced by the server's `/ingest` suggestion response.
    case server
    /// Modified by the user; survives any merge pass.
    case edited
}

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
    /// Normalized `[x1, y1, x2, y2]` bounding box (0–1, top-left origin) from the VLM.
    /// `nil` when the model did not return a bounding box for this item.
    let bbox: [Float]?
    /// Whether the pre-filled name/category came from a catalogue match.
    var isMatched: Bool { match != nil }
    /// Whether the user wants to teach this item name as a YOLO-World class.
    var teach: Bool
    /// Chip provenance — drives preliminary styling and merge rules.
    var origin: ChipOrigin = .server
}

// MARK: - SuggestionReviewViewModel

private let logger = Logger(subsystem: "com.binbrain.app", category: "SuggestionReview")
#if DEBUG
/// Debug-only logger for on-device top-K vs. user-confirmed labels (Phase 1.2,
/// §9 of the design doc). On-device-only by T2; never uploaded.
private let preliminaryDebugLogger = Logger(subsystem: "com.binbrain.app", category: "PreliminaryDebug")
#endif

/// Manages the review + confirmation step of the cataloging workflow.
///
/// Call `loadSuggestions(_:)` to populate from `AnalysisViewModel.suggestions`.
/// Then call `confirm(binId:apiClient:)` to upsert all included items.
///
/// `@MainActor`-isolated so that stored state (`pinnedImage`, `decodeGeneration`,
/// `decodeTask`) is race-free without per-property locking. Heavy UIImage decode
/// work still runs off-main by hopping to `Task.detached(priority: .userInitiated)`
/// from the `photoData` `didSet`; results are published back through the main
/// actor via `publish(image:generation:)`.
@MainActor
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

    /// Whether the Confirm button should be enabled (Finding #16).
    ///
    /// `confirm(...)` with zero included suggestions flips `isConfirming` true → false in a
    /// single synchronous tick, which SwiftUI coalesces — the parent's `onChange(of:isConfirming)`
    /// never fires and the sheet strands the user. Gating the button here prevents that dead-end.
    ///
    /// - Complexity: O(n) where n = `editableSuggestions.count`. Evaluated on each SwiftUI
    ///   update; n is bounded by the number of VLM suggestions (typically ≤ 10).
    var canConfirm: Bool {
        editableSuggestions.contains { $0.included }
    }

    /// Indices (into `editableSuggestions`) of included items that failed or were not yet attempted.
    private(set) var failedIndices: [Int] = []

    /// Number of `confirmClass` (teach) requests that failed during the most
    /// recent `confirm(binId:apiClient:)` call. Upserts are the primary
    /// confirmation; teach failures are secondary. Resets at the start of each
    /// `confirm` invocation so views can surface a toast when > 0.
    private(set) var teachFailureCount: Int = 0

    /// User-facing message describing the most recent `confirm` failure, or
    /// `nil` when the last call succeeded / no call has been made. The view
    /// observes this with `onChange` and shows it via the toast environment,
    /// then clears it back to `nil`. Set by the empty-binId guard, the
    /// upsert/associate catch path (categorized by error type), and the
    /// partial-failure summary. Never silently swallowed. (Swift2_013)
    var confirmationErrorMessage: String?

    /// Snapshot of the on-device top-K classifications captured at
    /// `loadPreliminaryClassifications(_:topK:)` time. Used by the `#if DEBUG`
    /// logger in `confirm(...)` to emit (top-K vs. confirmed label) pairs.
    /// Never uploaded — Phase 0 T2 decision is on-device-only.
    private var originalPreliminaryTopK: [ClassificationResult] = []

    /// JPEG bytes of the photo that produced the suggestions currently under
    /// review. Set by the parent view at navigation time. Nil between sessions.
    ///
    /// Setting this property triggers an off-main-thread UIImage decode and
    /// publishes the result to `pinnedImage`. Rapid updates cancel any
    /// in-flight decode — see `handlePhotoDataChange()`.
    var photoData: Data? {
        didSet { handlePhotoDataChange() }
    }

    /// Bin identifier under review. Set by the parent view alongside
    /// `photoData` at ingest time so Confirm reads a stable, VM-durable
    /// value instead of an ephemeral parent-view @State (Swift2_012).
    /// Empty string until assigned; the guard in `confirm(binId:apiClient:)`
    /// treats empty as "not yet ready" and aborts the call.
    var binId: String = ""

    /// Decoded image derived from `photoData`. Populated off the main actor
    /// via `Task.detached` and published back through `publish(image:generation:)`.
    /// Views bind directly to this instead of decoding in the view body.
    private(set) var pinnedImage: UIImage?

    /// Monotonic counter bumped on each `photoData` change. The detached decode
    /// task captures the value at spawn; `publish` no-ops if the counter has
    /// advanced, dropping stale results from superseded decodes.
    private var decodeGeneration: UInt64 = 0

    /// Handle to the in-flight decode task. Cancelled when `photoData` changes,
    /// preventing concurrent large-JPEG decodes from piling up in memory.
    /// Read-accessible to `@testable` imports so tests can `await decodeTask?.value`
    /// as a hard synchronization barrier.
    private(set) var decodeTask: Task<Void, Never>?

    /// Decode strategy injected at init time. Default uses `UIImage(data:)`.
    /// Test-only closures (e.g. thread-capture) replace via the initializer —
    /// no public mutable seam.
    private let decoder: @Sendable (Data) -> UIImage?

    // MARK: - Init

    /// Creates a SuggestionReviewViewModel with an optional custom decoder.
    ///
    /// - Parameter decoder: The function used to decode `photoData` JPEG bytes
    ///   into a `UIImage`. Defaults to `UIImage(data:)`. Tests supply a
    ///   capturing closure to observe the decode thread or intercept results.
    init(decoder: @escaping @Sendable (Data) -> UIImage? = { UIImage(data: $0) }) {
        self.decoder = decoder
    }

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
                bbox: item.bbox,
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
        guard !binId.isEmpty else {
            logger.error("confirm called with empty binId — aborting to prevent server 400")
            confirmationErrorMessage =
                "Couldn't save — missing bin reference. Tap Back and rescan the bin QR."
            return
        }
        isConfirming = true
        failedIndices = []
        teachFailureCount = 0
        confirmationErrorMessage = nil
        let includedIndices = editableSuggestions.indices.filter { editableSuggestions[$0].included }
        logger.debug("confirm: \(self.editableSuggestions.count, privacy: .public) total, \(includedIndices.count, privacy: .public) included")
        for idx in includedIndices {
            let s = editableSuggestions[idx]
            let quantity = Double(s.editedQuantity)
            let category = s.editedCategory.isEmpty ? nil : s.editedCategory
            let confidence = editableSuggestions[idx].confidence
            do {
                // Finding #6: /items alone leaves bin_items empty. Follow with
                // /associate to guarantee the join row is created.
                let upsert = try await apiClient.upsertItem(
                    name: s.editedName,
                    category: category,
                    quantity: quantity,
                    confidence: confidence,
                    binId: binId
                )
                _ = try await apiClient.associateItem(
                    binId: binId,
                    itemId: upsert.itemId,
                    confidence: confidence,
                    quantity: quantity
                )
            } catch {
                let remaining = includedIndices.filter { $0 >= idx }
                failedIndices = remaining
                let total = includedIndices.count
                let failedCount = remaining.count
                let savedCount = total - failedCount
                if savedCount > 0 {
                    confirmationErrorMessage =
                        "\(failedCount) of \(total) items failed. Tap Retry."
                } else {
                    confirmationErrorMessage = Self.userFacingMessage(for: error)
                }
                logger.error("confirm aborted at idx \(idx, privacy: .public): \(error.localizedDescription, privacy: .private)")
                isConfirming = false
                return
            }
        }

        #if DEBUG
        // On-device-only debug log: top-K vs. user-confirmed labels.
        // Never uploaded; gated behind #if DEBUG per Phase 0 T2 decision.
        if !originalPreliminaryTopK.isEmpty {
            let topK = originalPreliminaryTopK
                .map { "\($0.label):\(String(format: "%.2f", $0.confidence))" }
                .joined(separator: ",")
            let confirmed = includedIndices
                .map { editableSuggestions[$0].editedName }
                .joined(separator: ",")
            preliminaryDebugLogger.debug(
                "topK=[\(topK, privacy: .private)] confirmed=[\(confirmed, privacy: .private)]"
            )
        }
        #endif

        // Confirm taught items as YOLO-World classes (fire-and-forget).
        for idx in includedIndices where editableSuggestions[idx].teach {
            let s = editableSuggestions[idx]
            let category = s.editedCategory.isEmpty ? nil : s.editedCategory
            do {
                _ = try await apiClient.confirmClass(className: s.editedName, category: category)
            } catch {
                logger.error("confirmClass failed for '\(s.editedName, privacy: .private)': \(error.localizedDescription, privacy: .private)")
                teachFailureCount += 1
            }
        }

        isConfirming = false
    }

    /// Populates `editableSuggestions` with preliminary chips from on-device
    /// `VNClassifyImageRequest` classifications, shown while the server call
    /// is still in-flight.
    ///
    /// Chips are flagged with `origin = .preliminary` so the view can render
    /// them with "preliminary" styling. When the server response arrives, call
    /// `applyServerSuggestions(_:)` to reconcile. See
    /// `thoughts/shared/designs/coreml-mode-a-merge-ux.md` §2a.
    ///
    /// - Parameters:
    ///   - classifications: The on-device classification results from Stage 3.
    ///   - topK: Maximum number of chips to render. Caller chooses; production
    ///     default is `3`. Clamped to the available classification count.
    func loadPreliminaryClassifications(_ classifications: [ClassificationResult], topK: Int) {
        let limit = max(0, min(topK, classifications.count))
        originalPreliminaryTopK = Array(classifications.prefix(limit))
        editableSuggestions = classifications.prefix(limit).enumerated().map { idx, cls in
            EditableSuggestion(
                id: idx,
                included: true,
                editedName: cls.label,
                editedCategory: "",
                editedQuantity: "",
                confidence: Double(cls.confidence),
                visionName: cls.label,
                match: nil,
                bbox: nil,
                teach: true,
                origin: .preliminary
            )
        }
        failedIndices = []
    }

    /// Marks the chip at `index` as user-edited so subsequent merges preserve it.
    ///
    /// Call from the view when the user modifies any editable field on a
    /// preliminary chip. A `.server` chip that is later edited is also valid
    /// to mark — merge rules keep edited chips under all conditions.
    func markEdited(index: Int) {
        guard editableSuggestions.indices.contains(index) else { return }
        editableSuggestions[index].origin = .edited
    }

    /// Convenience wrapper that only promotes `.preliminary` chips to `.edited`.
    ///
    /// `SuggestionReviewView` attaches this to `onChange` handlers on each
    /// editable text field — calling it is cheap and avoids flipping `.server`
    /// chips (whose identity is already authoritative).
    func markEditedIfPreliminary(index: Int) {
        guard editableSuggestions.indices.contains(index),
              editableSuggestions[index].origin == .preliminary else { return }
        editableSuggestions[index].origin = .edited
    }

    func markEditedIfPreliminary(id: Int) {
        guard let idx = editableSuggestions.firstIndex(where: { $0.id == id }),
              editableSuggestions[idx].origin == .preliminary else { return }
        editableSuggestions[idx].origin = .edited
    }

    /// Reconciles the current preliminary chips with the server's suggestions.
    ///
    /// Behavior (from the merge-UX spike §2a):
    /// - `.edited` chips always survive.
    /// - `.preliminary` chips are replaced by the server's items; if a server
    ///   item has the same normalized name, it takes over that chip slot.
    /// - Server items whose names overlap an edited chip are skipped.
    /// - Server-empty + no edited chips → `[]` (clean empty state; no stale
    ///   preliminary list visible).
    ///
    /// - Parameter server: The server's `/ingest` suggestion response.
    func applyServerSuggestions(_ server: [SuggestionItem]) {
        editableSuggestions = Self.merge(preliminary: editableSuggestions, server: server)
    }

    // MARK: - Pure merge

    /// Pure merge of preliminary / edited chips with a server response.
    ///
    /// Exposed as `static` so tests can drive it without constructing a view
    /// model. See `thoughts/shared/designs/coreml-mode-a-merge-ux.md` §2a and
    /// the prompt's TDD plan (REFACTOR step).
    static func merge(
        preliminary: [EditableSuggestion],
        server: [SuggestionItem]
    ) -> [EditableSuggestion] {
        let editedChips = preliminary.filter { $0.origin == .edited }
        let editedNames = Set(editedChips.map { Self.normalize($0.editedName) })

        var result = editedChips
        var nextId = (result.map(\.id).max() ?? -1) + 1

        for item in server {
            let key = Self.normalize(item.name)
            if editedNames.contains(key) { continue }
            let name = item.match?.name ?? item.name
            let category = item.match?.category ?? item.category ?? ""
            result.append(
                EditableSuggestion(
                    id: nextId,
                    included: true,
                    editedName: name,
                    editedCategory: category,
                    editedQuantity: "",
                    confidence: item.confidence,
                    visionName: item.name,
                    match: item.match,
                    bbox: item.bbox,
                    teach: true,
                    origin: .server
                )
            )
            nextId += 1
        }
        return result
    }

    /// Case- and whitespace-insensitive key for chip-name overlap detection.
    private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
                let upsert = try await apiClient.upsertItem(
                    name: s.editedName,
                    category: category,
                    quantity: quantity,
                    confidence: confidence,
                    binId: binId
                )
                _ = try await apiClient.associateItem(
                    binId: binId,
                    itemId: upsert.itemId,
                    confidence: confidence,
                    quantity: quantity
                )
            } catch {
                failedIndices = toRetry.filter { $0 >= idx }
                isConfirming = false
                return
            }
        }
        isConfirming = false
    }

    // MARK: - Async UIImage Decode

    /// Cancels any in-flight decode, bumps `decodeGeneration`, and spawns a
    /// fresh `Task.detached(priority: .userInitiated)` that calls the decoder
    /// off-main. Runs on the main actor as a stored-property observer on
    /// `photoData`.
    ///
    /// When `photoData` is set to `nil`, clears `pinnedImage` synchronously —
    /// no detached hop needed, no stale-publish window.
    private func handlePhotoDataChange() {
        decodeTask?.cancel()
        decodeGeneration &+= 1
        let generation = decodeGeneration

        guard let data = photoData else {
            pinnedImage = nil
            decodeTask = nil
            return
        }

        let decoder = self.decoder
        decodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            let image = decoder(data)
            guard !Task.isCancelled else { return }
            await self?.publish(image: image, generation: generation)
        }
    }

    /// Main-actor publication point for a completed decode. No-ops if a newer
    /// decode has superseded this one (i.e. `decodeGeneration` has advanced).
    private func publish(image: UIImage?, generation: UInt64) {
        guard decodeGeneration == generation else { return }
        pinnedImage = image
    }

    // MARK: - Error Classification (Swift2_013)

    /// Translates a `confirm`-path error into a specific, actionable user-facing
    /// message. Caller is responsible for the partial-failure case — this
    /// classifier is only invoked when nothing was saved yet.
    ///
    /// Order matters: `URLError` must be checked before `APIClientError` to
    /// guarantee "connection" wording for transport failures (the
    /// `APIClientError` path only covers HTTP-layer failures where the server
    /// was reached).
    static func userFacingMessage(for error: Error) -> String {
        if error is URLError {
            return "Couldn't reach the server. Check your connection and try again."
        }
        if let clientError = error as? APIClientError {
            switch clientError {
            case .missingAPIKey:
                return "Your API key is invalid or expired. Open Settings to update it."
            case .invalidURL:
                return "Server URL is invalid. Open Settings to fix it."
            case .unexpectedStatusCode(let code):
                switch code {
                case 401, 403:
                    return "Your API key is invalid or expired. Open Settings to update it."
                case 429:
                    return "Server is busy — wait a moment and try again."
                case 400...499:
                    return "Couldn't save this item. (Server \(code))"
                case 500...599:
                    return "Server error while saving. Please retry."
                default:
                    return "Server error while saving. Please retry."
                }
            }
        }
        if let apiError = error as? APIError {
            return "Couldn't save this item. (Server: \(apiError.error.message))"
        }
        return "Server error while saving. Please retry."
    }
}
