// LocationsListView.swift
// Bin Brain
//
// Entry point for the Locations list screen.
// Displays all locations and supports creating and deleting.

import SwiftUI

// MARK: - LocationsListView

/// The main screen listing all storage locations.
///
/// Loads locations on appear and supports pull-to-refresh.
/// Toolbar "+" button opens a sheet for creating a new location.
/// Swipe-to-delete soft-deletes a location via the API.
struct LocationsListView: View {

    // MARK: - State

    @State private var viewModel = LocationsListViewModel()
    @Environment(\.apiClient) private var apiClient
    @Environment(\.embeddedInSplitView) private var embeddedInSplitView

    @State private var showAddLocation = false
    @State private var locationToDelete: LocationSummary?

    // MARK: - Body

    var body: some View {
        if embeddedInSplitView {
            locationsContent
        } else {
            NavigationStack {
                locationsContent
            }
        }
    }

    private var locationsContent: some View {
        content
            .navigationTitle("Locations")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showAddLocation = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add location")
                }
            }
            .task { await viewModel.load(apiClient: apiClient) }
            .refreshable { await viewModel.load(apiClient: apiClient) }
            .sheet(isPresented: $showAddLocation) {
                AddLocationSheet(
                    apiClient: apiClient,
                    viewModel: viewModel,
                    isPresented: $showAddLocation
                )
            }
            .alert(
                "Delete Location",
                isPresented: Binding(
                    get: { locationToDelete != nil },
                    set: { if !$0 { locationToDelete = nil } }
                ),
                presenting: locationToDelete
            ) { location in
                Button("Delete", role: .destructive) {
                    Task {
                        await viewModel.delete(locationId: location.locationId, apiClient: apiClient)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { location in
                Text("Delete \"\(location.name)\"? Bins assigned to this location will become unassigned.")
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.locations.isEmpty {
            ProgressView()
        } else if let errorMessage = viewModel.error {
            VStack(spacing: 12) {
                Text(errorMessage).foregroundStyle(.secondary)
                Button("Retry") {
                    Task { await viewModel.load(apiClient: apiClient) }
                }
            }
        } else if viewModel.locations.isEmpty {
            Text("No locations yet")
                .foregroundStyle(.secondary)
        } else {
            List {
                ForEach(viewModel.locations, id: \.locationId) { location in
                    LocationRowView(location: location)
                }
                .onDelete { offsets in
                    if let index = offsets.first {
                        locationToDelete = viewModel.locations[index]
                    }
                }
            }
        }
    }
}

// MARK: - LocationRowView

private struct LocationRowView: View {
    let location: LocationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(location.name).font(.headline)
            if let description = location.description, !description.isEmpty {
                Text(description).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(location.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - AddLocationSheet

private struct AddLocationSheet: View {
    let apiClient: APIClient
    let viewModel: LocationsListViewModel
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var description: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Location Details") {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $description)
                }
            }
            .navigationTitle("Add Location")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmedName = name.trimmingCharacters(in: .whitespaces)
                        guard !trimmedName.isEmpty else { return }
                        let trimmedDescription = description.trimmingCharacters(in: .whitespaces)
                        let descriptionValue = trimmedDescription.isEmpty ? nil : trimmedDescription
                        isPresented = false
                        Task {
                            await viewModel.create(
                                name: trimmedName,
                                description: descriptionValue,
                                apiClient: apiClient
                            )
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
