// Outcomes.swift
// Bin Brain
//
// DTOs for the /photos/{photo_id}/outcomes endpoint.

import Foundation

// MARK: - Suggestion Outcomes (Swift2_014 / Dev2_017)

/// One decision the user made about a VLM-suggested item on the Review screen.
///
/// Emitted as a fire-and-forget telemetry payload after `/confirm` succeeds.
/// The enum's raw values match the server-side `CHECK (decision IN (...))`
/// constraint exactly — changing them here is a wire-contract break.
///
/// `ignored` is part of the contract but iOS does not currently emit it: the
/// review UI has no gesture that distinguishes "saw the suggestion, didn't
/// touch it" from "the suggestion was never surfaced". Every non-accepted,
/// non-edited suggestion is emitted as `rejected` until a dismiss gesture
/// exists. See Swift2_014 deferred notes.
struct PhotoSuggestionOutcome: Encodable, Equatable {
    /// Decision the user made about a single presented suggestion.
    enum Decision: String, Encodable, Equatable {
        case accepted, rejected, edited, ignored
    }

    /// The original VLM label for the suggestion, as shown to the user.
    let label: String
    /// The original VLM category, if any. Preserved even when the user edits the on-screen category.
    let category: String?
    /// The VLM's confidence in this suggestion, `nil` if absent in the source.
    let confidence: Double?
    /// Normalized `[x1, y1, x2, y2]` bounding box (0–1, top-left origin), or `nil` if the VLM omitted it.
    let bbox: [Float]?
    /// Client-captured timestamp at which this suggestion was first presented.
    let shownAt: Date
    /// The user's decision for this suggestion.
    let decision: Decision
    /// Required when `decision == .edited`; the final label the user chose. Nil for all other decisions.
    let editedToLabel: String?
    /// Server `item_id` produced by the `upsertItem` call during confirm, for
    /// `.accepted` and `.edited` decisions. The server stores this directly on
    /// `photo_suggestion_outcomes.item_id` so `GET /bins/{bin_id}` can
    /// populate `source_photo_id` on each item via the existing LATERAL join.
    /// `nil` for `.rejected` / `.ignored` (no item was created or linked).
    let itemId: Int?

    enum CodingKeys: String, CodingKey {
        case label
        case category
        case confidence
        case bbox
        case shownAt = "shown_at"
        case decision
        case editedToLabel = "edited_to_label"
        case itemId = "item_id"
    }
}

/// The request body for `POST /photos/{photo_id}/outcomes`.
///
/// A batched, idempotent-per-(`photoId`, `visionModel`) payload describing
/// every suggestion that was surfaced on the Review screen. The server replaces
/// any prior outcomes for the pair — safe to re-fire on retry.
struct PhotoSuggestionOutcomesRequest: Encodable, Equatable {
    /// The VLM that produced the suggestions (from `PhotoSuggestResponse.model`).
    let visionModel: String
    /// Prompt revision identifier, if the server exposes it. `nil` is acceptable.
    let promptVersion: String?
    /// One entry per presented suggestion. Empty array is a valid no-op payload.
    let decisions: [PhotoSuggestionOutcome]

    enum CodingKeys: String, CodingKey {
        case visionModel = "vision_model"
        case promptVersion = "prompt_version"
        case decisions
    }
}

/// The response returned by `POST /photos/{photo_id}/outcomes`.
struct PhotoSuggestionOutcomesResponse: Decodable {
    let version: String
    let photoId: Int
    let outcomesRecorded: Int

    enum CodingKeys: String, CodingKey {
        case version
        case photoId = "photo_id"
        case outcomesRecorded = "outcomes_recorded"
    }
}
