// BinDetailView.swift
// Bin Brain
//
// Detail screen for a single bin.
// Displays items and photos; supports adding new items and scanning.

import SwiftUI
import SwiftData

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

    // Cataloging coordinator — owns all shared cataloging state and actions
    @State private var coordinator = CatalogingCoordinator()

    // MARK: - Sort Order

    enum SortOrder { case name, confidence }

    // MARK: - Body

    var body: some View {
        content
            // Swift2_022 G-1 — route the nav-bar title through the display-
            // name mapping so the reserved sentinel renders as "Binless"
            // instead of the raw server id "UNASSIGNED".
            .navigationTitle(BinsListViewModel.displayName(for: binId))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sortOrder) {
                            Label("Name", systemImage: "textformat").tag(SortOrder.name)
                            Label("Confidence", systemImage: "checkmark.seal").tag(SortOrder.confidence)
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Sort items")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        cameraTapCount += 1
                        showCamera = true
                    } label: {
                        Image(systemName: "camera")
                    }
                    .accessibilityLabel("Take photo")
                    .sensoryFeedback(.success, trigger: cameraTapCount)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAddItem = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("Add manually")
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
            .fullScreenCover(isPresented: $showCamera, onDismiss: { coordinator.resetCataloging() }) {
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
        @Bindable var c = coordinator
        NavigationStack(path: $c.path) {
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
                        guard coordinator.path.isEmpty else { return }
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
                        coordinator.capturedPhotoData = rawData
                        coordinator.capturedCameraContext = cameraContext
                        // Swift2_012 — seed VM-durable binId from the view's
                        // stable `let binId` before navigating to analysis.
                        coordinator.reviewViewModel.binId = binId
                        coordinator.path.append(.analysis)
                        // startAnalysis captures liveBarcode at call time (before
                        // its internal Task) so the UPC snapshot is accurate even
                        // if the user moved the camera between scan and shutter.
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
                    },
                    awaitsQR: false
                )
                .ignoresSafeArea()

                VStack {
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
                        .padding(.top, 16)
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
            .navigationTitle("Scan Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCamera = false }
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
        AnalysisStepView(coordinator: coordinator, binIdProvider: { binId })
    }

    // MARK: - Review View

    private var reviewView: some View {
        ReviewStepView(
            coordinator: coordinator,
            onDone: {
                // Swift2_027 — pop the inner NavigationStack FIRST so the
                // .analysis/.review pushes unwind before the fullScreenCover
                // tears down. resetCataloging() (cover's onDismiss) also
                // clears the path, but it runs *after* the cover has finished
                // dismissing — too late to prevent SwiftUI rendering a blank
                // intermediate frame.
                coordinator.path = []
                showCamera = false
                Task { await viewModel.load(binId: binId, apiClient: apiClient) }
            }
        )
        .alert(
            "Analysis Failed",
            isPresented: Binding(
                get: { coordinator.ingestErrorMessage != nil },
                set: { if !$0 { coordinator.ingestErrorMessage = nil } }
            ),
            presenting: coordinator.ingestErrorMessage
        ) { _ in
            Button("Retry") {
                coordinator.retryIngest(
                    binId: binId,
                    apiClient: apiClient,
                    sessionManager: sessionManager,
                    modelContext: modelContext
                )
            }
            Button("Cancel", role: .cancel) {
                coordinator.ingestErrorMessage = nil
                coordinator.path = []
                showCamera = false
            }
        } message: { message in
            Text(message)
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
            // scroll's gesture priority over the ancestor `.refreshable`.
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

