// ItemDetailView.swift
// Bin Brain
//
// FEAT-5: Shows the source photo + bbox overlay an item was added from,
// alongside editable metadata. Replaces the plain EditItemSheet — when an
// item has no source_photo_id (older items created before the outcomes
// backfill), the photo block is omitted and the view degrades to the
// editable form alone.

import SwiftUI

struct ItemDetailView: View {
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
                if let photoId = item.sourcePhotoId {
                    Section("Source Photo") {
                        SourcePhotoCard(
                            photoId: photoId,
                            bbox: item.sourceBbox,
                            apiClient: apiClient
                        )
                        .listRowInsets(EdgeInsets())
                    }
                }

                Section {
                    HStack {
                        Text("Name").foregroundStyle(.secondary)
                        Spacer()
                        Text(item.name)
                    }
                    if let category = item.category {
                        HStack {
                            Text("Category").foregroundStyle(.secondary)
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
            .navigationTitle("Item Details")
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
        return newQuantity != item.quantity || newConfidence != item.confidence
    }
}

// MARK: - SourcePhotoCard

/// Renders the source photo with an optional bbox highlight. Aspect-fit math
/// matches `SuggestionReviewView.bboxRect` so the overlay aligns regardless
/// of photo dimensions.
private struct SourcePhotoCard: View {
    let photoId: Int
    let bbox: [Float]?
    let apiClient: APIClient

    var body: some View {
        AuthenticatedAsyncImage(photoId: photoId, width: 1024, apiClient: apiClient) { phase in
            switch phase {
            case .success(let uiImage):
                photoContent(uiImage: uiImage)
            case .failure:
                placeholder(systemName: "photo.badge.exclamationmark")
            case .loading:
                placeholder(systemName: "photo")
                    .overlay(ProgressView())
            }
        }
    }

    private func photoContent(uiImage: UIImage) -> some View {
        GeometryReader { geo in
            ZStack {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.height)

                if let bbox, let rect = bboxRect(bbox, imageSize: uiImage.size, frameSize: geo.size) {
                    Path { path in path.addRect(rect) }
                        .stroke(Color.yellow, lineWidth: 2)
                }
            }
        }
        .aspectRatio(uiImage.size, contentMode: .fit)
    }

    private func placeholder(systemName: String) -> some View {
        Rectangle()
            .fill(Color(.secondarySystemBackground))
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay(
                Image(systemName: systemName)
                    .foregroundStyle(.tertiary)
            )
    }

    /// Maps normalized `[x1, y1, x2, y2]` bbox coords to display-space `CGRect`
    /// under `.aspectRatio(.fit)` letterboxing. Mirrors the implementation in
    /// `SuggestionReviewView.bboxRect` — kept local to avoid premature
    /// abstraction; extract to a shared helper if a third caller appears.
    private func bboxRect(_ bbox: [Float], imageSize: CGSize, frameSize: CGSize) -> CGRect? {
        guard bbox.count == 4, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let scale = min(frameSize.width / imageSize.width, frameSize.height / imageSize.height)
        let renderedW = imageSize.width * scale
        let renderedH = imageSize.height * scale
        let ox = (frameSize.width - renderedW) / 2
        let oy = (frameSize.height - renderedH) / 2
        let c0 = CGFloat(min(max(bbox[0], 0), 1))
        let c1 = CGFloat(min(max(bbox[1], 0), 1))
        let c2 = CGFloat(min(max(bbox[2], 0), 1))
        let c3 = CGFloat(min(max(bbox[3], 0), 1))
        let x1 = ox + c0 * renderedW
        let y1 = oy + c1 * renderedH
        let x2 = ox + c2 * renderedW
        let y2 = oy + c3 * renderedH
        guard x2 > x1, y2 > y1 else { return nil }
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }
}
