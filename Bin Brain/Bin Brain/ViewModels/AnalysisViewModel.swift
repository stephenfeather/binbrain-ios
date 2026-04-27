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
@MainActor
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

    /// Swift_prong1_ocr_preliminary — on-device OCR results from the same
    /// Stage 3 `MetadataExtractors.extract(from:)` call that produces
    /// `preliminaryClassifications`. Published alongside classifications so
    /// the preliminary-ready callback can thread them into
    /// `SuggestionReviewViewModel.loadPreliminaryFromOnDevice(...)` where
    /// the confidence + length bar decides whether an OCR chip lands.
    private(set) var preliminaryOCR: [OCRResult] = []

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

    /// Camera-state telemetry from the most recent `run(...)` invocation.
    /// Reused by `overrideQualityGate(...)` so the bypass path keeps the same
    /// capture context as the original (rejected) attempt.
    private var lastCameraContext: CameraCaptureContext?

    /// Cataloging-session supervision counts from the most recent `run(...)`
    /// invocation. `overrideQualityGate(...)` replaces this with an updated
    /// snapshot that reflects the just-incremented bypass count.
    private var lastUserBehavior: UserBehaviorContext?

    // MARK: - Dependencies

    /// The on-device image processing pipeline.
    private let pipeline = ImagePipeline()

    /// Background task lifecycle abstraction — injectable so tests can verify
    /// endBackgroundTask fires on every terminal path (Finding #15).
    private let backgroundTask: BackgroundTaskRunning

    // MARK: - Initializer

    nonisolated init(backgroundTask: BackgroundTaskRunning = UIApplicationBackgroundTaskRunner()) {
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
    ///   - sessionManager: Optional `SessionManager` reference
    ///     (`Swift2_019b` / SEC-24-1). When present, an `/ingest` failure
    ///     that decodes as `APIError { code == "invalid_session" }`
    ///     invalidates the cached session, auto-begins a fresh one via
    ///     `activeSessionId`, and retries `/ingest` once. Without this
    ///     wiring the client loops on 400s whenever the server rotates
    ///     or sweeps the cached session_id.
    ///   - context: An optional `ModelContext` for persisting a `PendingAnalysis` on background task expiry.
    ///   - cameraContext: Optional capture-time camera telemetry (ISO,
    ///     exposure, focal length, lens model, etc.) sourced from the
    ///     `AVCapturePhoto` delegate. Forwarded into `ImagePipeline.process`
    ///     so it lands in `device_metadata.capture_metadata`.
    ///   - userBehavior: Optional cataloging-session supervision snapshot
    ///     (retake_count, quality_bypass_count). Forwarded into
    ///     `ImagePipeline.process` so it lands in `device_metadata.user_behavior`.
    func run(jpegData: Data, binId: String, apiClient: APIClient, sessionId: UUID? = nil, sessionManager: SessionManager? = nil, context: ModelContext? = nil, cameraContext: CameraCaptureContext? = nil, userBehavior: UserBehaviorContext? = nil, prescannedBarcode: BarcodeResult? = nil) async {
        lastQualityFailure = nil
        lastRejectedPhotoData = nil
        lastCameraContext = cameraContext
        lastUserBehavior = userBehavior
        preliminaryClassifications = []
        preliminaryOCR = []

        // Box allows mutation from the synchronously-called expiration handler.
        final class WorkTaskBox: @unchecked Sendable {
            nonisolated(unsafe) var task: Task<Void, Never>?
            nonisolated(unsafe) var suggestTask: Task<PhotoSuggestResponse, Error>?
        }
        let workBox = WorkTaskBox()

        // Finding #15 — withBackgroundTask guarantees end fires on EVERY terminal
        // path (success, early return, thrown error, quality-gate failure).
        await withBackgroundTask(name: "BinBrainAnalysis", onExpiry: { [workBox] in
            workBox.task?.cancel()
            workBox.suggestTask?.cancel()

            let content = UNMutableNotificationContent()
            content.title = "Analysis interrupted"
            content.body = "Open Bin Brain to retry"
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }) {

            // MARK: Pipeline (Stages 1-3)

            phase = .processingImage

            var uploadData: Data
            var metadataString: String?

            do {
                let result = try await pipeline.process(jpegData, cameraContext: cameraContext, userBehavior: userBehavior)
                uploadData = result.optimizedImageData
                preliminaryClassifications = result.deviceMetadata.deviceProcessing.classifications
                preliminaryOCR = result.deviceMetadata.deviceProcessing.ocr
                // Merge any pre-shutter live-scanner barcode into the metadata
                // sidecar so /ingest sees the UPC even when the captured frame
                // does not contain it (user moves between scan and shutter).
                var deviceMetadata = result.deviceMetadata
                if let prescannedBarcode {
                    let alreadyPresent = deviceMetadata.deviceProcessing.barcodes.contains {
                        $0.payload == prescannedBarcode.payload
                    }
                    if !alreadyPresent {
                        deviceMetadata.deviceProcessing.barcodes.append(prescannedBarcode)
                    }
                }
                let jsonData = try JSONEncoder().encode(deviceMetadata)
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
                ingestResponse = try await Self.ingestWithSessionRecovery(
                    jpegData: uploadData,
                    binId: binId,
                    deviceMetadata: metadataString,
                    sessionId: sessionId,
                    sessionManager: sessionManager,
                    apiClient: apiClient
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
            workBox.suggestTask = suggestTask
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
    ///   - userBehavior: Optional cataloging-session supervision snapshot
    ///     taken AFTER the bypass tap was recorded. When supplied, replaces
    ///     the stored snapshot from the original `run(...)` so the bypass
    ///     count reflects reality.
    func overrideQualityGate(jpegData: Data, binId: String, apiClient: APIClient, sessionId: UUID? = nil, sessionManager: SessionManager? = nil, context: ModelContext? = nil, userBehavior: UserBehaviorContext? = nil, prescannedBarcode: BarcodeResult? = nil) async {
        // Finding #19 — same BG task protection as run() so the #18 180 s
        // /suggest window doesn't get OS-killed if the user backgrounds
        // after tapping "Upload Anyway".
        await withBackgroundTask(name: "BinBrainAnalysisOverride") {
            let originalFailure = lastQualityFailure
            lastQualityFailure = nil
            lastRejectedPhotoData = nil
            if let userBehavior {
                lastUserBehavior = userBehavior
            }
            preliminaryClassifications = []
            preliminaryOCR = []
            phase = .processingImage

            var uploadData: Data
            var metadataString: String?

            do {
                let result = try await pipeline.processSkippingQualityGates(jpegData, originalFailure: originalFailure, cameraContext: lastCameraContext, userBehavior: lastUserBehavior)
                uploadData = result.optimizedImageData
                preliminaryClassifications = result.deviceMetadata.deviceProcessing.classifications
                preliminaryOCR = result.deviceMetadata.deviceProcessing.ocr
                var deviceMetadata = result.deviceMetadata
                if let prescannedBarcode {
                    let alreadyPresent = deviceMetadata.deviceProcessing.barcodes.contains {
                        $0.payload == prescannedBarcode.payload
                    }
                    if !alreadyPresent {
                        deviceMetadata.deviceProcessing.barcodes.append(prescannedBarcode)
                    }
                }
                let jsonData = try JSONEncoder().encode(deviceMetadata)
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
                ingestResponse = try await Self.ingestWithSessionRecovery(
                    jpegData: uploadData,
                    binId: binId,
                    deviceMetadata: metadataString,
                    sessionId: sessionId,
                    sessionManager: sessionManager,
                    apiClient: apiClient
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
        await withBackgroundTask(name: "BinBrainAnalysisReSuggest") {
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
    }

    /// Resets all state back to `.idle` for a retry.
    func reset() {
        phase = .idle
        suggestions = []
        preliminaryClassifications = []
        preliminaryOCR = []
        lastPhotoId = nil
        lastVisionModel = nil
        lastPromptVersion = nil
        lastQualityFailure = nil
        lastRejectedPhotoData = nil
        lastUploadedPhotoData = nil
        lastCameraContext = nil
        lastUserBehavior = nil
    }

    // MARK: - Session recovery (Swift2_019b / SEC-24-1)

    /// Posts `/ingest` and, on server `invalid_session`, invalidates the
    /// cached `SessionManager` session, auto-begins a fresh one, and
    /// retries exactly once. If the retry fails (any error), that error
    /// propagates — the caller surfaces it normally and we never loop.
    ///
    /// Exposed as `static` so the logic is pure and testable from both
    /// `run(...)` and `overrideQualityGate(...)` without duplicating the
    /// try/catch ladder.
    static func ingestWithSessionRecovery(
        jpegData: Data,
        binId: String,
        deviceMetadata: String?,
        sessionId: UUID?,
        sessionManager: SessionManager?,
        apiClient: APIClient
    ) async throws -> IngestResponse {
        do {
            return try await apiClient.ingest(
                jpegData: jpegData,
                binId: binId,
                deviceMetadata: deviceMetadata,
                sessionId: sessionId
            )
        } catch let apiError as APIError where apiError.error.code == "reserved_bin_name" {
            // Swift2_023 — pre-flight (ScannerViewModel + any future create
            // form) should have rejected this before we got here. If the
            // server still rejects, remap the message to the same friendly
            // copy the pre-flight uses so the user sees one consistent
            // explanation regardless of which validator caught it.
            throw APIError(
                version: apiError.version,
                error: APIError.ErrorDetail(
                    code: apiError.error.code,
                    message: BinNameValidator.friendlyMessage(for: binId)
                )
            )
        } catch let apiError as APIError where apiError.error.code == "invalid_session" {
            // Swift2_019c / SEC-25-5 — intentionally tight-keyed to
            // `invalid_session` only. Adjacent codes (`session_expired`,
            // `session_closed`, `session_owner_mismatch`) are NOT caught
            // by design; any server-side addition to the recovery-eligible
            // set requires a matched iOS release that updates this clause.
            // Server invalidated our cached session. Drop it locally, get
            // a fresh one, and retry exactly once. If sessionManager is
            // nil (legacy callers without session wiring), the original
            // error propagates — no silent retry.
            guard let sessionManager else { throw apiError }
            // Swift2_019b G-1 / SEC-25-2 — only invalidate if `current`
            // is still the id that the failing /ingest used. Prevents a
            // delayed 400 from clobbering a newer legitimate session
            // (manual End-now, server idle sweep, auto-begin race).
            logger.info("[SESSION] server returned invalid_session for \(sessionId?.uuidString ?? "nil", privacy: .private) — invalidating and retrying with fresh session")
            sessionManager.invalidateCurrentSession(ifCurrentIs: sessionId)
            let freshId = try await sessionManager.activeSessionId(apiClient: apiClient)
            // Swift2_019c / SEC-25-4 — stamp the retry so server-side
            // telemetry can distinguish a session-recovery retry from an
            // independent first attempt. Mirrors the /outcomes pattern.
            return try await apiClient.ingest(
                jpegData: jpegData,
                binId: binId,
                deviceMetadata: deviceMetadata,
                sessionId: freshId,
                retryCount: 1
            )
        }
    }

    // MARK: - Background Task Helper

    /// Mutable box holding a background-task identifier.
    ///
    /// Needs to be a reference type so the expiration handler and the `defer`
    /// block share the same sentinel value. `@unchecked Sendable` because the
    /// OS expiration handler may execute on any thread; callers guard against
    /// concurrent mutation with the `-1` sentinel pattern.
    private final class BGTaskBox: @unchecked Sendable {
        var id: Int = -1
    }

    /// Wraps `body` in a named UIApplication background-task grant.
    ///
    /// Calls `backgroundTask.begin(name:expirationHandler:)` before executing
    /// `body`, and guarantees `backgroundTask.end(_:)` fires on every terminal
    /// path — success, early return, and OS expiry.
    ///
    /// On OS expiry the handler:
    /// 1. Calls `onExpiry()` for site-specific extra work (e.g. cancel in-flight tasks, post notifications).
    /// 2. Transitions `phase` to `.failed("Analysis interrupted — tap to retry")` on the main actor.
    /// 3. Ends the background task grant (idempotent via `-1` sentinel).
    ///
    /// - Note: Inherits `@MainActor` isolation from the class; the `defer` block
    ///   and `body` run on the main actor. The expiration handler is invoked by
    ///   the OS on an arbitrary thread and explicitly hops back via
    ///   `Task { @MainActor [weak self] in ... }`.
    /// - Parameters:
    ///   - name: The background-task name passed to `BackgroundTaskRunning.begin`.
    ///   - onExpiry: Additional work to perform when the OS fires the expiration
    ///               handler. Runs before the phase transition. Defaults to a no-op.
    ///   - body: The async body to execute under the background-task grant.
    /// - Returns: The value produced by `body`.
    private func withBackgroundTask<T>(
        name: String,
        onExpiry: @escaping @Sendable () -> Void = {},
        body: () async -> T
    ) async -> T {
        let bgBox = BGTaskBox()
        let runner = backgroundTask
        bgBox.id = runner.begin(name: name) {
            onExpiry()
            let id = bgBox.id
            bgBox.id = -1
            Task { @MainActor [weak self] in
                self?.phase = .failed("Analysis interrupted — tap to retry")
                if id != -1 { runner.end(id) }
            }
        }
        defer {
            if bgBox.id != -1 { runner.end(bgBox.id); bgBox.id = -1 }
        }
        return await body()
    }
}
