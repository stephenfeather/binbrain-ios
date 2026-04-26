// AddItemSheet.swift
// Bin Brain
//
// A sheet for manually adding a new item to a bin.
// Supports locale-aware decimal input, deferred dismiss (only on success),
// and isLoading state to prevent double-taps.

import SwiftUI

// MARK: - AddItemSheet

struct AddItemSheet: View {
    let binId: String
    let apiClient: APIClient
    let viewModel: BinDetailViewModel
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var category: String = ""
    @State private var quantityText: String = ""
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    // MARK: - Helpers

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var trimmedCategory: String {
        category.trimmingCharacters(in: .whitespaces)
    }

    private var categoryValue: String? {
        trimmedCategory.isEmpty ? nil : trimmedCategory
    }

    /// The parsed numeric value of `quantityText`, locale-aware.
    ///
    /// Evaluated only in `save()`; the UI's Save button uses `trimmedName`/`isLoading`
    /// for its disabled state and never reads this property.
    ///
    /// Non-O(1): allocates a `NumberFormatter` and parses the text on each access.
    /// Caching (e.g. via `.onChange(of: quantityText)`) is out of scope for this
    /// iteration since the access pattern is single-shot at Save.
    private var quantityValue: Double? {
        guard !quantityText.isEmpty else { return nil }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = .current
        return f.number(from: quantityText)?.doubleValue
            ?? Double(quantityText)
    }

    private var saveDisabled: Bool {
        trimmedName.isEmpty || isLoading
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                Section("Item Details") {
                    TextField("Name", text: $name)
                    TextField("Category (optional)", text: $category)
                    TextField("Quantity (optional)", text: $quantityText)
                        .keyboardType(.decimalPad)
                }

                if isLoading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Saving…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let message = errorMessage {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Add Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                        .disabled(isLoading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(saveDisabled)
                }
            }
        }
    }

    // MARK: - Actions

    private func save() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await viewModel.addItem(
                name: trimmedName,
                category: categoryValue,
                quantity: quantityValue,
                binId: binId,
                apiClient: apiClient
            )
            isPresented = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
