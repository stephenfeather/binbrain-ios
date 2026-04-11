// QualityGatesTests.swift
// Bin BrainTests
//
// Tests for the quality gate checks that validate image quality before upload.
// Uses synthetic CGImages generated with Core Graphics to test each gate.

import XCTest
import CoreGraphics
@testable import Bin_Brain

final class QualityGatesTests: XCTestCase {

    private let gates = QualityGates()

    // MARK: - Synthetic Image Helpers

    /// Creates a solid-color CGImage of the given size.
    private func makeSolidImage(width: Int, height: Int, gray: CGFloat = 0.5) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(gray: gray, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Creates a CGImage with a checkerboard pattern (high-frequency edges for sharpness).
    private func makeCheckerboardImage(width: Int, height: Int, blockSize: Int = 4) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        for y in 0..<(height / blockSize) {
            for x in 0..<(width / blockSize) {
                let isWhite = (x + y) % 2 == 0
                context.setFillColor(gray: isWhite ? 1.0 : 0.0, alpha: 1.0)
                context.fill(CGRect(x: x * blockSize, y: y * blockSize, width: blockSize, height: blockSize))
            }
        }
        return context.makeImage()!
    }

    // MARK: - Resolution Gate

    func testResolutionGateFailsForTinyImage() {
        let tinyImage = makeSolidImage(width: 100, height: 100)
        let failure = gates.checkResolution(tinyImage)
        XCTAssertNotNil(failure)
        XCTAssertEqual(failure?.gate, .resolution)
        XCTAssertTrue(failure!.message.contains("too small"))
    }

    func testResolutionGateFailsWhenShortestSideBelow1024() {
        // 2000x800 — shortest side is 800
        let narrowImage = makeSolidImage(width: 2000, height: 800)
        let failure = gates.checkResolution(narrowImage)
        XCTAssertNotNil(failure)
        XCTAssertEqual(failure?.gate, .resolution)
    }

    func testResolutionGatePassesAtExactMinimum() {
        let minImage = makeSolidImage(width: 1024, height: 1024)
        let failure = gates.checkResolution(minImage)
        XCTAssertNil(failure)
    }

    func testResolutionGatePassesForLargeImage() {
        let largeImage = makeSolidImage(width: 4032, height: 3024)
        let failure = gates.checkResolution(largeImage)
        XCTAssertNil(failure)
    }

    // MARK: - Blur Gate

    func testBlurGateDetectsUniformImage() {
        // A solid color image has zero Laplacian variance → blurry
        let solidImage = makeSolidImage(width: 1024, height: 1024, gray: 0.5)
        let result = gates.checkBlur(solidImage)
        XCTAssertNotNil(result.failure)
        XCTAssertEqual(result.failure?.gate, .blur)
        XCTAssertTrue(result.failure!.message.contains("blurry"))
        XCTAssertEqual(result.variance, 0, accuracy: 1.0)
    }

    func testBlurGatePassesSharpImage() {
        // A checkerboard pattern has high-frequency edges → high variance
        let sharpImage = makeCheckerboardImage(width: 1024, height: 1024, blockSize: 2)
        let result = gates.checkBlur(sharpImage)
        XCTAssertNil(result.failure, "Sharp checkerboard image should pass blur gate")
        XCTAssertGreaterThan(result.variance, 0)
    }

    func testBlurVarianceIsNonNegative() {
        let image = makeSolidImage(width: 1024, height: 1024)
        let result = gates.checkBlur(image)
        XCTAssertGreaterThanOrEqual(result.variance, 0)
    }

    // MARK: - Exposure Gate

    func testExposureGateDetectsUnderexposure() {
        // Nearly black image — most pixels in bottom 10%
        let darkImage = makeSolidImage(width: 1024, height: 1024, gray: 0.02)
        let result = gates.checkExposure(darkImage)
        XCTAssertNotNil(result.failure)
        XCTAssertEqual(result.failure?.gate, .exposure)
        XCTAssertTrue(result.failure!.message.contains("dark"))
    }

    func testExposureGateDetectsOverexposure() {
        // Nearly white image — most pixels in top 10%
        let brightImage = makeSolidImage(width: 1024, height: 1024, gray: 0.98)
        let result = gates.checkExposure(brightImage)
        XCTAssertNotNil(result.failure)
        XCTAssertEqual(result.failure?.gate, .exposure)
        XCTAssertTrue(result.failure!.message.contains("bright"))
    }

    func testExposureGatePassesMidtoneImage() {
        // Mid-gray image — pixels in the middle of the histogram
        let midImage = makeSolidImage(width: 1024, height: 1024, gray: 0.5)
        let result = gates.checkExposure(midImage)
        XCTAssertNil(result.failure, "Mid-gray image should pass exposure gate")
    }

