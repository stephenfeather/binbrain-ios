// AnalysisViewModel.swift
// Bin Brain
//
// State machine for the photo upload + AI analysis workflow.
// AnalysisProgressView drives this ViewModel by calling run() and observing phase.

import Foundation
import UIKit
import UserNotifications
import SwiftData
import Observation

// MARK: - AnalysisPhase

/// The current phase of the photo analysis workflow.
enum AnalysisPhase: Equatable {
    /// Idle; no analysis has started yet.
    case idle
    /// Uploading the photo to the server.
    case uploading
    /// Waiting for AI vision inference to complete.
    case analysing
    /// Inference complete; suggestions are available.
    case complete
    /// An error occurred; the associated message describes what went wrong.
    case failed(String)
}

// MARK: - AnalysisViewModel

/// Manages the upload + AI analysis workflow for a bin photo.
///
/// Call `run(jpegData:binId:apiClient:)` to start the full workflow.
/// Phase changes are observable; bind to `phase` in `AnalysisProgressView`.
@Observable
final class AnalysisViewModel {

    // MARK: - State

    /// The current phase of the analysis workflow.
    private(set) var phase: AnalysisPhase = .idle

    /// The item suggestions returned by vision inference; populated when `phase == .complete`.
    private(set) var suggestions: [SuggestionItem] = []

    /// The photo ID from the last successful ingest; `nil` until ingest completes.
    private(set) var lastPhotoId: Int?

    // MARK: - Actions

    /// Compresses `jpegData`, uploads it via `ingest()`, then calls `suggest()`.
    ///
    /// Manages a `UIApplication` background task around the suggest call so the
    /// workflow can complete if the user backgrounds the app. On expiry, posts a
    /// local notification and transitions to `.failed`.
    ///
    /// Never throws — all errors transition `phase` to `.failed(message)`.
    ///
    /// - Parameters:
    ///   - jpegData: Raw JPEG bytes to upload (compressed before sending).
    ///   - binId: The bin identifier to associate the photo with.
    ///   - apiClient: The `APIClient` instance to use for network calls.
    ///   - context: An optional `ModelContext` for persisting a `PendingAnalysis` on background task expiry.
    func run(jpegData: Data, binId: String, apiClient: APIClient, context: ModelContext? = nil) async {
        phase = .uploading

        let compressedData = compress(jpegData)

        // MARK: Ingest

        let ingestResponse: IngestResponse
        do {
            ingestResponse = try await apiClient.ingest(jpegData: compressedData, binId: binId)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        guard let firstPhoto = ingestResponse.photos.first else {
            phase = .failed("No photo returned from server")
            return
        }
        let photoId = firstPhoto.photoId
        lastPhotoId = photoId

        phase = .analysing

        // MARK: Suggest (with background task protection)

        // Boxes allow mutation from the synchronously-called expiration handler.
        final class SuggestTaskBox: @unchecked Sendable {
            var task: Task<PhotoSuggestResponse, Error>?
        }
        final class BGTaskBox: @unchecked Sendable {
            var identifier: UIBackgroundTaskIdentifier = .invalid
        }

        let taskBox = SuggestTaskBox()
        let bgBox = BGTaskBox()

        bgBox.identifier = UIApplication.shared.beginBackgroundTask(withName: "BinBrainSuggest") { [weak self] in
            taskBox.task?.cancel()

            let content = UNMutableNotificationContent()
            content.title = "Analysis interrupted"
            content.body = "Open Bin Brain to retry"
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)

            if let context {
                let entry = PendingAnalysis(photoId: photoId, binId: binId)
                context.insert(entry)
                try? context.save()
            }

            self?.phase = .failed("Analysis interrupted — tap to retry")

            if bgBox.identifier != .invalid {
                UIApplication.shared.endBackgroundTask(bgBox.identifier)
                bgBox.identifier = .invalid
            }
        }

        defer {
            if bgBox.identifier != .invalid {
                UIApplication.shared.endBackgroundTask(bgBox.identifier)
                bgBox.identifier = .invalid
            }
        }

        let suggestTask = Task { try await apiClient.suggest(photoId: photoId) }
        taskBox.task = suggestTask

        do {
            let suggestResponse = try await suggestTask.value
            suggestions = suggestResponse.suggestions
            phase = .complete
        } catch is CancellationError {
            // Expiration handler already set phase to .failed — do not overwrite.
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Re-runs suggest on the previously ingested photo without re-uploading.
    ///
    /// Call after switching to a larger model via `apiClient.selectModel()`.
    /// Requires a prior successful `run()` that set `lastPhotoId`.
    ///
    /// - Parameter apiClient: The `APIClient` instance to use for the suggest call.
    func reSuggest(apiClient: APIClient) async {
        guard let photoId = lastPhotoId else {
            phase = .failed("No photo to re-analyse")
            return
        }

        phase = .analysing
        suggestions = []

        do {
            let response = try await apiClient.suggest(photoId: photoId)
            suggestions = response.suggestions
            phase = .complete
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Resets all state back to `.uploading` for a retry.
    func reset() {
        phase = .idle
        suggestions = []
        lastPhotoId = nil
    }

    // MARK: - Private Helpers

    /// Resizes `data` so the longest edge is at most `maxDimension` pixels,
    /// then re-encodes at JPEG `quality`. Returns `data` unchanged if it is
    /// already within bounds or cannot be decoded as a `UIImage`.
    ///
    /// - Parameters:
    ///   - data: Raw image data to compress.
    ///   - maxDimension: Maximum pixel length for the longest edge. Defaults to 1920.
    ///   - quality: JPEG compression quality 0–1. Defaults to 0.85.
    private func compress(_ data: Data, maxDimension: CGFloat = 1920, quality: CGFloat = 0.85) -> Data {
        guard let image = UIImage(data: data) else { return data }
        let size = image.size
        let scale = min(maxDimension / max(size.width, size.height), 1.0)
        if scale >= 1.0 { return data }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: quality) ?? data
    }
}
