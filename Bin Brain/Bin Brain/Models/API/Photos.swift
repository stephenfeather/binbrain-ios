// Photos.swift
// Bin Brain
//
// DTOs for the /photos endpoints.

import Foundation

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
