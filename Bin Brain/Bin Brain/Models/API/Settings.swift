// Settings.swift
// Bin Brain
//
// DTOs for the /settings endpoints.

import Foundation

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
