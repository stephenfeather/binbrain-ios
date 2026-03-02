// SettingsViewModel.swift
// Bin Brain
//
// ViewModel for the Settings screen.
// Manages server URL, similarity threshold, and connection testing.

import Foundation
import Observation

// MARK: - ConnectionStatus

/// Represents the result of a connection test to the backend.
enum ConnectionStatus: Equatable {
    /// No test has been run yet, or a test is in progress.
    case unknown
    /// The health check succeeded.
    case ok
    /// The health check failed or the server was unreachable.
    case failed
}

// MARK: - SettingsViewModel

/// Manages state and actions for the Settings screen.
///
/// Inject `SettingsViewModel` as a `@State` property in `SettingsView`.
/// Reads and writes persisted values via `UserDefaults`, with
/// dependency injection for testability.
@Observable
final class SettingsViewModel {

    // MARK: - State

    /// The backend server URL (e.g. `https://raspberrypi.local:8000`).
    var serverURL: String

    /// Minimum similarity score for search results (0–1). Defaults to `0.5`.
    var similarityThreshold: Double

    /// The result of the most recent connection test.
    ///
    /// Set only by `testConnection(apiClient:)`. Starts as `.unknown`.
    private(set) var connectionStatus: ConnectionStatus = .unknown

    /// In-flight debounce task for `debouncedSave()`. Cancelled on each new call.
    private var saveTask: Task<Void, Never>?

    // MARK: - Initializer

    /// Creates a `SettingsViewModel`, loading persisted values from `defaults`.
    ///
    /// - Parameter defaults: The `UserDefaults` suite to read/write. Defaults to `.standard`.
    init(defaults: UserDefaults = .standard) {
        serverURL = defaults.string(forKey: "serverURL") ?? "http://10.1.1.206:8000"
        let stored = defaults.double(forKey: "similarityThreshold")
        similarityThreshold = stored == 0.0 ? 0.5 : stored
    }

    // MARK: - Actions

    /// Persists `serverURL` and `similarityThreshold` to `defaults`.
    ///
    /// - Parameter defaults: The `UserDefaults` suite to write to. Defaults to `.standard`.
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(serverURL, forKey: "serverURL")
        defaults.set(similarityThreshold, forKey: "similarityThreshold")
    }

    /// Schedules a debounced save after a 0.5-second pause.
    ///
    /// Each call cancels the previous pending save, so only the final
    /// value after typing stops is persisted. Safe to call from `@MainActor`.
    ///
    /// - Parameter defaults: The `UserDefaults` suite to write to. Defaults to `.standard`.
    func debouncedSave(to defaults: UserDefaults = .standard) {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save(to: defaults)
        }
    }

    /// Tests the connection to the backend and updates `connectionStatus`.
    ///
    /// Resets `connectionStatus` to `.unknown` before the network call.
    /// Sets `.ok` on success, `.failed` on any error.
    ///
    /// - Parameter apiClient: The `APIClient` used to call `GET /health`.
    func testConnection(apiClient: APIClient) async {
        connectionStatus = .unknown
        do {
            _ = try await apiClient.health()
            connectionStatus = .ok
        } catch {
            connectionStatus = .failed
        }
    }
}
