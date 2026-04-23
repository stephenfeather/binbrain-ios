// EdgeMetricsExtractorTests.swift
// Bin BrainTests
//
// Focused tests for additive edge telemetry extracted from Core Image Canny output.

import CoreImage
import UIKit
import XCTest
@testable import Bin_Brain

@MainActor
final class EdgeMetricsExtractorTests: XCTestCase {

    private let extractor = EdgeMetricsExtractor()
    private let context = CIContext(options: [.useSoftwareRenderer: true])

    func testExtractReturnsMetricsForCheckerboardImage() throws {
        let image = try XCTUnwrap(makeCheckerboardCGImage(width: 512, height: 512))
        let metrics = extractor.extract(
            from: image,
            saliencyBoundingBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            cropInfo: CropInfo(originalSize: [512, 512], cropRect: [64, 64, 384, 384]),
            context: context
        )

        guard let metrics else {
            throw XCTSkip("Canny edge detector unavailable in this test environment")
        }

        XCTAssertEqual(metrics.analysisLongestSide, 512)
        XCTAssertGreaterThan(metrics.fullFrameEdgeDensity, 0)
        XCTAssertNotNil(metrics.saliencyEdgeDensity)
        XCTAssertNotNil(metrics.uploadFrameEdgeDensity)
    }

    func testCheckerboardProducesHigherEdgeDensityThanFlatImage() throws {
        let checkerboard = try XCTUnwrap(makeCheckerboardCGImage(width: 512, height: 512))
        let flat = try XCTUnwrap(makeFlatCGImage(width: 512, height: 512))

        let checkerMetrics = extractor.extract(
            from: checkerboard,
            saliencyBoundingBox: nil,
            cropInfo: nil,
            context: context
        )
        let flatMetrics = extractor.extract(
            from: flat,
            saliencyBoundingBox: nil,
            cropInfo: nil,
            context: context
        )

        guard let checkerMetrics, let flatMetrics else {
            throw XCTSkip("Canny edge detector unavailable in this test environment")
        }

        XCTAssertGreaterThan(checkerMetrics.fullFrameEdgeDensity, flatMetrics.fullFrameEdgeDensity)
    }

    private func makeFlatCGImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(UIColor.lightGray.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private func makeCheckerboardCGImage(width: Int, height: Int, blockSize: Int = 32) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        for row in stride(from: 0, to: height, by: blockSize) {
            for column in stride(from: 0, to: width, by: blockSize) {
                let isDark = ((row / blockSize) + (column / blockSize)).isMultiple(of: 2)
                ctx.setFillColor((isDark ? UIColor.black : UIColor.white).cgColor)
                ctx.fill(CGRect(x: column, y: row, width: blockSize, height: blockSize))
            }
        }

        return ctx.makeImage()
    }
}
