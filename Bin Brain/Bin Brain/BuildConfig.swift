// BuildConfig.swift
// Bin Brain
//
// Debug-build defaults sourced from `Development.xcconfig` via `Info.plist`
// key substitution. In Release builds (no xcconfig applied) the substituted
// values are empty strings, so the accessors return `nil` and callers must
// chain to a hardcoded fallback.

import Foundation

/// Read-only accessors for Info.plist-baked build defaults.
///
/// The chain that consumers (e.g. `APIClient`) should implement is:
/// `UserDefaults → BuildConfig → hardcoded fallback`.
enum BuildConfig {

    /// The default server URL baked into the bundle, or `nil` if absent/empty.
    static var defaultServerURL: String? { nonEmpty("DefaultServerURL") }

    /// The default API key baked into the bundle, or `nil` if absent/empty.
    static var defaultAPIKey: String? { nonEmpty("DefaultAPIKey") }

    /// Injectable lookup seam for testability. Defaults to `Bundle.main.object(forInfoDictionaryKey:)`.
    ///
    /// Tests substitute a closure over a fixture dictionary; production code
    /// leaves this alone.
    static var lookup: (String) -> Any? = { key in
        Bundle.main.object(forInfoDictionaryKey: key)
    }

    /// Returns the string value at `key` trimmed of surrounding whitespace,
    /// or `nil` when the key is missing, non-string, empty, or whitespace-only.
    static func nonEmpty(_ key: String) -> String? {
        guard let raw = lookup(key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
