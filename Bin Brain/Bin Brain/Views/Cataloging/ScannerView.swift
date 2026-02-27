// ScannerView.swift
// Bin Brain
//
// UIViewControllerRepresentable wrapping DataScannerViewController.
// The shutter button overlay is NOT part of this view — it is rendered
// by the parent SwiftUI view as a ZStack overlay after QR detection.

import SwiftUI
import Vision
import VisionKit
import AVFoundation

// MARK: - ScannerView

/// A SwiftUI wrapper around `DataScannerViewController` for QR scanning and photo capture.
///
/// Configure it with the two callback closures; the shutter button is rendered
/// by the parent view using the `showShutterButton` binding as a visibility gate.
/// The parent triggers capture by calling the closure delivered via `onCaptureReady`.
struct ScannerView: UIViewControllerRepresentable {

    // MARK: - Properties

    /// Set to `true` by the coordinator when a QR code is first detected,
    /// signalling the parent view to render the shutter button overlay.
    @Binding var showShutterButton: Bool

    /// Called once per scan session when a QR code payload is first decoded.
    let onQRCode: (String) -> Void

    /// Called when the scanner delivers a captured still photo.
    let onPhotoCapture: (AVCapturePhoto) -> Void

    /// Called once the scanner is ready, delivering a closure the parent can invoke
    /// to trigger `capturePhoto()` when the shutter button is tapped.
    var onCaptureReady: (@MainActor @escaping () -> Void) -> Void = { _ in }

    // MARK: - UIViewControllerRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        guard DataScannerViewController.isSupported else {
            return makeFallbackViewController()
        }

        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .accurate,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        context.coordinator.scanner = scanner

        let captureFunc: @MainActor () -> Void = { [weak scanner] in
            guard let scanner else { return }
            Task { try? await scanner.capturePhoto() }
        }
        // Defer state mutation to avoid modifying state during the SwiftUI update pass.
        DispatchQueue.main.async { onCaptureReady(captureFunc) }

        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // Keep the coordinator's parent reference current so closures stay fresh.
        context.coordinator.parent = self
    }

    // MARK: - Private Helpers

    /// Returns a plain view controller with a "Camera not available" label.
    private func makeFallbackViewController() -> UIViewController {
        let controller = UIViewController()
        let label = UILabel()
        label.text = "Camera not available"
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor)
        ])
        return controller
    }

    // MARK: - Coordinator

    /// Bridges `DataScannerViewControllerDelegate` callbacks to the SwiftUI closures.
    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {

        // MARK: - Properties

        /// The parent `ScannerView`; updated on every SwiftUI re-render via `updateUIViewController`.
        var parent: ScannerView

        /// Guards against firing `onQRCode` more than once per scan session.
        private var hasDeliveredQR = false

        /// Weak reference to the scanner VC, used to deliver the capture trigger.
        weak var scanner: DataScannerViewController?

        // MARK: - Init

        init(parent: ScannerView) {
            self.parent = parent
        }

        // MARK: - DataScannerViewControllerDelegate

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !hasDeliveredQR else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item,
                   let payload = barcode.payloadStringValue {
                    hasDeliveredQR = true
                    parent.onQRCode(payload)
                    parent.showShutterButton = true
                    return
                }
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didCapturePhoto photo: AVCapturePhoto
        ) {
            parent.onPhotoCapture(photo)
        }
    }
}
