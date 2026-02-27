// SettingsView.swift
// Bin Brain
//
// Settings screen for configuring server URL, similarity threshold,
// and managing the offline upload queue.

import SwiftUI

// MARK: - UploadQueueManager Environment Key

private struct UploadQueueManagerKey: EnvironmentKey {
    static let defaultValue = UploadQueueManager()
}

extension EnvironmentValues {
    /// The shared `UploadQueueManager` instance injected via the environment.
    var uploadQueueManager: UploadQueueManager {
        get { self[UploadQueueManagerKey.self] }
        set { self[UploadQueueManagerKey.self] = newValue }
    }
}

// MARK: - SettingsView

/// The Settings screen for configuring the Bin Brain backend and search options.
struct SettingsView: View {

    // MARK: - State

    @State private var viewModel = SettingsViewModel()
    @Environment(\.apiClient) private var apiClient
    @Environment(\.uploadQueueManager) private var uploadQueueManager

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                searchSection
                uploadQueueSection
            }
            .navigationTitle("Settings")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var serverSection: some View {
        Section("Server") {
            TextField("Server URL", text: $viewModel.serverURL)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .onChange(of: viewModel.serverURL) {
                    viewModel.save()
                }

            HStack {
                Button("Test Connection") {
                    Task { await viewModel.testConnection(apiClient: apiClient) }
                }
                Spacer()
                connectionIndicator
            }
        }
    }

    @ViewBuilder
    private var connectionIndicator: some View {
        switch viewModel.connectionStatus {
        case .unknown:
            EmptyView()
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        Section("Search") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Minimum similarity: \(viewModel.similarityThreshold, specifier: "%.2f")")
                Slider(value: $viewModel.similarityThreshold, in: 0...1)
                    .onChange(of: viewModel.similarityThreshold) {
                        viewModel.save()
                    }
                Text("0 = any result, 1 = exact match only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var uploadQueueSection: some View {
        Section("Upload Queue") {
            Text("Pending uploads: \(uploadQueueManager.pendingCount)")

            Button("Upload Now") {
                // TODO: Task 13 wires ModelContext via @Environment
            }

            Button("Clear Queue", role: .destructive) {
                // TODO: Task 13 wires ModelContext via @Environment
            }
        }
    }
}
