// AddItemSheet.swift
// Bin Brain
//
// A sheet for manually adding a new item to a bin.

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

    var body: some View {
        NavigationStack {
            Form {
                Section("Item Details") {
                    TextField("Name", text: $name)
                    TextField("Category (optional)", text: $category)
                    TextField("Quantity (optional)", text: $quantityText)
                        .keyboardType(.decimalPad)
                }
            }
            .navigationTitle("Add Item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmedName = name.trimmingCharacters(in: .whitespaces)
                        guard !trimmedName.isEmpty else { return }
                        let trimmedCategory = category.trimmingCharacters(in: .whitespaces)
                        let categoryValue = trimmedCategory.isEmpty ? nil : trimmedCategory
                        let quantityValue = Double(quantityText)
                        isPresented = false
                        Task {
                            await viewModel.addItem(
                                name: trimmedName,
                                category: categoryValue,
                                quantity: quantityValue,
                                binId: binId,
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
