// PhotoViewer.swift
// Bin Brain
//
// Full-screen photo viewer with pinch-to-zoom and drag-to-dismiss.

import SwiftUI

/// A full-screen photo viewer that loads an image by photo ID via `APIClient`.
///
/// Supports pinch-to-zoom and double-tap to toggle between fit and 2x zoom.
/// Uses `AuthenticatedAsyncImage` so the `X-API-Key` header is attached on
/// the `/photos/{id}/file` fetch (Finding #8-B).
struct PhotoViewer: View {

    let photoId: Int
    let apiClient: APIClient
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                AuthenticatedAsyncImage(photoId: photoId, apiClient: apiClient) { phase in
                    switch phase {
                    case .success(let uiImage):
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(scale)
                            .offset(offset)
                            .gesture(magnificationGesture)
                            .gesture(dragGesture)
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
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
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
