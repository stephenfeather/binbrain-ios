// Mutations.swift
// Bin Brain
//
// DTOs for bin item mutation endpoints (remove, update).

import Foundation

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
