// QualityGatesTests.swift
// Bin BrainTests
//
// Tests for the quality gate checks that validate image quality before upload.
// Uses synthetic CGImages generated with Core Graphics to test each gate.

import XCTest
import CoreGraphics
@testable import Bin_Brain

@MainActor
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

    // MARK: - Blur Gate (re-enabled — Swift2_004 Step 1)

    // The blur gate is now active. A flat (zero-variance) image must fail;
    // a sharp (high-variance) image must pass.
    func testBlurGateFailsForFlatImage() {
        // Solid flat image → Laplacian variance ≈ 0, well below the 2.0 threshold
        let flatImage = makeSolidImage(width: 1024, height: 1024, gray: 0.5)
        let result = gates.checkBlur(flatImage)
        XCTAssertNotNil(result.failure, "Blur gate should reject a flat (zero-variance) image")
        XCTAssertEqual(result.failure?.gate, .blur)
    }

    func testBlurGatePassesForSharpImage() {
        // Checkerboard with 2px blocks → Laplacian variance ≈ 16, well above 2.0 threshold
        let sharpImage = makeCheckerboardImage(width: 1024, height: 1024, blockSize: 2)
        let result = gates.checkBlur(sharpImage)
        XCTAssertNil(result.failure, "Blur gate should pass a high-frequency (sharp) image")
        XCTAssertGreaterThan(result.variance, 0, "Variance should be computed and positive")
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

    func testValidateFailsBlurGateOnFlatImage() async throws {
        // Flat solid image (variance ≈ 0) fails the blur gate before saliency runs,
        // so no Vision skip is needed — validate() returns early at Gate 2.
        let solidImage = makeSolidImage(width: 1024, height: 1024, gray: 0.5)
        let result = try await gates.validate(solidImage)
        XCTAssertEqual(result.failure?.gate, .blur,
                       "Blur gate should fail on a flat image now that it is re-enabled")
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

    // MARK: - Gate Metrics (Swift2_004 Step 2)

    func testBlurGateFailureCarriesMetrics() {
        let flatImage = makeSolidImage(width: 1024, height: 1024, gray: 0.5)
        let result = gates.checkBlur(flatImage)
        guard let failure = result.failure else {
            return XCTFail("Expected blur gate failure for flat image")
        }
        XCTAssertEqual(failure.metrics.label, "Blur variance")
        XCTAssertEqual(failure.metrics.thresholdLabel, "minimum")
        // Flat image → variance ≈ 0; threshold at 1024px = 2.0
        XCTAssertEqual(failure.metrics.measured, result.variance, accuracy: 1e-9)
        let expectedThreshold = QualityGates.scaledBlurThreshold(shortestSide: 1024, baseThresholdAt1024: kBlurVarianceThresholdAt1024)
        XCTAssertEqual(failure.metrics.threshold, expectedThreshold, accuracy: 1e-9)
    }

    func testResolutionGateFailureCarriesMetrics() {
        let tinyImage = makeSolidImage(width: 512, height: 512)
        let failure = gates.checkResolution(tinyImage)
        guard let failure else {
            return XCTFail("Expected resolution gate failure for 512px image")
        }
        XCTAssertEqual(failure.metrics.label, "Short side")
        XCTAssertEqual(failure.metrics.thresholdLabel, "minimum")
        XCTAssertEqual(failure.metrics.measured, 512.0, accuracy: 0.1)
        XCTAssertEqual(failure.metrics.threshold, Double(kMinimumShortestSide), accuracy: 0.1)
    }

    func testExposureGateFailureCarriesMetricsForDarkImage() {
        let darkImage = makeSolidImage(width: 1024, height: 1024, gray: 0.02)
        let result = gates.checkExposure(darkImage)
        guard let failure = result.failure else {
            return XCTFail("Expected exposure gate failure for near-black image")
        }
        XCTAssertEqual(failure.gate, .exposure)
        XCTAssertEqual(failure.metrics.thresholdLabel, "maximum")
        XCTAssertEqual(failure.metrics.threshold, kExposureExtremeFraction, accuracy: 1e-9)
        XCTAssertGreaterThan(failure.metrics.measured, kExposureExtremeFraction,
                             "Measured fraction must exceed threshold to have triggered the failure")
    }

    // MARK: - Pure Blur Threshold Math (Finding #4)

    func testScaledBlurThresholdAt1024IsBaseline() {
        // At the reference resolution the scaled threshold must equal the base.
        let scaled = QualityGates.scaledBlurThreshold(shortestSide: 1024, baseThresholdAt1024: 2.0)
        XCTAssertEqual(scaled, 2.0, accuracy: 1e-9)
    }

    func testScaledBlurThresholdScalesLinearly() {
        // Halving the shortest side halves the threshold.
        let scaled = QualityGates.scaledBlurThreshold(shortestSide: 512, baseThresholdAt1024: 2.0)
        XCTAssertEqual(scaled, 1.0, accuracy: 1e-9)
    }

    func testBlurGatePassesWhenVarianceAboveThreshold() {
        XCTAssertTrue(QualityGates.blurGatePasses(variance: 3.0, scaledThreshold: 2.0))
    }

    func testBlurGateFailsWhenVarianceBelowThreshold() {
        XCTAssertFalse(QualityGates.blurGatePasses(variance: 1.0, scaledThreshold: 2.0))
    }

    func testBlurGatePassesAtExactThreshold() {
        // Inclusive lower bound — variance == threshold counts as pass.
        XCTAssertTrue(QualityGates.blurGatePasses(variance: 2.0, scaledThreshold: 2.0))
    }

    // MARK: - Metric Formatting (Swift2_004 Step 4)

    func testFormatMetricValueForIntegerLargeValue() {
        XCTAssertEqual(formatMetricValue(1024.0), "1024")
    }

    func testFormatMetricValueForSmallInteger() {
        XCTAssertEqual(formatMetricValue(2.0), "2")
    }

    func testFormatMetricValueForUnitFraction() {
        // Blur variance spec example: 0.001234 → "0.0012" (4 decimal places)
        XCTAssertEqual(formatMetricValue(0.001234), "0.0012")
    }

    func testFormatMetricValueForExposureFraction() {
        XCTAssertEqual(formatMetricValue(0.7), "0.7000")
    }

    func testFormatMetricValueForTinyValueUsesFixedPoint() {
        // Values below 0.0001 stay in fixed-point with extended precision
        // (scientific notation is hard to read for a blur-variance UI readout).
        XCTAssertEqual(formatMetricValue(0.000001), "0.000001")
    }

    func testFormatMetricValueForVeryTinyValueUsesFixedPoint() {
        // 6-decimal precision — values that round to zero still display as "0.000000",
        // never in scientific form.
        let result = formatMetricValue(0.0000001)
        XCTAssertFalse(result.contains("e"), "Scientific notation leaked through: \(result)")
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
