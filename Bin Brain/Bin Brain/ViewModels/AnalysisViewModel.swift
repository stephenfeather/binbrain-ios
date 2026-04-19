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

    /// On-device `VNClassifyImageRequest` classifications, populated the moment
    /// Stage 3 of `ImagePipeline.process(_:)` succeeds (before `.uploading`).
    ///
    /// The parent view uses this to render preliminary chips in
    /// `SuggestionReviewView` during the ~40 s server call. See
    /// `thoughts/shared/designs/coreml-mode-a-merge-ux.md`.
    private(set) var preliminaryClassifications: [ClassificationResult] = []

    /// The photo ID from the last successful ingest; `nil` until ingest completes.
    private(set) var lastPhotoId: Int?

    /// The VLM that produced the most recent suggestion list, sourced from
    /// `PhotoSuggestResponse.model`. Consumed by parent views (BinsListView,
    /// BinDetailView) when handing off to `SuggestionReviewViewModel` so
    /// Swift2_014 outcomes telemetry knows which model produced the
    /// decisions being reported. `nil` until a suggest response lands.
    private(set) var lastVisionModel: String?

    /// The prompt revision identifier echoed by the most recent
    /// `/suggest` response (`PhotoSuggestResponse.promptVersion`). Threaded
    /// into `SuggestionReviewViewModel` so outcomes telemetry records the
    /// exact prompt version under which the user's decisions were made.
    /// `nil` until a suggest response lands OR when the server omitted the
    /// field (cache hit from before prompt_version was exposed, or any
    /// future case where the value is genuinely absent). iOS must forward
    /// nil unchanged — never synthesize a client-side value.
    private(set) var lastPromptVersion: String?

    /// The last quality gate failure, if any. Set when `phase == .qualityFailed`.
    private(set) var lastQualityFailure: QualityGateFailure?

    /// Raw bytes of the photo that was just rejected by a quality gate.
    ///
    /// Populated when `phase` transitions to `.qualityFailed` so the rejection
    /// screen can render a thumbnail — otherwise the user has no way to judge
    /// whether to retry or force-accept (Finding #4-UX). Cleared at the start
    /// of each new `run(...)` and on retry.
    private(set) var lastRejectedPhotoData: Data?

    /// The post-optimize JPEG bytes that were uploaded for the current analysis.
    /// Mirrors `lastRejectedPhotoData` but for the success path. Consumed by
    /// `SuggestionReviewView` so the user sees the exact bytes the classifier saw.
    /// Cleared by `reset()`.
    private(set) var lastUploadedPhotoData: Data?

    // MARK: - Dependencies

    /// The on-device image processing pipeline.
    private let pipeline = ImagePipeline()

    /// Background task lifecycle abstraction — injectable so tests can verify
    /// endBackgroundTask fires on every terminal path (Finding #15).
    private let backgroundTask: BackgroundTaskRunning

    // MARK: - Initializer

    init(backgroundTask: BackgroundTaskRunning = UIApplicationBackgroundTaskRunner()) {
        self.backgroundTask = backgroundTask
    }

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
    ///   - sessionId: Server-minted session UUID (`Swift2_019`). When
    ///     present, forwarded to `/ingest` as the `session_id` multipart
    ///     field. Callers typically obtain this by awaiting
    ///     `SessionManager.activeSessionId(apiClient:)` so the first
    ///     photo after launch opens a session transparently.
    ///   - context: An optional `ModelContext` for persisting a `PendingAnalysis` on background task expiry.
    func run(jpegData: Data, binId: String, apiClient: APIClient, sessionId: UUID? = nil, context: ModelContext? = nil) async {
        lastQualityFailure = nil
        lastRejectedPhotoData = nil
        preliminaryClassifications = []

        // Boxes allow mutation from the synchronously-called expiration handler.
        final class WorkTaskBox: @unchecked Sendable {
            var task: Task<Void, Never>?
        }
        final class BGTaskBox: @unchecked Sendable {
            var identifier: Int = -1 // sentinel for "released"
        }

        let workBox = WorkTaskBox()
        let bgBox = BGTaskBox()
        let runner = self.backgroundTask

        // Begin background task covering the entire pipeline + upload + suggest flow.
        bgBox.identifier = runner.begin(name: "BinBrainAnalysis") { [weak self] in
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

            Task { @MainActor [weak self] in
                self?.phase = .failed("Analysis interrupted — tap to retry")
            }

            if bgBox.identifier != -1 {
                runner.end(bgBox.identifier)
                bgBox.identifier = -1
            }
        }

        // Finding #15 — defer guarantees the grant is released on EVERY terminal
        // path (success, early return, thrown error, quality-gate failure).
        defer {
            if bgBox.identifier != -1 {
                runner.end(bgBox.identifier)
                bgBox.identifier = -1
            }
        }

        // MARK: Pipeline (Stages 1-3)

        phase = .processingImage

        var uploadData: Data
        var metadataString: String?

        do {
            let result = try await pipeline.process(jpegData)
            uploadData = result.optimizedImageData
            preliminaryClassifications = result.deviceMetadata.deviceProcessing.classifications
            let jsonData = try JSONEncoder().encode(result.deviceMetadata)
            metadataString = String(data: jsonData, encoding: .utf8)
        } catch let error as PipelineError {
            switch error {
            case .qualityGateFailed(let failure):
                lastQualityFailure = failure
                // Finding #4-UX: keep the raw bytes so the rejection screen
                // can render a thumbnail of what the camera actually captured.
                lastRejectedPhotoData = jpegData
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

        lastUploadedPhotoData = uploadData
        phase = .uploading

        let ingestResponse: IngestResponse
        do {
            ingestResponse = try await apiClient.ingest(
                jpegData: uploadData,
                binId: binId,
                deviceMetadata: metadataString,
                sessionId: sessionId
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
            lastVisionModel = suggestResponse.model
            lastPromptVersion = suggestResponse.promptVersion
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
    func overrideQualityGate(jpegData: Data, binId: String, apiClient: APIClient, sessionId: UUID? = nil, context: ModelContext? = nil) async {
        // Finding #19 — same BG task protection as run() so the #18 180 s
        // /suggest window doesn't get OS-killed if the user backgrounds
        // after tapping "Upload Anyway".
        final class BGTaskBox: @unchecked Sendable { var id: Int = -1 }
        let bgBox = BGTaskBox()
        let runner = self.backgroundTask
        bgBox.id = runner.begin(name: "BinBrainAnalysisOverride") { [weak self] in
            Task { @MainActor [weak self] in
                self?.phase = .failed("Analysis interrupted — tap to retry")
            }
            if bgBox.id != -1 { runner.end(bgBox.id); bgBox.id = -1 }
        }
        defer {
            if bgBox.id != -1 { runner.end(bgBox.id); bgBox.id = -1 }
        }

        lastQualityFailure = nil
        lastRejectedPhotoData = nil
        preliminaryClassifications = []
        phase = .processingImage

        var uploadData: Data
        var metadataString: String?

        do {
            let result = try await pipeline.processSkippingQualityGates(jpegData)
            uploadData = result.optimizedImageData
            preliminaryClassifications = result.deviceMetadata.deviceProcessing.classifications
            let jsonData = try JSONEncoder().encode(result.deviceMetadata)
            metadataString = String(data: jsonData, encoding: .utf8)
        } catch {
            // Graceful degradation: upload original without metadata.
            uploadData = jpegData
            metadataString = nil
        }

        // Reuse the main run() flow for upload + suggest by setting state and calling ingest directly.
        lastUploadedPhotoData = uploadData
        phase = .uploading

        let ingestResponse: IngestResponse
        do {
            ingestResponse = try await apiClient.ingest(
                jpegData: uploadData,
                binId: binId,
                deviceMetadata: metadataString,
                sessionId: sessionId
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
            lastVisionModel = suggestResponse.model
            lastPromptVersion = suggestResponse.promptVersion
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

        // Finding #19 — reSuggest hits /suggest which can run 149 s+ on cold
        // model loads. Without BG task protection the OS kills us if the user
        // backgrounds mid-wait.
        final class BGTaskBox: @unchecked Sendable { var id: Int = -1 }
        let bgBox = BGTaskBox()
        let runner = self.backgroundTask
        bgBox.id = runner.begin(name: "BinBrainAnalysisReSuggest") { [weak self] in
            Task { @MainActor [weak self] in
                self?.phase = .failed("Analysis interrupted — tap to retry")
            }
            if bgBox.id != -1 { runner.end(bgBox.id); bgBox.id = -1 }
        }
        defer {
            if bgBox.id != -1 { runner.end(bgBox.id); bgBox.id = -1 }
        }

        phase = .analysing
        suggestions = []

        do {
            let response = try await apiClient.suggest(photoId: photoId)
            suggestions = response.suggestions
            lastVisionModel = response.model
            lastPromptVersion = response.promptVersion
            phase = .complete
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Resets all state back to `.idle` for a retry.
    func reset() {
        phase = .idle
        suggestions = []
        preliminaryClassifications = []
        lastPhotoId = nil
        lastVisionModel = nil
        lastPromptVersion = nil
        lastQualityFailure = nil
        lastRejectedPhotoData = nil
        lastUploadedPhotoData = nil
    }
}
