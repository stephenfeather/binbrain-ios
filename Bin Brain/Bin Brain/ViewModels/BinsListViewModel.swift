// BinsListViewModel.swift
// Bin Brain
//
// ViewModel for the Bins list screen.
// Manages fetching and exposing the list of bins.

import Foundation
import Observation

// MARK: - BinsListViewModel

/// Manages the state for the bins list screen.
///
/// Call `load(apiClient:)` to fetch all bins. Observe `bins`, `isLoading`,
/// and `error` in `BinsListView`.
@Observable
final class BinsListViewModel {

    // MARK: - State

    /// The list of bin summaries returned by the server.
    private(set) var bins: [BinSummary] = []

    /// `true` while a network request is in flight.
    private(set) var isLoading: Bool = false

    /// A human-readable error message set when `load` fails; `nil` otherwise.
    private(set) var error: String? = nil

    // MARK: - Actions

    /// Fetches all bins from the server.
    ///
    /// Sets `isLoading` to `true` during the call. On success, populates `bins`
    /// and clears `error`. On failure, sets `error` and leaves `bins` unchanged.
    ///
    /// - Parameter apiClient: The `APIClient` instance to use for the request.
    func load(apiClient: APIClient) async {
        isLoading = true
        error = nil
        do {
            bins = try await apiClient.listBins()
            // listBins() already sorts alphanumerically client-side — do not re-sort
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
