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
    /// The server is reachable and a key exists in the Keychain, but
    /// that key is bound to a different host than `serverURL`.
    ///
    /// `canRebind` reflects whether the current state allows the UI to
    /// offer a "Re-bind key to this host" action (always `true` when a
    /// key is present; kept as an associated value for future UX gating).
    case connectedKeyNotBoundToHost(canRebind: Bool)
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

    /// Name of the model the user most recently tapped while `isSwitchingModel`
    /// is true. Drives the inline spinner in `SettingsView` so the progress
    /// indicator lives next to the tapped row instead of at the section bottom
    /// (Finding #9).
    private(set) var selectingModelId: String?

    /// Tick counter that increments each time `selectModel` succeeds. Views
    /// observe the change to fire a haptic + toast. Using a tick avoids having
    /// to reset a Bool; each increment is a distinct successful event.
    private(set) var modelSelectSuccessTick: Int = 0

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
        serverURL = defaults.string(forKey: "serverURL")
            ?? BuildConfig.defaultServerURL
            ?? "http://10.1.1.206:8000"
        apiKey = keychain.readString(forKey: KeychainHelper.apiKeyAccount)
            ?? BuildConfig.defaultAPIKey
            ?? ""
        // Use object(forKey:) so a user-set value of 0 is distinguishable from "never set".
        // double(forKey:) returns 0 for both cases, which conflates them.
        similarityThreshold = defaults.object(forKey: "similarityThreshold") as? Double ?? 0.5
    }

    // MARK: - Actions

    /// Persists `serverURL` and `similarityThreshold` to `defaults`.
    ///
    /// Does NOT write the API key — that flows through `commitAPIKey()` on
    /// explicit user commit (blur, Return, or clear). See F-12 / #11:
    /// debounced persistence of a credential while the user is still typing
    /// creates Keychain churn and races the bound-host write from #13.
    ///
    /// - Parameter defaults: The `UserDefaults` suite to write to. Defaults to `.standard`.
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(serverURL, forKey: "serverURL")
        defaults.set(similarityThreshold, forKey: "similarityThreshold")
    }

    /// Persists the current `apiKey` (with its bound host) to the Keychain.
    ///
    /// Call on explicit user commit only: field blur, Return/Done submit,
    /// or an explicit Save/Clear action. Never from debounced typing.
    ///
    /// Binding rules (F-04 / #13):
    /// - Clearing the key removes both `apiKey` and `apiKeyBoundHost` so
    ///   the next network call falls through the attach gate cleanly.
    /// - Setting a non-empty key requires a parseable `serverURL`; the
    ///   origin is recorded in `apiKeyBoundHost`. Writes are atomic:
    ///   if the bound-host write fails, the key is rolled back so an
    ///   unbound key is never persisted.
    /// - An unparseable `serverURL` silently skips the key write — the
    ///   UI surfaces the parse failure elsewhere and the existing key is
    ///   left untouched.
    func commitAPIKey() {
        if apiKey.isEmpty {
            try? keychain.clearAPIKeyBinding()
            return
        }
        guard let origin = APIClient.normalizedOrigin(of: serverURL) else {
            logger.warning("Skipping apiKey commit: serverURL has no parseable origin")
            return
        }
        do {
            try keychain.writeAPIKeyBinding(key: apiKey, boundHost: origin)
        } catch {
            logger.error("apiKey binding write failed: \(error.localizedDescription, privacy: .public)")
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
                // `/health` reached the server but no key was sent. Two sub-cases:
                // (a) user has no key → `.connectedNoKey`.
                // (b) user has a key bound to a different host → the attach gate
                //     stripped the header → `.connectedKeyNotBoundToHost`.
                connectionStatus = keyExistsButUnboundForCurrentHost()
                    ? .connectedKeyNotBoundToHost(canRebind: true)
                    : .connectedNoKey
            }
        } catch {
            logger.error("testConnection failed: \(error.localizedDescription, privacy: .private)")
            let friendly = Self.friendlyConnectionErrorMessage(for: error)
            connectionStatus = .unreachable(errorMessage: friendly)
            connectionErrorMessage = friendly
        }
    }

    /// Maps a thrown connection error to user-facing copy.
    ///
    /// Exposed `static` so tests can validate the mapping without standing
    /// up an APIClient. Handles ATS (-1022), host-not-found (-1003), and
    /// cannot-connect (-1004) explicitly; falls back to the system's
    /// `localizedDescription` for unknown codes (Finding #10).
    static func friendlyConnectionErrorMessage(for error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return error.localizedDescription
        }
        switch nsError.code {
        case NSURLErrorAppTransportSecurityRequiresSecureConnection: // -1022
            return "That host isn't allowed by this build. Use a whitelisted host, or rebuild with it added to Info-Debug.plist."
        case NSURLErrorCannotFindHost: // -1003
            return "Host not found on this network."
        case NSURLErrorCannotConnectToHost: // -1004
            return "Host reachable but connection refused."
        case NSURLErrorTimedOut: // -1001
            return "Connection timed out. Check that the server is running and reachable from this network."
        case NSURLErrorNotConnectedToInternet: // -1009
            return "No network connection."
        default:
            return error.localizedDescription
        }
    }

    /// Re-binds the existing Keychain API key to the current `serverURL`.
    ///
    /// Sends a `/health` probe with the key attached regardless of the
    /// current binding. On `auth_ok: true`, the key is valid for this host
    /// and we persist the new binding. On `auth_ok: false`, the key isn't
    /// valid for this host either — don't touch the binding; surface a
    /// `.connectedKeyInvalid` so the user re-enters.
    ///
    /// Only meaningful when `connectionStatus == .connectedKeyNotBoundToHost`.
    ///
    /// - Parameter apiClient: The `APIClient` used to probe `/health`.
    func rebindKey(apiClient: APIClient) async {
        connectionErrorMessage = nil
        do {
            let response = try await apiClient.health(probeWithCurrentKey: true)
            switch response.authOk {
            case .some(true):
                guard let origin = APIClient.normalizedOrigin(of: serverURL) else {
                    connectionStatus = .unreachable(errorMessage: "Server URL has no parseable origin")
                    return
                }
                do {
                    try keychain.writeString(origin, forKey: KeychainHelper.boundHostAccount)
                    connectionStatus = .connected(role: response.role ?? .user)
                } catch {
                    logger.error("rebind write failed: \(error.localizedDescription, privacy: .public)")
                    connectionStatus = .unreachable(errorMessage: error.localizedDescription)
                    connectionErrorMessage = error.localizedDescription
                }
            case .some(false):
                connectionStatus = .connectedKeyInvalid
            case .none:
                // Probe was supposed to send the key. If the server still
                // reports no key, treat it as invalid for this host.
                connectionStatus = .connectedKeyInvalid
            }
        } catch {
            logger.error("rebindKey failed: \(error.localizedDescription, privacy: .private)")
            connectionStatus = .unreachable(errorMessage: error.localizedDescription)
            connectionErrorMessage = error.localizedDescription
        }
    }

    /// Returns true when the Keychain holds an API key whose bound host
    /// does not match the normalized origin of the current `serverURL`
    /// (including the "bound host missing entirely" sub-case).
    private func keyExistsButUnboundForCurrentHost() -> Bool {
        guard let key = keychain.readString(forKey: KeychainHelper.apiKeyAccount),
              !key.isEmpty else {
            return false
        }
        let bound = keychain.readString(forKey: KeychainHelper.boundHostAccount)
        let current = APIClient.normalizedOrigin(of: serverURL)
        return bound != current
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
        selectingModelId = model
        modelError = nil
        do {
            let response = try await apiClient.selectModel(model)
            activeModel = response.activeModel
            modelSelectSuccessTick &+= 1
        } catch {
            modelError = error.localizedDescription
        }
        isSwitchingModel = false
        selectingModelId = nil
    }
}
