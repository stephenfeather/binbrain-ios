// SearchViewModel.swift
// Bin Brain
//
// ViewModel for the Search screen.
// Manages debounced search and exposes results to SearchView.

import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "com.binbrain.app", category: "Search")

// MARK: - SearchViewModel

/// Manages the state for the search screen.
///
/// Bind `query` via `@Bindable` + `.searchable`. Call `scheduleSearch(apiClient:)`
/// on `query` changes. Observe `results` and `isSearching` in `SearchView`.
@Observable
final class SearchViewModel {

    // MARK: - State

    /// The current search query text. Bound to `.searchable` in the view.
    var query: String = ""

    /// The list of search results returned by the server.
    private(set) var results: [SearchResultItem] = []

    /// `true` while a network request is in flight.
    private(set) var isSearching: Bool = false

    /// The localized message from the most recent search failure, or `nil`
    /// if the last search succeeded (or none has been run).
    private(set) var error: String?

    // MARK: - Private State

    private var searchTask: Task<Void, Never>?

    // MARK: - Actions

    /// Cancels any pending debounced search and schedules a new one 300 ms out.
    ///
    /// Clears `results` immediately if `query` is empty.
    ///
    /// - Parameter apiClient: The `APIClient` instance to use for the request.
    func scheduleSearch(apiClient: APIClient) {
        searchTask?.cancel()
        guard !query.isEmpty else {
            results = []
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.performSearch(apiClient: apiClient)
        }
    }

    /// Executes the search immediately without debouncing.
    ///
    /// Sets `isSearching` to `true` during the call. On success, populates `results`
    /// and clears `error`. On failure, clears `results`, logs the error via
    /// `os.Logger`, and sets `error` to the localized description so the view can
    /// surface it to the user.
    ///
    /// - Parameter apiClient: The `APIClient` instance to use for the request.
    func performSearch(apiClient: APIClient) async {
        guard !query.isEmpty else { results = []; error = nil; return }
        isSearching = true
        let minScoreRaw = UserDefaults.standard.double(forKey: "similarityThreshold")
        let minScore: Double? = minScoreRaw > 0 ? minScoreRaw : nil
        do {
            let response = try await apiClient.search(query: query, minScore: minScore)
            results = response.results
            error = nil
        } catch {
            logger.error("search failed: \(error.localizedDescription)")
            results = []
            self.error = error.localizedDescription
        }
        isSearching = false
    }
}
