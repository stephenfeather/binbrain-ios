// BinDetailView.swift
// Bin Brain
//
// Detail screen for a single bin.
// Displays items and photos; supports adding new items and scanning.

import SwiftUI
import SwiftData

// MARK: - BinDetailCaptureProxy

/// Reference-type container for the scanner's capture action.
private final class CaptureProxy {
    var action: (() -> Void)?
}

// MARK: - BinCatalogingStep

private enum BinCatalogingStep: Hashable {
    case analysis
    case review
}

// MARK: - BinDetailView

/// The detail screen for a single storage bin.
///
/// Loads bin contents on appear. Supports sorting by name or confidence,
/// adding items manually, and scanning new photos.
struct BinDetailView: View {

    // MARK: - Properties

    let binId: String

    // MARK: - State

    @State private var viewModel = BinDetailViewModel()
    @Environment(\.apiClient) private var apiClient
    @Environment(\.modelContext) private var modelContext
    @Environment(\.outcomeQueueManager) private var outcomeQueueManager
    @Environment(\.sessionManager) private var sessionManager
    @State private var showAddItem = false
    @State private var showCamera = false
    @State private var sortOrder: SortOrder = .name
    @State private var cameraTapCount = 0

    // Location state
    @State private var showLocationPicker = false
    @State private var displayedLocationName: String?

    // Photo viewer state
    @State private var selectedPhotoId: Int?

    // Edit item state
    @State private var editingItem: BinItemRecord?

    // Delete confirmation state
    @State private var itemToDelete: BinItemRecord?

    // Cataloging flow state
    @State private var catalogingPath: [BinCatalogingStep] = []
    @State private var analysisViewModel = AnalysisViewModel()
    @State private var catalogingSession = CatalogingSession()
    @State private var reviewViewModel = SuggestionReviewViewModel()
    @State private var captureProxy = CaptureProxy()
    @State private var capturedPhotoData: Data?
    /// Camera telemetry captured alongside `capturedPhotoData`. Retained so a
    /// retry after an /ingest failure can re-submit with the original metadata.
    @State private var capturedCameraContext: CameraCaptureContext?
    /// Non-nil when /ingest (or /suggest) failed after the user had already
    /// navigated to the preliminary review screen. Drives the retry alert.
    @State private var ingestErrorMessage: String?
    /// True once preliminary on-device chips have been loaded and navigation
    /// to `.review` happened early (Mode A). Drives how `onComplete` merges.
    @State private var navigatedOnPreliminary = false
    /// Top-K chips to surface as preliminary (Mode A, Phase 1).
    private static let preliminaryTopK = 10

    // Model escalation
    private static let modelEscalation = ["qwen3-vl:2b", "qwen3-vl:4b", "qwen3-vl:8b"]
    @State private var currentModelIndex = 0

    // MARK: - Sort Order

    enum SortOrder { case name, confidence }

    // MARK: - Body

