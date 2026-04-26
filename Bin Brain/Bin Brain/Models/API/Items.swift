// Items.swift
// Bin Brain
//
// DTOs for the /items and /associate endpoints.

import Foundation

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
///
/// Server PR #41 (ApiDev2_013) added `inserted: bool` so the client can
/// distinguish a brand-new association from an idempotent no-op (the
/// `(bin_id, item_id)` row already existed and the server explicitly
/// did NOT merge quantity/confidence). When `inserted == false`, the
/// user's edited quantity was discarded by the server — the toast in
/// `SuggestionReviewViewModel.confirm()` surfaces this for the user.
///
/// Backward-compat: a missing `inserted` key (pre-PR-#41 server, or
/// staging drift) decodes as `inserted = true` so the old contract
/// ("association succeeded; nothing to surface") survives unchanged.
struct AssociateItemResponse: Decodable {
    let ok: Bool
    let binId: String
    let itemId: Int
    let inserted: Bool

    enum CodingKeys: String, CodingKey {
        case ok
        case binId = "bin_id"
        case itemId = "item_id"
        case inserted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.ok = try c.decode(Bool.self, forKey: .ok)
        self.binId = try c.decode(String.self, forKey: .binId)
        self.itemId = try c.decode(Int.self, forKey: .itemId)
        // Swift2_029: default to true for graceful degradation against
        // any server that hasn't shipped PR #41 yet.
        self.inserted = try c.decodeIfPresent(Bool.self, forKey: .inserted) ?? true
    }
}
