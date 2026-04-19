// BinNameValidator.swift
// Bin Brain
//
// Pre-flight UX guard for bin names that the server reserves for its own
// sentinels. Mirrors the server's casefolded reserved set (ApiDev_011,
// HTTP 400 with error code `reserved_bin_name`) so the user gets an inline
// error without a network round-trip when they enter or scan one of these.

import Foundation

// MARK: - BinNameValidator

/// Pure validator for user-supplied bin names.
///
/// The server is the authority on reserved names. This struct mirrors the
/// server's set so iOS can reject before dispatching the request and surface
/// a friendlier message than the raw HTTP error path.
struct BinNameValidator {

    /// Canonical reserved names — kept in sync with the server's casefolded
    /// set (ApiDev_011). If a new reserved name is added on the server side,
    /// mirror it here too. Server is authoritative; this set exists only to
    /// avoid a guaranteed-failure round-trip on the client.
    static let reservedNames: Set<String> = ["unassigned", "binless"]

    /// Returns `true` if `raw`, after whitespace-trim and ASCII-lowercase,
    /// matches a reserved bin name. Empty / whitespace-only inputs return
    /// `false` — those fail other validators (e.g. the QR pattern check)
    /// for unrelated reasons.
    static func isReserved(_ raw: String) -> Bool {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return reservedNames.contains(normalized)
    }

    /// User-facing copy used both pre-flight (scanner / form) and as the
    /// remap target when the server's `reserved_bin_name` error somehow
    /// reaches the ingest path. Single source of truth so the message stays
    /// identical on both code paths.
    static func friendlyMessage(for raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return "'\(trimmed)' is a reserved name. Please choose a different bin name."
    }
}
