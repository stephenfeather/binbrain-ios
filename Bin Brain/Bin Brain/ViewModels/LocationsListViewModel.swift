// LocationsListViewModel.swift
// Bin Brain
//
// ViewModel for the Locations list screen.
// Manages fetching, creating, and deleting locations.

import Foundation
import Observation

// MARK: - LocationsListViewModel

/// Manages the state for the locations list screen.
///
/// Call `load(apiClient:)` to fetch all locations.
/// Call `create(name:description:apiClient:)` to add a new location.
/// Call `delete(locationId:apiClient:)` to soft-delete a location.
@Observable
final class LocationsListViewModel {

    // MARK: - State

    /// The list of location summaries returned by the server.
    private(set) var locations: [LocationSummary] = []

    /// `true` while a network request is in flight.
    private(set) var isLoading = false

    /// A human-readable error message set when a request fails; `nil` otherwise.
    private(set) var error: String? = nil

    // MARK: - Actions

    /// Fetches all active locations from the server.
    ///
    /// Sets `isLoading` to `true` during the call. On success, populates `locations`
    /// and clears `error`. On failure, sets `error` and leaves `locations` unchanged.
    ///
    /// - Parameter apiClient: The `APIClient` instance to use for the request.
    func load(apiClient: APIClient) async {
        isLoading = true
        error = nil
        do {
            locations = try await apiClient.listLocations()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// Creates a new location, then reloads the list.
    ///
    /// - Parameters:
    ///   - name: The location name (required).
    ///   - description: Optional description.
    ///   - apiClient: The `APIClient` instance to use for the request.
    func create(name: String, description: String?, apiClient: APIClient) async {
        do {
            _ = try await apiClient.createLocation(name: name, description: description)
            await load(apiClient: apiClient)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Soft-deletes a location, then reloads the list.
    ///
    /// - Parameters:
    ///   - locationId: The location to delete.
    ///   - apiClient: The `APIClient` instance to use for the request.
    func delete(locationId: Int, apiClient: APIClient) async {
        do {
            try await apiClient.deleteLocation(locationId)
            await load(apiClient: apiClient)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
