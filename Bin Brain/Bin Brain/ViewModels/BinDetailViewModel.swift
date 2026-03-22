// BinDetailViewModel.swift
// Bin Brain
//
// ViewModel for the Bin detail screen.
// Manages fetching bin contents and adding items.

import Foundation
import Observation

// MARK: - BinDetailViewModel

/// Manages the state for the bin detail screen.
///
/// Call `load(binId:apiClient:)` to fetch bin contents.
/// Call `addItem(name:category:quantity:binId:apiClient:)` to create an item and reload.
@Observable
final class BinDetailViewModel {

    // MARK: - State

    /// The full bin response returned by the server; `nil` until first successful load.
    private(set) var bin: GetBinResponse? = nil

    /// `true` while a network request is in flight.
    private(set) var isLoading: Bool = false

    /// A human-readable error message; `nil` when no error has occurred.
    private(set) var error: String? = nil

    // MARK: - Actions

    /// Fetches full bin contents for the given bin identifier.
    ///
    /// Sets `isLoading` to `true` during the call. On success, populates `bin`
    /// and clears `error`. On failure, sets `error` and leaves `bin` unchanged.
    ///
    /// - Parameters:
    ///   - binId: The alphanumeric bin identifier (e.g. `BIN-0001`).
    ///   - apiClient: The `APIClient` instance to use for the request.
    func load(binId: String, apiClient: APIClient) async {
        isLoading = true
        error = nil
        do {
            bin = try await apiClient.getBin(binId)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// Upserts a new item into the bin, then reloads the bin contents.
    ///
    /// On failure, sets `error`. The subsequent `load` call manages the loading indicator.
    ///
    /// - Parameters:
    ///   - name: Item name (required).
    ///   - category: Optional category.
    ///   - quantity: Optional quantity.
    ///   - binId: Bin to associate the item with.
    ///   - apiClient: API client for network calls.
    /// Removes an item from this bin, then reloads the bin contents.
    ///
    /// - Parameters:
    ///   - itemId: The item to remove.
    ///   - binId: The bin to remove the item from.
    ///   - apiClient: API client for network calls.
    func removeItem(itemId: Int, binId: String, apiClient: APIClient) async {
        do {
            try await apiClient.removeItem(itemId: itemId, binId: binId)
            await load(binId: binId, apiClient: apiClient)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Updates quantity and/or confidence for an item in this bin, then reloads.
    ///
    /// - Parameters:
    ///   - itemId: The item to update.
    ///   - quantity: New quantity, or `nil` to leave unchanged.
    ///   - confidence: New confidence, or `nil` to leave unchanged.
    ///   - binId: The bin the item belongs to.
    ///   - apiClient: API client for network calls.
    func updateItem(itemId: Int, quantity: Double?, confidence: Double?, binId: String, apiClient: APIClient) async {
        do {
            try await apiClient.updateItem(itemId: itemId, binId: binId, quantity: quantity, confidence: confidence)
            await load(binId: binId, apiClient: apiClient)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func addItem(name: String, category: String?, quantity: Double?, binId: String, apiClient: APIClient) async {
        do {
            _ = try await apiClient.upsertItem(
                name: name,
                category: category,
                quantity: quantity,
                confidence: nil,
                binId: binId
            )
            await load(binId: binId, apiClient: apiClient)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
