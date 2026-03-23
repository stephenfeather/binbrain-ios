// ConfidenceBadge.swift
// Bin Brain
//
// A small capsule badge displaying a confidence level.

import SwiftUI

// MARK: - ConfidenceBadge

/// A small capsule badge displaying a confidence level as "High", "Medium", or "Low".
///
/// - High (>=0.8): green
/// - Medium (0.5..<0.8): yellow
/// - Low (<0.5): orange
struct ConfidenceBadge: View {
    let confidence: Double

    // MARK: - Computed Properties

    /// The human-readable label for this confidence level.
    var label: String {
        if confidence >= 0.8 { return "High" }
        if confidence >= 0.5 { return "Medium" }
        return "Low"
    }

    /// The color associated with this confidence level.
    var badgeColor: Color {
        if confidence >= 0.8 { return .green }
        if confidence >= 0.5 { return .yellow }
        return .orange
    }

    // MARK: - Body

    var body: some View {
        Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.15))
            .foregroundStyle(badgeColor)
            .clipShape(Capsule())
            .accessibilityLabel("\(label) confidence")
    }
}
