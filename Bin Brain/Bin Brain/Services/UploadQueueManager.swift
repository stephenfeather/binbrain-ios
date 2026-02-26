// UploadQueueManager.swift
// Bin Brain
//
// Manages the offline photo upload queue, draining it sequentially when the
// server becomes reachable and the app enters the foreground.

import Foundation
import SwiftData
import Observation

// MARK: - UploadQueueManager

/// Manages the `PendingUpload` queue, draining it sequentially using `APIClient`.
///
/// Inject via `@Environment` key. Call `drain(context:using:)` on foreground entry
/// (via `onChange(of: scenePhase)`) and `clearQueue(context:)` from the Settings screen.
/// Observe `pendingCount` to drive badges and status indicators.
@Observable
final class UploadQueueManager {

    // MARK: - Public Properties

    /// The number of uploads with status `.pending` or `.failed`.
    ///
    /// Updated after every mutation in `drain` and `clearQueue`.
    /// Suitable for display in a badge or status indicator.
    private(set) var pendingCount: Int = 0

    // MARK: - Public Methods

    /// Drains the upload queue sequentially, processing all `.pending` uploads.
    ///
    /// Uploads are processed oldest-first. Errors are caught per-upload; this method
    /// does not throw. On success the upload is deleted from the store; on failure the
    /// retry count is incremented. Uploads that reach or exceed a retry count of 3 are
    /// marked `.failed` and will not be retried automatically.
    ///
    /// - Parameters:
    ///   - context: The SwiftData `ModelContext` used for reads and writes.
    ///   - apiClient: The `APIClient` used to perform the network upload.
    func drain(context: ModelContext, using apiClient: APIClient) async {
        let uploads: [PendingUpload]
        do {
            // Fetch all and filter in memory to avoid SwiftData predicate issues with enums.
            let all = try context.fetch(FetchDescriptor<PendingUpload>())
            uploads = all
                .filter { $0.status == .pending }
                .sorted { $0.queuedAt < $1.queuedAt }
        } catch {
            print("UploadQueueManager: failed to fetch pending uploads — \(error)")
            return
        }

        for upload in uploads {
            // Mark as in-progress before the network call.
            upload.status = .uploading
            do { try context.save() } catch {
                print("UploadQueueManager: save after marking .uploading failed — \(error)")
            }

            do {
                _ = try await apiClient.ingest(jpegData: upload.jpegData, binId: upload.binId)
                // Success: remove from queue.
                context.delete(upload)
                do { try context.save() } catch {
                    print("UploadQueueManager: save after delete failed — \(error)")
                }
            } catch {
                // Failure: increment retry count and decide next status.
                print("UploadQueueManager: ingest failed for bin '\(upload.binId)' — \(error)")
                upload.retryCount += 1
                upload.status = upload.retryCount >= 3 ? .failed : .pending
                do { try context.save() } catch {
                    print("UploadQueueManager: save after failure handling failed — \(error)")
                }
            }

            refreshCount(context: context)
        }
    }

    /// Deletes all `PendingUpload` entries from the store regardless of status.
    ///
    /// - Parameter context: The SwiftData `ModelContext` used for reads and writes.
    func clearQueue(context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<PendingUpload>())) ?? []
        for upload in all {
            context.delete(upload)
        }
        try? context.save()
        refreshCount(context: context)
    }

    // MARK: - Internal Helpers

    /// Updates `pendingCount` by querying the store for `.pending` and `.failed` rows.
    ///
    /// Exposed as `internal` (not `private`) so the test target can call it directly
    /// via `@testable import` to verify count-update behaviour in isolation.
    ///
    /// - Parameter context: The SwiftData `ModelContext` used to fetch the count.
    func refreshCount(context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<PendingUpload>())) ?? []
        pendingCount = all.filter { $0.status == .pending || $0.status == .failed }.count
    }
}
