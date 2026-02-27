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
