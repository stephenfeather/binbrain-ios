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

    /// The API key sent as `X-API-Key` on every request.
    var apiKey: String

    /// Minimum similarity score for search results (0–1). Defaults to `0.5`.
    var similarityThreshold: Double

    /// The result of the most recent connection test.
    ///
    /// Set only by `testConnection(apiClient:)`. Starts as `.unknown`.
    private(set) var connectionStatus: ConnectionStatus = .unknown

    /// In-flight debounce task for `debouncedSave()`. Cancelled on each new call.
    private var saveTask: Task<Void, Never>?

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

    /// Creates a `SettingsViewModel`, loading persisted values from `defaults`.
    ///
    /// - Parameter defaults: The `UserDefaults` suite to read/write. Defaults to `.standard`.
    init(defaults: UserDefaults = .standard) {
        serverURL = defaults.string(forKey: "serverURL") ?? "http://10.1.1.206:8000"
        apiKey = defaults.string(forKey: "apiKey") ?? ""
        let stored = defaults.double(forKey: "similarityThreshold")
        similarityThreshold = stored == 0.0 ? 0.5 : stored
    }

    // MARK: - Actions

    /// Persists `serverURL` and `similarityThreshold` to `defaults`.
    ///
    /// - Parameter defaults: The `UserDefaults` suite to write to. Defaults to `.standard`.
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(serverURL, forKey: "serverURL")
        defaults.set(apiKey, forKey: "apiKey")
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
