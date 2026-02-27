// BinsListView.swift
// Bin Brain
//
// Entry point for the Bins list screen.
// Displays all bins and navigates to BinDetailView on selection.

import SwiftUI

// MARK: - APIClient Environment Key

// Temporary until Task 13 wires the full @Environment keys
private struct APIClientKey: EnvironmentKey {
    static let defaultValue = APIClient()
}

extension EnvironmentValues {
    /// The shared `APIClient` instance injected via the environment.
    var apiClient: APIClient {
        get { self[APIClientKey.self] }
        set { self[APIClientKey.self] = newValue }
    }
}

// MARK: - BinsListView

/// The main screen listing all storage bins.
///
/// Loads bins on appear and supports pull-to-refresh.
/// Navigates to `BinDetailView` when a bin row is tapped.
struct BinsListView: View {

    // MARK: - State

    @State private var viewModel = BinsListViewModel()
    @Environment(\.apiClient) private var apiClient
    @State private var showScanner = false
    @State private var showShutterButton = false

    // MARK: - Body

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Bins")
                .toolbar {
                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            showScanner = true
                        } label: {
                            Image(systemName: "camera.fill")
                                .font(.title2)
                        }
                    }
                }
                .task { await viewModel.load(apiClient: apiClient) }
                .refreshable { await viewModel.load(apiClient: apiClient) }
                .sheet(isPresented: $showScanner) {
                    ScannerView(
                        showShutterButton: $showShutterButton,
                        onQRCode: { _ in },
                        onPhotoCapture: { _ in }
                    )
                }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.bins.isEmpty {
            ProgressView()
        } else if let errorMessage = viewModel.error {
            VStack(spacing: 12) {
                Text(errorMessage).foregroundStyle(.secondary)
                Button("Retry") {
                    Task { await viewModel.load(apiClient: apiClient) }
                }
            }
        } else if viewModel.bins.isEmpty {
            Text("Scan your first bin to get started")
                .foregroundStyle(.secondary)
        } else {
            List(viewModel.bins, id: \.binId) { bin in
                NavigationLink(destination: BinDetailView(binId: bin.binId)) {
                    BinRowView(bin: bin)
                }
            }
        }
    }
}

// MARK: - BinRowView

private struct BinRowView: View {
    let bin: BinSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(bin.binId).font(.headline)
            Text("\(bin.itemCount) items").font(.subheadline).foregroundStyle(.secondary)
            Text(bin.lastUpdated, style: .relative).font(.caption).foregroundStyle(.secondary)
        }
    }
}
