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
    private let defaults: UserDefaults

    // MARK: - Initializer

    /// Creates a `SearchViewModel`, reading the user's similarity threshold from `defaults`.
    ///
    /// - Parameter defaults: The `UserDefaults` suite to read. Defaults to `.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Helpers

    /// Whether tapping a search result row should navigate to the bin detail view.
    ///
    /// Returns `false` when the result has no associated bins, preventing navigation to
    /// `BinDetailView(binId: "")` which renders a broken detail screen.
    static func shouldEnableNavigation(for result: SearchResultItem) -> Bool {
        !result.bins.isEmpty
    }

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
        // object(forKey:) distinguishes "user set 0" from "never set". If the user
        // deliberately picked 0, pass it through; the server's min_score=0 excludes
        // only results with negative scores (distance > 1.0), which differs from nil
        // (no filter at all) per the /search endpoint contract in openapi.yaml.
        let minScore = defaults.object(forKey: "similarityThreshold") as? Double
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
