// ScannerViewModelTests.swift
// Bin BrainTests
//
// XCTest coverage for ScannerViewModel.swift.
// ScannerView wraps UIKit and cannot be unit-tested;
// all testable logic lives in ScannerViewModel.

import XCTest
@testable import Bin_Brain

// MARK: - MockCapturedPhoto

/// Test double for AVCapturePhoto, which has no public initializer.
///
/// Conforms to `PhotoCapturing` so it can be passed to `photoCaptured(_:)` in tests.
final class MockCapturedPhoto: PhotoCapturing {}

// MARK: - ScannerViewModelTests

@MainActor
final class ScannerViewModelTests: XCTestCase {

    var sut: ScannerViewModel!

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        sut = ScannerViewModel()
    }

    override func tearDown() async throws {
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Test 1: Initial state

    func testInitialPhaseIsScanning() {
        XCTAssertEqual(sut.phase, .scanning, "Fresh ScannerViewModel should start in .scanning phase")
        XCTAssertNil(sut.scannedBinId, "scannedBinId should be nil on init")
        XCTAssertNil(sut.capturedPhoto, "capturedPhoto should be nil on init")
    }

    // MARK: - Test 2: QR detection transitions to .awaitingPhoto

    func testQRDetectedTransitionsToAwaitingPhoto() {
        sut.qrDetected("BIN-0001")

        XCTAssertEqual(sut.phase, .awaitingPhoto, "qrDetected should transition phase to .awaitingPhoto")
        XCTAssertEqual(sut.scannedBinId, "BIN-0001", "scannedBinId should store the detected code")
    }

    // MARK: - Test 3: Duplicate QR events are ignored when not in .scanning phase

    func testQRDetectedIgnoredWhenNotScanning() {
        sut.qrDetected("BIN-0001")
        XCTAssertEqual(sut.phase, .awaitingPhoto)

        sut.qrDetected("OTHER")

        XCTAssertEqual(sut.phase, .awaitingPhoto, "Phase should remain .awaitingPhoto after second QR event")
        XCTAssertEqual(sut.scannedBinId, "BIN-0001", "scannedBinId should retain the first detected value")
    }

    // MARK: - Test 4: Photo capture transitions to .captured

    func testPhotoCapturedTransitionsToCaptured() {
        sut.qrDetected("BIN-0001")

        let mockPhoto = MockCapturedPhoto()
        sut.photoCaptured(mockPhoto)

        XCTAssertEqual(sut.phase, .captured, "photoCaptured should transition phase to .captured")
        XCTAssertNotNil(sut.capturedPhoto, "capturedPhoto should be non-nil after photoCaptured")
    }

    // MARK: - Test 5: Reset restores initial state

    func testResetRestoresInitialState() {
        sut.qrDetected("BIN-0001")
        sut.photoCaptured(MockCapturedPhoto())
        XCTAssertEqual(sut.phase, .captured)

        sut.reset()

        XCTAssertEqual(sut.phase, .scanning, "reset should restore phase to .scanning")
        XCTAssertNil(sut.scannedBinId, "reset should clear scannedBinId")
        XCTAssertNil(sut.capturedPhoto, "reset should clear capturedPhoto")
    }

    // MARK: - Test 6: QR detection works correctly after reset

    func testQRDetectedAfterResetWorks() {
        sut.qrDetected("BIN-0001")
        sut.photoCaptured(MockCapturedPhoto())
        sut.reset()

        sut.qrDetected("BIN-0042")

        XCTAssertEqual(sut.phase, .awaitingPhoto, "qrDetected after reset should transition to .awaitingPhoto")
        XCTAssertEqual(sut.scannedBinId, "BIN-0042", "scannedBinId should reflect the new code after reset")
    }

    // MARK: - Issue #15 / F-07: QR payload sanitization

    func testQRDetectedAcceptsValidBinId() {
        sut.qrDetected("BIN-0001")
        XCTAssertEqual(sut.scannedBinId, "BIN-0001")
        XCTAssertEqual(sut.phase, .awaitingPhoto)
        XCTAssertNil(sut.scanError)
    }

    func testQRDetectedTrimsWhitespace() {
        sut.qrDetected("  BIN-0001\n")
        XCTAssertEqual(sut.scannedBinId, "BIN-0001", "Leading/trailing whitespace must be trimmed")
        XCTAssertEqual(sut.phase, .awaitingPhoto)
    }

    func testQRDetectedRejectsQueryStringInjection() {
        sut.qrDetected("BIN-0001?admin=1")
        XCTAssertNil(sut.scannedBinId, "Query-param injection must be rejected")
        XCTAssertEqual(sut.phase, .scanning)
        XCTAssertNotNil(sut.scanError)
    }

    func testQRDetectedRejectsPathTraversal() {
        sut.qrDetected("../../OTHER")
        XCTAssertNil(sut.scannedBinId, "Path traversal sequences must be rejected")
        XCTAssertEqual(sut.phase, .scanning)
        XCTAssertNotNil(sut.scanError)
    }

    func testQRDetectedRejectsFragment() {
        sut.qrDetected("BIN-0001#frag")
        XCTAssertNil(sut.scannedBinId, "URL fragments must be rejected")
        XCTAssertEqual(sut.phase, .scanning)
        XCTAssertNotNil(sut.scanError)
    }

    func testQRDetectedRejectsEmptyPayload() {
        sut.qrDetected("")
        XCTAssertNil(sut.scannedBinId)
        XCTAssertEqual(sut.phase, .scanning)
        XCTAssertNotNil(sut.scanError)
    }

    func testQRDetectedRejectsWhitespaceOnlyPayload() {
        sut.qrDetected("   ")
        XCTAssertNil(sut.scannedBinId)
        XCTAssertEqual(sut.phase, .scanning)
        XCTAssertNotNil(sut.scanError)
    }

    func testQRDetectedRejectsOverlongPayload() {
        let tooLong = String(repeating: "A", count: 33)
        sut.qrDetected(tooLong)
        XCTAssertNil(sut.scannedBinId, "Payloads over 32 characters must be rejected")
        XCTAssertEqual(sut.phase, .scanning)
        XCTAssertNotNil(sut.scanError)
    }

    func testQRDetectedRejectsNonASCII() {
        sut.qrDetected("BIN-0001é")
        XCTAssertNil(sut.scannedBinId, "Non-ASCII characters must be rejected")
        XCTAssertEqual(sut.phase, .scanning)
        XCTAssertNotNil(sut.scanError)
    }

    func testQRDetectedClearsErrorOnValidRetry() {
        sut.qrDetected("BAD?x=1")
        XCTAssertNotNil(sut.scanError)

        sut.qrDetected("BIN-0002")

        XCTAssertNil(sut.scanError, "scanError should clear once a valid payload is accepted")
        XCTAssertEqual(sut.scannedBinId, "BIN-0002")
    }

    func testResetClearsScanError() {
        sut.qrDetected("BAD/path")
        XCTAssertNotNil(sut.scanError)

        sut.reset()

        XCTAssertNil(sut.scanError, "reset should clear scanError")
    }
}
