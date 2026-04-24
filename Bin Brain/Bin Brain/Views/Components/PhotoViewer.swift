// PhotoViewer.swift
// Bin Brain
//
// Full-screen photo viewer with pinch-to-zoom and horizontal paging.

import SwiftUI

/// A full-screen, paginated photo viewer.
///
/// Presents the bin's full photo list with swipe-left/right navigation,
/// starting at `initialPhotoId`. Each page supports pinch-to-zoom,
/// drag-to-pan while zoomed, and double-tap to toggle fit / 2×.
/// Uses `AuthenticatedAsyncImage` so the `X-API-Key` header is attached on
/// the `/photos/{id}/file` fetch (Finding #8-B).
struct PhotoViewer: View {

    /// The full list of photos to page through. Order here is the swipe order.
    let photos: [PhotoRecord]
    /// The photo to show first when the viewer opens.
    let initialPhotoId: Int
    let apiClient: APIClient
    /// Bin items whose `sourcePhotoId` matches the current page's photo are
    /// listed at the bottom of the viewer. Pass the hosting bin's full item
    /// list; the view does the filtering per-page.
    var items: [BinItemRecord] = []

    @Environment(\.dismiss) private var dismiss
    @State private var currentPhotoId: Int

    init(
        photos: [PhotoRecord],
        initialPhotoId: Int,
        apiClient: APIClient,
        items: [BinItemRecord] = []
    ) {
        self.photos = photos
        self.initialPhotoId = initialPhotoId
        self.apiClient = apiClient
        self.items = items
        // Clamp to a photo actually in the list so a stale `initialPhotoId`
        // (e.g. after the bin reloaded) still lands on a valid page.
        let fallback = photos.first?.photoId ?? initialPhotoId
        _currentPhotoId = State(initialValue: photos.contains { $0.photoId == initialPhotoId } ? initialPhotoId : fallback)
    }

    private var connectedItems: [BinItemRecord] {
        items.filter { $0.sourcePhotoId == currentPhotoId }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                TabView(selection: $currentPhotoId) {
                    ForEach(photos, id: \.photoId) { photo in
                        PhotoPage(photoId: photo.photoId, apiClient: apiClient)
                            .tag(photo.photoId)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .automatic : .never))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                .ignoresSafeArea()

                bottomPanel
            }
            .background(Color.black)
            .ignoresSafeArea()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .principal) {
                    if photos.count > 1, let index = photos.firstIndex(where: { $0.photoId == currentPhotoId }) {
                        Text("\(index + 1) of \(photos.count)")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Bottom Panel

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Items in this photo (\(connectedItems.count))")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
            if connectedItems.isEmpty {
                Text("No items linked to this photo yet.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(connectedItems, id: \.itemId) { item in
                            HStack(spacing: 6) {
                                Text("•").foregroundStyle(.white.opacity(0.6))
                                Text(item.name)
                                    .foregroundStyle(.white)
                                if let category = item.category, !category.isEmpty {
                                    Text("· \(category)")
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                                Spacer()
                            }
                            .font(.footnote)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
            Text("Photo ID: \(currentPhotoId)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel("Photo ID \(currentPhotoId)")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 28)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

// MARK: - PhotoPage

/// A single page inside `PhotoViewer`'s paginated `TabView`.
///
/// Owns its own zoom/pan state so each photo remembers its own zoom level
/// while the user is viewing it, and a sibling page is not affected by
/// gestures on the visible page. Zoom resets when the page disappears so
/// returning to a page starts fresh.
private struct PhotoPage: View {

    let photoId: Int
    let apiClient: APIClient

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            AuthenticatedAsyncImage(photoId: photoId, apiClient: apiClient) { phase in
                switch phase {
                case .success(let uiImage):
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .offset(offset)
                        // highPriority so pan wins over TabView's swipe when zoomed.
                        .highPriorityGesture(dragGesture)
                        .gesture(magnificationGesture)
                        .onTapGesture(count: 2) { doubleTap() }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                case .failure:
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Failed to load photo")
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                case .loading:
                    ProgressView()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
        .onDisappear { resetZoom() }
    }

    // MARK: - Gestures

    private var magnificationGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let newScale = lastScale * value.magnification
                scale = min(max(newScale, 1.0), 5.0)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.0 {
                    withAnimation { resetZoom() }
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1.0 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private func doubleTap() {
        withAnimation(.easeInOut(duration: 0.25)) {
            if scale > 1.0 {
                resetZoom()
            } else {
                scale = 2.0
                lastScale = 2.0
            }
        }
    }

    private func resetZoom() {
        scale = 1.0
        lastScale = 1.0
        offset = .zero
        lastOffset = .zero
    }
}
