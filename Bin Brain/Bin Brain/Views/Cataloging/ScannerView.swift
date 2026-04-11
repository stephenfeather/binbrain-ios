// ScannerView.swift
// Bin Brain
//
// UIViewControllerRepresentable wrapping DataScannerViewController.
// The shutter button overlay is NOT part of this view — it is rendered
// by the parent SwiftUI view as a ZStack overlay after QR detection.

import AVFoundation
import OSLog
import SwiftUI
import UIKit

private let logger = Logger(subsystem: "com.binbrain.app", category: "ScannerView")
import Vision
import VisionKit

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

    /// Called when the scanner delivers a captured still image.
    let onPhotoCapture: (UIImage) -> Void

    /// Called once the scanner is ready, delivering a closure the parent can invoke
    /// to trigger `capturePhoto()` when the shutter button is tapped.
    var onCaptureReady: (@MainActor @escaping () -> Void) -> Void = { _ in }

    // MARK: - UIViewControllerRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        logger.debug("makeUIViewController called")
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

        // Wrap in a plain UIViewController to isolate the scanner
        // from SwiftUI's color environment (prevents yellow tint).
        let container = UIViewController()
        // Clamp tintColor to sRGB to suppress the
        // "UIColor component values far outside expected range" warning.
        container.view.tintColor = .systemBlue
        container.addChild(scanner)
        container.view.addSubview(scanner.view)
        scanner.view.frame = container.view.bounds
        scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scanner.didMove(toParent: container)

        let photoCallback = onPhotoCapture
        let captureFunc: @MainActor () -> Void = { [weak scanner] in
            guard let scanner else {
                logger.warning("capturePhoto: scanner is nil")
                return
            }
            Task {
                do {
                    let photo = try await scanner.capturePhoto()
                    logger.debug("capturePhoto returned: \(photo.size.width)x\(photo.size.height)")
                    photoCallback(photo)
                } catch {
                    logger.error("capturePhoto error: \(error.localizedDescription)")
                }
            }
        }
        onCaptureReady(captureFunc)

        do {
            try scanner.startScanning()
        } catch {
            logger.error("Failed to start scanning: \(error.localizedDescription)")
        }
        return container
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        logger.debug("updateUIViewController called")
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

        var parent: ScannerView
        private var hasDeliveredQR = false
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
            // On modern iOS, capturePhoto() returns UIImage directly via the async call.
            // This delegate path is a fallback; convert via fileDataRepresentation.
            if let data = photo.fileDataRepresentation(),
               let image = UIImage(data: data) {
                parent.onPhotoCapture(image)
            }
        }
    }
}
