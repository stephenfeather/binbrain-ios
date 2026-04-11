// RootView.swift
// Bin Brain
//
// The root view that hosts the three main sections of the app.
// Uses NavigationSplitView on iPad (regular width) and TabView on iPhone (compact width).
// On launch, retries any PendingAnalysis entries interrupted by background task expiry.

import SwiftUI
import SwiftData

// MARK: - SidebarSection

/// The sections available in the sidebar / tab bar.
enum SidebarSection: String, CaseIterable, Identifiable {
    case bins
    case locations
    case search
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bins: "Bins"
        case .locations: "Locations"
        case .search: "Search"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .bins: "tray.2.fill"
        case .locations: "mappin.and.ellipse"
        case .search: "magnifyingglass"
        case .settings: "gear"
        }
    }
}

// MARK: - RootView

/// The root view presented after app launch.
///
/// On iPad (regular horizontal size class), presents a `NavigationSplitView`
/// with a sidebar for section selection and a detail pane.
/// On iPhone (compact), presents the familiar `TabView`.
/// On appear, checks for interrupted analyses and retries them via `APIClient`.
struct RootView: View {

    // MARK: - Environment

    @Environment(\.apiClient) private var apiClient
    @Environment(\.modelContext) private var modelContext
    @Environment(\.serverMonitor) private var serverMonitor
    @Environment(\.horizontalSizeClass) private var sizeClass

    // MARK: - State

    @State private var toast = ToastViewModel()
    @State private var selectedSection: SidebarSection? = .bins
    @State private var selectedBinId: String?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            offlineBanner

            if sizeClass == .regular {
                splitView
            } else {
                tabView
            }
        }
        .toast(message: toast.message, isShowing: Binding(
            get: { toast.isShowing },
            set: { if !$0 { toast.dismiss() } }
        ))
        .task { await retryPendingAnalyses() }
    }

    // MARK: - Offline Banner

    @ViewBuilder
    private var offlineBanner: some View {
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
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Server unreachable")
        }
    }

    // MARK: - Tab View (iPhone)

    private var tabView: some View {
        TabView {
            BinsListView()
                .tabItem {
                    Label("Bins", systemImage: "tray.2.fill")
                }

            LocationsListView()
                .tabItem {
                    Label("Locations", systemImage: "mappin.and.ellipse")
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

    // MARK: - Split View (iPad)

    private var splitView: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.systemImage)
            }
            .navigationTitle("Bin Brain")
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            NavigationStack {
                switch selectedSection {
                case .bins:
                    BinsListView()
                case .locations:
                    LocationsListView()
                case .search:
                    SearchView()
                case .settings:
                    SettingsView()
                case nil:
                    Text("Select a section")
                        .foregroundStyle(.secondary)
                }
            }
            .environment(\.embeddedInSplitView, true)
        }
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
