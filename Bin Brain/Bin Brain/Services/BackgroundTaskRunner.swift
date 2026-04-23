// BackgroundTaskRunner.swift
// Bin Brain
//
// Injectable shim around UIApplication.beginBackgroundTask so AnalysisViewModel
// can be tested for Finding #15 — verify endBackgroundTask fires on every
// terminal path of the analysis pipeline (success, ingest error, suggest error,
// quality-gate failure, early return).

import Foundation
import UIKit

/// Minimal lifecycle contract for a background task.
protocol BackgroundTaskRunning: AnyObject, Sendable {
    /// Begins a background task. Returns an opaque identifier usable with `end(_:)`.
    /// `expirationHandler` is invoked by the OS if the grant runs out.
    func begin(name: String, expirationHandler: @escaping @Sendable () -> Void) -> Int

    /// Ends the background task identified by `id`. Safe to call with any
    /// value; implementations must be idempotent.
    func end(_ id: Int)
}

/// Production impl — routes directly to `UIApplication.shared`.
final class UIApplicationBackgroundTaskRunner: BackgroundTaskRunning, @unchecked Sendable {
    func begin(name: String, expirationHandler: @escaping @Sendable () -> Void) -> Int {
        let raw = UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expirationHandler)
        return raw.rawValue
    }

    func end(_ id: Int) {
        let identifier = UIBackgroundTaskIdentifier(rawValue: id)
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
