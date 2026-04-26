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
    @Environment(\.outcomeQueueManager) private var outcomeQueueManager
    @Environment(\.sessionManager) private var sessionManager
    @Environment(\.embeddedInSplitView) private var embeddedInSplitView

    // Cataloging flow — view-specific state
    @State private var showCataloging = false
    @State private var showShutterButton = false
    @State private var scannerViewModel = ScannerViewModel()
    @State private var capturedBinId: String?

    // Cataloging coordinator — owns all shared cataloging state and actions
    @State private var coordinator = CatalogingCoordinator()

    // Delete confirmation state
    @State private var binToDelete: BinSummary?

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
        @Bindable var c = coordinator
        NavigationStack(path: $c.path) {
            ZStack {
                ScannerView(
                    showShutterButton: $showShutterButton,
                    onQRCode: { code in
                        scannerViewModel.qrDetected(code)
                    },
                    onPhotoCapture: { image, cameraContext in
                        // Debounce: a second shutter tap that lands before
                        // SwiftUI pushes the analysis destination would push
                        // a duplicate, producing two stacked quality-gate
                        // screens. Drop captures that arrive after the path
                        // has already advanced.
                        guard coordinator.path.isEmpty else {
                            logger.debug("onPhotoCapture ignored — catalogingPath already advanced")
                            return
                        }
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
                        coordinator.capturedPhotoData = rawData
                        capturedBinId = binId
                        coordinator.capturedCameraContext = cameraContext
                        // Swift2_012 — put binId on the VM immediately so Confirm reads a
                        // VM-durable value.
                        coordinator.reviewViewModel.binId = binId
                        coordinator.path.append(.analysis)
                        // startAnalysis captures liveBarcode at call time (before its
                        // internal Task) so the UPC snapshot is accurate even if the
                        // user moved the camera between scan and shutter.
                        coordinator.startAnalysis(
                            binId: binId,
                            apiClient: apiClient,
                            sessionManager: sessionManager,
                            modelContext: modelContext,
                            cameraContext: cameraContext
                        )
                    },
                    onCaptureReady: { action in
                        coordinator.captureProxy.action = action
                    },
                    onBarcodeScanned: { payload, symbology in
                        coordinator.liveBarcodePayload = payload
                        coordinator.liveBarcodeSymbology = symbology
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
                    VStack(spacing: 8) {
                        Text(binId)
                            .font(.title2.bold())
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .padding(.top, 16)

                        if let payload = coordinator.liveBarcodePayload {
                            HStack(spacing: 8) {
                                Image(systemName: "barcode.viewfinder")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(payload)
                                        .font(.footnote.monospaced())
                                    if let sym = coordinator.liveBarcodeSymbology {
                                        Text(sym)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel("Detected barcode \(payload)")
                        }

                        Spacer()

                        Button(action: { coordinator.captureProxy.action?() }) {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 72, height: 72)
                                .overlay(Circle().stroke(Color.gray.opacity(0.4), lineWidth: 2))
                                .shadow(radius: 4)
                        }
                        .accessibilityLabel("Take photo")
                        .disabled(!coordinator.path.isEmpty)
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
            viewModel: coordinator.analysisViewModel,
            onComplete: { suggestions in
                coordinator.reviewViewModel.photoData = coordinator.analysisViewModel.lastUploadedPhotoData
                if coordinator.navigatedOnPreliminary {
                    coordinator.reviewViewModel.applyServerSuggestions(
                        suggestions,
                        photoId: coordinator.analysisViewModel.lastPhotoId,
                        visionModel: coordinator.analysisViewModel.lastVisionModel,
                        promptVersion: coordinator.analysisViewModel.lastPromptVersion
                    )
                } else {
                    coordinator.reviewViewModel.loadSuggestions(
                        suggestions,
                        photoId: coordinator.analysisViewModel.lastPhotoId,
                        visionModel: coordinator.analysisViewModel.lastVisionModel,
                        promptVersion: coordinator.analysisViewModel.lastPromptVersion
                    )
                    coordinator.path.append(.review)
                }
            },
            onRetry: {
                // Finding #4-UX-2: "Retake Photo" must return to the camera so
                // the user can capture a fresh frame.
                coordinator.catalogingSession.recordRetake()
                coordinator.analysisViewModel.reset()
                coordinator.navigatedOnPreliminary = false
                coordinator.capturedPhotoData = nil
                coordinator.path.removeAll()
            },
            onOverride: {
                coordinator.catalogingSession.recordQualityBypass()
                guard let binId = capturedBinId else { return }
                coordinator.startOverrideQualityGate(
                    binId: binId,
                    apiClient: apiClient,
                    sessionManager: sessionManager,
                    modelContext: modelContext
                )
            },
            onPreliminaryReady: { classifications, ocr in
                coordinator.reviewViewModel.photoData = coordinator.analysisViewModel.lastUploadedPhotoData
                coordinator.reviewViewModel.loadPreliminaryFromOnDevice(
                    classifications: classifications,
                    ocr: ocr,
                    topK: CatalogingCoordinator.preliminaryTopK
                )
                coordinator.navigatedOnPreliminary = true
                coordinator.path.append(.review)
            }
        )
    }

    // MARK: - Review View

    private var reviewView: some View {
        SuggestionReviewView(
            viewModel: coordinator.reviewViewModel,
            apiClient: apiClient,
            onDone: {
                // Swift2_027 — pop the inner NavigationStack FIRST so the
                // .analysis/.review pushes unwind before the fullScreenCover
                // tears down.
                coordinator.path = []
                showCataloging = false
                Task { await viewModel.load(apiClient: apiClient) }
            },
            onRetryWithLargerModel: coordinator.nextModelAvailable ? {
                coordinator.escalateModelAndReSuggest(apiClient: apiClient)
            } : nil
        )
        // Swift2_018 — inject the durable outcomes queue + context so
        // confirm() persists each outcomes POST instead of firing it as a
        // one-shot detached Task. Both must be set before confirm() runs.
        .onAppear {
            coordinator.reviewViewModel.outcomeQueueManager = outcomeQueueManager
            coordinator.reviewViewModel.outcomeQueueContext = modelContext
        }
        // AnalysisProgressView.onChange(of: phase) is unreliable when that view is
        // in the NavigationStack background (non-visible destination). Observe here
        // on the active visible view so server suggestions always land.
        .onChange(of: coordinator.analysisViewModel.phase) { _, newPhase in
            guard coordinator.navigatedOnPreliminary else { return }
            switch newPhase {
            case .complete:
                coordinator.reviewViewModel.photoData = coordinator.analysisViewModel.lastUploadedPhotoData
                coordinator.reviewViewModel.applyServerSuggestions(
                    coordinator.analysisViewModel.suggestions,
                    photoId: coordinator.analysisViewModel.lastPhotoId,
                    visionModel: coordinator.analysisViewModel.lastVisionModel,
                    promptVersion: coordinator.analysisViewModel.lastPromptVersion
                )
            case .failed(let message):
                // The review screen owns the alert because the parent owns the
                // API call — without this hook the user would be stuck on a
                // permanent "Working…" spinner with no way to resubmit.
                coordinator.ingestErrorMessage = message
            default:
                break
            }
        }
        .alert(
            "Analysis Failed",
            isPresented: Binding(
                get: { coordinator.ingestErrorMessage != nil },
                set: { if !$0 { coordinator.ingestErrorMessage = nil } }
            ),
            presenting: coordinator.ingestErrorMessage
        ) { _ in
            Button("Retry") { retryIngest() }
            Button("Cancel", role: .cancel) {
                coordinator.ingestErrorMessage = nil
                coordinator.path = []
                showCataloging = false
            }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Helpers

    /// Resets view-specific cataloging state, then delegates shared state
    /// reset to the coordinator.
    private func resetCataloging() {
        showShutterButton = false
        scannerViewModel.reset()
        capturedBinId = nil
        coordinator.reviewViewModel.binId = ""
        coordinator.resetCataloging()
    }

    /// Thin wrapper that preserves the `capturedBinId == nil` early-return
    /// guard before delegating to the coordinator's retry logic.
    private func retryIngest() {
        guard let binId = capturedBinId else { return }
        coordinator.retryIngest(
            binId: binId,
            apiClient: apiClient,
            sessionManager: sessionManager,
            modelContext: modelContext
        )
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
            List {
                ForEach(viewModel.bins, id: \.binId) { bin in
                    NavigationLink(destination: BinDetailView(binId: bin.binId)) {
                        BinRowView(bin: bin)
                    }
                    // Swift2_022 — suppress swipe-to-delete on the reserved
                    // sentinel row. Server would reject it with 400
                    // cannot_delete_sentinel; the VM has a belt-and-braces
                    // guard too.
                    .deleteDisabled(BinsListViewModel.isSentinel(bin.binId))
                }
                .onDelete { offsets in
                    guard let index = offsets.first else { return }
                    let bin = viewModel.bins[index]
                    guard !BinsListViewModel.isSentinel(bin.binId) else { return }
                    binToDelete = bin
                }
            }
            .alert(
                "Delete Bin",
                isPresented: Binding(
                    get: { binToDelete != nil },
                    set: { if !$0 { binToDelete = nil } }
                ),
                presenting: binToDelete
            ) { bin in
                Button("Delete", role: .destructive) {
                    Task {
                        await viewModel.deleteBin(binId: bin.binId, apiClient: apiClient)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { bin in
                Text("Delete \"\(bin.binId)\"? Items in this bin will become binless.")
            }
            .overlay(alignment: .bottom) {
                if let toast = viewModel.toastMessage {
                    Text(toast)
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: toast) {
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            if viewModel.toastMessage == toast {
                                viewModel.toastMessage = nil
                            }
                        }
                }
            }
        }
    }
}

