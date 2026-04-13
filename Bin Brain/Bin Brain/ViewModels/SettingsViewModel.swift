// SettingsViewModel.swift
// Bin Brain
//
// ViewModel for the Settings screen.
// Manages server URL, similarity threshold, and connection testing.

import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "com.binbrain.app", category: "Settings")

// MARK: - ConnectionStatus

/// Represents the result of a connection test to the backend.
enum ConnectionStatus: Equatable {
    /// No test has been run yet, or a test is in progress.
    case unknown
    /// The server is reachable and the configured API key was accepted.
    case connected(role: HealthResponse.Role)
    /// The server is reachable but rejected the configured API key.
    case connectedKeyInvalid
    /// The server is reachable but no API key is configured (or sent).
    case connectedNoKey
    /// The request failed (network error, non-2xx status, decoding error).
    case unreachable(errorMessage: String)
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

    /// The API key sent as `X-API-Key` on every request.
    var apiKey: String

    /// Minimum similarity score for search results (0–1). Defaults to `0.5`.
    var similarityThreshold: Double

    /// The result of the most recent connection test.
    ///
    /// Set only by `testConnection(apiClient:)`. Starts as `.unknown`.
    private(set) var connectionStatus: ConnectionStatus = .unknown

    /// Localized error description from the most recent failed connection test,
    /// or `nil` if the last test succeeded (or none has been run).
    private(set) var connectionErrorMessage: String?

    /// In-flight debounce task for `debouncedSave()`. Cancelled on each new call.
    private var saveTask: Task<Void, Never>?

    /// Keychain facade used to persist `apiKey`. Injected for testability.
    private let keychain: KeychainReading

    // MARK: - Image Size State

    /// The current max image dimension (longest side in pixels) for vision inference.
    ///
    /// Writable so the slider can update the local value before committing to the server.
    var maxImagePx: Int = 1280

    /// Whether the image size is currently being loaded or saved.
    private(set) var isLoadingImageSize: Bool = false

    /// Error message from the last image size operation, if any.
    private(set) var imageSizeError: String?

    // MARK: - Model State

    /// Available Ollama models on the server.
    private(set) var availableModels: [OllamaModel] = []

    /// The currently active vision model name.
    private(set) var activeModel: String = ""

    /// Whether models are being loaded or switched.
    private(set) var isLoadingModels: Bool = false

    /// Whether a model switch is in progress (can take 5–30 s).
    private(set) var isSwitchingModel: Bool = false

    /// Error message from the last model operation, if any.
    private(set) var modelError: String?

    // MARK: - Initializer

    /// Creates a `SettingsViewModel`, loading persisted values from `defaults`
    /// and the API key from `keychain`.
    ///
    /// - Parameters:
    ///   - defaults: The `UserDefaults` suite for non-secret settings. Defaults to `.standard`.
    ///   - keychain: The Keychain facade for the API key. Defaults to `KeychainHelper.shared`.
    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainReading = KeychainHelper.shared
    ) {
        self.keychain = keychain
        serverURL = defaults.string(forKey: "serverURL") ?? "http://10.1.1.206:8000"
        apiKey = keychain.readString(forKey: KeychainHelper.apiKeyAccount) ?? ""
        // Use object(forKey:) so a user-set value of 0 is distinguishable from "never set".
        // double(forKey:) returns 0 for both cases, which conflates them.
        similarityThreshold = defaults.object(forKey: "similarityThreshold") as? Double ?? 0.5
    }

    // MARK: - Actions

    /// Persists `serverURL` and `similarityThreshold` to `defaults`, and
    /// `apiKey` to the Keychain.
    ///
    /// An empty `apiKey` removes the Keychain entry so the API client falls
    /// back to `BuildConfig.defaultAPIKey` (if any) or `nil`.
    ///
    /// - Parameter defaults: The `UserDefaults` suite to write to. Defaults to `.standard`.
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(serverURL, forKey: "serverURL")
        defaults.set(similarityThreshold, forKey: "similarityThreshold")
        if apiKey.isEmpty {
            try? keychain.removeValue(forKey: KeychainHelper.apiKeyAccount)
        } else {
            try? keychain.writeString(apiKey, forKey: KeychainHelper.apiKeyAccount)
        }
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
    /// Resets `connectionStatus` to `.unknown` before the network call, then
    /// maps the server's `auth_ok` field to one of:
    /// - `.connected(role:)` when `auth_ok == true`,
    /// - `.connectedKeyInvalid` when `auth_ok == false`,
    /// - `.connectedNoKey` when `auth_ok` is absent,
    /// - `.unreachable(errorMessage:)` on any thrown error (also populates
    ///   `connectionErrorMessage`).
    ///
    /// - Parameter apiClient: The `APIClient` used to call `GET /health`.
    func testConnection(apiClient: APIClient) async {
        connectionStatus = .unknown
        connectionErrorMessage = nil
        do {
            let response = try await apiClient.health()
            switch response.authOk {
            case .some(true):
                // Server docs guarantee `role` is present when authOk is true.
                // If the server omits it, fall back to `.user` to keep the UI coherent.
                connectionStatus = .connected(role: response.role ?? .user)
            case .some(false):
                connectionStatus = .connectedKeyInvalid
            case .none:
                connectionStatus = .connectedNoKey
            }
        } catch {
            logger.error("testConnection failed: \(error.localizedDescription, privacy: .private)")
            connectionStatus = .unreachable(errorMessage: error.localizedDescription)
            connectionErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Image Size Actions

    /// Fetches the current image size setting from the server.
    func loadImageSize(apiClient: APIClient) async {
        isLoadingImageSize = true
        imageSizeError = nil
        do {
            let response = try await apiClient.getImageSize()
            maxImagePx = response.maxImagePx
        } catch {
            imageSizeError = error.localizedDescription
        }
        isLoadingImageSize = false
    }

    /// Updates the max image size on the server.
    ///
    /// - Parameter value: Max longest side in pixels (128–4096).
    func setImageSize(_ value: Int, apiClient: APIClient) async {
        isLoadingImageSize = true
        imageSizeError = nil
        do {
            let response = try await apiClient.setImageSize(value)
            maxImagePx = response.maxImagePx
        } catch {
            imageSizeError = error.localizedDescription
        }
        isLoadingImageSize = false
    }

    // MARK: - Model Actions

    /// Fetches available models and the active model from the server.
    func loadModels(apiClient: APIClient) async {
        isLoadingModels = true
        modelError = nil
        do {
            let response = try await apiClient.listModels()
            availableModels = response.models
            activeModel = response.activeModel
        } catch {
            modelError = error.localizedDescription
        }
        isLoadingModels = false
    }

    /// Selects a new vision model on the server.
    ///
    /// Blocks until the model is warmed up (typically 5–30 s).
    ///
    /// - Parameter model: The model name to switch to.
    func selectModel(_ model: String, apiClient: APIClient) async {
        isSwitchingModel = true
        modelError = nil
        do {
            let response = try await apiClient.selectModel(model)
            activeModel = response.activeModel
        } catch {
            modelError = error.localizedDescription
        }
        isSwitchingModel = false
    }
}
