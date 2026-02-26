// PendingUpload.swift
// Bin Brain
//
// SwiftData model for a photo queued for upload when the server was unreachable.

import Foundation
import SwiftData

// MARK: - UploadStatus

/// The lifecycle state of a queued photo upload.
enum UploadStatus: String, Codable {
    /// Waiting to be uploaded.
    case pending
    /// Currently being sent to the server.
    case uploading
    /// Upload failed after the maximum number of retry attempts.
    case failed
}

// MARK: - PendingUpload

/// A photo queued for upload to the server while the server was unreachable.
///
/// Persisted via SwiftData so the queue survives app termination.
/// `UploadQueueManager` drains this queue when the app enters the foreground.
@Model
final class PendingUpload {

    /// The compressed JPEG image bytes to upload.
    var jpegData: Data

    /// The identifier of the target bin.
    var binId: String

    /// The time at which this item was added to the queue.
    var queuedAt: Date

    /// The number of upload attempts made for this item.
    var retryCount: Int

    /// The current lifecycle state of the upload.
    var status: UploadStatus

    /// Creates a new pending upload for the given JPEG data and bin.
    ///
    /// - Parameters:
    ///   - jpegData: Compressed JPEG image bytes to upload.
    ///   - binId: The identifier of the target bin.
    init(jpegData: Data, binId: String) {
        self.jpegData = jpegData
        self.binId = binId
        self.queuedAt = Date()
        self.retryCount = 0
        self.status = .pending
    }
}
