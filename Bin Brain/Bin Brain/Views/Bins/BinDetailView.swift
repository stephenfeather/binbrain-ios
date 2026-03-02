// BinDetailView.swift
// Bin Brain
//
// Detail screen for a single bin.
// Displays items and photos; supports adding new items and scanning.

import SwiftUI

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

    // Cataloging flow state
    @State private var catalogingPath: [BinCatalogingStep] = []
    @State private var analysisViewModel = AnalysisViewModel()
    @State private var reviewViewModel = SuggestionReviewViewModel()
    @State private var captureProxy = CaptureProxy()
    @State private var capturedPhotoData: Data?

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
                        showCamera = true
                    } label: {
                        Image(systemName: "camera.fill")
                            .font(.title2)
                    }
                }
            }
            .task { await viewModel.load(binId: binId, apiClient: apiClient) }
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
            }
        )
    }

    // MARK: - Cataloging Helpers

    private func resetCataloging() {
        catalogingPath = []
        analysisViewModel.reset()
        captureProxy.action = nil
        capturedPhotoData = nil
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
            Text("\(bin.photos.count) photos")
                .font(.subheadline)
                .padding([.horizontal, .top])

            List(sortedItems(bin.items), id: \.itemId) { item in
                ItemRowView(item: item)
            }
        }
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
