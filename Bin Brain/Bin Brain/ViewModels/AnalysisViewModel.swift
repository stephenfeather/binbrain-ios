// AnalysisViewModel.swift
// Bin Brain
//
// State machine for the photo upload + AI analysis workflow.
// AnalysisProgressView drives this ViewModel by calling run() and observing phase.

import Foundation
import OSLog
import UIKit
import UserNotifications
import SwiftData
import Observation

private let logger = Logger(subsystem: "com.binbrain.app", category: "AnalysisViewModel")

// MARK: - AnalysisPhase

/// The current phase of the photo analysis workflow.
enum AnalysisPhase: Equatable {
    /// Idle; no analysis has started yet.
    case idle
    /// On-device pipeline is processing the image (quality gates, optimize, extract).
    case processingImage
    /// A quality gate failed; the associated message explains why and suggests a fix.
    /// The user can retry (retake photo) or override (upload anyway).
    case qualityFailed(String)
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

    /// The last quality gate failure, if any. Set when `phase == .qualityFailed`.
    private(set) var lastQualityFailure: QualityGateFailure?

    // MARK: - Dependencies

    /// The on-device image processing pipeline.
    private let pipeline = ImagePipeline()

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
        lastQualityFailure = nil

        // Boxes allow mutation from the synchronously-called expiration handler.
        final class WorkTaskBox: @unchecked Sendable {
            var task: Task<Void, Never>?
        }
        final class BGTaskBox: @unchecked Sendable {
            var identifier: UIBackgroundTaskIdentifier = .invalid
        }

        let workBox = WorkTaskBox()
        let bgBox = BGTaskBox()

        // Begin background task covering the entire pipeline + upload + suggest flow.
        bgBox.identifier = UIApplication.shared.beginBackgroundTask(withName: "BinBrainAnalysis") { [weak self] in
            workBox.task?.cancel()

            let content = UNMutableNotificationContent()
            content.title = "Analysis interrupted"
            content.body = "Open Bin Brain to retry"
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)

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

        // MARK: Pipeline (Stages 1-3)

        phase = .processingImage

        var uploadData: Data
        var metadataString: String?

        do {
            let result = try await pipeline.process(jpegData)
            uploadData = result.optimizedImageData
            let jsonData = try JSONEncoder().encode(result.deviceMetadata)
            metadataString = String(data: jsonData, encoding: .utf8)
        } catch let error as PipelineError {
            switch error {
            case .qualityGateFailed(let failure):
                lastQualityFailure = failure
                phase = .qualityFailed(failure.message)
                return
            case .invalidImageData:
                // Graceful degradation: upload original bytes without pipeline processing.
                uploadData = jpegData
                metadataString = nil
            }
        } catch {
            // Graceful degradation: pipeline internal error → upload original without metadata.
            // Matches the old compress() contract of never-failing.
            uploadData = jpegData
            metadataString = nil
        }

        // MARK: Ingest

        phase = .uploading

        let ingestResponse: IngestResponse
        do {
            ingestResponse = try await apiClient.ingest(
                jpegData: uploadData,
                binId: binId,
                deviceMetadata: metadataString
            )
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

        // MARK: Suggest

        let suggestTask = Task { try await apiClient.suggest(photoId: photoId) }
        workBox.task = Task { [suggestTask] in _ = try? await suggestTask.value }

        // Persist pending analysis in case of background task expiry.
        if let context {
            let entry = PendingAnalysis(photoId: photoId, binId: binId)
            context.insert(entry)
            do {
                try context.save()
            } catch {
                logger.error("Failed to persist PendingAnalysis for photoId '\(photoId, privacy: .private)': \(error.localizedDescription, privacy: .private)")
            }
        }

        do {
            let suggestResponse = try await suggestTask.value
            suggestions = suggestResponse.suggestions
            phase = .complete

            // Clean up the pending analysis entry on success.
            if let context {
                let all: [PendingAnalysis]
                do {
                    all = try context.fetch(FetchDescriptor<PendingAnalysis>())
                } catch {
                    logger.error("Failed to fetch PendingAnalysis for cleanup: \(error.localizedDescription, privacy: .private)")
                    all = []
                }
                for entry in all where entry.photoId == photoId {
                    context.delete(entry)
                }
                do {
                    try context.save()
                } catch {
                    logger.error("Failed to save after PendingAnalysis cleanup: \(error.localizedDescription, privacy: .private)")
                }
            }
        } catch is CancellationError {
            // Expiration handler already set phase to .failed — do not overwrite.
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Bypasses quality gates and proceeds with the pipeline + upload.
    ///
    /// Called when the user taps "Upload Anyway" after a quality gate failure.
    /// Runs the optimizer and metadata extractors without quality validation.
    ///
    /// - Parameters:
    ///   - jpegData: Raw JPEG bytes from the camera capture.
    ///   - binId: The bin identifier to associate the photo with.
    ///   - apiClient: The `APIClient` instance to use for network calls.
    ///   - context: An optional `ModelContext` for persisting a `PendingAnalysis` on background task expiry.
    func overrideQualityGate(jpegData: Data, binId: String, apiClient: APIClient, context: ModelContext? = nil) async {
        lastQualityFailure = nil
        phase = .processingImage

        var uploadData: Data
        var metadataString: String?

        do {
            let result = try await pipeline.processSkippingQualityGates(jpegData)
            uploadData = result.optimizedImageData
            let jsonData = try JSONEncoder().encode(result.deviceMetadata)
            metadataString = String(data: jsonData, encoding: .utf8)
        } catch {
            // Graceful degradation: upload original without metadata.
            uploadData = jpegData
            metadataString = nil
        }

        // Reuse the main run() flow for upload + suggest by setting state and calling ingest directly.
        phase = .uploading

        let ingestResponse: IngestResponse
        do {
            ingestResponse = try await apiClient.ingest(
                jpegData: uploadData,
                binId: binId,
                deviceMetadata: metadataString
            )
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

        do {
            let suggestResponse = try await apiClient.suggest(photoId: photoId)
            suggestions = suggestResponse.suggestions
            phase = .complete
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

    /// Resets all state back to `.idle` for a retry.
    func reset() {
        phase = .idle
        suggestions = []
        lastPhotoId = nil
        lastQualityFailure = nil
    }
}
