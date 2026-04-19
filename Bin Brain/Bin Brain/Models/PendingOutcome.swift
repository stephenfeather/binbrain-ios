// PendingOutcome.swift
// Bin Brain
//
// SwiftData model backing the Swift2_018 offline-outcomes queue. Each row
// is a serialized `PhotoSuggestionOutcomesRequest` awaiting delivery to
// `POST /photos/{id}/outcomes`. The queue survives app termination so
// training signal is not dropped on a flaky network.

import Foundation
import SwiftData

// MARK: - OutcomeQueueStatus

/// Lifecycle of a queued outcomes POST.
///
/// Stored as `Int` rather than `String` so predicate-less filtering (which
/// SwiftData handles poorly for enums) reads plain integers. The raw values
/// are frozen — changing them would orphan rows persisted under older apps.
enum OutcomeQueueStatus: Int, Codable, Sendable {
    /// Waiting for delivery. Eligible for retry once `nextRetryAt <= now`.
    case pending = 0
    /// Currently in flight. Transitory; persisted so cold-launch recovery
    /// can re-queue stuck rows on relaunch.
    case sending = 1
    /// Server accepted the POST (2xx). Retained for Settings visibility
    /// for 7 days, then swept like any other row past TTL.
    case delivered = 2
    /// Permanent failure — either a non-retryable 4xx, 20 retry attempts
    /// exhausted, or age > 7 days. Surfaced in Settings "Pending Outcomes"
    /// so the user can see what was lost.
    case expired = 3
}

// MARK: - PendingOutcome

/// A single outcomes-POST attempt persisted for retry.
///
/// `id` is a client-side UUID used for dedup at the queue level — NOT an
/// idempotency key against the server (server is append-only per plan).
/// `payload` is the already-serialized JSON body so retries don't need to
/// rebuild the outcomes list from state that may have changed on-device.
@Model
final class PendingOutcome {

    /// Client-side stable identity. Not sent to the server.
    @Attribute(.unique) var id: UUID

    /// Server-assigned photo ID — the path component for
    /// `POST /photos/{id}/outcomes`.
    var photoId: Int

    /// Serialized JSON body. Frozen at enqueue time; retries re-send verbatim.
    var payload: Data

    /// Wall-clock time the row was created. Used for the 7-day TTL sweep.
    var queuedAt: Date

    /// Number of delivery attempts that have failed. 0 on first send;
    /// increments on every non-2xx retry; emitted to the server via
    /// `X-Client-Retry-Count` so backend analytics can quantify offline
    /// pressure.
    var retryCount: Int

    /// Earliest time the manager may retry this row. Mirrors `queuedAt`
    /// on the first attempt (no backoff) and advances by
    /// `OutcomeQueueManager.backoff(retryCount:)` after every failure.
    var nextRetryAt: Date

    /// Lifecycle position — see `OutcomeQueueStatus`.
    var status: OutcomeQueueStatus

    /// Last HTTP status or `URLError.code.rawValue`. Surfaced in the
    /// Settings detail view so users can triage persistent failures.
    var lastErrorCode: Int?

    /// Creates a `.pending` row for immediate delivery.
    ///
    /// - Parameters:
    ///   - photoId: Server-side photo ID from the preceding `/ingest` call.
    ///   - payload: Fully-serialized outcomes JSON body.
    init(photoId: Int, payload: Data) {
        let now = Date()
        self.id = UUID()
        self.photoId = photoId
        self.payload = payload
        self.queuedAt = now
        self.retryCount = 0
        self.nextRetryAt = now
        self.status = .pending
        self.lastErrorCode = nil
    }
}
