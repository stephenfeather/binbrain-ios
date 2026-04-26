// Sessions.swift
// Bin Brain
//
// DTOs for the /sessions endpoints.

import Foundation

// MARK: - Sessions

/// A server-minted cataloging session. `Swift2_019` — the client requests one
/// from `POST /sessions`, plumbs `session_id` through every photo ingest, and
/// closes it via `DELETE /sessions/{session_id}` when the user is done or the
/// 30-min idle timer fires.
struct Session: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date?
    let label: String?
    let photoCount: Int

    enum CodingKeys: String, CodingKey {
        case id = "session_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case label
        case photoCount = "photo_count"
    }
}
