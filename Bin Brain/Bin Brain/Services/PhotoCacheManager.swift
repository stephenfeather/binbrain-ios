// PhotoCacheManager.swift
// Bin Brain
//
// Owns the URLCache used by URLSession.shared for `/photos/{id}/file`
// responses. Server now sends `Cache-Control: immutable` on photo
// payloads, so a generously-sized URLCache lets thumbnails and
// fullscreen photos render instantly on revisit. The disk capacity
// is user-tunable via Settings.

import Foundation

enum PhotoCacheManager {

    /// `UserDefaults` key for the disk capacity in MB.
    static let userDefaultsKey = "photoDiskCacheMB"

    /// Default disk capacity when no preference has been written yet.
    /// 200 MB is generous for a thumbnail-heavy bin grid without
    /// dominating the device's free space.
    static let defaultDiskCapacityMB = 200

    /// Memory cap. Small relative to disk because URLCache memory is
    /// scrubbed aggressively under pressure; the disk tier is what
    /// survives between launches.
    static let memoryCapacityBytes = 16 * 1024 * 1024

    /// Available picker options surfaced in Settings. `0` means "off".
    static let availableDiskCapacityChoicesMB: [Int] = [0, 50, 200, 500, 1000]

    /// Reads the persisted disk capacity (or the default) and installs
    /// a fresh `URLCache.shared` with that capacity. Call once at app
    /// startup, before any `URLSession.shared` request goes out, so
    /// every photo fetch sees the configured cache.
    static func applyFromUserDefaults() {
        let stored = UserDefaults.standard.object(forKey: userDefaultsKey) as? Int
        let mb = stored ?? defaultDiskCapacityMB
        applyDiskCapacity(mb: mb)
    }

    /// Installs a new `URLCache.shared` with the given disk capacity.
    /// Pass `0` to effectively disable caching (server responses are
    /// no longer stored). Negative values are clamped to `0`.
    static func applyDiskCapacity(mb: Int) {
        let diskBytes = max(0, mb) * 1024 * 1024
        URLCache.shared = URLCache(
            memoryCapacity: memoryCapacityBytes,
            diskCapacity: diskBytes,
            directory: nil
        )
    }

    /// Persists the new capacity AND installs a fresh `URLCache.shared`.
    /// Existing cached entries do not survive the swap — a capacity
    /// change behaves like a clear, which is the safe default.
    static func setDiskCapacity(mb: Int) {
        UserDefaults.standard.set(mb, forKey: userDefaultsKey)
        applyDiskCapacity(mb: mb)
    }

    /// Drops every cached response without changing capacity.
    static func clear() {
        URLCache.shared.removeAllCachedResponses()
    }

    /// Current disk usage in bytes — used by the Settings UI to show
    /// "X MB of Y MB" to the user.
    static var currentDiskUsageBytes: Int { URLCache.shared.currentDiskUsage }

    /// Configured disk capacity in bytes.
    static var diskCapacityBytes: Int { URLCache.shared.diskCapacity }
}
