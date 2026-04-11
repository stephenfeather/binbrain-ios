// LocationPickerSheet.swift
// Bin Brain
//
// A picker sheet for assigning a location to a bin.
// Presents all active locations with a checkmark on the current selection.

import SwiftUI

// MARK: - LocationPickerSheet

/// A sheet that lists all locations and lets the user assign one to a bin.
///
/// Shows a "None" option at the top to clear the assignment.
/// Calls `PATCH /bins/{bin_id}/location` on selection and dismisses.
struct LocationPickerSheet: View {

    // MARK: - Properties

    let binId: String
    let currentLocationName: String?
    let onLocationChanged: (String?) -> Void

    // MARK: - State

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss
    @State private var locations: [LocationSummary] = []
    @State private var isLoading = true
    @State private var error: String?

    // MARK: - Body

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Assign Location")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .task { await loadLocations() }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
        } else if let errorMessage = error {
            VStack(spacing: 12) {
                Text(errorMessage).foregroundStyle(.secondary)
                Button("Retry") { Task { await loadLocations() } }
            }
        } else {
            List {
                Button {
                    Task { await assign(locationId: nil, locationName: nil) }
                } label: {
                    HStack {
                        Text("None")
                            .foregroundStyle(currentLocationName == nil ? .primary : .secondary)
                        Spacer()
                        if currentLocationName == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }

                ForEach(locations, id: \.locationId) { location in
                    Button {
                        Task { await assign(locationId: location.locationId, locationName: location.name) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(location.name)
                                if let description = location.description, !description.isEmpty {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if currentLocationName == location.name {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .tint(.primary)
                }
            }
        }
    }

    // MARK: - Private

    private func loadLocations() async {
        isLoading = true
        error = nil
        do {
            locations = try await apiClient.listLocations()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func assign(locationId: Int?, locationName: String?) async {
        do {
            try await apiClient.assignLocation(binId: binId, locationId: locationId)
            onLocationChanged(locationName)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
