// AuthenticatedAsyncImage.swift
// Bin Brain
//
// AsyncImage replacement for server photos. `AsyncImage(url:)` can't attach
// `X-API-Key`, so `/photos/{id}/file` returns 401 and thumbnails render as
// placeholders on device (Finding #8-B). This file adds a small loader that
// routes the fetch through `APIClient.fetchPhotoData` (which goes through the
// same auth-attach gate as every other authed request) and a SwiftUI view
// that mirrors `AsyncImage`'s phase-based API.

import SwiftUI
import UIKit
import Observation

// MARK: - PhotoLoader

/// Phase-based state for `AuthenticatedAsyncImage`. Mirrors the subset of
/// `AsyncImagePhase` the existing call sites use (loading / success / failure).
enum PhotoLoadPhase: Equatable {
    case loading
    case success(UIImage)
    case failure

    static func == (lhs: PhotoLoadPhase, rhs: PhotoLoadPhase) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading), (.failure, .failure): return true
        case let (.success(a), .success(b)): return a === b
        default: return false
        }
    }
}

/// Testable loader for a single photo. Owns its phase state so XCTests can
/// drive through loading → success/failure via an injected `APIClient`.
@Observable
final class PhotoLoader {
    private(set) var phase: PhotoLoadPhase = .loading

    private let photoId: Int
    private let width: Int?
    private let apiClient: APIClient

    init(photoId: Int, width: Int?, apiClient: APIClient) {
        self.photoId = photoId
        self.width = width
        self.apiClient = apiClient
    }

    /// Fetches the photo through `APIClient.fetchPhotoData` and updates
    /// `phase`. Safe to call multiple times; each call resets to `.loading`.
    func load() async {
        phase = .loading
        do {
            let data = try await apiClient.fetchPhotoData(photoId: photoId, width: width)
            if let image = UIImage(data: data) {
                phase = .success(image)
            } else {
                phase = .failure
            }
        } catch {
            phase = .failure
        }
    }
}

// MARK: - AuthenticatedAsyncImage

/// Drop-in replacement for `AsyncImage(url:)` that attaches the API key
/// via `APIClient`. Preserves the three-phase rendering used by
/// `BinDetailView`'s photo strip and fullscreen viewer.
struct AuthenticatedAsyncImage<Content: View>: View {

    let photoId: Int
    let width: Int?
    let apiClient: APIClient
    @ViewBuilder let content: (PhotoLoadPhase) -> Content

    @State private var loader: PhotoLoader?

    init(
        photoId: Int,
        width: Int? = nil,
        apiClient: APIClient,
        @ViewBuilder content: @escaping (PhotoLoadPhase) -> Content
    ) {
        self.photoId = photoId
        self.width = width
        self.apiClient = apiClient
        self.content = content
    }

    var body: some View {
        Group {
            if let loader {
                content(loader.phase)
            } else {
                content(.loading)
            }
        }
        .task(id: photoId) {
            let l = PhotoLoader(photoId: photoId, width: width, apiClient: apiClient)
            loader = l
            await l.load()
        }
    }
}
