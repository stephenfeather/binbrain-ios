// ScannerViewModel.swift
// Bin Brain
//
// State machine for the QR scan → photo capture workflow.
// ScannerView drives this ViewModel via callbacks from DataScannerViewControllerDelegate.

import Foundation
import AVFoundation
import VisionKit
import Observation

// MARK: - ScanPhase

/// The current phase of the bin scanning workflow.
enum ScanPhase: Equatable {
    /// Waiting for a QR code to be detected.
    case scanning
    /// QR code found; waiting for the user to tap the shutter button.
    case awaitingPhoto
    /// Photo captured and ready to proceed to analysis.
    case captured
}

// MARK: - PhotoCapturing

/// Abstracts `AVCapturePhoto` for unit-test isolation.
///
/// `AVCapturePhoto` has no public initializer, so tests supply a
/// `MockCapturedPhoto` that conforms to this protocol instead.
protocol PhotoCapturing: AnyObject {}

extension AVCapturePhoto: PhotoCapturing {}

// MARK: - ScannerViewModel

/// Manages state for the QR scan + photo capture workflow.
///
/// Drives `ScanPhase` transitions in response to scanner events.
/// All methods must be called on the main actor (matching the VisionKit delegate).
@Observable
final class ScannerViewModel {

    // MARK: - State

    /// The current phase of the scanning workflow.
    private(set) var phase: ScanPhase = .scanning

    /// The bin ID decoded from the most recent QR code scan; `nil` until a QR is detected.
    private(set) var scannedBinId: String? = nil

    /// The photo captured after QR detection; non-nil only in the `.captured` phase.
    private(set) var capturedPhoto: (any PhotoCapturing)? = nil

    // MARK: - Actions

    /// Handles a decoded QR code from the scanner.
    ///
    /// Transitions `phase` to `.awaitingPhoto` and stores the bin ID.
    /// Ignores duplicate QR events when the phase is already past `.scanning`.
    ///
    /// - Parameter code: The raw string payload from the QR barcode.
    func qrDetected(_ code: String) {
        guard phase == .scanning else { return }
        scannedBinId = code
        phase = .awaitingPhoto
    }

    /// Initiates photo capture when the shutter button is tapped.
    ///
    /// Only calls `scanner.capturePhoto()` when `phase == .awaitingPhoto`;
    /// silently ignores taps in any other phase.
    ///
    /// - Parameter scanner: The active `DataScannerViewController` instance.
    func shutterTapped(scanner: DataScannerViewController) {
        guard phase == .awaitingPhoto else { return }
        Task { try? await scanner.capturePhoto() }
    }

    /// Stores the captured photo and transitions to the `.captured` phase.
    ///
    /// Called by `ScannerView.Coordinator` via `DataScannerViewControllerDelegate`.
    ///
    /// - Parameter photo: The photo delivered by the scanner delegate.
    func photoCaptured(_ photo: any PhotoCapturing) {
        capturedPhoto = photo
        phase = .captured
    }

    /// Resets all state back to `.scanning` for a new scan session.
    func reset() {
        phase = .scanning
        scannedBinId = nil
        capturedPhoto = nil
    }
}
