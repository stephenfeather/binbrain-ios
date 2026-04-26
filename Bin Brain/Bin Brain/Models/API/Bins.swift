// Bins.swift
// Bin Brain
//
// DTOs for the /bins endpoints.

import Foundation

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

/// The response returned by `DELETE /bins/{bin_id}`.
///
/// Soft-deletes the bin and reparents its items to the reserved `UNASSIGNED`
/// sentinel. `movedItemCount` is the count of `bin_items` rows the delete
/// consumed (moved + dropped-via-conflict) — surfaced in the client toast.
struct DeleteBinResponse: Decodable {
    let status: String
    let binId: String
    let movedItemCount: Int
    let deletedAt: Date

    enum CodingKeys: String, CodingKey {
        case status
        case binId = "bin_id"
        case movedItemCount = "moved_item_count"
        case deletedAt = "deleted_at"
    }
}

/// A record representing an item associated with a bin.
struct BinItemRecord: Decodable {
    let itemId: Int
    let name: String
    let category: String?
    let upc: String?
    let quantity: Double?
    let confidence: Double?
    let sourcePhotoId: Int?
    let sourceBbox: [Float]?

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case name
        case category
        case upc
        case quantity
        case confidence
        case sourcePhotoId = "source_photo_id"
        case sourceBbox = "source_bbox"
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
