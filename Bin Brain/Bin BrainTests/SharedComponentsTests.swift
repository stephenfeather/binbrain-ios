// SharedComponentsTests.swift
// Bin BrainTests
//
// Tests for ConfidenceBadge and ToastViewModel shared components.

import XCTest
import SwiftUI
@testable import Bin_Brain

// MARK: - ConfidenceBadgeTests

final class ConfidenceBadgeTests: XCTestCase {

    func testHighConfidenceLabel() {
        let badge = ConfidenceBadge(confidence: 0.9)
        XCTAssertEqual(badge.label, "High")
        XCTAssertEqual(badge.badgeColor, .green)
    }

    func testMediumConfidenceLabel() {
        let badge = ConfidenceBadge(confidence: 0.65)
        XCTAssertEqual(badge.label, "Medium")
        XCTAssertEqual(badge.badgeColor, .yellow)
    }

    func testLowConfidenceLabel() {
        let badge = ConfidenceBadge(confidence: 0.3)
        XCTAssertEqual(badge.label, "Low")
        XCTAssertEqual(badge.badgeColor, .orange)
    }

    func testBoundaryHighLabel() {
        let badge = ConfidenceBadge(confidence: 0.8)
        XCTAssertEqual(badge.label, "High")
    }

    func testBoundaryMediumLabel() {
        let badge = ConfidenceBadge(confidence: 0.5)
        XCTAssertEqual(badge.label, "Medium")
    }
}

// MARK: - ToastViewModelTests

final class ToastViewModelTests: XCTestCase {
    var sut: ToastViewModel!

    override func setUp() async throws {
        try await super.setUp()
        sut = ToastViewModel()
    }

    override func tearDown() async throws {
        sut.dismiss()
        sut = nil
        try await super.tearDown()
    }

    func testInitialState() {
        XCTAssertFalse(sut.isShowing)
        XCTAssertTrue(sut.message.isEmpty)
    }

    func testShowSetsMessageAndIsShowing() {
        sut.show("Upload failed")
        XCTAssertTrue(sut.isShowing)
        XCTAssertEqual(sut.message, "Upload failed")
    }

    func testDismissClearsState() {
        sut.show("Some message")
        sut.dismiss()
        XCTAssertFalse(sut.isShowing)
        XCTAssertTrue(sut.message.isEmpty)
    }

    func testShowReplacesExistingMessage() {
        sut.show("A")
        sut.show("B")
        XCTAssertEqual(sut.message, "B")
        XCTAssertTrue(sut.isShowing)
    }

    func testAutoDismissAfterDuration() async throws {
        sut.show("Test", duration: 0.05)
        XCTAssertTrue(sut.isShowing, "Should be showing immediately")
        try await Task.sleep(nanoseconds: 150_000_000) // 0.15s
        XCTAssertFalse(sut.isShowing, "Should have auto-dismissed after 0.05s")
        XCTAssertTrue(sut.message.isEmpty, "Message should be cleared after dismiss")
    }
}
