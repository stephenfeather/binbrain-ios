// ItemRowView.swift
// Bin Brain
//
// A list row displaying a single bin item with name, category, quantity, and confidence.

import SwiftUI

// MARK: - ItemRowView

struct ItemRowView: View {
    let item: BinItemRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.headline)
                Text(item.category ?? "Uncategorized").font(.subheadline).foregroundStyle(.secondary)
                if let quantity = item.quantity {
                    Text("Qty: \(quantity, specifier: "%.0f")").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let confidence = item.confidence {
                ConfidenceBadge(confidence: confidence)
            }
        }
    }
}
