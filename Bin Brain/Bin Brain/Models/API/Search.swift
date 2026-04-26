// Search.swift
// Bin Brain
//
// DTOs for the /search endpoint.

import Foundation

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
