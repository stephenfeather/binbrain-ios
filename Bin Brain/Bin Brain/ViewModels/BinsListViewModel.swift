// BinsListViewModel.swift
// Bin Brain
//
// ViewModel for the Bins list screen.
// Manages fetching and exposing the list of bins.

import Foundation
import OSLog
import Observation

private let logger = Logger(subsystem: "com.binbrain.app", category: "BinsListViewModel")

// MARK: - BinsListViewModel

/// Manages the state for the bins list screen.
///
/// Call `load(apiClient:)` to fetch all bins. Observe `bins`, `isLoading`,
/// and `error` in `BinsListView`.
@Observable
final class BinsListViewModel {

    // MARK: - Sentinel (Swift2_022)

    /// The reserved bin id returned by the server for items that have lost
    /// their parent bin. Never shown to the user — `displayName(for:)`
    /// remaps it to `sentinelDisplayName`.
    static let sentinelBinId = "UNASSIGNED"

    /// The user-facing label for the sentinel row.
    static let sentinelDisplayName = "Binless"

    /// Whether the given bin id is the reserved sentinel. The UI uses this
    /// to suppress the swipe-to-delete affordance.
    static func isSentinel(_ binId: String) -> Bool {
        binId == sentinelBinId
    }

    /// Display-name remap — the raw `UNASSIGNED` string must never appear
    /// in the UI.
    static func displayName(for binId: String) -> String {
        isSentinel(binId) ? sentinelDisplayName : binId
    }

    // MARK: - State

    /// The list of bin summaries with the sentinel (if present) pinned at
    /// index 0 and all other bins in the order `APIClient.listBins()`
    /// returned them (alphanumeric ascending).
    private(set) var bins: [BinSummary] = []

    /// `true` while a network request is in flight.
    private(set) var isLoading: Bool = false

    /// A human-readable error message set when the delete path fails with
    /// a non-404 server error; `nil` otherwise. `load` failures populate
    /// this too for backwards-compat with the existing Retry UI.
    private(set) var error: String? = nil

    /// A short-lived status string set by `deleteBin` for toast presentation.
    /// The view owns dismissal (e.g. `.task` with a delay + self-clear).
    var toastMessage: String? = nil

    // MARK: - Actions

    /// Fetches all bins from the server.
    ///
    /// Sets `isLoading` to `true` during the call. On success, populates `bins`
    /// (sentinel-pinned) and clears `error`. On failure, sets `error` and
    /// leaves `bins` unchanged.
    ///
    /// - Parameter apiClient: The `APIClient` instance to use for the request.
    func load(apiClient: APIClient) async {
        isLoading = true
        error = nil
        do {
            let fetched = try await apiClient.listBins()
            // listBins() already sorts alphanumerically client-side; pin the
            // sentinel to the top without disturbing the rest of that order.
            bins = Self.pinSentinelFirst(fetched)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// Soft-deletes a bin via `DELETE /bins/{id}` and refreshes the list.
    ///
    /// - UI-level sentinel guard: a call for `UNASSIGNED` is short-circuited
    ///   with a warning log. Defense in depth — the view layer should never
    ///   offer the affordance, but this keeps the invariant enforceable from
    ///   a unit test.
    /// - On 200: sets a toast citing `moved_item_count` and reloads.
    /// - On 404: treats the bin as already-gone; reloads and surfaces a brief
    ///   "Bin no longer exists" message.
    /// - On other errors: surfaces the server message in `error` so the user
    ///   sees what happened.
    func deleteBin(binId: String, apiClient: APIClient) async {
        guard !Self.isSentinel(binId) else {
            logger.warning("Refused UI-level delete of sentinel bin — the affordance should be suppressed in the view layer")
            return
        }
        do {
            if let response = try await apiClient.deleteBin(binId: binId) {
                toastMessage = "Deleted \"\(binId)\" — \(response.movedItemCount) items became binless"
            } else {
                // 404 — bin already gone. Not an error condition, but the
                // user deserves to know their action was a no-op.
                toastMessage = "Bin no longer exists"
            }
            await load(apiClient: apiClient)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Private

    private static func pinSentinelFirst(_ bins: [BinSummary]) -> [BinSummary] {
        guard let sentinelIndex = bins.firstIndex(where: { isSentinel($0.binId) }) else {
            return bins
        }
        var reordered = bins
        let sentinel = reordered.remove(at: sentinelIndex)
        reordered.insert(sentinel, at: 0)
        return reordered
    }
}
