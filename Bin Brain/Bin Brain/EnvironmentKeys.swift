// EnvironmentKeys.swift
// Bin Brain
//
// Centralised @Environment key definitions for dependency injection.
// All services are injected at the app root (Bin_BrainApp) and consumed
// throughout the view hierarchy via @Environment.

import SwiftUI

// MARK: - APIClient

struct APIClientKey: EnvironmentKey {
    static let defaultValue = APIClient()
}

extension EnvironmentValues {
    /// The shared `APIClient` instance injected via the environment.
    var apiClient: APIClient {
        get { self[APIClientKey.self] }
        set { self[APIClientKey.self] = newValue }
    }
}

// MARK: - UploadQueueManager

struct UploadQueueManagerKey: EnvironmentKey {
    static let defaultValue = UploadQueueManager()
}

extension EnvironmentValues {
    /// The shared `UploadQueueManager` instance injected via the environment.
    var uploadQueueManager: UploadQueueManager {
        get { self[UploadQueueManagerKey.self] }
        set { self[UploadQueueManagerKey.self] = newValue }
    }
}

// MARK: - Embedded in Split View

struct EmbeddedInSplitViewKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the view is embedded in a `NavigationSplitView` detail pane.
    ///
    /// When `true`, child views should skip creating their own `NavigationStack`
    /// because the split view's detail column already provides one.
    var embeddedInSplitView: Bool {
        get { self[EmbeddedInSplitViewKey.self] }
        set { self[EmbeddedInSplitViewKey.self] = newValue }
    }
}

// MARK: - ToastViewModel

struct ToastViewModelKey: EnvironmentKey {
    static let defaultValue = ToastViewModel()
}

extension EnvironmentValues {
    /// The shared `ToastViewModel` used to surface transient user-facing messages.
    ///
    /// Injected by `RootView`. Child views read this to post toasts
    /// (e.g. partial background-failure notices) without instantiating their own.
    var toast: ToastViewModel {
        get { self[ToastViewModelKey.self] }
        set { self[ToastViewModelKey.self] = newValue }
    }
}

// MARK: - ServerMonitor

struct ServerMonitorKey: EnvironmentKey {
    static let defaultValue = ServerMonitor()
}

extension EnvironmentValues {
    /// The shared `ServerMonitor` instance injected via the environment.
    var serverMonitor: ServerMonitor {
        get { self[ServerMonitorKey.self] }
        set { self[ServerMonitorKey.self] = newValue }
    }
}
