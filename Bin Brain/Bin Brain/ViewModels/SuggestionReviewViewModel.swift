// SuggestionReviewViewModel.swift
// Bin Brain
//
// Manages the review + confirmation step of the cataloging workflow.
// SuggestionReviewView drives this ViewModel by calling loadSuggestions()
// and then confirm() or retryRemaining().

import Foundation
import Observation
import OSLog
import SwiftData
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
    /// Category from the original server suggestion, preserved even after the
    /// user edits `editedCategory`. Used by Swift2_014 to emit accurate
    /// `PhotoSuggestionOutcome.category` — the original VLM signal is what the
    /// server wants for training, not the user's replacement. Nil for chips
    /// that did not come from a server suggestion (preliminary CoreML chips).
    let originalCategory: String?
    /// Three-state outcome (Swift2_020). Defaults to `.accepted` so any code
    /// path that constructs an `EditableSuggestion` without setting state
    /// keeps the legacy default-on semantics. The view model overrides this
    /// at `loadSuggestions` time when the feature flag is on.
    var outcomeState: OutcomeState = .accepted
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

    // MARK: - Swift2_018 Outcomes Queue

    /// Optional reference to the durable outcomes queue. When the view
    /// injects this alongside `outcomeQueueContext`, `confirm()` enqueues
    /// the outcomes payload instead of firing it as a one-shot detached
    /// `Task`. When either is `nil`, the legacy fire-and-forget path
    /// runs unchanged so the 30+ existing `confirm(...)` test call sites
    /// keep passing.
    var outcomeQueueManager: OutcomeQueueManager?

    /// Main-thread `ModelContext` paired with `outcomeQueueManager`.
    var outcomeQueueContext: ModelContext?

    // MARK: - Swift2_014 Outcomes State

    /// Photo identifier under review, threaded from `AnalysisViewModel.lastPhotoId`.
    /// Required for `POST /photos/{id}/outcomes`. Zero is a "not-yet-assigned"
    /// sentinel — the outcomes fire-and-forget guard short-circuits in that state.
    var photoId: Int = 0

    /// The VLM that produced the current suggestion list. Captured from
    /// `PhotoSuggestResponse.model` via `loadSuggestions(_:photoId:visionModel:promptVersion:)`
    /// or `applyServerSuggestions(_:photoId:visionModel:promptVersion:)`. The outcomes
    /// fire guard requires a non-nil value.
    private(set) var visionModel: String?

    /// Prompt revision identifier echoed by the server on `/suggest`
    /// (binbrain PRs #22/#23). Threaded in via
    /// `loadSuggestions(...,promptVersion:)` or
    /// `applyServerSuggestions(...,promptVersion:)` and emitted on the
    /// outcomes POST so the training signal records the exact prompt
    /// under which the user's decisions were made. Nil is a valid
    /// server-side value (pre-bump cache hit, or an older server build).
    /// iOS must forward nil unchanged — never synthesize a client value.
    private(set) var promptVersion: String?

    /// Wall-clock time the first non-empty server suggestion list landed.
    /// Every `PhotoSuggestionOutcome.shownAt` inherits this value. Stamped
    /// once per review session; preserved across subsequent merges and
    /// retries so confirm+retry cycles report a stable presentation time.
    private(set) var shownAt: Date?

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

    // MARK: - Swift2_020 Three-State Outcome Toggle

    /// `UserDefaults` key surfaced via `@AppStorage` in `SettingsView`.
    /// Production default is `true` (three-state on); flipping to `false`
    /// reverts the suggestion-review screen to legacy default-on UX without
    /// a code release.
    static let outcomeModelEnabledDefaultsKey = "outcomeModelEnabled"

    /// Whether the three-state outcome toggle is active. Reads
    /// `UserDefaults.standard` at init time so settings flips take effect on
    /// the next sheet presentation; tests override directly.
    var threeStateEnabled: Bool

    /// Number of rows currently in the `.ignored` state. Drives
    /// `confirmButtonTitle` so users can see what they're about to skip.
    /// Always zero in legacy mode (rows arrive `.accepted`).
    ///
    /// - Complexity: O(n).
    var ignoredCount: Int {
        editableSuggestions.reduce(into: 0) { count, item in
            if item.outcomeState == .ignored { count += 1 }
        }
    }

    /// Title for the Confirm button. `"Confirm"` when nothing is ignored or
    /// the flag is off; `"Confirm (N ignored)"` when N > 0 under three-state.
    var confirmButtonTitle: String {
        guard threeStateEnabled else { return "Confirm" }
        let n = ignoredCount
        return n == 0 ? "Confirm" : "Confirm (\(n) ignored)"
    }

    /// Advances `editableSuggestions[id].outcomeState` per the tap cycle and
    /// keeps `included` in sync (only `.accepted` rows fire the upsert
    /// pipeline). Unknown ids are no-ops. Also a no-op while `isConfirming`
    /// — defence-in-depth for SEC-22-2; the view's `.disabled` already
    /// blocks the taps in practice.
    func cycleOutcome(id: Int) {
        guard !isConfirming else { return }
        guard let idx = editableSuggestions.firstIndex(where: { $0.id == id }) else { return }
        let newState = editableSuggestions[idx].outcomeState.next()
        editableSuggestions[idx].outcomeState = newState
        editableSuggestions[idx].included = (newState == .accepted)
    }

    // MARK: - Init

    /// Creates a SuggestionReviewViewModel with an optional custom decoder.
    ///
    /// - Parameters:
    ///   - decoder: The function used to decode `photoData` JPEG bytes into a
    ///     `UIImage`. Defaults to `UIImage(data:)`. Tests supply a capturing
    ///     closure to observe the decode thread or intercept results.
    ///   - threeStateEnabled: Override the `outcomeModelEnabled` user default.
    ///     Production callers omit this so the value tracks Settings; tests
    ///     pass an explicit Bool to pin the mode.
    init(
        decoder: @escaping @Sendable (Data) -> UIImage? = { UIImage(data: $0) },
        threeStateEnabled: Bool? = nil
    ) {
        self.decoder = decoder
        if let threeStateEnabled {
            self.threeStateEnabled = threeStateEnabled
        } else {
            // `UserDefaults.bool(forKey:)` returns `false` for an unset key,
            // which would silently disable the flag on first launch. Read via
            // `object(forKey:)` so an absent key falls back to the documented
            // production default of `true`.
            let stored = UserDefaults.standard.object(
                forKey: Self.outcomeModelEnabledDefaultsKey
            ) as? Bool
            self.threeStateEnabled = stored ?? true
        }
    }

    // MARK: - Setup

    /// Populates `editableSuggestions` from a raw `SuggestionItem` array.
    ///
    /// When a suggestion has a catalogue `match`, the matched item's name and
    /// category are used as defaults (since the catalogue entry is more accurate
    /// than the raw vision label). The original vision name and category are
    /// preserved in `visionName` and `originalCategory` for reference and for
    /// Swift2_014 outcome telemetry.
    ///
    /// Each item starts with `included = true`. Calling this method clears
    /// any previous `failedIndices`.
    ///
    /// - Parameters:
    ///   - suggestions: The suggestion items returned by vision inference.
    ///   - photoId: Optional photo ID to thread through for outcomes telemetry.
    ///     Omit (or pass `nil`) to leave the current value unchanged.
    ///   - visionModel: Optional VLM identifier from `PhotoSuggestResponse.model`.
    ///     Omit to leave the current value unchanged.
    ///   - promptVersion: Optional prompt revision identifier. Kept nil today
    ///     (server follow-up pending).
    func loadSuggestions(
        _ suggestions: [SuggestionItem],
        photoId: Int? = nil,
        visionModel: String? = nil,
        promptVersion: String? = nil
    ) {
        // Fresh server-suggestion landing ⇒ fresh review session. Drop ALL
        // prior outcomes context so stale values from an earlier photo don't
        // leak into this session's telemetry. Production callers pass
        // photoId + visionModel every time, but clearing defensively here
        // guarantees a reused VM cannot attach new decisions to old context.
        // (ultrareview bug_003 + CodeRabbit defense-in-depth follow-up.)
        resetOutcomesContext()
        // Swift2_020 — under three-state, new rows arrive `.ignored`
        // (yellow) and excluded; legacy mode keeps default-on `.accepted`.
        let initialState: OutcomeState = threeStateEnabled ? .ignored : .accepted
        let initialIncluded = (initialState == .accepted)
        editableSuggestions = suggestions.enumerated().map { idx, item in
            let name = item.match?.name ?? item.name
            let category = item.match?.category ?? item.category ?? ""
            return EditableSuggestion(
                id: idx,
                included: initialIncluded,
                editedName: name,
                editedCategory: category,
                editedQuantity: "",
                confidence: item.confidence,
                visionName: item.name,
                match: item.match,
                bbox: item.bbox,
                teach: true,
                originalCategory: item.category,
                outcomeState: initialState
            )
        }
        failedIndices = []
        applyOutcomesContext(
            photoId: photoId,
            visionModel: visionModel,
            promptVersion: promptVersion
        )
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

        // Swift2_014 — telemetry fires only on confirm-success; failures here
        // MUST NOT surface (fire-and-forget detached Task swallows errors).
        fireOutcomesIfReady(apiClient: apiClient)

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
        // Fresh session (on-device preliminary chips arrive BEFORE server
        // suggestions). Reset ALL outcomes context here so the subsequent
        // `applyServerSuggestions` lands on a clean slate — otherwise a
        // reused VM carries the prior session's photoId/visionModel forward
        // if the new applyServerSuggestions caller were to omit them.
        resetOutcomesContext()
        let limit = max(0, min(topK, classifications.count))
        originalPreliminaryTopK = Array(classifications.prefix(limit))
        // Swift2_020 — preliminary chips obey the same three-state initial
        // state as server suggestions, so the user sees a consistent yellow
        // baseline regardless of which inference path produced the chip.
        let initialState: OutcomeState = threeStateEnabled ? .ignored : .accepted
        let initialIncluded = (initialState == .accepted)
        editableSuggestions = classifications.prefix(limit).enumerated().map { idx, cls in
            EditableSuggestion(
                id: idx,
                included: initialIncluded,
                editedName: cls.label,
                editedCategory: "",
                editedQuantity: "",
                confidence: Double(cls.confidence),
                visionName: cls.label,
                match: nil,
                bbox: nil,
                teach: true,
                origin: .preliminary,
                originalCategory: nil,
                outcomeState: initialState
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

    /// Single onChange entry point for any editable field on a row.
    ///
    /// Two responsibilities (was named `markEditedIfPreliminary(id:)` before
    /// Swift2_020; renamed because it now carries a second concern):
    /// 1. Promote a `.preliminary` chip to `.edited` so the merge rules in
    ///    `merge(preliminary:server:threeStateEnabled:)` keep it.
    /// 2. Under three-state, flip an `.ignored` row to `.accepted` (editing
    ///    implies endorsement). `.rejected` rows do NOT auto-resurrect —
    ///    that requires an explicit chip tap.
    func noteUserEdit(id: Int) {
        guard let idx = editableSuggestions.firstIndex(where: { $0.id == id }) else { return }
        if editableSuggestions[idx].origin == .preliminary {
            editableSuggestions[idx].origin = .edited
        }
        if threeStateEnabled, editableSuggestions[idx].outcomeState == .ignored {
            editableSuggestions[idx].outcomeState = .accepted
            editableSuggestions[idx].included = true
        }
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
    /// - Parameters:
    ///   - server: The server's `/ingest` suggestion response.
    ///   - photoId: Optional photo ID threaded through for outcomes telemetry.
    ///   - visionModel: Optional VLM identifier from `PhotoSuggestResponse.model`.
    ///   - promptVersion: Optional prompt revision identifier (server follow-up pending).
    func applyServerSuggestions(
        _ server: [SuggestionItem],
        photoId: Int? = nil,
        visionModel: String? = nil,
        promptVersion: String? = nil
    ) {
        editableSuggestions = Self.merge(
            preliminary: editableSuggestions,
            server: server,
            threeStateEnabled: threeStateEnabled
        )
        applyOutcomesContext(
            photoId: photoId,
            visionModel: visionModel,
            promptVersion: promptVersion
        )
    }

    /// Clears all outcomes-telemetry context to a clean "not-yet-ready"
    /// state. Called at fresh-session entry points (`loadSuggestions`,
    /// `loadPreliminaryClassifications`) so a reused `@State`-held VM
    /// cannot carry stale (photoId, visionModel, promptVersion, shownAt)
    /// from a prior cataloging flow into the new session's outcomes POST.
    private func resetOutcomesContext() {
        photoId = 0
        visionModel = nil
        promptVersion = nil
        shownAt = nil
    }

    /// Applies any supplied outcomes-telemetry context values and stamps
    /// `shownAt` on the first non-empty suggestion landing.
    ///
    /// `nil` parameters are no-ops, so existing callers that don't pass context
    /// preserve any state set through another path. `shownAt` is stamped at most
    /// once per review session — subsequent merges don't reset it, so confirm +
    /// retryRemaining cycles report a stable presentation time.
    private func applyOutcomesContext(
        photoId: Int?,
        visionModel: String?,
        promptVersion: String?
    ) {
        if let photoId { self.photoId = photoId }
        if let visionModel { self.visionModel = visionModel }
        if let promptVersion { self.promptVersion = promptVersion }
        if shownAt == nil, !editableSuggestions.isEmpty {
            shownAt = Date()
        }
    }

    // MARK: - Pure merge

    /// Pure merge of preliminary / edited chips with a server response.
    ///
    /// Exposed as `static` so tests can drive it without constructing a view
    /// model. See `thoughts/shared/designs/coreml-mode-a-merge-ux.md` §2a and
    /// the prompt's TDD plan (REFACTOR step).
    static func merge(
        preliminary: [EditableSuggestion],
        server: [SuggestionItem],
        threeStateEnabled: Bool = false
    ) -> [EditableSuggestion] {
        let editedChips = preliminary.filter { $0.origin == .edited }
        let editedNames = Set(editedChips.map { Self.normalize($0.editedName) })

        var result = editedChips
        var nextId = (result.map(\.id).max() ?? -1) + 1

        // Server items added by merge follow the same three-state initial
        // state as a fresh `loadSuggestions` call so the user sees a
        // consistent baseline regardless of the load path.
        let initialState: OutcomeState = threeStateEnabled ? .ignored : .accepted
        let initialIncluded = (initialState == .accepted)
        for item in server {
            let key = Self.normalize(item.name)
            if editedNames.contains(key) { continue }
            let name = item.match?.name ?? item.name
            let category = item.match?.category ?? item.category ?? ""
            result.append(
                EditableSuggestion(
                    id: nextId,
                    included: initialIncluded,
                    editedName: name,
                    editedCategory: category,
                    editedQuantity: "",
                    confidence: item.confidence,
                    visionName: item.name,
                    match: item.match,
                    bbox: item.bbox,
                    teach: true,
                    origin: .server,
                    originalCategory: item.category,
                    outcomeState: initialState
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

    // MARK: - Swift2_014 Outcomes Building

    /// Builds per-suggestion decision telemetry from the presented list.
    ///
    /// Pure function — exposed as `static` so tests can drive the classification
    /// logic without constructing a view model, network stack, or Task scheduler.
    ///
    /// Classification rules (Phase 2a):
    /// - Item in `confirmedIds` with unchanged label → `.accepted`.
    /// - Item in `confirmedIds` with `editedName != visionName` → `.edited`
    ///   (carries `editedToLabel`).
    /// - Item NOT in `confirmedIds` → `.rejected`.
    /// - `.ignored` is never emitted — deferred until the UI has an explicit
    ///   dismiss gesture that distinguishes "saw but didn't act" from "toggled
    ///   off".
    ///
    /// Defensive: an `.edited` decision with a missing/empty `editedToLabel`
    /// would trip the server's Pydantic validator (422). Such entries are
    /// dropped from the output rather than emitted, per the fire-and-forget
    /// contract — never throw from telemetry.
    ///
    /// - Parameters:
    ///   - shownAt: Client-captured timestamp at which the suggestion list
    ///     was first presented. Every outcome inherits this value.
    ///   - editable: The presented suggestion list as the user last saw it.
    ///   - confirmedIds: IDs of items that made it through upsert + associate.
    ///     Every other item is classified `.rejected`.
    /// - Returns: One `PhotoSuggestionOutcome` per presented item, minus any
    ///   defensively-dropped broken `.edited` entries.
    static func buildOutcomes(
        shownAt: Date,
        editable: [EditableSuggestion],
        confirmedIds: Set<Int>,
        threeStateEnabled: Bool = false
    ) -> [PhotoSuggestionOutcome] {
        editable.compactMap { item in
            let finalLabel = item.editedName.trimmingCharacters(in: .whitespacesAndNewlines)
            let originalLabel = item.visionName
            // Edit-detection baseline is the value `editedName` was PREFILLED
            // with — which is `match.name` when a catalogue match exists,
            // NOT `visionName`. Comparing against `visionName` alone would
            // false-flag every catalogue-matched but untouched confirmation
            // as `.edited` (poisoning the training signal Swift2_014 exists
            // to collect — see ultrareview bug_001).
            let prefilledLabel = item.match?.name ?? item.visionName
            let labelChanged = !finalLabel.isEmpty && finalLabel != prefilledLabel

            let decision: PhotoSuggestionOutcome.Decision
            let editedTo: String?
            if threeStateEnabled {
                // Swift2_020 — `outcomeState` is authoritative. `.accepted`
                // with a divergent label still surfaces as `.edited` so the
                // training signal mirrors what the user actually saved.
                switch item.outcomeState {
                case .accepted:
                    if labelChanged {
                        decision = .edited
                        editedTo = finalLabel
                    } else {
                        decision = .accepted
                        editedTo = nil
                    }
                case .rejected:
                    decision = .rejected
                    editedTo = nil
                case .ignored:
                    decision = .ignored
                    editedTo = nil
                }
            } else {
                let confirmed = confirmedIds.contains(item.id)
                let wasEdited = confirmed && labelChanged
                if wasEdited {
                    decision = .edited
                    editedTo = finalLabel
                } else if confirmed {
                    decision = .accepted
                    editedTo = nil
                } else {
                    decision = .rejected
                    editedTo = nil
                }
            }

            if decision == .edited, (editedTo ?? "").isEmpty {
                logger.error("[OUTCOMES] dropping edited decision with empty label for '\(originalLabel, privacy: .private)'")
                return nil
            }

            return PhotoSuggestionOutcome(
                label: originalLabel,
                category: item.originalCategory,
                confidence: item.confidence,
                bbox: item.bbox,
                shownAt: shownAt,
                decision: decision,
                editedToLabel: editedTo
            )
        }
    }

    /// Fires `POST /photos/{id}/outcomes` in a detached Task when the VM has
    /// everything needed. Silent no-op otherwise — outcomes are best-effort.
    ///
    /// Must be called ONLY from a confirm-success path (no failedIndices,
    /// upsert+associate loop completed). Errors are logged, never surfaced.
    private func fireOutcomesIfReady(apiClient: APIClient) {
        guard photoId > 0,
              let visionModel,
              let shownAt,
              !editableSuggestions.isEmpty else {
            return
        }
        let confirmedIds = Set(editableSuggestions.filter { $0.included }.map(\.id))
        let decisions = Self.buildOutcomes(
            shownAt: shownAt,
            editable: editableSuggestions,
            confirmedIds: confirmedIds,
            threeStateEnabled: threeStateEnabled
        )
        let request = PhotoSuggestionOutcomesRequest(
            visionModel: visionModel,
            promptVersion: promptVersion,
            decisions: decisions
        )
        let pid = photoId

        // Swift2_018 — preferred path. The queue persists the payload so
        // network or 5xx failures retry on backoff, NWPathMonitor, and
        // foreground transitions instead of being silently dropped.
        if let queue = outcomeQueueManager, let context = outcomeQueueContext {
            do {
                let body = try JSONEncoder.binBrain.encode(request)
                Task { @MainActor in
                    await queue.enqueue(
                        photoId: pid,
                        payload: body,
                        context: context,
                        apiClient: apiClient
                    )
                }
            } catch {
                logger.error("[OUTCOMES] payload encode failed (queue path): \(error.localizedDescription, privacy: .private)")
            }
            return
        }

        // Legacy fire-and-forget path — kept for tests that pre-date the
        // queue. Production view sites set `outcomeQueueManager` and
        // `outcomeQueueContext`, which short-circuits this branch.
        Task { [apiClient, pid, request] in
            do {
                _ = try await apiClient.postPhotoSuggestionOutcomes(photoId: pid, request: request)
            } catch {
                logger.error("[OUTCOMES] fire-and-forget post failed: \(error.localizedDescription, privacy: .private)")
            }
        }
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
        // Swift2_014 — retry success path also fires outcomes (server is
        // idempotent per (photoId, visionModel), so re-firing is safe).
        fireOutcomesIfReady(apiClient: apiClient)
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
