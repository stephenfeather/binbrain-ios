// UploadQueueManager.swift
// Bin Brain
//
// Manages the offline photo upload queue, draining it sequentially when the
// server becomes reachable and the app enters the foreground.

import Foundation
import OSLog
import SwiftData
import Observation

private let logger = Logger(subsystem: "com.binbrain.app", category: "UploadQueueManager")
private let uploadSignposter = OSSignposter(subsystem: "com.binbrain.app", category: "UploadQueue")

// MARK: - UploadQueueManager

/// Manages the `PendingUpload` queue, draining it sequentially using `APIClient`.
///
/// Inject via `@Environment` key. Call `drain(context:using:)` on foreground entry
/// (via `onChange(of: scenePhase)`) and `clearQueue(context:)` from the Settings screen.
/// Observe `pendingCount` to drive badges and status indicators.
@Observable
final class UploadQueueManager {

    // MARK: - Constants

    /// Exponential backoff delays in seconds between retry attempts.
    static let backoffDelays: [TimeInterval] = [5, 15, 45, 120]

    /// Maximum age for a pending upload before it is pruned, in seconds (7 days).
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - Public Properties

    /// The number of uploads with status `.pending` or `.failed`.
    ///
    /// Updated after every mutation in `drain` and `clearQueue`.
    /// Suitable for display in a badge or status indicator.
    private(set) var pendingCount: Int = 0

    // MARK: - Internal Properties

    /// The current date provider, overridable for testing time-based expiry.
    var now: () -> Date = { Date() }

    /// The sleep function used for backoff delays, overridable for testing.
    var sleepForInterval: (TimeInterval) async throws -> Void = { interval in
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }

    // MARK: - Public Methods

    /// Drains the upload queue sequentially, processing all `.pending` uploads.
    ///
    /// Uploads are processed oldest-first. Before processing, entries older than 7 days
    /// are pruned. On failure, exponential backoff delays of 5s, 15s, 45s, and 120s are
    /// applied between retries. Errors are caught per-upload; this method does not throw.
    ///
    /// - Parameters:
    ///   - context: The SwiftData `ModelContext` used for reads and writes.
    ///   - apiClient: The `APIClient` used to perform the network upload.
    func drain(context: ModelContext, using apiClient: APIClient) async {
        let drainID = uploadSignposter.makeSignpostID()
        let drainInterval = uploadSignposter.beginInterval("upload_drain", id: drainID)
        uploadSignposter.emitEvent("upload_drain", id: drainID, "start=\(true, privacy: .public)")

        // Prune expired entries before processing.
        pruneExpired(context: context)

        let uploads: [PendingUpload]
        do {
            // Fetch all and filter in memory to avoid SwiftData predicate issues with enums.
            let all = try context.fetch(FetchDescriptor<PendingUpload>())
            uploads = all
                .filter { $0.status == .pending }
                .sorted { $0.queuedAt < $1.queuedAt }
        } catch {
            uploadSignposter.emitEvent("upload_drain", id: drainID, "error=\("fetch_failed", privacy: .public)")
            uploadSignposter.endInterval("upload_drain", drainInterval)
            logger.error("Failed to fetch pending uploads: \(error.localizedDescription, privacy: .private)")
            return
        }

        uploadSignposter.emitEvent("upload_drain", id: drainID, "pending=\(uploads.count, privacy: .public)")

        for upload in uploads {
            let attemptID = uploadSignposter.makeSignpostID()
            let attemptInterval = uploadSignposter.beginInterval("upload_attempt", id: attemptID)
            uploadSignposter.emitEvent("upload_attempt", id: attemptID, "binId=\(upload.binId, privacy: .private) retry=\(upload.retryCount, privacy: .public) size=\(upload.jpegData.count, privacy: .public)")

            // Apply exponential backoff delay based on retry count.
            if upload.retryCount > 0 {
                let delayIndex = min(upload.retryCount - 1, Self.backoffDelays.count - 1)
                let chosenDelay = Self.backoffDelays[delayIndex]
                uploadSignposter.emitEvent("upload_attempt", id: attemptID, "backoff=\(chosenDelay, privacy: .public)s")
                do {
                    try await sleepForInterval(chosenDelay)
                } catch {
                    // Task was cancelled — stop draining.
                    uploadSignposter.emitEvent("upload_attempt", id: attemptID, "cancelled=\(true, privacy: .public)")
                    uploadSignposter.endInterval("upload_attempt", attemptInterval)
                    return
                }
            }

            // Mark as in-progress before the network call.
            upload.status = .uploading
            do { try context.save() } catch {
                logger.error("Save after marking .uploading failed: \(error.localizedDescription, privacy: .private)")
            }
            uploadSignposter.emitEvent("upload_attempt", id: attemptID, "uploading=\(true, privacy: .public)")

            do {
                _ = try await apiClient.ingest(
                    jpegData: upload.jpegData,
                    binId: upload.binId,
                    deviceMetadata: upload.deviceMetadataJSON
                )
                uploadSignposter.emitEvent("upload_attempt", id: attemptID, "result=\("success", privacy: .public)")
                // Success: remove from queue.
                context.delete(upload)
                do { try context.save() } catch {
                    logger.error("Save after delete failed: \(error.localizedDescription, privacy: .private)")
                }
            } catch {
                uploadSignposter.emitEvent("upload_attempt", id: attemptID, "result=\("failure", privacy: .public) error=\(error.localizedDescription, privacy: .private)")
                // Failure: increment retry count and keep pending for next drain cycle.
                logger.error("Ingest failed for bin '\(upload.binId, privacy: .private)': \(error.localizedDescription, privacy: .private)")
                upload.retryCount += 1
                upload.status = .pending
                do { try context.save() } catch {
                    logger.error("Save after failure handling failed: \(error.localizedDescription, privacy: .private)")
                }
            }

            refreshCount(context: context)

            uploadSignposter.endInterval("upload_attempt", attemptInterval)
        }

        uploadSignposter.emitEvent("upload_drain", id: drainID, "done=\(true, privacy: .public)")
        uploadSignposter.endInterval("upload_drain", drainInterval)
    }

