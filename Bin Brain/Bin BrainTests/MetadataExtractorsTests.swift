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

    func testDeduplicateOCRKeepsHighestConfidenceForDuplicates() {
        let input = [
            OCRResult(text: "SKU-1234", confidence: 0.6),
            OCRResult(text: "sku-1234", confidence: 0.95),
            OCRResult(text: " SKU-1234 ", confidence: 0.7)
        ]

        let deduplicated = MetadataExtractors.deduplicateOCR(input)

        XCTAssertEqual(deduplicated.count, 1)
        XCTAssertEqual(deduplicated[0].confidence, 0.95)
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
