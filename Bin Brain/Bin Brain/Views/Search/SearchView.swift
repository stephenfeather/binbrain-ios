// SearchView.swift
// Bin Brain
//
// The Search screen — lets users search the item catalogue using natural language.

import SwiftUI

// MARK: - SearchView

/// The search screen. Provides a `.searchable` bar and displays results
/// returned by `SearchViewModel`.
struct SearchView: View {

    // MARK: - State

    @State private var viewModel = SearchViewModel()
    @Environment(\.apiClient) private var apiClient
    @Environment(\.embeddedInSplitView) private var embeddedInSplitView

    // MARK: - Body

    var body: some View {
        if embeddedInSplitView {
            searchContent
        } else {
            NavigationStack {
                searchContent
            }
        }
    }

    private var searchContent: some View {
        content
            .navigationTitle("Search")
            .searchable(text: $viewModel.query, prompt: "Search items...")
            .onChange(of: viewModel.query) { _, _ in
                viewModel.scheduleSearch(apiClient: apiClient)
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.query.isEmpty {
            Text("Search for items across all bins")
                .foregroundStyle(.secondary)
        } else if viewModel.isSearching {
            ProgressView()
        } else if viewModel.results.isEmpty {
            Text("No results for \"\(viewModel.query)\"")
                .foregroundStyle(.secondary)
        } else {
            List(viewModel.results, id: \.itemId) { result in
                if SearchViewModel.shouldEnableNavigation(for: result),
                   let binId = result.bins.first {
                    NavigationLink(destination: BinDetailView(binId: binId)) {
                        SearchResultRowView(result: result)
                    }
                } else {
                    SearchResultRowView(result: result)
                }
            }
        }
    }
}

// MARK: - SearchResultRowView

private struct SearchResultRowView: View {
    let result: SearchResultItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.name).font(.headline)
            Text(result.category ?? "Uncategorized")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Found in \(result.bins.isEmpty ? "unknown" : result.bins.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: "%.0f%% match", result.score * 100))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
