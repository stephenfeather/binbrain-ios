// RootView.swift
// Bin Brain
//
// The root TabView that hosts the three main sections of the app.
// On launch, retries any PendingAnalysis entries interrupted by background task expiry.

import SwiftUI
import SwiftData

/// The root view presented after app launch.
///
/// Hosts a `TabView` with Bins, Search, and Settings tabs.
/// On appear, checks for interrupted analyses and retries them via `APIClient`.
struct RootView: View {

    // MARK: - Environment

    @Environment(\.apiClient) private var apiClient
    @Environment(\.modelContext) private var modelContext
    @Environment(\.serverMonitor) private var serverMonitor

    // MARK: - State

    @State private var toast = ToastViewModel()

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if !serverMonitor.isReachable {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash")
                        .font(.caption)
                    Text("Server unreachable")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.85))
            }

            TabView {
                BinsListView()
                    .tabItem {
                        Label("Bins", systemImage: "tray.2.fill")
                    }

                SearchView()
                    .tabItem {
                        Label("Search", systemImage: "magnifyingglass")
                    }

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
            }
        }
        .toast(message: toast.message, isShowing: Binding(
            get: { toast.isShowing },
            set: { if !$0 { toast.dismiss() } }
        ))
        .task { await retryPendingAnalyses() }
    }

    // MARK: - Private

    /// Fetches all interrupted `PendingAnalysis` entries and retries the suggest call.
    ///
    /// Shows a toast while each retry is in progress.
    /// Deletes entries on success or after 3 consecutive failures.
    private func retryPendingAnalyses() async {
        let descriptor = FetchDescriptor<PendingAnalysis>()
        guard let entries = try? modelContext.fetch(descriptor), !entries.isEmpty else { return }

        for entry in entries {
            toast.show("Resuming analysis for \(entry.binId)...")
            do {
                _ = try await apiClient.suggest(photoId: entry.photoId)
                modelContext.delete(entry)
                try? modelContext.save()
            } catch {
                entry.retryCount += 1
                if entry.retryCount >= 3 {
                    modelContext.delete(entry)
                    try? modelContext.save()
                }
            }
        }
    }
}