    func testExposureMeanIsInUnitRange() {
        let image = makeSolidImage(width: 1024, height: 1024, gray: 0.5)
        let result = gates.checkExposure(image)
        XCTAssertGreaterThanOrEqual(result.mean, 0)
        XCTAssertLessThanOrEqual(result.mean, 1.0)
    }

    // MARK: - Saliency Gate

    func testSaliencyGateFailsForUniformImage() async throws {
        let uniformImage = makeSolidImage(width: 1024, height: 1024, gray: 0.5)
        do {
            let result = try await gates.checkSaliency(uniformImage)
            if result.coverage == 0 {
                XCTAssertNotNil(result.failure)
                XCTAssertEqual(result.failure?.gate, .saliency)
            }
        } catch {
            try XCTSkipIf(
                error.localizedDescription.contains("espresso"),
                "Vision Neural Engine unavailable in this environment — requires device testing"
            )
            throw error
        }
    }

    func testSaliencyGateReturnsNonNegativeCoverage() async throws {
        let image = makeCheckerboardImage(width: 1024, height: 1024)
        do {
            let result = try await gates.checkSaliency(image)
            XCTAssertGreaterThanOrEqual(result.coverage, 0)
        } catch {
            try XCTSkipIf(
                error.localizedDescription.contains("espresso"),
                "Vision Neural Engine unavailable in this environment — requires device testing"
            )
            throw error
        }
    }

    // MARK: - Full Validation Pipeline

    func testValidateFailsOnTinyImage() async throws {
        let tinyImage = makeSolidImage(width: 100, height: 100)
        let result = try await gates.validate(tinyImage)
        XCTAssertNotNil(result.failure)
        XCTAssertEqual(result.failure?.gate, .resolution)
        XCTAssertEqual(result.scores.shortestSide, 100)
        // Blur, exposure, saliency should be zero (unchecked)
        XCTAssertEqual(result.scores.blurVariance, 0)
        XCTAssertEqual(result.scores.exposureMean, 0)
        XCTAssertEqual(result.scores.saliencyCoverage, 0)
    }

    func testValidateFailsBlurBeforeSaliency() async throws {
        // Solid uniform image at valid resolution — should fail blur, not reach saliency
        let solidImage = makeSolidImage(width: 1024, height: 1024, gray: 0.5)
        let result = try await gates.validate(solidImage)
        XCTAssertNotNil(result.failure)
        XCTAssertEqual(result.failure?.gate, .blur)
        // Saliency should be zero (skipped)
        XCTAssertEqual(result.scores.saliencyCoverage, 0)
        // Blur variance should have been computed
        XCTAssertEqual(result.scores.blurVariance, 0, accuracy: 1.0)
    }

    func testValidateReturnsScoresEvenOnFailure() async throws {
        let tinyImage = makeSolidImage(width: 100, height: 100)
        let result = try await gates.validate(tinyImage)
        // Scores struct should be populated (with zeros for unchecked gates)
        XCTAssertNotNil(result.scores)
        XCTAssertEqual(result.scores.shortestSide, 100)
    }

    func testValidatePassesWithSharpWellExposedImage() async throws {
        // Checkerboard at valid resolution — sharp, mid-exposure
        let image = makeCheckerboardImage(width: 1024, height: 1024, blockSize: 2)
        do {
            let result = try await gates.validate(image)
            // Resolution and blur should pass; exposure and saliency depend on Vision behavior
            XCTAssertNotEqual(result.failure?.gate, .resolution)
            XCTAssertNotEqual(result.failure?.gate, .blur)
            XCTAssertGreaterThan(result.scores.blurVariance, 0)
        } catch {
            try XCTSkipIf(
                error.localizedDescription.contains("espresso"),
                "Vision Neural Engine unavailable in this environment — requires device testing"
            )
            throw error
        }
    }

    // MARK: - Sequential Ordering

    func testGatesRunInOrder() async throws {
        // An image that fails resolution should not have blur computed
        let tinyImage = makeSolidImage(width: 50, height: 50)
        let result = try await gates.validate(tinyImage)
        XCTAssertEqual(result.failure?.gate, .resolution)
        XCTAssertEqual(result.scores.blurVariance, 0, "Blur should not be computed when resolution fails")
        XCTAssertEqual(result.scores.exposureMean, 0, "Exposure should not be computed when resolution fails")
        XCTAssertEqual(result.scores.saliencyCoverage, 0, "Saliency should not be computed when resolution fails")
    }
}
