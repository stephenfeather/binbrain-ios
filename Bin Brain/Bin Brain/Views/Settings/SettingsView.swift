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

    /// Controls the transient success toast shown after a successful model switch
    /// (Finding #9). Kept in the view, not the view model, because it's pure UI.
    @State private var showModelSelectToast: Bool = false

    /// Swift2_020 — three-state outcome toggle feature flag. Default `true`
    /// (yellow/green/red tap-cycle UX in suggestion review). Flipping to
    /// `false` reverts the sheet to the legacy default-on toggle without a
    /// code release — the VM reads the same key at init time.
    @AppStorage(SuggestionReviewViewModel.outcomeModelEnabledDefaultsKey)
    private var outcomeModelEnabled: Bool = true

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
            catalogingSection
            uploadQueueSection
        }
        .navigationTitle("Settings")
        .task {
            // Finding #20 — prime the key-binding chip once on appear via an
            // off-main Keychain read, instead of reading Keychain from a
            // computed getter every SwiftUI body re-render.
            async let models: () = viewModel.loadModels(apiClient: apiClient)
            async let imageSize: () = viewModel.loadImageSize(apiClient: apiClient)
            async let binding: () = viewModel.refreshAPIKeyBindingStatus()
            _ = await (models, imageSize, binding)
        }
        .onChange(of: viewModel.modelSelectSuccessTick) { _, _ in
            // Finding #9 — fire haptic + brief toast on each successful switch.
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showModelSelectToast = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                showModelSelectToast = false
            }
        }
        .overlay(alignment: .top) {
            if showModelSelectToast {
                Text("Model switched")
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showModelSelectToast)
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

            // Finding #12 — chip below the key field so the binding state is
            // visible without running Test Connection.
            // Finding #20 — the onChange used to spawn a Task per keystroke
            // that read Keychain on main and could fire a /health probe.
            // scheduleAutoRebindIfApplicable debounces to one call after the
            // user stops typing.
            apiKeyBindingChip
                .onChange(of: viewModel.serverURL) { _, _ in
                    viewModel.scheduleAutoRebindIfApplicable(apiClient: apiClient)
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
    private var apiKeyBindingChip: some View {
        switch viewModel.apiKeyBindingStatus {
        case .noKeyStored:
            Label("No key stored", systemImage: "key.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .keyBoundToCurrentHost:
            Label("Key bound", systemImage: "checkmark.seal")
                .font(.caption)
                .foregroundStyle(.green)
        case .keyUnboundForCurrentHost:
            Button {
                Task { await viewModel.rebindKey(apiClient: apiClient) }
            } label: {
                Label("Key unbound — tap to rebind", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
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
                if let provider = viewModel.visionProvider, provider != "localhost" {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(provider, systemImage: "cloud")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(viewModel.activeModel)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                    }
                    .padding(.vertical, 2)
                } else {
                    Text("No models available")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(viewModel.availableModels, id: \.name) { model in
                    Button {
                        // Ignore taps while a switch is in flight so siblings
                        // feel tappable (not greyed-out) but only the first
                        // tap is honored. (Finding #9)
                        guard !viewModel.isSwitchingModel else { return }
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
                            // Inline spinner next to the tapped row (Finding #9)
                            if viewModel.selectingModelId == model.name {
                                ProgressView()
                            } else if model.name == viewModel.activeModel {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .tint(.primary)
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
    private var catalogingSection: some View {
        Section("Cataloging") {
            Toggle("Three-state outcome toggle", isOn: $outcomeModelEnabled)
            Text(outcomeModelEnabled
                 ? "Tap each suggestion to cycle: ignored (yellow) → accepted (green) → rejected (red). Only accepted items are saved."
                 : "Legacy behaviour: every suggestion is accepted by default — flip its switch to exclude.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
