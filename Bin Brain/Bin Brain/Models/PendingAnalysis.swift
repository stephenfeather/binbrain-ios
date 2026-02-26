// PendingAnalysis.swift
// Bin Brain
//
// SwiftData model for an interrupted suggest call that should be retried on next launch.

import Foundation
import SwiftData

// MARK: - PendingAnalysis

/// A suggest call that was interrupted when the background task expired.
///
/// Created in `AnalysisViewModel` when `UIApplication.shared.beginBackgroundTask`
/// expires before `GET /photos/{id}/suggest` completes. Persisted via SwiftData
/// so the app can resume the analysis on next launch and notify the user via a
/// local notification.
@Model
final class PendingAnalysis {

    /// The server-assigned identifier for the photo awaiting analysis.
    var photoId: Int

    /// The identifier of the bin the photo belongs to.
    var binId: String

    /// The time at which the background task was interrupted.
    var interruptedAt: Date

    /// The number of retry attempts made for this analysis.
    var retryCount: Int

    /// Creates a new pending analysis record for the given photo and bin.
    ///
    /// - Parameters:
    ///   - photoId: The server-assigned photo identifier.
    ///   - binId: The identifier of the bin the photo belongs to.
    init(photoId: Int, binId: String) {
        self.photoId = photoId
        self.binId = binId
        self.interruptedAt = Date()
        self.retryCount = 0
    }
}
