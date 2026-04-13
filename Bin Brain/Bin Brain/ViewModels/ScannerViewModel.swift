// ScannerViewModel.swift
// Bin Brain
//
// State machine for the QR scan → photo capture workflow.
// ScannerView drives this ViewModel via callbacks from DataScannerViewControllerDelegate.

import Foundation
import AVFoundation
import OSLog
import VisionKit
import Observation

private let logger = Logger(subsystem: "com.binbrain.app", category: "ScannerViewModel")

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

    /// User-facing message when the most recent QR payload is rejected by the
    /// bin-id format check. Cleared on the next successful scan or `reset()`.
    var scanError: String? = nil

    // MARK: - Validation

    /// Strict bin-id pattern: 1–32 ASCII letters, digits, hyphens, or underscores.
    ///
    /// Rejects anything that could manipulate the URL path (`/`, `.`, `?`, `#`, `%`),
    /// inject query parameters, or carry non-ASCII content. See issue #15 / F-07.
    private static let binIdPattern = #"^[A-Za-z0-9_-]{1,32}$"#

    // MARK: - Actions

    /// Handles a decoded QR code from the scanner.
    ///
    /// Trims whitespace, validates the payload against `binIdPattern`, and
    /// transitions `phase` to `.awaitingPhoto` on success. On rejection,
    /// sets `scanError` and leaves `phase` at `.scanning` so the user can retry.
    /// Ignores duplicate QR events when the phase is already past `.scanning`.
    ///
    /// - Parameter code: The raw string payload from the QR barcode.
    func qrDetected(_ code: String) {
        guard phase == .scanning else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: Self.binIdPattern, options: .regularExpression) != nil else {
            logger.warning("Rejected QR payload: format mismatch")
            scanError = "QR payload doesn't match expected bin-id format"
            return
        }
        scanError = nil
        scannedBinId = trimmed
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
        Task {
            do {
                try await scanner.capturePhoto()
            } catch {
                logger.error("capturePhoto failed: \(error.localizedDescription, privacy: .private)")
            }
        }
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
        scanError = nil
    }
}
