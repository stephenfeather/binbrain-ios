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
///
/// `begin` and `end` call `UIApplication.shared` synchronously, so the Swift
/// compiler infers them (and the class) as `@MainActor`. The `init()` is
/// explicitly `nonisolated` so instances can be created as stored-property
/// defaults and in test contexts without requiring a main-actor hop.
final class UIApplicationBackgroundTaskRunner: BackgroundTaskRunning, @unchecked Sendable {
    nonisolated init() {}

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
