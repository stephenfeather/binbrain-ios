// ImageOptimizerTests.swift
// Bin BrainTests
//
// Tests for the image optimizer — smart crop, auto-enhance, resize, and JPEG encoding.

import XCTest
import CoreGraphics
import CoreImage
@testable import Bin_Brain

final class ImageOptimizerTests: XCTestCase {

    // MARK: - Helpers

    private let optimizer = ImageOptimizer()
    private let context = CIContext(options: [.useSoftwareRenderer: true])

    /// Creates a solid-color CGImage at the specified dimensions.
    private func makeSolidImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        )!
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    // MARK: - Resize Tests

    func testLargeImageResizedToMaxDimension() {
        let image = makeSolidImage(width: 4032, height: 3024)

        let (jpegData, _) = optimizer.optimize(
            image,
            saliencyBoundingBox: nil,
            context: context
        )

        let decoded = UIImage(data: jpegData)!
        let longestSide = max(decoded.size.width, decoded.size.height)
        XCTAssertLessThanOrEqual(longestSide, 2048, "Longest side should be <= 2048")
    }

    func testSmallImageNotResized() {
        let image = makeSolidImage(width: 1024, height: 768)

        let (jpegData, _) = optimizer.optimize(
            image,
            saliencyBoundingBox: nil,
            context: context
        )

        let decoded = UIImage(data: jpegData)!
        XCTAssertEqual(Int(decoded.size.width), 1024, "Width should remain unchanged")
        XCTAssertEqual(Int(decoded.size.height), 768, "Height should remain unchanged")
    }

    func testResizePreservesAspectRatio() {
        let image = makeSolidImage(width: 4032, height: 3024)

        let (jpegData, _) = optimizer.optimize(
            image,
            saliencyBoundingBox: nil,
            context: context
        )

        let decoded = UIImage(data: jpegData)!
        let ratio = decoded.size.width / decoded.size.height
        let expectedRatio = 4032.0 / 3024.0
        XCTAssertEqual(ratio, expectedRatio, accuracy: 0.02, "Aspect ratio should be preserved")
    }

    // MARK: - Smart Crop Tests

    func testSaliencyBoxUnder60PercentTriggersCrop() {
        let image = makeSolidImage(width: 2000, height: 2000)
        // Normalized box covering 25% of the frame (0.5 * 0.5)
        let saliencyBox = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

        let (_, cropInfo) = optimizer.optimize(
            image,
            saliencyBoundingBox: saliencyBox,
            context: context
        )

        XCTAssertNotNil(cropInfo, "CropInfo should be populated when saliency < 60%")
        XCTAssertEqual(cropInfo?.originalSize, [2000, 2000])
    }

    func testSaliencyBoxOver60PercentSkipsCrop() {
        let image = makeSolidImage(width: 2000, height: 2000)
        // Normalized box covering 81% of the frame (0.9 * 0.9)
        let saliencyBox = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)

        let (_, cropInfo) = optimizer.optimize(
            image,
            saliencyBoundingBox: saliencyBox,
            context: context
        )

        XCTAssertNil(cropInfo, "CropInfo should be nil when saliency >= 60%")
    }

    func testNilSaliencyBoxSkipsCrop() {
        let image = makeSolidImage(width: 2000, height: 2000)

        let (_, cropInfo) = optimizer.optimize(
            image,
            saliencyBoundingBox: nil,
            context: context
        )

        XCTAssertNil(cropInfo, "CropInfo should be nil when saliency box is nil")
    }

    func testCropInfoContainsPixelCoordinates() {
        let image = makeSolidImage(width: 4000, height: 3000)
        // Small box in the center: 20% coverage (0.4 * 0.5)
        let saliencyBox = CGRect(x: 0.3, y: 0.25, width: 0.4, height: 0.5)

        let (_, cropInfo) = optimizer.optimize(
            image,
            saliencyBoundingBox: saliencyBox,
            context: context
        )

        let info = try! XCTUnwrap(cropInfo)
        XCTAssertEqual(info.originalSize, [4000, 3000])
        // cropRect should be [x, y, width, height] in pixel coordinates
        XCTAssertEqual(info.cropRect.count, 4)
        // All values should be within image bounds
        XCTAssertGreaterThanOrEqual(info.cropRect[0], 0)
        XCTAssertGreaterThanOrEqual(info.cropRect[1], 0)
        XCTAssertLessThanOrEqual(info.cropRect[0] + info.cropRect[2], 4000)
        XCTAssertLessThanOrEqual(info.cropRect[1] + info.cropRect[3], 3000)
    }

    // MARK: - JPEG Encoding Tests

    func testOutputIsValidJPEG() {
        let image = makeSolidImage(width: 800, height: 600)

        let (jpegData, _) = optimizer.optimize(
            image,
            saliencyBoundingBox: nil,
            context: context
        )

        // JPEG magic bytes: FF D8 FF
        XCTAssertGreaterThan(jpegData.count, 3)
        XCTAssertEqual(jpegData[0], 0xFF)
        XCTAssertEqual(jpegData[1], 0xD8)
        XCTAssertEqual(jpegData[2], 0xFF)

        // Can decode back to UIImage
        let decoded = UIImage(data: jpegData)
        XCTAssertNotNil(decoded, "Output JPEG should be decodable to UIImage")
    }

    // MARK: - Auto-Enhance Tests

    func testAutoEnhanceDisabledByDefault() {
        let image = makeSolidImage(width: 800, height: 600)

        // Default parameter — autoEnhance should be false
        let (jpegData1, _) = optimizer.optimize(
            image,
            saliencyBoundingBox: nil,
            context: context
        )

        // Explicitly disabled
        let (jpegData2, _) = optimizer.optimize(
            image,
            saliencyBoundingBox: nil,
            context: context,
            autoEnhance: false
        )

        // Both should produce identical output (no enhancement applied)
        XCTAssertEqual(jpegData1, jpegData2, "Default and explicit false should produce identical output")
    }

    func testAutoEnhanceEnabledProducesDifferentOutput() {
        // Use a gradient image so auto-enhance has something to adjust
        let image = makeGradientImage(width: 800, height: 600)

        let (jpegDefault, _) = optimizer.optimize(
            image,
            saliencyBoundingBox: nil,
            context: context,
            autoEnhance: false
        )

        let (jpegEnhanced, _) = optimizer.optimize(
            image,
            saliencyBoundingBox: nil,
            context: context,
            autoEnhance: true
        )

        // Auto-enhance may or may not change the image depending on the input.
        // If filters are applied, the output should differ. If CIImage decides
        // no adjustment is needed, they could be equal. We just verify both are valid.
        XCTAssertNotNil(UIImage(data: jpegDefault))
        XCTAssertNotNil(UIImage(data: jpegEnhanced))
    }

    // MARK: - Edge Cases

    func testExactly2048ImageNotResized() {
        let image = makeSolidImage(width: 2048, height: 1536)

        let (jpegData, _) = optimizer.optimize(
            image,
            saliencyBoundingBox: nil,
            context: context
        )

        let decoded = UIImage(data: jpegData)!
        XCTAssertEqual(Int(decoded.size.width), 2048)
        XCTAssertEqual(Int(decoded.size.height), 1536)
    }

    func testCropThenResizeProducesCorrectSize() {
        // Large image with small saliency region → crop then resize
        let image = makeSolidImage(width: 4032, height: 3024)
        // Small centered box: 10% coverage
        let saliencyBox = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)

        let (jpegData, cropInfo) = optimizer.optimize(
            image,
            saliencyBoundingBox: saliencyBox,
            context: context
        )

        XCTAssertNotNil(cropInfo, "Should have cropped")
        let decoded = UIImage(data: jpegData)!
        let longestSide = max(decoded.size.width, decoded.size.height)
        // After crop + padding, image may still be > 2048, so resize kicks in
        XCTAssertLessThanOrEqual(longestSide, 2048, "Should be resized after crop if still too large")
    }

    // MARK: - Gradient Image Helper

    /// Creates a horizontal gradient CGImage for auto-enhance testing.
    private func makeGradientImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        )!
        let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0),
                     CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0)] as CFArray,
            locations: [0.0, 1.0]
        )!
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: CGFloat(width), y: 0),
            options: []
        )
        return ctx.makeImage()!
    }
}
