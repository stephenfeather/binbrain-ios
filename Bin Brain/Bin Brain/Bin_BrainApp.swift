// Bin_BrainApp.swift
// Bin Brain

import SwiftUI
import SwiftData
import UserNotifications

@main
struct Bin_BrainApp: App {

    // MARK: - Scene Phase

    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Services

    @State private var apiClient = APIClient()
    @State private var uploadQueueManager = UploadQueueManager()
    @State private var serverMonitor = ServerMonitor()

    // MARK: - SwiftData

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            PendingUpload.self,
            PendingAnalysis.self,
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
                .environment(\.apiClient, apiClient)
                .environment(\.uploadQueueManager, uploadQueueManager)
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
            }
        }
    }

    // MARK: - Private

    /// Requests notification authorization on first launch.
    ///
    /// Called once via `.task` on the root view. The result is discarded
    /// because the app degrades gracefully if the user declines.
    private func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        )
    }
}
