// BinsListView.swift
// Bin Brain
//
// Entry point for the Bins list screen.
// Displays all bins and navigates to BinDetailView on selection.
// The camera toolbar button launches the full cataloging flow:
// Scanner → Analysis → Suggestion Review.

import OSLog
import SwiftUI
import SwiftData

private let logger = Logger(subsystem: "com.binbrain.app", category: "BinsListView")

// MARK: - CaptureProxy

/// Reference-type container for the scanner's capture action.
///
/// Stored in `@State` so the same instance persists across renders.
/// The button closure captures the proxy by reference, so it always
/// reads the current `action` value at tap time — avoiding the
/// stale-closure issue that arises with `@State var (() -> Void)?`.
private final class CaptureProxy {
    var action: (() -> Void)?
}

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
    @Environment(\.embeddedInSplitView) private var embeddedInSplitView

    // Cataloging flow
    @State private var showCataloging = false
    @State private var showShutterButton = false
    @State private var catalogingPath: [CatalogingStep] = []
    @State private var scannerViewModel = ScannerViewModel()
    @State private var analysisViewModel = AnalysisViewModel()
    @State private var reviewViewModel = SuggestionReviewViewModel()
    @State private var captureProxy = CaptureProxy()
    @State private var capturedPhotoData: Data?
    @State private var capturedBinId: String?
    @State private var navigatedOnPreliminary = false
    private static let preliminaryTopK = 10

    // Model escalation
    private static let modelEscalation = ["qwen3-vl:2b", "qwen3-vl:4b", "qwen3-vl:8b"]
    @State private var currentModelIndex = 0

    // MARK: - Body

    var body: some View {
        if embeddedInSplitView {
            binsContent
        } else {
            NavigationStack {
                binsContent
            }
        }
    }

    private var binsContent: some View {
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
                    .accessibilityLabel("Scan new bin")
                }
            }
            .task { await viewModel.load(apiClient: apiClient) }
            .refreshable { await viewModel.load(apiClient: apiClient) }
            // fullScreenCover instead of sheet: .sheet is dismissed when the
            // horizontal size class changes on rotation (compact→regular on
            // large iPhones). fullScreenCover fills the whole screen regardless
            // of orientation, so the ScannerView + NavigationStack survive rotation.
            .fullScreenCover(isPresented: $showCataloging, onDismiss: resetCataloging) {
                catalogingSheet
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
                    onPhotoCapture: { image in
                        logger.debug("onPhotoCapture called, image: \(image.size.width, privacy: .public)x\(image.size.height, privacy: .public) orientation: \(image.imageOrientation.rawValue, privacy: .public)")
                        // Normalize EXIF orientation before JPEG encoding. jpegData(compressionQuality:)
                        // does not reliably embed the EXIF orientation tag, so a landscape capture
                        // re-decoded in decodeCGImage would appear as .up (rotated pixels, no tag).
                        let oriented: UIImage
                        if image.imageOrientation != .up {
                            let fmt = UIGraphicsImageRendererFormat()
                            fmt.scale = image.scale
                            oriented = UIGraphicsImageRenderer(size: image.size, format: fmt).image { _ in
                                image.draw(in: CGRect(origin: .zero, size: image.size))
                            }
                        } else {
                            oriented = image
                        }
                        guard let binId = scannerViewModel.scannedBinId,
                              let rawData = oriented.jpegData(compressionQuality: 1.0) else { return }
                        logger.debug("JPEG data: \(rawData.count, privacy: .public) bytes, binId: \(binId, privacy: .private)")
                        capturedPhotoData = rawData
                        capturedBinId = binId
                        catalogingPath.append(.analysis)
                        // Launch analysis in an unstructured Task so SwiftUI
                        // re-renders cannot cancel the in-flight network call.
                        Task {
                            await analysisViewModel.run(
                                jpegData: rawData,
                                binId: binId,
                                apiClient: apiClient,
                                context: modelContext
                            )
                        }
                    },
                    onCaptureReady: { action in
                        captureProxy.action = action
                    }
                )
                .ignoresSafeArea()

                if let message = scannerViewModel.scanError {
                    VStack {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                            .padding(.top, 16)
                        Spacer()
                    }
                    .accessibilityLabel("Scan error: \(message)")
                }

                if showShutterButton, let binId = scannerViewModel.scannedBinId {
                    VStack {
                        Text(binId)
                            .font(.title2.bold())
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .padding(.top, 16)

                        Spacer()

                        Button(action: { captureProxy.action?() }) {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 72, height: 72)
                                .overlay(Circle().stroke(Color.gray.opacity(0.4), lineWidth: 2))
                                .shadow(radius: 4)
                        }
                        .accessibilityLabel("Take photo")
                        .padding(.bottom, 50)
                    }
                }
            }
            .navigationTitle(showShutterButton ? "Scan Item" : "Scan Bin")
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

    private var analysisView: some View {
        AnalysisProgressView(
            viewModel: analysisViewModel,
            onComplete: { suggestions in
                reviewViewModel.photoData = analysisViewModel.lastUploadedPhotoData
                if navigatedOnPreliminary {
                    reviewViewModel.applyServerSuggestions(suggestions)
                } else {
                    reviewViewModel.loadSuggestions(suggestions)
                    catalogingPath.append(.review)
                }
            },
            onRetry: {
                // Finding #4-UX-2: "Retake Photo" must return to the camera so
                // the user can capture a fresh frame. The previous implementation
                // re-ran analysis on the SAME (still-blurry) photo.
                analysisViewModel.reset()
                navigatedOnPreliminary = false
                capturedPhotoData = nil
                catalogingPath.removeAll()
            },
            onOverride: {
                Task {
                    guard let data = capturedPhotoData,
                          let binId = capturedBinId else { return }
                    navigatedOnPreliminary = false
                    await analysisViewModel.overrideQualityGate(
                        jpegData: data,
                        binId: binId,
                        apiClient: apiClient,
                        context: modelContext
                    )
                }
            },
            onPreliminaryReady: { classifications in
                reviewViewModel.photoData = analysisViewModel.lastUploadedPhotoData
                reviewViewModel.loadPreliminaryClassifications(
                    classifications,
                    topK: Self.preliminaryTopK
                )
                navigatedOnPreliminary = true
                catalogingPath.append(.review)
            }
        )
    }

    // MARK: - Review View

    private var reviewView: some View {
        SuggestionReviewView(
            viewModel: reviewViewModel,
            binId: capturedBinId ?? "",
            apiClient: apiClient,
            onDone: {
                showCataloging = false
                Task { await viewModel.load(apiClient: apiClient) }
            },
            onRetryWithLargerModel: nextModelAvailable ? {
                escalateModelAndReSuggest()
            } : nil
        )
        // AnalysisProgressView.onChange(of: phase) is unreliable when that view is
        // in the NavigationStack background (non-visible destination). Observe here
        // on the active visible view so server suggestions always land.
        .onChange(of: analysisViewModel.phase) { _, newPhase in
            guard case .complete = newPhase, navigatedOnPreliminary else { return }
            reviewViewModel.photoData = analysisViewModel.lastUploadedPhotoData
            reviewViewModel.applyServerSuggestions(analysisViewModel.suggestions)
        }
    }

    // MARK: - Helpers

    private var nextModelAvailable: Bool {
        currentModelIndex + 1 < Self.modelEscalation.count
    }

    private func escalateModelAndReSuggest() {
        guard nextModelAvailable else { return }
        currentModelIndex += 1
        let nextModel = Self.modelEscalation[currentModelIndex]
        catalogingPath = [.analysis]
        reviewViewModel = SuggestionReviewViewModel()
        Task {
            do {
                _ = try await apiClient.selectModel(nextModel)
            } catch {
                // selectModel failed — still try suggest with current model
            }
            await analysisViewModel.reSuggest(apiClient: apiClient)
        }
    }

    private func resetCataloging() {
        catalogingPath = []
        showShutterButton = false
        scannerViewModel.reset()
        analysisViewModel.reset()
        captureProxy.action = nil
        capturedPhotoData = nil
        capturedBinId = nil
        currentModelIndex = 0
        navigatedOnPreliminary = false
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
            if let locationName = bin.locationName {
                Text(locationName).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Text("Last updated:")
                Text(bin.lastUpdated, style: .date)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
