// OutcomeState.swift
// Bin Brain
//
// Three-state outcome model used by the Swift2_020 suggestion-review tap
// cycle: ignored (yellow, default) → accepted (green) → rejected (red) →
// ignored. Tapping a row advances `next()`. The wire-format mapping in
// `serverDecision` matches the values the binbrain server's
// `photo_suggestion_outcomes.decision` column accepts.
//
// `Int` raw values let `EditableSuggestion` round-trip the field through
// `Codable` without a custom container, and CaseIterable supports tests.

import Foundation

/// Per-row cataloging outcome surfaced by the three-state tap toggle.
///
/// Behind `outcomeModelEnabled = true` (Swift2_020 default), every row in
/// the suggestion-review screen carries one of these states. Tapping the
/// row chip cycles the value via `next()`.
enum OutcomeState: Int, Codable, CaseIterable, Sendable {
    /// Yellow chip, the spawn state under the three-state model. Items in
    /// this state are NOT upserted on confirm; the `confirmButtonTitle`
    /// surfaces the count so users see what they're about to skip.
    case ignored = 0

    /// Green chip. Item is selected for upsert; the outcome telemetry
    /// classifies it `.accepted` (or `.edited` when the label diverged
    /// from the prefilled value).
    case accepted = 1

    /// Red chip. Item is explicitly skipped from upsert AND emits a
    /// `.rejected` decision in the outcome payload (negative training signal).
    case rejected = 2

    /// Returns the next state in the tap cycle.
    func next() -> OutcomeState {
        switch self {
        case .ignored: return .accepted
        case .accepted: return .rejected
        case .rejected: return .ignored
        }
    }

    /// Wire-format value for `photo_suggestion_outcomes.decision`. Stable
    /// strings — the server's Pydantic enum reads these literally.
    var serverDecision: String {
        switch self {
        case .ignored: return "ignored"
        case .accepted: return "accepted"
        case .rejected: return "rejected"
        }
    }
}
