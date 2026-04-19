// Bin_BrainApp.swift
// Bin Brain

import OSLog
import SwiftUI
import SwiftData
import UserNotifications

private let logger = Logger(subsystem: "com.binbrain.app", category: "App")

@main
struct Bin_BrainApp: App {

    // MARK: - Scene Phase

    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Services

    @State private var apiClient = APIClient()
    @State private var uploadQueueManager = UploadQueueManager()
    @State private var outcomeQueueManager = OutcomeQueueManager()
    @State private var sessionManager = SessionManager()
    @State private var serverMonitor = ServerMonitor()

    // MARK: - Initializer

    init() {
        // One-time migration of the API key out of UserDefaults into Keychain.
        // Idempotent — safe to run on every cold start.
        KeychainHelper.migrateAPIKeyFromUserDefaultsIfNeeded()
        // Back-fill apiKeyBoundHost for installs that predate host binding (#13).
        // Must run after the apiKey migration because it reads that entry.
        KeychainHelper.migrateAPIKeyBoundHostIfNeeded()
        #if DEBUG
        // DEBUG-only DX: seed the API key from BuildConfig when the Keychain
        // is empty (fresh install / simulator reset). Compiled out of Release.
        KeychainHelper.seedDebugAPIKeyFromBuildConfigIfNeeded()
        #endif
        // Apply complete file protection to the SwiftData store so queued
        // pending uploads are unreadable when the device is locked (#9, F-08).
        Self.applyFileProtection(to: sharedModelContainer)
    }

    // MARK: - SwiftData

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            PendingUpload.self,
            PendingAnalysis.self,
            PendingOutcome.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    // MARK: - Scene

    var body: some Scene {
        WindowGroup {
            RootView()
                .task { await requestNotificationPermission() }
                .task {
                    // Swift2_018b F-1 — reclaim any rows left `.sending`
                    // by a previous process that crashed mid-POST. Must
                    // run BEFORE the first drain; `startMonitoring` may
                    // trigger a drain via NWPathMonitor immediately.
                    outcomeQueueManager.reclaimOrphanedSendingRows(
                        context: sharedModelContainer.mainContext
                    )
                    // Swift2_018 — start NWPathMonitor + foreground observer
                    // for the outcomes queue so retries fire automatically
                    // on connectivity recovery. Idempotent.
                    outcomeQueueManager.startMonitoring(
                        context: sharedModelContainer.mainContext,
                        apiClient: apiClient
                    )
                }
                .environment(\.apiClient, apiClient)
                .environment(\.uploadQueueManager, uploadQueueManager)
                .environment(\.outcomeQueueManager, outcomeQueueManager)
                .environment(\.sessionManager, sessionManager)
                .environment(\.serverMonitor, serverMonitor)
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await serverMonitor.check(using: apiClient)
                await uploadQueueManager.drain(
                    context: sharedModelContainer.mainContext,
                    using: apiClient
                )
                await outcomeQueueManager.drain(
                    context: sharedModelContainer.mainContext,
                    apiClient: apiClient
                )
            }
        }
    }

    // MARK: - Private

    /// Requests notification authorization on first launch.
    ///
    /// Called once via `.task` on the root view. The result is discarded
    /// because the app degrades gracefully if the user declines.
    private func requestNotificationPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            )
            if !granted {
                logger.info("User declined notification permission")
            }
        } catch {
            logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Applies `.completeFileProtection` to the SwiftData store file and its
    /// SQLite WAL/SHM siblings. Idempotent and safe to call on every launch.
    ///
    /// File protection only enforces on a locked device, but the attribute is
    /// persisted and readable in tests. Failures log but do not crash, since
    /// the sidecar files may not exist on first launch.
    static func applyFileProtection(to container: ModelContainer) {
        guard let storeURL = container.configurations.first?.url else {
            logger.error("[SwiftData] could not resolve store URL for file protection")
            return
        }
        let parent = storeURL.deletingLastPathComponent()
        let base = storeURL.lastPathComponent
        let urls = [
            storeURL,
            parent.appendingPathComponent("\(base)-wal"),
            parent.appendingPathComponent("\(base)-shm"),
        ]
        let fileManager = FileManager.default
        for url in urls where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: url.path
                )
            } catch {
                logger.error("[SwiftData] failed to set file protection on \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)")
            }
        }
    }
}
