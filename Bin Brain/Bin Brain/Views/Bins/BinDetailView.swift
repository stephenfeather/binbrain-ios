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
    @State private var showAddItem = false
    @State private var showCamera = false
    @State private var sortOrder: SortOrder = .name
    @State private var cameraTapCount = 0

    // Location state
    @State private var showLocationPicker = false
    @State private var displayedLocationName: String?

    // Photo viewer state
    @State private var selectedPhotoURL: URL?

    // Edit item state
    @State private var editingItem: BinItemRecord?

    // Delete confirmation state
    @State private var itemToDelete: BinItemRecord?

    // Cataloging flow state
    @State private var catalogingPath: [BinCatalogingStep] = []
    @State private var analysisViewModel = AnalysisViewModel()
    @State private var reviewViewModel = SuggestionReviewViewModel()
    @State private var captureProxy = CaptureProxy()
    @State private var capturedPhotoData: Data?

    // Model escalation
    private static let modelEscalation = ["qwen3-vl:2b", "qwen3-vl:4b", "qwen3-vl:8b"]
    @State private var currentModelIndex = 0

    // MARK: - Sort Order

    enum SortOrder { case name, confidence }

    // MARK: - Body

    var body: some View {
        content
            .navigationTitle(binId)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAddItem = true
                    } label: {
                        Image(systemName: "plus")
                    }
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
                    .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.6), trigger: cameraTapCount)
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
            .sheet(isPresented: $showCamera, onDismiss: resetCataloging) {
                cameraSheet
            }
            .fullScreenCover(isPresented: Binding(
                get: { selectedPhotoURL != nil },
                set: { if !$0 { selectedPhotoURL = nil } }
            )) {
                if let url = selectedPhotoURL {
                    PhotoViewer(url: url)
                }
            }
            .sheet(isPresented: Binding(
                get: { editingItem != nil },
                set: { if !$0 { editingItem = nil } }
            )) {
                if let item = editingItem {
                    EditItemSheet(
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
                    onPhotoCapture: { image in
                        guard let rawData = image.jpegData(compressionQuality: 1.0) else { return }
                        capturedPhotoData = rawData
                        catalogingPath.append(.analysis)
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
                reviewViewModel.loadSuggestions(suggestions)
                catalogingPath.append(.review)
            },
            onRetry: {
                Task {
                    guard let data = capturedPhotoData else { return }
                    analysisViewModel.reset()
                    await analysisViewModel.run(
                        jpegData: data,
                        binId: binId,
                        apiClient: apiClient,
                        context: modelContext
                    )
                }
            },
            onOverride: {
                Task {
                    guard let data = capturedPhotoData else { return }
                    await analysisViewModel.overrideQualityGate(
                        jpegData: data,
                        binId: binId,
                        apiClient: apiClient,
                        context: modelContext
                    )
                }
            }
        )
    }

    // MARK: - Review View

    private var reviewView: some View {
        SuggestionReviewView(
            viewModel: reviewViewModel,
            binId: binId,
            apiClient: apiClient,
            onDone: {
                showCamera = false
                Task { await viewModel.load(binId: binId, apiClient: apiClient) }
            },
            onRetryWithLargerModel: nextModelAvailable ? {
                escalateModelAndReSuggest()
            } : nil
        )
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
        captureProxy.action = nil
        capturedPhotoData = nil
        currentModelIndex = 0
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
                    if let url = apiClient.photoFileURL(photoId: photo.photoId, width: 200) {
                        Button {
                            selectedPhotoURL = apiClient.photoFileURL(photoId: photo.photoId)
                        } label: {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 100, height: 100)
                                        .clipped()
                                case .failure:
                                    placeholderThumbnail(systemName: "photo.badge.exclamationmark")
                                default:
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
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(height: 116)
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

// MARK: - EditItemSheet

private struct EditItemSheet: View {
    let item: BinItemRecord
    let binId: String
    let apiClient: APIClient
    let viewModel: BinDetailViewModel
    @Binding var isPresented: Bool

    @State private var quantityText: String = ""
    @State private var confidenceText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Name")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(item.name)
                    }
                    if let category = item.category {
                        HStack {
                            Text("Category")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(category)
                        }
                    }
                }

                Section("Editable Fields") {
                    TextField("Quantity", text: $quantityText)
                        .keyboardType(.decimalPad)
                    TextField("Confidence (0–1)", text: $confidenceText)
                        .keyboardType(.decimalPad)
                }
            }
            .navigationTitle("Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let newQuantity = Double(quantityText)
                        let newConfidence = Double(confidenceText)
                        isPresented = false
                        Task {
                            await viewModel.updateItem(
                                itemId: item.itemId,
                                quantity: newQuantity,
                                confidence: newConfidence,
                                binId: binId,
                                apiClient: apiClient
                            )
                        }
                    }
                    .disabled(!hasChanges)
                }
            }
            .onAppear {
                if let q = item.quantity {
                    quantityText = String(format: "%.0f", q)
                }
                if let c = item.confidence {
                    confidenceText = String(format: "%.2f", c)
                }
            }
        }
    }

    private var hasChanges: Bool {
        let newQuantity = Double(quantityText)
        let newConfidence = Double(confidenceText)
        let quantityChanged = newQuantity != item.quantity
        let confidenceChanged = newConfidence != item.confidence
        return quantityChanged || confidenceChanged
    }
}
