// Ingest.swift
// Bin Brain
//
// DTOs for the /ingest endpoint.

import Foundation

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
