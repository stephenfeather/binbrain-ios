// APIModels.swift
// Bin Brain
//
// Decodable structs mirroring the Bin Brain OpenAPI response schemas.
// These are pure data types — no networking logic.

import Foundation

// MARK: - Shared Decoder

extension JSONDecoder {
    /// A shared decoder configured for Bin Brain API responses.
    ///
    /// Uses ISO 8601 date decoding to parse `last_updated` and other date fields.
    static let binBrain: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    /// A shared encoder configured for Bin Brain API request bodies.
    ///
    /// Uses ISO 8601 date encoding so `Date` fields (e.g. `shown_at` in
    /// `PhotoSuggestionOutcome`) land on the wire in the format FastAPI's
    /// Pydantic `datetime` validators accept without coercion.
    static let binBrain: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

// MARK: - Health

/// The response returned by `GET /health`.
struct HealthResponse: Decodable {
    let version: String
    let ok: Bool
    let dbOk: Bool
    let embedModel: String
    let expectedDims: Int
    /// Authentication status reported by the server.
    ///
    /// - `true`: request carried a valid `X-API-Key` header.
    /// - `false`: request carried an `X-API-Key` header that the server rejected.
    /// - `nil`: no `X-API-Key` header was sent.
    let authOk: Bool?
    /// The role associated with the API key when `authOk == true`.
    let role: Role?

    /// The role granted to an authenticated API key.
    ///
    /// Present only when `authOk == true`. Matches the server-side role enum.
    enum Role: String, Decodable, Equatable {
        case user
        case admin
    }

    enum CodingKeys: String, CodingKey {
        case version
        case ok
        case dbOk = "db_ok"
        case embedModel = "embed_model"
        case expectedDims = "expected_dims"
        case authOk = "auth_ok"
        case role
    }
}

// MARK: - Photos

/// A record representing a photo stored on the server.
///
/// Finding #8 — the server previously returned an internal filesystem `path`
/// which the F-10 allowlist had to strip, breaking decode. The contract now
/// returns `url` pointing at `/photos/{photo_id}/file` (an already-auth'd
/// server endpoint), keeping on-device consumers path-free.
struct PhotoRecord: Decodable {
    let photoId: Int
    let url: String
    /// On-device processing metadata, present when the client sent a `device_metadata` sidecar.
    let deviceMetadata: DeviceMetadata?

    enum CodingKeys: String, CodingKey {
        case photoId = "photo_id"
        case url
        case deviceMetadata = "device_metadata"
    }
}

// MARK: - Locations

/// A record representing a storage location.
struct LocationSummary: Decodable {
    let locationId: Int
    let name: String
    let description: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case locationId = "location_id"
        case name
        case description
        case createdAt = "created_at"
    }
}

/// The response returned by `GET /locations`.
struct ListLocationsResponse: Decodable {
    let version: String
    let locations: [LocationSummary]
}

/// The response returned by `POST /locations`.
struct CreateLocationResponse: Decodable {
    let version: String
    let location: LocationSummary
}

/// The response returned by `DELETE /locations/{location_id}`.
struct DeleteLocationResponse: Decodable {
    let version: String
    let deleted: Bool
}

/// The response returned by `PATCH /bins/{bin_id}/location`.
struct AssignLocationResponse: Decodable {
    let version: String
    let binId: String
    let locationId: Int?
    let locationName: String?

    enum CodingKeys: String, CodingKey {
        case version
        case binId = "bin_id"
        case locationId = "location_id"
        case locationName = "location_name"
    }
}

// MARK: - Bins

/// Summary information about a single storage bin.
struct BinSummary: Decodable {
    let binId: String
    let locationId: Int?
    let locationName: String?
    let itemCount: Int
    let photoCount: Int
    let lastUpdated: Date

    enum CodingKeys: String, CodingKey {
        case binId = "bin_id"
        case locationId = "location_id"
        case locationName = "location_name"
        case itemCount = "item_count"
        case photoCount = "photo_count"
        case lastUpdated = "last_updated"
    }
}

/// The response returned by `GET /bins`.
struct ListBinsResponse: Decodable {
    let version: String
    let bins: [BinSummary]
}

/// A record representing an item associated with a bin.
struct BinItemRecord: Decodable {
    let itemId: Int
    let name: String
    let category: String?
    let upc: String?
    let quantity: Double?
    let confidence: Double?

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case name
        case category
        case upc
        case quantity
        case confidence
    }
}

/// The response returned by `GET /bins/{bin_id}`.
struct GetBinResponse: Decodable {
    let version: String
    let binId: String
    let locationId: Int?
    let locationName: String?
    let items: [BinItemRecord]
    let photos: [PhotoRecord]

    enum CodingKeys: String, CodingKey {
        case version
        case binId = "bin_id"
        case locationId = "location_id"
        case locationName = "location_name"
        case items
        case photos
    }
}

// MARK: - Ingest

/// The response returned by `POST /ingest`.
struct IngestResponse: Decodable {
    let version: String
    let binId: String
    let photos: [PhotoRecord]

    enum CodingKeys: String, CodingKey {
        case version
        case binId = "bin_id"
        case photos
    }
}

