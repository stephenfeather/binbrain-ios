// ServerMonitor.swift
// Bin Brain
//
// Lightweight health-check observer. Views bind to `isReachable` to show
// connectivity banners. Call `check(using:)` on scene foreground transitions.

import Foundation
import Observation

// MARK: - ServerMonitor

/// Tracks whether the Bin Brain backend is currently reachable.
///
/// Inject via `@Environment` and call `check(using:)` from the scene lifecycle
/// (`onChange(of: scenePhase)`) whenever the app returns to the foreground.
/// Views observe `isReachable` to show or hide connectivity banners.
@Observable
final class ServerMonitor {

    // MARK: - Properties

    /// Whether the server responded successfully to the last health check.
    ///
    /// Starts `false` and is updated each time `check(using:)` is called.
    private(set) var isReachable: Bool = false

    // MARK: - Public API

    /// Checks server health and updates `isReachable`.
    ///
    /// Calls `apiClient.health()` and sets `isReachable` to `true` on a
    /// successful response, or `false` on any error — including network
    /// failures, timeouts, and non-2xx status codes. This method never throws.
    ///
    /// - Parameter apiClient: The client used to perform the health check request.
    func check(using apiClient: APIClient) async {
        do {
            _ = try await apiClient.health()
            isReachable = true
        } catch {
            isReachable = false
        }
    }
}
