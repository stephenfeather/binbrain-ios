// SettingsView.swift
// Bin Brain
//
// Settings screen for configuring server URL, similarity threshold,
// and managing the offline upload queue.

import SwiftUI
import SwiftData
import UIKit

// MARK: - SettingsView

/// The Settings screen for configuring the Bin Brain backend and search options.
struct SettingsView: View {

    // MARK: - State

    @State private var viewModel = SettingsViewModel()
    @Environment(\.apiClient) private var apiClient
    @Environment(\.uploadQueueManager) private var uploadQueueManager
    @Environment(\.modelContext) private var modelContext
    @Environment(\.embeddedInSplitView) private var embeddedInSplitView

    /// Tracks focus on the API key field so we can commit to Keychain on blur.
    @FocusState private var apiKeyFocused: Bool

    // MARK: - Body

    var body: some View {
        if embeddedInSplitView {
            settingsContent
        } else {
            NavigationStack {
                settingsContent
            }
        }
    }

    private var settingsContent: some View {
        Form {
            serverSection
            visionModelSection
            imageSizeSection
            searchSection
            uploadQueueSection
        }
        .navigationTitle("Settings")
        .task {
            async let models: () = viewModel.loadModels(apiClient: apiClient)
            async let imageSize: () = viewModel.loadImageSize(apiClient: apiClient)
            _ = await (models, imageSize)
        }
    }

    // MARK: - Bindings

    /// Bridges the Int `maxImagePx` to the Double that `Slider` requires.
    private var imageSizeBinding: Binding<Double> {
        Binding(
            get: { Double(viewModel.maxImagePx) },
            set: { viewModel.maxImagePx = Int($0) }
        )
    }

    // MARK: - Sections

    @ViewBuilder
    private var serverSection: some View {
        Section("Server") {
            TextField("Server URL", text: $viewModel.serverURL)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .onChange(of: viewModel.serverURL) {
                    viewModel.debouncedSave()
                }

            SecureField("API Key", text: $viewModel.apiKey)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($apiKeyFocused)
                .submitLabel(.done)
                .onSubmit {
                    viewModel.commitAPIKey()
                }
                .onChange(of: apiKeyFocused) { _, isFocused in
                    // Persist to Keychain on blur only — never on every keystroke.
                    if !isFocused {
                        viewModel.commitAPIKey()
                    }
                }

            HStack {
                Button("Test Connection") {
                    Task {
                        await viewModel.testConnection(apiClient: apiClient)
                        let generator = UINotificationFeedbackGenerator()
                        let feedback: UINotificationFeedbackGenerator.FeedbackType
                        switch viewModel.connectionStatus {
                        case .connected:
                            feedback = .success
                        case .connectedKeyInvalid, .connectedNoKey, .connectedKeyNotBoundToHost:
                            feedback = .warning
                        case .unreachable, .unknown:
                            feedback = .error
                        }
                        generator.notificationOccurred(feedback)
                    }
                }
                Spacer()
                connectionIndicator
            }
            connectionStatusRow
        }
    }

    @ViewBuilder
    private var connectionIndicator: some View {
        switch viewModel.connectionStatus {
        case .unknown:
            EmptyView()
        case .connected:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .connectedKeyInvalid:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .connectedNoKey:
            Image(systemName: "key.slash")
                .foregroundStyle(.orange)
        case .connectedKeyNotBoundToHost:
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .foregroundStyle(.orange)
        case .unreachable:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var connectionStatusRow: some View {
        switch viewModel.connectionStatus {
        case .unknown:
            EmptyView()
        case .connected(let role):
            Text("Connected · role \(role.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .connectedKeyInvalid:
            Text("Server reachable, API key invalid")
                .font(.caption)
                .foregroundStyle(.orange)
        case .connectedNoKey:
            Text("Server reachable, no API key configured")
                .font(.caption)
                .foregroundStyle(.orange)
        case .connectedKeyNotBoundToHost(let canRebind):
            VStack(alignment: .leading, spacing: 4) {
                Text("API key is bound to a different host. Re-bind to \(viewModel.serverURL)?")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if canRebind {
                    Button("Re-bind key to this host") {
                        Task { await viewModel.rebindKey(apiClient: apiClient) }
                    }
                    .font(.caption)
                }
            }
        case .unreachable(let errorMessage):
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var visionModelSection: some View {
        Section("Vision Model") {
            if viewModel.isLoadingModels {
                HStack {
                    ProgressView()
                    Text("Loading models…").foregroundStyle(.secondary)
                }
            } else if viewModel.availableModels.isEmpty {
                Text("No models available")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.availableModels, id: \.name) { model in
                    Button {
                        guard model.name != viewModel.activeModel else { return }
                        Task { await viewModel.selectModel(model.name, apiClient: apiClient) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(model.name)
                                if let size = model.size {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if model.name == viewModel.activeModel {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .tint(.primary)
                    .disabled(viewModel.isSwitchingModel)
                }
            }
            if viewModel.isSwitchingModel {
                HStack {
                    ProgressView()
                    Text("Switching model…").foregroundStyle(.secondary)
                }
            }
            if let error = viewModel.modelError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var imageSizeSection: some View {
        Section("Image Size") {
            if viewModel.isLoadingImageSize {
                HStack {
                    ProgressView()
                    Text("Loading…").foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Max dimension: \(viewModel.maxImagePx) px")
                    Slider(
                        value: imageSizeBinding,
                        in: 128...4096,
                        step: 64
                    ) {
                        Text("Max image size")
                    } onEditingChanged: { editing in
                        if !editing {
                            Task {
                                await viewModel.setImageSize(viewModel.maxImagePx, apiClient: apiClient)
                            }
                        }
                    }
                    Text("Smaller = faster inference, larger = more detail")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = viewModel.imageSizeError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
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
                Task { await uploadQueueManager.drain(context: modelContext, using: apiClient) }
            }

            Button("Clear Queue", role: .destructive) {
                uploadQueueManager.clearQueue(context: modelContext)
            }
        }
    }
}