// MARK: - Items

/// The response returned by `POST /items` (create or upsert).
struct UpsertItemResponse: Decodable {
    let version: String
    let itemId: Int
    let fingerprint: String
    let name: String
    let category: String?
    let notes: String?
    let upc: String?
    let binId: String?

    enum CodingKeys: String, CodingKey {
        case version
        case itemId = "item_id"
        case fingerprint
        case name
        case category
        case notes
        case upc
        case binId = "bin_id"
    }
}

/// The response returned by `POST /associate` (link an item to a bin).
struct AssociateItemResponse: Decodable {
    let ok: Bool
    let binId: String
    let itemId: Int

    enum CodingKeys: String, CodingKey {
        case ok
        case binId = "bin_id"
        case itemId = "item_id"
    }
}

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
struct PhotoSuggestResponse: Decodable {
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
}

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

    enum CodingKeys: String, CodingKey {
        case label
        case category
        case confidence
        case bbox
        case shownAt = "shown_at"
        case decision
        case editedToLabel = "edited_to_label"
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

// MARK: - Search

/// A single result item from the semantic search endpoint.
struct SearchResultItem: Decodable {
    let itemId: Int
    let name: String
    let category: String?
    let upc: String?
    let score: Double
    let bins: [String]

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case name
        case category
        case upc
        case score
        case bins
    }
}

/// The response returned by `GET /search`.
struct SearchResponse: Decodable {
    let version: String
    let q: String
    let limit: Int
    let offset: Int
    let minScore: Double?
    let results: [SearchResultItem]

    enum CodingKeys: String, CodingKey {
        case version
        case q
        case limit
        case offset
        case minScore = "min_score"
        case results
    }
}

// MARK: - Models

/// An Ollama model available on the server.
struct OllamaModel: Decodable {
    let name: String
    let size: Int?
    let modifiedAt: Date?

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case modifiedAt = "modified_at"
    }
}

/// The response returned by `GET /models`.
struct ListModelsResponse: Decodable {
    let version: String
    let activeModel: String
    let visionProvider: String?
    let models: [OllamaModel]

    enum CodingKeys: String, CodingKey {
        case version
        case activeModel = "active_model"
        case visionProvider = "vision_provider"
        case models
    }
}

/// An Ollama model currently loaded in memory.
struct RunningModel: Decodable {
    let name: String
    let size: Int?
    let sizeVram: Int?
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case sizeVram = "size_vram"
        case expiresAt = "expires_at"
    }
}

/// The response returned by `GET /models/running`.
struct RunningModelsResponse: Decodable {
    let version: String
    let activeModel: String
    let models: [RunningModel]

    enum CodingKeys: String, CodingKey {
        case version
        case activeModel = "active_model"
        case models
    }
}

/// The response returned by `POST /models/select`.
struct SelectModelResponse: Decodable {
    let version: String
    let previousModel: String
    let activeModel: String

    enum CodingKeys: String, CodingKey {
        case version
        case previousModel = "previous_model"
        case activeModel = "active_model"
    }
}

// MARK: - Settings

/// The response returned by `GET /settings/image-size`.
struct ImageSizeResponse: Decodable {
    let version: String
    let maxImagePx: Int

    enum CodingKeys: String, CodingKey {
        case version
        case maxImagePx = "max_image_px"
    }
}

/// The response returned by `POST /settings/image-size`.
struct SetImageSizeResponse: Decodable {
    let version: String
    let previousMaxImagePx: Int
    let maxImagePx: Int

    enum CodingKeys: String, CodingKey {
        case version
        case previousMaxImagePx = "previous_max_image_px"
        case maxImagePx = "max_image_px"
    }
}

// MARK: - Bin Item Mutations

/// The response returned by `DELETE /bins/{bin_id}/items/{item_id}`.
struct RemoveItemResponse: Decodable {
    let removed: Bool
}

/// The response returned by `PATCH /bins/{bin_id}/items/{item_id}`.
struct UpdateItemResponse: Decodable {
    let itemId: Int
    let binId: String
    let quantity: Double?
    let confidence: Double?

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case binId = "bin_id"
        case quantity
        case confidence
    }
}

// MARK: - Class Confirmation

/// The response returned by `POST /classes/confirm`.
struct ConfirmClassResponse: Decodable {
    let version: String
    let className: String
    let added: Bool
    let activeClassCount: Int
    let reloadTriggered: Bool

    enum CodingKeys: String, CodingKey {
        case version
        case className = "class_name"
        case added
        case activeClassCount = "active_class_count"
        case reloadTriggered = "reload_triggered"
    }
}

// MARK: - Errors

/// An API error decoded from the server's `ErrorResponse` envelope.
///
/// Conforms to `LocalizedError` so it can be surfaced directly in UI error messages.
struct APIError: Decodable, LocalizedError {
    let version: String
    let error: ErrorDetail

    /// The detail payload nested inside an `APIError` response.
    struct ErrorDetail: Decodable {
        let code: String
        let message: String
    }

    /// A human-readable description of the error, suitable for display to the user.
    var errorDescription: String? { error.message }
}