    /// Deletes all `PendingUpload` entries from the store regardless of status.
    ///
    /// - Parameter context: The SwiftData `ModelContext` used for reads and writes.
    func clearQueue(context: ModelContext) {
        let all: [PendingUpload]
        do {
            all = try context.fetch(FetchDescriptor<PendingUpload>())
        } catch {
            logger.error("clearQueue fetch failed: \(error.localizedDescription, privacy: .private)")
            return
        }
        for upload in all {
            context.delete(upload)
        }
        do {
            try context.save()
        } catch {
            logger.error("clearQueue save failed: \(error.localizedDescription, privacy: .private)")
        }
        refreshCount(context: context)
    }

    // MARK: - Internal Helpers

    /// Removes uploads older than `maxAge` from the store.
    ///
    /// Called at the start of each `drain()` cycle to prevent stale entries
    /// from accumulating indefinitely. Exposed as `internal` so tests can
    /// verify pruning behaviour directly.
    ///
    /// - Parameter context: The SwiftData `ModelContext` used for reads and writes.
    func pruneExpired(context: ModelContext) {
        let cutoff = now().addingTimeInterval(-Self.maxAge)

        let pruneID = uploadSignposter.makeSignpostID()
        let pruneInterval = uploadSignposter.beginInterval("upload_prune", id: pruneID)
        uploadSignposter.emitEvent("upload_prune", id: pruneID, "cutoff=\(cutoff.timeIntervalSince1970, privacy: .public)")

        let all: [PendingUpload]
        do {
            all = try context.fetch(FetchDescriptor<PendingUpload>())
        } catch {
            uploadSignposter.emitEvent("upload_prune", id: pruneID, "error=\("fetch_failed", privacy: .public)")
            uploadSignposter.endInterval("upload_prune", pruneInterval)
            logger.error("pruneExpired fetch failed: \(error.localizedDescription, privacy: .private)")
            return
        }
        var pruned = false
        for upload in all where upload.queuedAt < cutoff {
            context.delete(upload)
            pruned = true
        }
        if pruned {
            do {
                try context.save()
            } catch {
                logger.error("pruneExpired save failed: \(error.localizedDescription, privacy: .private)")
            }
            uploadSignposter.emitEvent("upload_prune", id: pruneID, "pruned=\(all.filter { $0.queuedAt < cutoff }.count, privacy: .public)")
            refreshCount(context: context)
        }
        uploadSignposter.endInterval("upload_prune", pruneInterval)
    }

    /// Updates `pendingCount` by querying the store for `.pending` and `.failed` rows.
    ///
    /// Exposed as `internal` (not `private`) so the test target can call it directly
    /// via `@testable import` to verify count-update behaviour in isolation.
    ///
    /// - Parameter context: The SwiftData `ModelContext` used to fetch the count.
    func refreshCount(context: ModelContext) {
        let all: [PendingUpload]
        do {
            all = try context.fetch(FetchDescriptor<PendingUpload>())
        } catch {
            logger.error("refreshCount fetch failed: \(error.localizedDescription, privacy: .private)")
            return
        }
        pendingCount = all.filter { $0.status == .pending || $0.status == .failed }.count
    }
}

