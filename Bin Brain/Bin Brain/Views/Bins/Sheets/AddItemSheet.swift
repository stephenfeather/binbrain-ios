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

    private static let quantityFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = .current
        return f
    }()

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var trimmedCategory: String {
        category.trimmingCharacters(in: .whitespaces)
    }

    private var categoryValue: String? {
        trimmedCategory.isEmpty ? nil : trimmedCategory
    }

    private var quantityValue: Double? {
        guard !quantityText.isEmpty else { return nil }
        return Self.quantityFormatter.number(from: quantityText)?.doubleValue
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

        let errorBefore = viewModel.error
        await viewModel.addItem(
            name: trimmedName,
            category: categoryValue,
            quantity: quantityValue,
            binId: binId,
            apiClient: apiClient
        )
        if viewModel.error != nil && viewModel.error != errorBefore {
            errorMessage = viewModel.error
        } else {
            isPresented = false
        }
    }
}
