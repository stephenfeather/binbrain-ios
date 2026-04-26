// BinRowView.swift
// Bin Brain
//
// A list row displaying a single bin summary with sentinel-aware formatting.

import SwiftUI

// MARK: - BinRowView

struct BinRowView: View {
    let bin: BinSummary

    private var isSentinel: Bool { BinsListViewModel.isSentinel(bin.binId) }

    var body: some View {
        HStack(spacing: 10) {
            if isSentinel {
                Image(systemName: "tray.2")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(BinsListViewModel.displayName(for: bin.binId))
                    .font(.headline)
                    .foregroundStyle(isSentinel ? Color.secondary : Color.primary)
                if isSentinel {
                    Text(bin.itemCount == 0 ? "No binless items" : "\(bin.itemCount) items")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(bin.itemCount) items")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let locationName = bin.locationName {
                        Text(locationName).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Text("Last updated:")
                        Text(bin.lastUpdated, style: .date)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}
