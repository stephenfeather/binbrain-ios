// BinsListView.swift
// Bin Brain
//
// Entry point for the Bins list screen.
// Displays all bins and navigates to BinDetailView on selection.
// The camera toolbar button launches the full cataloging flow:
// Scanner → Analysis → Suggestion Review.

import AVFoundation
import SwiftUI

// MARK: - CatalogingStep

private enum CatalogingStep: Hashable {
    case analysis
    case review
}

// MARK: - BinsListView

/// The main screen listing all storage bins.
///
/// Loads bins on appear and supports pull-to-refresh.
/// Navigates to `BinDetailView` when a bin row is tapped.
/// The camera toolbar button launches the scanner sheet, which walks
/// through QR scan → photo capture → AI analysis → suggestion review.
struct BinsListView: View {

    // MARK: - State

    @State private var viewModel = BinsListViewModel()
    @Environment(\.apiClient) private var apiClient
    @Environment(\.modelContext) private var modelContext

    // Cataloging flow
    @State private var showCataloging = false
    @State private var showShutterButton = false
    @State private var catalogingPath: [CatalogingStep] = []
    @State private var scannerViewModel = ScannerViewModel()
    @State private var analysisViewModel = AnalysisViewModel()
    @State private var reviewViewModel = SuggestionReviewViewModel()
    @State private var captureAction: (() -> Void)?
    @State private var capturedPhotoData: Data?
    @State private var capturedBinId: String?

    // MARK: - Body

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Bins")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showCataloging = true
                        } label: {
                            Image(systemName: "camera.fill")
                                .font(.title2)
                        }
                    }
                }
                .task { await viewModel.load(apiClient: apiClient) }
                .refreshable { await viewModel.load(apiClient: apiClient) }
                .sheet(isPresented: $showCataloging, onDismiss: resetCataloging) {
                    catalogingSheet
                }
        }
    }

    // MARK: - Cataloging Sheet

    @ViewBuilder
    private var catalogingSheet: some View {
        NavigationStack(path: $catalogingPath) {
            ZStack {
                ScannerView(
                    showShutterButton: $showShutterButton,
                    onQRCode: { code in
                        scannerViewModel.qrDetected(code)
                    },
                    onPhotoCapture: { photo in
                        guard let binId = scannerViewModel.scannedBinId,
                              let rawData = photo.fileDataRepresentation() else { return }
                        scannerViewModel.photoCaptured(photo)
                        capturedPhotoData = rawData
                        capturedBinId = binId
                        catalogingPath.append(.analysis)
                    },
                    onCaptureReady: { action in
                        captureAction = action
                    }
                )
                .ignoresSafeArea()

                if showShutterButton {
                    VStack {
                        Spacer()
                        Button(action: { captureAction?() }) {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 72, height: 72)
                                .overlay(Circle().stroke(Color.gray.opacity(0.4), lineWidth: 2))
                                .shadow(radius: 4)
                        }
                        .padding(.bottom, 50)
                    }
                }
            }
            .navigationTitle("Scan Bin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCataloging = false }
                }
            }
            .navigationDestination(for: CatalogingStep.self) { step in
                switch step {
                case .analysis:
                    analysisView
                case .review:
                    reviewView
                }
            }
        }
    }

    // MARK: - Analysis View

    @ViewBuilder
    private var analysisView: some View {
        if let data = capturedPhotoData, let binId = capturedBinId {
            AnalysisProgressView(
                viewModel: analysisViewModel,
                onComplete: { suggestions in
                    reviewViewModel.loadSuggestions(suggestions)
                    catalogingPath.append(.review)
                },
                onRetry: {
                    Task {
                        analysisViewModel.reset()
                        await analysisViewModel.run(
                            jpegData: data,
                            binId: binId,
                            apiClient: apiClient,
                            context: modelContext
                        )
                    }
                }
            )
            .task {
                await analysisViewModel.run(
                    jpegData: data,
                    binId: binId,
                    apiClient: apiClient,
                    context: modelContext
                )
            }
        }
    }

    // MARK: - Review View

    @ViewBuilder
    private var reviewView: some View {
        if let binId = capturedBinId {
            SuggestionReviewView(
                viewModel: reviewViewModel,
                binId: binId,
                apiClient: apiClient,
                onDone: {
                    showCataloging = false
                    Task { await viewModel.load(apiClient: apiClient) }
                }
            )
        }
    }

    // MARK: - Helpers

    private func resetCataloging() {
        catalogingPath = []
        showShutterButton = false
        scannerViewModel.reset()
        analysisViewModel.reset()
        captureAction = nil
        capturedPhotoData = nil
        capturedBinId = nil
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
