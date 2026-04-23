// Bin_BrainApp.swift
// Bin Brain

import OSLog
import SwiftUI
import SwiftData
import UserNotifications

private let logger = Logger(subsystem: "com.binbrain.app", category: "App")
private let appSignposter = OSSignposter(subsystem: "com.binbrain.app", category: "AppLifecycle")

@main
struct Bin_BrainApp: App {

    // MARK: - Startup State

    @State private var didRunPostLaunchSetup = false

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
        let spid = appSignposter.makeSignpostID()
        let startupInterval = appSignposter.beginInterval("app_startup", id: spid)
        // One-time migration of the API key out of UserDefaults into Keychain.
        // Idempotent — safe to run on every cold start.
        KeychainHelper.migrateAPIKeyFromUserDefaultsIfNeeded()
        appSignposter.emitEvent("app_startup", id: spid, "keychain_migrated=\(true, privacy: .public)")
        // Back-fill apiKeyBoundHost for installs that predate host binding (#13).
        // Must run after the apiKey migration because it reads that entry.
        KeychainHelper.migrateAPIKeyBoundHostIfNeeded()
        appSignposter.emitEvent("app_startup", id: spid, "bound_host_migrated=\(true, privacy: .public)")
        #if DEBUG
        // DEBUG-only DX: seed the API key from BuildConfig when the Keychain
        // is empty (fresh install / simulator reset). Compiled out of Release.
        KeychainHelper.seedDebugAPIKeyFromBuildConfigIfNeeded()
        appSignposter.emitEvent("app_startup", id: spid, "debug_seeded=\(true, privacy: .public)")
        #endif
        appSignposter.endInterval("app_startup", startupInterval)
    }

    // MARK: - SwiftData

    var sharedModelContainer: ModelContainer = {
        let spid = appSignposter.makeSignpostID()
        let interval = appSignposter.beginInterval("model_container_create", id: spid)
        let schema = Schema([
            PendingUpload.self,
            PendingAnalysis.self,
            PendingOutcome.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            let storePath = container.configurations.first.map { $0.url.lastPathComponent } ?? "unknown"
            appSignposter.emitEvent(
                "model_container_create",
                id: spid,
                "result=\("success", privacy: .public) store=\(storePath, privacy: .private)"
            )
            appSignposter.endInterval("model_container_create", interval)
            return container
        } catch {
            appSignposter.emitEvent(
                "model_container_create",
                id: spid,
                "result=\("failure", privacy: .public)"
            )
            appSignposter.endInterval("model_container_create", interval)
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    // MARK: - Scene

    var body: some Scene {
        WindowGroup {
            RootView()
                .task { await requestNotificationPermission() }
                .task {
                    await runPostLaunchSetupIfNeeded()
                }
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
                    do {
                        let mid = appSignposter.makeSignpostID()
                        appSignposter.emitEvent("monitors_started", id: mid, "outcome_queue=\(true, privacy: .public)")
                    }
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
            let spid = appSignposter.makeSignpostID()
            let activeInterval = appSignposter.beginInterval("scene_active", id: spid)
            appSignposter.emitEvent("scene_active", id: spid, "launching_server_check=\(true, privacy: .public)")
            Task {
                appSignposter.emitEvent("scene_active", id: spid, "server_check_start=\(true, privacy: .public)")
                await serverMonitor.check(using: apiClient)
                appSignposter.emitEvent("scene_active", id: spid, "server_check_done=\(true, privacy: .public)")
                appSignposter.emitEvent("scene_active", id: spid, "upload_drain_start=\(true, privacy: .public)")
                await uploadQueueManager.drain(
                    context: sharedModelContainer.mainContext,
                    using: apiClient
                )
                appSignposter.emitEvent("scene_active", id: spid, "upload_drain_done=\(true, privacy: .public)")
                appSignposter.emitEvent("scene_active", id: spid, "outcome_drain_start=\(true, privacy: .public)")
                await outcomeQueueManager.drain(
                    context: sharedModelContainer.mainContext,
                    apiClient: apiClient
                )
                appSignposter.emitEvent("scene_active", id: spid, "outcome_drain_done=\(true, privacy: .public)")
                appSignposter.endInterval("scene_active", activeInterval)
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

    /// Defers launch-agnostic filesystem setup until after the first scene is live.
    @MainActor
    private func runPostLaunchSetupIfNeeded() async {
        guard !didRunPostLaunchSetup else { return }
        didRunPostLaunchSetup = true
        await Task.yield()
        let spid = appSignposter.makeSignpostID()
        let interval = appSignposter.beginInterval("post_launch_setup", id: spid)
        // Apply complete file protection to the SwiftData store so queued
        // pending uploads are unreadable when the device is locked (#9, F-08).
        Self.applyFileProtection(to: sharedModelContainer)
        appSignposter.emitEvent("post_launch_setup", id: spid, "file_protection_applied=\(true, privacy: .public)")
        appSignposter.endInterval("post_launch_setup", interval)
    }

    /// Applies `.completeFileProtection` to the SwiftData store file and its
    /// SQLite WAL/SHM siblings. Idempotent and safe to call on every launch.
    ///
    /// File protection only enforces on a locked device, but the attribute is
    /// persisted and readable in tests. Failures log but do not crash, since
    /// the sidecar files may not exist on first launch.
    static func applyFileProtection(to container: ModelContainer) {
        let spid = appSignposter.makeSignpostID()
        let fpInterval = appSignposter.beginInterval("apply_file_protection", id: spid)
        guard let storeURL = container.configurations.first?.url else {
            appSignposter.emitEvent("apply_file_protection", id: spid, "error=\("no_store_url", privacy: .public)")
            appSignposter.endInterval("apply_file_protection", fpInterval)
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
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }.map { $0.lastPathComponent }.joined(separator: ",")
        appSignposter.emitEvent("apply_file_protection", id: spid, "existing=\(existing, privacy: .private)")
        let fileManager = FileManager.default
        for url in urls where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: url.path
                )
                appSignposter.emitEvent("apply_file_protection", id: spid, "protected=\(url.lastPathComponent, privacy: .private)")
            } catch {
                logger.error("[SwiftData] failed to set file protection on \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)")
                appSignposter.emitEvent("apply_file_protection", id: spid, "failed=\(url.lastPathComponent, privacy: .private)")
            }
        }
        appSignposter.endInterval("apply_file_protection", fpInterval)
    }
}