    var body: some View {
        let _ = print("[BIND] body binId=\(binId)")
        content
            // Swift2_022 G-1 — route the nav-bar title through the display-
            // name mapping so the reserved sentinel renders as "Binless"
            // instead of the raw server id "UNASSIGNED".
            .navigationTitle(BinsListViewModel.displayName(for: binId))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        cameraTapCount += 1
                        showCamera = true
                    } label: {
                        Image(systemName: "camera")
                    }
                    .accessibilityLabel("Take photo")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAddItem = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("Add manually")
                }
                ToolbarItem(placement: .bottomBar) {
                    Picker("Sort", selection: $sortOrder) {
                        Text("Name").tag(SortOrder.name)
                        Text("Confidence").tag(SortOrder.confidence)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        cameraTapCount += 1
                        showCamera = true
                    } label: {
                        Image(systemName: "camera.fill")
                            .font(.title2)
                    }
                    .accessibilityLabel("Scan item into this bin")
                    .sensoryFeedback(.success, trigger: cameraTapCount)
                }
            }
            .task {
                await viewModel.load(binId: binId, apiClient: apiClient)
                displayedLocationName = viewModel.bin?.locationName
            }
            .refreshable {
                await viewModel.load(binId: binId, apiClient: apiClient)
                displayedLocationName = viewModel.bin?.locationName
            }
            .sheet(isPresented: $showAddItem) {
                AddItemSheet(
                    binId: binId,
                    apiClient: apiClient,
                    viewModel: viewModel,
                    isPresented: $showAddItem
                )
            }
            // fullScreenCover instead of sheet: .sheet is dismissed when the
            // horizontal size class changes on rotation (compact→regular on
            // large iPhones). fullScreenCover fills the whole screen regardless
            // of orientation, so the ScannerView + NavigationStack survive rotation.
            .fullScreenCover(isPresented: $showCamera, onDismiss: resetCataloging) {
                cameraSheet
            }
            .fullScreenCover(isPresented: Binding(
                get: { selectedPhotoId != nil },
                set: { if !$0 { selectedPhotoId = nil } }
            )) {
                if let id = selectedPhotoId {
                    PhotoViewer(
                        photos: viewModel.bin?.photos ?? [],
                        initialPhotoId: id,
                        apiClient: apiClient,
                        items: viewModel.bin?.items ?? []
                    )
                }
            }
            .sheet(isPresented: Binding(
                get: { editingItem != nil },
                set: { if !$0 { editingItem = nil } }
            )) {
                if let item = editingItem {
                    ItemDetailView(
                        item: item,
                        binId: binId,
                        apiClient: apiClient,
                        viewModel: viewModel,
                        isPresented: Binding(
                            get: { editingItem != nil },
                            set: { if !$0 { editingItem = nil } }
                        )
                    )
                }
            }
            .sheet(isPresented: $showLocationPicker) {
                LocationPickerSheet(
                    binId: binId,
                    currentLocationName: displayedLocationName,
                    onLocationChanged: { newName in
                        displayedLocationName = newName
                    }
                )
            }
            .alert(
                "Remove Item",
                isPresented: Binding(
                    get: { itemToDelete != nil },
                    set: { if !$0 { itemToDelete = nil } }
                ),
                presenting: itemToDelete
            ) { item in
                Button("Remove", role: .destructive) {
                    Task {
                        await viewModel.removeItem(
                            itemId: item.itemId,
                            binId: binId,
                            apiClient: apiClient
                        )
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                Text("Remove \"\(item.name)\" from this bin? The item will remain in the catalogue.")
            }
    }

    // MARK: - Camera Sheet

    @ViewBuilder
    private var cameraSheet: some View {
        NavigationStack(path: $catalogingPath) {
            ZStack {
                ScannerView(
                    showShutterButton: .constant(true),
                    onQRCode: { _ in },
                    onPhotoCapture: { image, cameraContext in
                        // Debounce: a second shutter tap that lands before
                        // SwiftUI pushes the analysis destination would push
                        // a duplicate, producing two stacked quality-gate
                        // screens. Drop captures that arrive after the path
                        // has already advanced.
                        guard catalogingPath.isEmpty else { return }
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
                        guard let rawData = oriented.jpegData(compressionQuality: 1.0) else { return }
                        capturedPhotoData = rawData
                        capturedCameraContext = cameraContext
                        // Swift2_012 — seed VM-durable binId from the view's
                        // stable `let binId` before navigating to analysis.
                        reviewViewModel.binId = binId
                        catalogingPath.append(.analysis)
                        Task {
                            // Swift2_019 — transparently open a session on
                            // the first photo so the natural "open app, tap
                            // shutter" flow still works. SessionManager
                            // caches the id for subsequent captures and
                            // auto-closes after 30 min of inactivity.
                            // Swift2_019b — pass the manager so AnalysisViewModel
                            // can invalidate + retry on 400 invalid_session.
                            let sessionId = try? await sessionManager.activeSessionId(apiClient: apiClient)
                            await analysisViewModel.run(
                                jpegData: rawData,
                                binId: binId,
                                apiClient: apiClient,
                                sessionId: sessionId,
                                sessionManager: sessionManager,
                                context: modelContext,
                                cameraContext: cameraContext,
                                userBehavior: catalogingSession.snapshot()
                            )
                        }
                    },
                    onCaptureReady: { action in
                        captureProxy.action = action
                    }
                )
                .ignoresSafeArea()

                VStack {
                    Spacer()
                    Button(action: { captureProxy.action?() }) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 72, height: 72)
                            .overlay(Circle().stroke(Color.gray.opacity(0.4), lineWidth: 2))
                            .shadow(radius: 4)
                    }
                    .accessibilityLabel("Take photo")
                    .disabled(!catalogingPath.isEmpty)
                    .padding(.bottom, 50)
                }
            }
            .navigationTitle("Scan Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCamera = false }
                }
            }
            .navigationDestination(for: BinCatalogingStep.self) { step in
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
                    reviewViewModel.applyServerSuggestions(
                        suggestions,
                        photoId: analysisViewModel.lastPhotoId,
                        visionModel: analysisViewModel.lastVisionModel,
                        promptVersion: analysisViewModel.lastPromptVersion
                    )
                } else {
                    reviewViewModel.loadSuggestions(
                        suggestions,
                        photoId: analysisViewModel.lastPhotoId,
                        visionModel: analysisViewModel.lastVisionModel,
                        promptVersion: analysisViewModel.lastPromptVersion
                    )
                    catalogingPath.append(.review)
                }
            },
            onRetry: {
                // Finding #4-UX-2: "Retake Photo" must return to the camera so
                // the user can capture a fresh frame. The previous implementation
                // re-ran analysis on the SAME (still-blurry) photo.
                catalogingSession.recordRetake()
                analysisViewModel.reset()
                navigatedOnPreliminary = false
                capturedPhotoData = nil
                catalogingPath.removeAll()
            },
            onOverride: {
                catalogingSession.recordQualityBypass()
                Task {
                    guard let data = capturedPhotoData else { return }
                    navigatedOnPreliminary = false
                    let sessionId = try? await sessionManager.activeSessionId(apiClient: apiClient)
                    await analysisViewModel.overrideQualityGate(
                        jpegData: data,
                        binId: binId,
                        apiClient: apiClient,
                        sessionId: sessionId,
                        sessionManager: sessionManager,
                        context: modelContext,
                        userBehavior: catalogingSession.snapshot()
                    )
                }
            },
            onPreliminaryReady: { classifications, ocr in
                reviewViewModel.photoData = analysisViewModel.lastUploadedPhotoData
                reviewViewModel.loadPreliminaryFromOnDevice(
                    classifications: classifications,
                    ocr: ocr,
                    topK: Self.preliminaryTopK
                )
                navigatedOnPreliminary = true
                catalogingPath.append(.review)
            }
        )
    }

    // MARK: - Review View

    private var reviewView: some View {
        let _ = print("[BIND] reviewView binId=\(binId) vmBinId=\(reviewViewModel.binId)")
        return SuggestionReviewView(
            viewModel: reviewViewModel,
            apiClient: apiClient,
            onDone: {
                // Swift2_027 — pop the inner NavigationStack FIRST so the
                // .analysis/.review pushes unwind before the fullScreenCover
                // tears down. resetCataloging() (cover's onDismiss) also
                // clears the path, but it runs *after* the cover has finished
                // dismissing — too late to prevent SwiftUI rendering a blank
                // intermediate frame with just the parent's back arrow when
                // the user taps Dismiss on a preliminary-only result.
                catalogingPath = []
                showCamera = false
                Task { await viewModel.load(binId: binId, apiClient: apiClient) }
            },
            onRetryWithLargerModel: nextModelAvailable ? {
                escalateModelAndReSuggest()
            } : nil
        )
        // Swift2_018 — inject the durable outcomes queue + context so
        // confirm() persists each outcomes POST instead of firing it as a
        // one-shot detached Task. Both must be set before confirm() runs.
        .onAppear {
            reviewViewModel.outcomeQueueManager = outcomeQueueManager
            reviewViewModel.outcomeQueueContext = modelContext
        }
        // Same fix as BinsListView: observe phase on the visible view, not the background AnalysisProgressView.
        .onChange(of: analysisViewModel.phase) { _, newPhase in
            guard navigatedOnPreliminary else { return }
            switch newPhase {
            case .complete:
                reviewViewModel.photoData = analysisViewModel.lastUploadedPhotoData
                reviewViewModel.applyServerSuggestions(
                    analysisViewModel.suggestions,
                    photoId: analysisViewModel.lastPhotoId,
                    visionModel: analysisViewModel.lastVisionModel,
                    promptVersion: analysisViewModel.lastPromptVersion
                )
            case .failed(let message):
                // The review screen owns the alert because the parent owns the
                // API call — without this hook the user would be stuck on a
                // permanent "Working…" spinner with no way to resubmit.
                ingestErrorMessage = message
            default:
                break
            }
        }
        .alert(
            "Analysis Failed",
            isPresented: Binding(
                get: { ingestErrorMessage != nil },
                set: { if !$0 { ingestErrorMessage = nil } }
            ),
            presenting: ingestErrorMessage
        ) { _ in
            Button("Retry") { retryIngest() }
            Button("Cancel", role: .cancel) {
                ingestErrorMessage = nil
                catalogingPath = []
                showCamera = false
            }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Cataloging Helpers

    private var nextModelAvailable: Bool {
        currentModelIndex + 1 < Self.modelEscalation.count
    }

    private func escalateModelAndReSuggest() {
        guard nextModelAvailable else { return }
        currentModelIndex += 1
        let nextModel = Self.modelEscalation[currentModelIndex]
        // Pop back to analysis screen, select the larger model, re-suggest
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
        analysisViewModel.reset()
        catalogingSession.reset()
        captureProxy.action = nil
        capturedPhotoData = nil
        capturedCameraContext = nil
        ingestErrorMessage = nil
        currentModelIndex = 0
        navigatedOnPreliminary = false
    }

    private func retryIngest() {
        guard let data = capturedPhotoData else { return }
        ingestErrorMessage = nil
        Task {
            let sessionId = try? await sessionManager.activeSessionId(apiClient: apiClient)
            await analysisViewModel.run(
                jpegData: data,
                binId: binId,
                apiClient: apiClient,
                sessionId: sessionId,
                sessionManager: sessionManager,
                context: modelContext,
                cameraContext: capturedCameraContext,
                userBehavior: catalogingSession.snapshot()
            )
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.bin == nil {
            ProgressView()
        } else if let errorMessage = viewModel.error {
            VStack(spacing: 12) {
                Text(errorMessage).foregroundStyle(.secondary)
                Button("Retry") {
                    Task { await viewModel.load(binId: binId, apiClient: apiClient) }
                }
            }
        } else if let bin = viewModel.bin {
            loadedView(bin: bin)
        } else {
            ProgressView()
        }
    }

    // MARK: - Loaded View

    @ViewBuilder
    private func loadedView(bin: GetBinResponse) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(bin.items.count) items")
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(bin.photos.count) scans")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding([.horizontal, .top])

            Button {
                showLocationPicker = true
            } label: {
                HStack {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(.secondary)
                    Text(displayedLocationName ?? "No location")
                        .foregroundStyle(displayedLocationName != nil ? .primary : .secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .tint(.primary)
            .accessibilityLabel("Location: \(displayedLocationName ?? "none")")
            .accessibilityHint("Double-tap to change location")

            if !bin.photos.isEmpty {
                photoStrip(photos: bin.photos)
            }

            List {
                ForEach(sortedItems(bin.items), id: \.itemId) { item in
                    ItemRowView(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture { editingItem = item }
                }
                .onDelete { offsets in
                    let sorted = sortedItems(bin.items)
                    if let index = offsets.first {
                        itemToDelete = sorted[index]
                    }
                }
            }
        }
    }

    // MARK: - Photo Strip

    @ViewBuilder
    private func photoStrip(photos: [PhotoRecord]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(photos, id: \.photoId) { photo in
                    Button {
                        selectedPhotoId = photo.photoId
                    } label: {
                        AuthenticatedAsyncImage(
                            photoId: photo.photoId,
                            width: 200,
                            apiClient: apiClient
                        ) { phase in
                            switch phase {
                            case .success(let uiImage):
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 100, height: 100)
                                    .clipped()
                            case .failure:
                                placeholderThumbnail(systemName: "photo.badge.exclamationmark")
                            case .loading:
                                placeholderThumbnail(systemName: "photo")
                                    .overlay(ProgressView())
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Scan photo")
                    .accessibilityHint("Double-tap to view full size")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            // Swift2_025 — declaring the LazyHStack as a scroll target lets
            // `.scrollTargetBehavior(.viewAligned)` raise this horizontal
            // scroll's gesture priority over the ancestor `.refreshable`, so a
            // sideways swipe on the photo strip no longer flickers the
            // pull-to-refresh indicator. Side benefit: thumbnails snap to
            // alignment on release, which reads as more deliberate.
            .scrollTargetLayout()
        }
        .frame(height: 116)
        .scrollTargetBehavior(.viewAligned)
    }

    private func placeholderThumbnail(systemName: String) -> some View {
        Rectangle()
            .fill(Color(.secondarySystemBackground))
            .frame(width: 100, height: 100)
            .overlay(
                Image(systemName: systemName)
                    .foregroundStyle(.tertiary)
            )
    }

    // MARK: - Helpers

    private func sortedItems(_ items: [BinItemRecord]) -> [BinItemRecord] {
        switch sortOrder {
        case .name:
            return items.sorted { $0.name < $1.name }
        case .confidence:
            return items.sorted { ($0.confidence ?? 0) > ($1.confidence ?? 0) }
        }
    }
}

// MARK: - ItemRowView

private struct ItemRowView: View {
    let item: BinItemRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.headline)
                Text(item.category ?? "Uncategorized").font(.subheadline).foregroundStyle(.secondary)
                if let quantity = item.quantity {
                    Text("Qty: \(quantity, specifier: "%.0f")").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let confidence = item.confidence {
                ConfidenceBadge(confidence: confidence)
            }
        }
    }
}

// MARK: - AddItemSheet

private struct AddItemSheet: View {
    let binId: String
    let apiClient: APIClient
    let viewModel: BinDetailViewModel
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var category: String = ""
    @State private var quantityText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Item Details") {
                    TextField("Name", text: $name)
                    TextField("Category (optional)", text: $category)
                    TextField("Quantity (optional)", text: $quantityText)
                        .keyboardType(.decimalPad)
                }
            }
            .navigationTitle("Add Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmedName = name.trimmingCharacters(in: .whitespaces)
                        guard !trimmedName.isEmpty else { return }
                        let trimmedCategory = category.trimmingCharacters(in: .whitespaces)
                        let categoryValue = trimmedCategory.isEmpty ? nil : trimmedCategory
                        let quantityValue = Double(quantityText)
                        isPresented = false
                        Task {
                            await viewModel.addItem(
                                name: trimmedName,
                                category: categoryValue,
                                quantity: quantityValue,
                                binId: binId,
                                apiClient: apiClient
                            )
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

