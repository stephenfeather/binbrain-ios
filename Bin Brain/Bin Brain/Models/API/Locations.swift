// Locations.swift
// Bin Brain
//
// DTOs for the /locations endpoints.

import Foundation

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
