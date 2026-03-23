// ToastView.swift
// Bin Brain
//
// Toast notification view, view model, and view modifier.

import SwiftUI
import Observation

// MARK: - ToastViewModel

/// Manages the visibility and message of a toast notification.
///
/// Call `show(_:duration:)` to display a message. It auto-dismisses after `duration` seconds.
@Observable
final class ToastViewModel {
    private(set) var isShowing: Bool = false
    private(set) var message: String = ""
    private var dismissTask: Task<Void, Never>?

    // MARK: - Actions

    /// Displays `message` for `duration` seconds, then auto-dismisses.
    ///
    /// If a toast is already showing, it is replaced immediately.
    ///
    /// - Parameters:
    ///   - message: The text to display in the toast.
    ///   - duration: How long the toast stays visible before auto-dismissing. Defaults to 3.0 seconds.
    func show(_ message: String, duration: TimeInterval = 3.0) {
        self.message = message
        self.isShowing = true
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.dismiss() }
        }
    }

    /// Immediately hides the toast and clears the message.
    func dismiss() {
        isShowing = false
        message = ""
        dismissTask?.cancel()
        dismissTask = nil
    }
}

// MARK: - ToastView

/// A non-interactive banner shown at the bottom of the screen.
struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.75))
            .clipShape(Capsule())
    }
}

// MARK: - Toast ViewModifier

private struct ToastModifier: ViewModifier {
    let message: String
    @Binding var isShowing: Bool

    func body(content: Content) -> some View {
        ZStack(alignment: .bottom) {
            content
            if isShowing {
                ToastView(message: message)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 32)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isShowing)
        .onChange(of: isShowing) { _, showing in
            if showing {
                AccessibilityNotification.Announcement(message).post()
            }
        }
    }
}

extension View {
    /// Overlays an auto-dismissing toast banner at the bottom of the view.
    ///
    /// - Parameters:
    ///   - message: The text to display in the toast.
    ///   - isShowing: A binding that controls toast visibility.
    func toast(message: String, isShowing: Binding<Bool>) -> some View {
        modifier(ToastModifier(message: message, isShowing: isShowing))
    }
}
