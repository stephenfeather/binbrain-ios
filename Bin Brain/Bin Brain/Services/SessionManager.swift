// SessionManager.swift
// Bin Brain
//
// Swift2_019 — owns the server-minted cataloging-session lifecycle.
// Server PR #35 made `session_id` validation strict on `/ingest`; this
// class is the single source of truth for the current session UUID,
// transparently opens one on first ingest, and auto-closes after 30 min
// of inactivity.
//
// Deliberately lean: no offline-queue integration yet. End-session
// failures log and clear state locally; the server's open-session
// sweep catches anything we don't explicitly close. Swift2_018b can
// plug a SessionCloseQueue in later if telemetry shows abandoned rows.

import Foundation
import OSLog
import Observation

private let logger = Logger(subsystem: "com.binbrain.app", category: "SessionManager")

// MARK: - SessionManager

/// Main-actor singleton that tracks the active `Session`. Views and
/// view-models read `current` to plumb `session_id` into `/ingest`; the
/// idle timer closes the session after 30 min of no `noteActivity` calls.
@MainActor
@Observable
final class SessionManager {

    // MARK: - Observable state

    /// Server-returned session that outbound ingests should join.
    /// Nil between sessions.
    private(set) var current: Session?

    // MARK: - Configuration

    /// Seconds of inactivity before the session auto-closes. Production
    /// default is 30 min; tests pass a tiny value to exercise the fire.
    let idleTimeout: TimeInterval

    // MARK: - Private

    /// Cancellable auto-close task. Any call to `noteActivity` cancels
    /// the existing task and schedules a fresh one.
    private var idleTask: Task<Void, Never>?

    /// In-flight `beginSession` memoization (Swift2_019b / SEC-24-2).
    /// Concurrent `activeSessionId` callers see this value and await the
    /// same Task instead of each firing their own `POST /sessions`.
    /// Main-actor isolation guarantees the `beginTask = task` assignment
    /// and the first-reader `if let beginTask` check serialize correctly
    /// — no lock needed.
    private var beginTask: Task<Session, Error>?

    // MARK: - Init

    init(idleTimeout: TimeInterval = 30 * 60) {
        self.idleTimeout = idleTimeout
    }

    // MARK: - Lifecycle

    /// Creates a new session on the server and stores it as `current`.
    /// Arms the idle timer so inactive clients don't leak open sessions.
    @discardableResult
    func beginSession(label: String? = nil, apiClient: APIClient) async throws -> Session {
        let session = try await apiClient.createSession(label: label)
        current = session
        scheduleIdleAutoClose(apiClient: apiClient)
        return session
    }

    /// Fire-and-forget close. Returns when the network call completes
    /// (or fails). 404 / 410 / transport errors all clear `current`
    /// because the server side is either gone or will be cleaned up by
    /// the idle-sweep — forcing the user to stare at a spinner on a
    /// best-effort close is worse than the rare orphaned row.
    func endSession(apiClient: APIClient) async {
        cancelIdleTimer()
        guard let session = current else { return }
        do {
            _ = try await apiClient.endSession(id: session.id)
        } catch {
            logger.error("[SESSION] close failed: \(error.localizedDescription, privacy: .private) — clearing local state anyway")
        }
        current = nil
    }

    /// Reset the idle timer. Call from photo capture, confirm tap, any
    /// user-initiated activity that means "still actively cataloging".
    func noteActivity(apiClient: APIClient) {
        guard current != nil else { return }
        scheduleIdleAutoClose(apiClient: apiClient)
    }

    /// Clears `current` without calling the server. Intended for the
    /// `invalid_session` 400 path — the server already told us the row
    /// is gone, so any DELETE would just 404.
    func invalidateCurrentSession() {
        cancelIdleTimer()
        current = nil
    }

    // MARK: - Convenience

    /// Returns the active session id, opening a fresh session if there
    /// isn't one yet. Use at every ingest call site so the "first photo
    /// after app launch" path doesn't require the user to tap anything.
    ///
    /// Swift2_019b / SEC-24-2 — concurrent callers hitting this while
    /// `current == nil` previously raced: both passed the gate, both
    /// awaited `beginSession`, both POSTed `/sessions` — orphaning
    /// sessions against the server's 20-open cap. Now each concurrent
    /// caller awaits the same memoized `beginTask`.
    func activeSessionId(apiClient: APIClient) async throws -> UUID {
        if let existing = current {
            return existing.id
        }
        if let inflight = beginTask {
            return try await inflight.value.id
        }
        let task = Task<Session, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.beginSession(apiClient: apiClient)
        }
        beginTask = task
        defer { beginTask = nil }
        return try await task.value.id
    }

    // MARK: - Idle timer

    /// Cancels any pending auto-close. Exposed internal so tests can
    /// tear the timer down in `tearDown` without leaking Tasks into the
    /// next test.
    func cancelIdleTimer() {
        idleTask?.cancel()
        idleTask = nil
    }

    private func scheduleIdleAutoClose(apiClient: APIClient) {
        idleTask?.cancel()
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            let nanos = UInt64(max(0, timeout) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await self?.endSession(apiClient: apiClient)
        }
    }
}
