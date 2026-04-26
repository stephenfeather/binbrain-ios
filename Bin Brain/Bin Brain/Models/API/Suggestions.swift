// Suggestions.swift
// Bin Brain
//
// DTOs for the /photos/{photo_id}/suggest endpoint.

import Foundation

// MARK: - Suggestions

/// A catalogue item matched to a vision suggestion by embedding similarity.
///
/// Present when an existing item scored above the cosine similarity threshold (0.5).
struct SuggestionMatch: Decodable {
    let itemId: Int
    let name: String
    let category: String?
    let score: Double
    let bins: [String]

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case name
        case category
        case score
        case bins
    }
}

/// A single item suggested by vision inference for a photo.
///
/// `itemId` is always `nil` — use `match?.itemId` for DB-matched items.
/// `bins` is always empty — use `match?.bins` for DB-matched items.
/// `bbox` holds normalized `[x1, y1, x2, y2]` coordinates (0–1, top-left origin)
/// when the VLM returns a bounding box; `nil` for models that omit it.
struct SuggestionItem: Decodable {
    let itemId: Int?
    let name: String
    let category: String?
    let confidence: Double
    let bins: [String]
    let match: SuggestionMatch?
    let bbox: [Float]?

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case name
        case category
        case confidence
        case bins
        case match
        case bbox
    }
}

/// The response returned by `GET /photos/{photo_id}/suggest`.
///
/// `promptVersion` mirrors the server's `prompt_version` field introduced by
/// binbrain PRs #22/#23 — the live constant on fresh calls, or the historical
/// stamp on cache hits (may differ from the live value after a prompt bump).
/// Nil when the server did not echo the field (older server build or a future
/// case where the value is genuinely absent).
///
/// Defensive decode (Swift2_016, aegis F8): `promptVersion` is clamped to
/// `nil` at decode time when the server echoes an over-length value (> 64
/// chars) or one containing ASCII control characters (< 0x20). Nil, not
/// truncation — the whole point of `prompt_version` is lineage auditing,
/// and a value we can't trust must become "unknown" rather than "incorrect."
struct PhotoSuggestResponse: Decodable {
    /// Max character count accepted for a server-echoed `prompt_version`.
    /// Values exceeding this decode to nil. Current production values like
    /// `"v2"` are two characters — 64 is a generous headroom, not a tight
    /// limit.
    private static let maxPromptVersionLength = 64

    let version: String
    let photoId: Int
    let model: String
    let promptVersion: String?
    let visionElapsedMs: Int
    let suggestions: [SuggestionItem]

    enum CodingKeys: String, CodingKey {
        case version
        case photoId = "photo_id"
        case model
        case promptVersion = "prompt_version"
        case visionElapsedMs = "vision_elapsed_ms"
        case suggestions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(String.self, forKey: .version)
        self.photoId = try container.decode(Int.self, forKey: .photoId)
        self.model = try container.decode(String.self, forKey: .model)
        self.visionElapsedMs = try container.decode(Int.self, forKey: .visionElapsedMs)
        self.suggestions = try container.decode([SuggestionItem].self, forKey: .suggestions)

        let rawPromptVersion = try container.decodeIfPresent(String.self, forKey: .promptVersion)
        self.promptVersion = Self.sanitizePromptVersion(rawPromptVersion)
    }

    /// Returns `raw` unchanged if it is nil, within the length cap, and
    /// contains no ASCII control characters; returns `nil` otherwise.
    /// Silent clamp — no logging, no truncation. Matches the existing
    /// nil-forward telemetry contract from Swift2_015.
    private static func sanitizePromptVersion(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if raw.count > maxPromptVersionLength { return nil }
        for scalar in raw.unicodeScalars where scalar.value < 0x20 {
            return nil
        }
        return raw
    }
}
