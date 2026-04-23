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
///
/// ## Rotation contract (Finding #23)
/// This view must be hosted inside a `.fullScreenCover`, **not** a `.sheet`.
/// On large iPhones (Pro Max), rotating to landscape flips the horizontal size class
/// compact→regular; SwiftUI dismisses `.sheet` presentations on that transition,
/// tearing down the `NavigationStack` and losing all capture/quality-gate state.
/// `.fullScreenCover` fills the entire screen in all orientations and is immune to
/// size-class–driven dismissal. `updateUIViewController` is called on rotation and
/// correctly propagates updated closures through the `Coordinator` without recreating
/// the `DataScannerViewController`.
struct ScannerView: UIViewControllerRepresentable {

    // MARK: - Properties

    /// Set to `true` by the coordinator when a QR code is first detected,
    /// signalling the parent view to render the shutter button overlay.
    @Binding var showShutterButton: Bool

    /// Called once per scan session when a QR code payload is first decoded.
    let onQRCode: (String) -> Void

    /// Called when the scanner delivers a captured still image.
    ///
    /// The optional `CameraCaptureContext` carries EXIF/lens telemetry from
    /// the most recent `AVCapturePhoto` delegate callback, when available.
    /// The async `DataScannerViewController.capturePhoto()` returns only a
    /// `UIImage` (no metadata), so the coordinator stashes the most recent
    /// `AVCapturePhoto` from `didCapturePhoto` and pairs the two here.
    let onPhotoCapture: (UIImage, CameraCaptureContext?) -> Void

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
        let coordinator = context.coordinator
        let captureFunc: @MainActor () -> Void = { [weak scanner, weak coordinator] in
            guard let scanner else {
                logger.warning("capturePhoto: scanner is nil")
                return
            }
            coordinator?.consumeCapturedPhoto()
            Task {
                do {
                    let photo = try await scanner.capturePhoto()
                    logger.debug("capturePhoto returned: \(photo.size.width, privacy: .public)x\(photo.size.height, privacy: .public)")
                    let cameraContext = await coordinator?.consumeCapturedPhotoContext()
                    photoCallback(photo, cameraContext)
                } catch {
                    logger.error("capturePhoto error: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
        onCaptureReady(captureFunc)

        do {
            try scanner.startScanning()
        } catch {
            logger.error("Failed to start scanning: \(error.localizedDescription, privacy: .private)")
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

        /// AVCapturePhoto stashed from the most recent `didCapturePhoto`
        /// delegate fire. Read once by the async `capturePhoto()` flow and
        /// then cleared so subsequent captures don't see stale data.
        private var lastCapturedPhoto: AVCapturePhoto?

        // MARK: - Init

        init(parent: ScannerView) {
            self.parent = parent
        }

        // MARK: - Capture Coordination

        /// Clears any previously-stashed AVCapturePhoto so the next
        /// `didCapturePhoto` delegate fire is uniquely tied to the upcoming
        /// shutter event.
        func consumeCapturedPhoto() {
            lastCapturedPhoto = nil
        }

        /// Drains the stashed AVCapturePhoto into a `CameraCaptureContext`,
        /// returning `nil` when the delegate did not fire (or carried no
        /// metadata). The slot is cleared either way.
        func consumeCapturedPhotoContext() -> CameraCaptureContext? {
            defer { lastCapturedPhoto = nil }
            guard let photo = lastCapturedPhoto else { return nil }
            return CameraMetadataExtractor.context(from: photo)
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
            // The async `capturePhoto()` flow above is the canonical photo
            // delivery path; the delegate fires alongside it, and we use it
            // only to stash the AVCapturePhoto so the async path can extract
            // EXIF/lens metadata. We do NOT fire `onPhotoCapture` from here
            // to avoid double-processing the same capture.
            lastCapturedPhoto = photo
        }
    }
}
