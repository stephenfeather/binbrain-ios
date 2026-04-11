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
                .onChange(of: viewModel.apiKey) {
                    viewModel.debouncedSave()
                }

            HStack {
                Button("Test Connection") {
                    Task {
                        await viewModel.testConnection(apiClient: apiClient)
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(
                            viewModel.connectionStatus == .ok ? .success : .error
                        )
                    }
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
