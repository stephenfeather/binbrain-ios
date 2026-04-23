// ImagePipelineTests.swift
// Bin BrainTests
//
// Tests for the ImagePipeline actor — the orchestrator wiring stages 1-3.

import XCTest
@testable import Bin_Brain

@MainActor
final class ImagePipelineTests: XCTestCase {

    private var pipeline: ImagePipeline!

    override func setUp() {
        super.setUp()
        pipeline = ImagePipeline()
    }

    override func tearDown() {
        pipeline = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Creates a valid JPEG Data from a synthetic CGImage of the given size.
    private func makeTestJPEG(width: Int, height: Int) -> Data? {
        guard let cgImage = makeTestCGImage(width: width, height: height) else { return nil }
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: 1.0)
    }

    /// Creates a synthetic CGImage with a gradient pattern.
    private func makeTestCGImage(width: Int, height: Int) -> CGImage? {
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

        // Draw a gradient to avoid triggering blur/exposure gates
        let colors = [UIColor.darkGray.cgColor, UIColor.lightGray.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: width, y: height),
                options: []
            )
        }

        return ctx.makeImage()
    }

    // MARK: - Invalid Input

    func testProcessWithInvalidDataThrowsInvalidImageData() async {
        let badData = Data("not an image".utf8)
        do {
            _ = try await pipeline.process(badData)
            XCTFail("Expected PipelineError.invalidImageData")
        } catch let error as PipelineError {
            if case .invalidImageData = error {
                // Expected
            } else {
                XCTFail("Expected .invalidImageData, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testProcessSkippingGatesWithInvalidDataThrows() async {
        let badData = Data("not an image".utf8)
        do {
            _ = try await pipeline.processSkippingQualityGates(badData)
            XCTFail("Expected PipelineError.invalidImageData")
        } catch let error as PipelineError {
            if case .invalidImageData = error {
                // Expected
            } else {
                XCTFail("Expected .invalidImageData, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Tiny Image (Quality Gate Failure)

    func testProcessWithTinyImageThrowsQualityGateFailed() async {
        guard let jpegData = makeTestJPEG(width: 100, height: 100) else {
            XCTFail("Failed to create test JPEG")
            return
        }

        do {
            _ = try await pipeline.process(jpegData)
            XCTFail("Expected PipelineError.qualityGateFailed")
        } catch let error as PipelineError {
            if case .qualityGateFailed(let failure) = error {
                XCTAssertEqual(failure.gate, .resolution)
            } else {
                XCTFail("Expected .qualityGateFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Skip Quality Gates

    func testProcessSkippingGatesWithTinyImageSucceeds() async throws {
        guard let jpegData = makeTestJPEG(width: 100, height: 100) else {
            XCTFail("Failed to create test JPEG")
            return
        }

        do {
            let result = try await pipeline.processSkippingQualityGates(jpegData)
            XCTAssertFalse(result.optimizedImageData.isEmpty, "Should produce output data")
            XCTAssertEqual(result.deviceMetadata.deviceProcessing.version, "1")
            XCTAssertGreaterThanOrEqual(result.deviceMetadata.deviceProcessing.pipelineMs, 0)
        } catch {
            try XCTSkipIf(
                error.localizedDescription.contains("espresso"),
                "Vision Neural Engine unavailable — requires device testing"
            )
            throw error
        }
    }

    // MARK: - Metadata Structure

    func testResultMetadataHasCorrectStructure() async throws {
        guard let jpegData = makeTestJPEG(width: 100, height: 100) else {
            XCTFail("Failed to create test JPEG")
            return
        }

        do {
            let result = try await pipeline.processSkippingQualityGates(jpegData)
            let processing = result.deviceMetadata.deviceProcessing

            XCTAssertEqual(processing.version, "1")
            XCTAssertFalse(processing.iosVersion.isEmpty)
            XCTAssertFalse(processing.deviceModel.isEmpty)
            XCTAssertGreaterThanOrEqual(processing.pipelineMs, 0)

            XCTAssertEqual(processing.qualityScores.blurVariance, 0)
            XCTAssertEqual(processing.qualityScores.exposureMean, 0)
            XCTAssertEqual(processing.qualityScores.saliencyCoverage, 0)
            XCTAssertNotNil(processing.saliencyContext)
            XCTAssertNil(processing.qualityOverrideContext)
            XCTAssertNotNil(processing.cannyMetrics)

            _ = processing.ocr
            _ = processing.barcodes
            _ = processing.classifications
        } catch {
            try XCTSkipIf(
                error.localizedDescription.contains("espresso"),
                "Vision Neural Engine unavailable — requires device testing"
            )
            throw error
        }
    }

    func testProcessSkippingGatesCarriesQualityOverrideContext() async throws {
        guard let jpegData = makeTestJPEG(width: 100, height: 100) else {
            XCTFail("Failed to create test JPEG")
            return
        }

        let failure = QualityGateFailure(
            gate: .blur,
            message: "Image is too blurry — hold still and retake",
            metrics: QualityGateMetrics(
                measured: 1.28,
                threshold: 2.0,
                label: "Blur variance",
                thresholdLabel: "minimum"
            )
        )

        do {
            let result = try await pipeline.processSkippingQualityGates(jpegData, originalFailure: failure)
            let override = try XCTUnwrap(result.deviceMetadata.deviceProcessing.qualityOverrideContext)
            XCTAssertTrue(override.bypassed)
            XCTAssertEqual(override.failedGate, .blur)
            XCTAssertEqual(override.message, failure.message)
            XCTAssertEqual(override.measured, 1.28, accuracy: 0.0001)
            XCTAssertEqual(override.threshold, 2.0, accuracy: 0.0001)
            XCTAssertEqual(override.label, "Blur variance")
            XCTAssertEqual(override.thresholdLabel, "minimum")
        } catch {
            try XCTSkipIf(
                error.localizedDescription.contains("espresso"),
                "Vision Neural Engine unavailable — requires device testing"
            )
            throw error
        }
    }

    // MARK: - Resolution Capping

    func testLargeImageIsCappedBeforeProcessing() async throws {
        guard let jpegData = makeTestJPEG(width: 5000, height: 4000) else {
            XCTFail("Failed to create test JPEG")
            return
        }

        do {
            let result = try await pipeline.processSkippingQualityGates(jpegData)
            XCTAssertFalse(result.optimizedImageData.isEmpty)
            XCTAssertNotNil(UIImage(data: result.optimizedImageData))
        } catch {
            try XCTSkipIf(
                error.localizedDescription.contains("espresso"),
                "Vision Neural Engine unavailable — requires device testing"
            )
            throw error
        }
    }

    // MARK: - JSON Encoding

    func testResultMetadataEncodesToValidJSON() async throws {
        guard let jpegData = makeTestJPEG(width: 100, height: 100) else {
            XCTFail("Failed to create test JPEG")
            return
        }

        do {
            let result = try await pipeline.processSkippingQualityGates(jpegData)
            let encoder = JSONEncoder()
            let data = try encoder.encode(result.deviceMetadata)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let processing = try XCTUnwrap(json["device_processing"] as? [String: Any])
            let saliency = try XCTUnwrap(processing["saliency_context"] as? [String: Any])
            let capture = try XCTUnwrap(processing["capture_metadata"] as? [String: Any])
            let ocr = try XCTUnwrap(processing["ocr"] as? [[String: Any]])
            let barcodes = try XCTUnwrap(processing["barcodes"] as? [[String: Any]])
            XCTAssertNotNil(saliency["status"])
            XCTAssertNotNil(saliency["object_count"])
            XCTAssertNotNil(saliency["crop_threshold"])
            XCTAssertNotNil(saliency["crop_decision"])
            XCTAssertEqual(capture["original_width"] as? Int, 100)
            XCTAssertEqual(capture["original_height"] as? Int, 100)
            XCTAssertEqual(capture["original_bytes"] as? Int, jpegData.count)
            XCTAssertEqual(capture["input_format"] as? String, "jpeg")
            if let firstOCR = ocr.first {
                XCTAssertNotNil(firstOCR["bounding_box"])
            }
            if let firstBarcode = barcodes.first {
                XCTAssertNotNil(firstBarcode["bounding_box"])
            }
            XCTAssertNil(processing["quality_override_context"])
            XCTAssertNotNil(processing["canny_metrics"])
        } catch {
            try XCTSkipIf(
                error.localizedDescription.contains("espresso"),
                "Vision Neural Engine unavailable — requires device testing"
            )
            throw error
        }
    }

    // MARK: - Finding #29: EXIF orientation baking

    /// Creates a 200×100 JPEG tagged with .right orientation (simulates iPhone portrait capture).
    ///
    /// The sensor shoots in landscape (200 wide × 100 tall raw pixels). The EXIF `.right` tag
    /// tells decoders to rotate 90° CW to display correctly, producing a 100×200 portrait image.
    /// After orientation baking the decoded CGImage dimensions must be 100×200, not 200×100.
    private func makeRightOrientedJPEG(width: Int = 200, height: Int = 100) -> Data? {
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
        // Asymmetric fill: blue body with a red 2×2 block at raw top-right corner.
        // With .right orientation that corner becomes the visual top-left.
        ctx.setFillColor(UIColor.blue.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(UIColor.red.cgColor)
        ctx.fill(CGRect(x: width - 2, y: 0, width: 2, height: 2))
        guard let cgImage = ctx.makeImage() else { return nil }
        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
        return uiImage.jpegData(compressionQuality: 1.0)
    }

    /// Verifies decodeCGImage returns a CGImage in visual orientation.
    ///
    /// A .right-oriented JPEG has raw bitmap dimensions 200×100 (landscape sensor).
    /// The visual portrait result must be 100×200.
    func testDecodeCGImageBakesExifOrientationIntoPixels() async throws {
        guard let jpegData = makeRightOrientedJPEG(width: 200, height: 100) else {
            XCTFail("failed to create orientation test JPEG"); return
        }

        let decoded = try await pipeline.decodeCGImage(from: jpegData)

        // Visual portrait: width and height are swapped relative to the raw sensor dims.
        XCTAssertEqual(decoded.width, 100,
            "decoded width should be the visual portrait width (100), not the raw landscape width (200)")
        XCTAssertEqual(decoded.height, 200,
            "decoded height should be the visual portrait height (200), not the raw landscape height (100)")
    }

    /// Verifies the .up fast-path: images already in correct orientation pass through
    /// without re-rendering — dimensions must be preserved exactly.
    func testDecodeCGImageUpOrientationPreservesDimensions() async throws {
        // makeTestJPEG produces a UIImage(cgImage:) with no EXIF orientation tag → .up
        guard let jpegData = makeTestJPEG(width: 100, height: 200) else {
            XCTFail("failed to create test JPEG"); return
        }

        let decoded = try await pipeline.decodeCGImage(from: jpegData)

        XCTAssertEqual(decoded.width, 100,
            ".up orientation must not alter width")
        XCTAssertEqual(decoded.height, 200,
            ".up orientation must not alter height")
    }
}
