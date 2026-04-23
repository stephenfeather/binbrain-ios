// MetadataExtractorsTests.swift
// Bin BrainTests
//
// Tests for MetadataExtractors — focuses on the mapping, filtering,
// and deduplication logic. Actual Vision framework accuracy requires
// device testing; unit tests use synthetic CGImages and mock observations.

import CoreGraphics
import XCTest
import Vision
@testable import Bin_Brain

final class MetadataExtractorsTests: XCTestCase {

    // MARK: - Test Image Helpers

    /// Creates a solid-color CGImage of the specified size.
    private func makeSolidImage(width: Int = 100, height: Int = 100) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    // MARK: - Extract with Blank Image

    func testExtractFromBlankImageReturnsEmptyOrMinimalResults() async throws {
        let extractor = MetadataExtractors()
        let blankImage = makeSolidImage()

        do {
            let result = try await extractor.extract(from: blankImage)
            // A blank solid-color image should produce no meaningful OCR or barcode results.
            XCTAssertTrue(result.ocr.isEmpty, "Blank image should yield no OCR results")
            XCTAssertTrue(result.barcodes.isEmpty, "Blank image should yield no barcode results")
        } catch {
            // Vision's Neural Engine (espresso) is unavailable in some simulator environments.
            try XCTSkipIf(
                error.localizedDescription.contains("espresso"),
                "Vision Neural Engine unavailable in this environment — requires device testing"
            )
            throw error
        }
    }

    // MARK: - OCR Confidence Filtering

    func testMapOCRResultsFiltersLowConfidence() {
        // OCRResult directly tests the threshold logic without needing VNRecognizedTextObservation
        // (which cannot be constructed in tests). We test the threshold constant instead.
        XCTAssertEqual(MetadataExtractors.ocrConfidenceThreshold, 0.5)
    }

    func testMapOCRResultsReturnsEmptyForEmptyInput() {
        let results = MetadataExtractors.mapOCRResults([])
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - OCR Deduplication

    func testDeduplicateOCRRemovesCaseInsensitiveDuplicates() {
        let input = [
            OCRResult(text: "Hello World", confidence: 0.8),
            OCRResult(text: "hello world", confidence: 0.9),
            OCRResult(text: "HELLO WORLD", confidence: 0.7)
        ]

        let deduplicated = MetadataExtractors.deduplicateOCR(input)

        XCTAssertEqual(deduplicated.count, 1)
        // Should keep the highest confidence version
        XCTAssertEqual(deduplicated[0].confidence, 0.9)
        XCTAssertEqual(deduplicated[0].text, "hello world")
    }

    func testDeduplicateOCRTrimsWhitespace() {
        let input = [
            OCRResult(text: "  Hello  ", confidence: 0.6),
            OCRResult(text: "Hello", confidence: 0.85)
        ]

        let deduplicated = MetadataExtractors.deduplicateOCR(input)

        XCTAssertEqual(deduplicated.count, 1)
        XCTAssertEqual(deduplicated[0].confidence, 0.85)
    }

    func testDeduplicateOCRPreservesDistinctEntries() {
        let input = [
            OCRResult(text: "M3x8 DIN 912", confidence: 0.94),
            OCRResult(text: "Würth", confidence: 0.87),
            OCRResult(text: "4005176834561", confidence: 0.92)
        ]

        let deduplicated = MetadataExtractors.deduplicateOCR(input)

        XCTAssertEqual(deduplicated.count, 3)
    }

    func testDeduplicateOCRHandlesEmptyInput() {
        let deduplicated = MetadataExtractors.deduplicateOCR([])
        XCTAssertTrue(deduplicated.isEmpty)
    }

    func testDeduplicateOCRKeepsHighestConfidenceForDuplicates() throws {
        let input = [
            OCRResult(
                text: "SKU-1234",
                confidence: 0.6,
                boundingBox: NormalizedBoundingBox(x: 0.10, y: 0.20, width: 0.30, height: 0.08)
            ),
            OCRResult(
                text: "sku-1234",
                confidence: 0.95,
                boundingBox: NormalizedBoundingBox(x: 0.14, y: 0.26, width: 0.34, height: 0.09)
            ),
            OCRResult(
                text: " SKU-1234 ",
                confidence: 0.7,
                boundingBox: NormalizedBoundingBox(x: 0.18, y: 0.29, width: 0.28, height: 0.07)
            )
        ]

        let deduplicated = MetadataExtractors.deduplicateOCR(input)

        XCTAssertEqual(deduplicated.count, 1)
        XCTAssertEqual(deduplicated[0].confidence, 0.95)
        let bbox = try XCTUnwrap(deduplicated[0].boundingBox)
        XCTAssertEqual(bbox.x, 0.14, accuracy: 1e-10)
        XCTAssertEqual(bbox.height, 0.09, accuracy: 1e-10)
    }

    @MainActor
    func testOCRResultRoundTripsBoundingBox() throws {
        let result = OCRResult(
            text: "M3x8 DIN 912",
            confidence: 0.94,
            boundingBox: NormalizedBoundingBox(x: 0.12, y: 0.44, width: 0.41, height: 0.09)
        )

        let data = try JSONEncoder().encode(result)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let bbox = try XCTUnwrap(json["bounding_box"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(bbox["x"] as? Double), 0.12, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(bbox["width"] as? Double), 0.41, accuracy: 1e-10)
    }

    @MainActor
    func testBarcodeResultRoundTripsBoundingBox() throws {
        let result = BarcodeResult(
            payload: "4005176834561",
            symbology: "EAN-13",
            boundingBox: NormalizedBoundingBox(x: 0.58, y: 0.14, width: 0.27, height: 0.18)
        )

        let data = try JSONEncoder().encode(result)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let bbox = try XCTUnwrap(json["bounding_box"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(bbox["y"] as? Double), 0.14, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(bbox["height"] as? Double), 0.18, accuracy: 1e-10)
    }

    // MARK: - Barcode Mapping

    func testMapBarcodeResultsReturnsEmptyForEmptyInput() {
        let results = MetadataExtractors.mapBarcodeResults([])
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Classification Filtering

    func testFilterClassificationsAppliesThresholdAndLimit() {
        // VNClassificationObservation cannot be constructed directly in tests.
        // Verify the threshold and limit constants are set correctly.
        XCTAssertEqual(MetadataExtractors.classificationConfidenceThreshold, 0.1)
        XCTAssertEqual(MetadataExtractors.classificationMaxResults, 10)
    }

    func testFilterClassificationsReturnsEmptyForEmptyInput() {
        let results = MetadataExtractors.filterClassifications([])
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Swift2_018 Blocklist Tests

    /// Verifies that blocklisted identifiers are dropped and non-blocklisted
    /// identifiers survive. Uses the internal `identifiersAndConfidences:` overload
    /// because `VNClassificationObservation` cannot be directly constructed in unit
    /// tests (as documented in the existing threshold test above).
    func testFilterClassifications_dropsBlocklistedLabels() {
        let result = MetadataExtractors.filterClassifications(identifiersAndConfidences: [
            (identifier: "box", confidence: 0.8),
            (identifier: "phillips_screwdriver", confidence: 0.7)
        ])

        XCTAssertEqual(result.count, 1,
                       "Blocklisted 'box' must be dropped; 'phillips_screwdriver' must survive")
        XCTAssertEqual(result.first?.label, "phillips_screwdriver")
    }

    func testFilterClassifications_blocklistIsCaseInsensitive() {
        let result = MetadataExtractors.filterClassifications(identifiersAndConfidences: [
            (identifier: "Box", confidence: 0.8),
            (identifier: "CONTAINER", confidence: 0.6)
        ])

        XCTAssertTrue(result.isEmpty,
                      "Blocklist check must be case-insensitive; 'Box' and 'CONTAINER' should both be dropped")
    }

    func testFilterClassifications_confidenceAndBlocklistCombined() {
        let result = MetadataExtractors.filterClassifications(identifiersAndConfidences: [
            (identifier: "bolt", confidence: 0.05),               // below threshold → drop
            (identifier: "box", confidence: 0.8),                  // above threshold + blocklisted → drop
            (identifier: "phillips_screwdriver", confidence: 0.6)  // above threshold + not blocklisted → keep
        ])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.label, "phillips_screwdriver")
    }

    // MARK: - Integration: Extract Does Not Crash

    func testExtractFromLargerBlankImageDoesNotCrash() async throws {
        let extractor = MetadataExtractors()
        let image = makeSolidImage(width: 1024, height: 768)

        do {
            let result = try await extractor.extract(from: image)
            XCTAssertNotNil(result.ocr)
            XCTAssertNotNil(result.barcodes)
            XCTAssertNotNil(result.classifications)
        } catch {
            try XCTSkipIf(
                error.localizedDescription.contains("espresso"),
                "Vision Neural Engine unavailable in this environment — requires device testing"
            )
            throw error
        }
    }
}
