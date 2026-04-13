// PipelineModelsTests.swift
// Bin BrainTests
//
// Tests for pipeline data models — JSON encoding/decoding round-trips
// and format verification against the spec sidecar format.

import XCTest
@testable import Bin_Brain

@MainActor
final class PipelineModelsTests: XCTestCase {

    // MARK: - JSON Encoder/Decoder

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private var decoder: JSONDecoder {
        JSONDecoder()
    }

    // MARK: - Fixtures

    private func makeSampleMetadata() -> DeviceMetadata {
        DeviceMetadata(
            deviceProcessing: DeviceProcessing(
                version: "1",
                pipelineMs: 623,
                iosVersion: "18.4",
                deviceModel: "iPhone16,1",
                qualityScores: QualityScores(
                    blurVariance: 842.3,
                    exposureMean: 0.47,
                    saliencyCoverage: 0.72,
                    shortestSide: 3024
                ),
                ocr: [
                    OCRResult(text: "M3x8 DIN 912", confidence: 0.94),
                    OCRResult(text: "Würth", confidence: 0.87)
                ],
                barcodes: [
                    BarcodeResult(payload: "4005176834561", symbology: "EAN-13")
                ],
                classifications: [
                    ClassificationResult(label: "screw", confidence: 0.82),
                    ClassificationResult(label: "nail", confidence: 0.11)
                ],
                cropApplied: CropInfo(
                    originalSize: [4032, 3024],
                    cropRect: [420, 310, 3200, 2400]
                )
            )
        )
    }

    // MARK: - Round-Trip Tests

    func testDeviceMetadataRoundTrip() throws {
        let original = makeSampleMetadata()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(DeviceMetadata.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testQualityScoresRoundTrip() throws {
        let original = QualityScores(
            blurVariance: 500.0,
            exposureMean: 0.5,
            saliencyCoverage: 0.8,
            shortestSide: 2048
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(QualityScores.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testCropInfoRoundTrip() throws {
        let original = CropInfo(originalSize: [4032, 3024], cropRect: [100, 200, 3000, 2000])
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(CropInfo.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - Snake Case Key Verification

    func testEncodedKeysAreSnakeCase() throws {
        let metadata = makeSampleMetadata()
        let data = try encoder.encode(metadata)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Top level
        XCTAssertNotNil(json["device_processing"], "Expected 'device_processing' key")
        XCTAssertNil(json["deviceProcessing"], "Should not have camelCase key")

        // Nested level
        let processing = try XCTUnwrap(json["device_processing"] as? [String: Any])
        XCTAssertNotNil(processing["pipeline_ms"])
        XCTAssertNotNil(processing["ios_version"])
        XCTAssertNotNil(processing["device_model"])
        XCTAssertNotNil(processing["quality_scores"])
        XCTAssertNotNil(processing["crop_applied"])

        // Quality scores level
        let scores = try XCTUnwrap(processing["quality_scores"] as? [String: Any])
        XCTAssertNotNil(scores["blur_variance"])
        XCTAssertNotNil(scores["exposure_mean"])
        XCTAssertNotNil(scores["saliency_coverage"])
        XCTAssertNotNil(scores["shortest_side"])

        // Crop info level
        let crop = try XCTUnwrap(processing["crop_applied"] as? [String: Any])
        XCTAssertNotNil(crop["original_size"])
        XCTAssertNotNil(crop["crop_rect"])
    }

    // MARK: - Nil Crop Info

    func testDeviceMetadataWithNilCrop() throws {
        let metadata = DeviceMetadata(
            deviceProcessing: DeviceProcessing(
                version: "1",
                pipelineMs: 400,
                iosVersion: "18.4",
                deviceModel: "iPhone15,3",
                qualityScores: QualityScores(
                    blurVariance: 900.0,
                    exposureMean: 0.5,
                    saliencyCoverage: 0.65,
                    shortestSide: 2048
                ),
                ocr: [],
                barcodes: [],
                classifications: [],
                cropApplied: nil
            )
        )
        let data = try encoder.encode(metadata)
        let decoded = try decoder.decode(DeviceMetadata.self, from: data)
        XCTAssertEqual(metadata, decoded)
        XCTAssertNil(decoded.deviceProcessing.cropApplied)
    }

    // MARK: - Spec Format Match

    func testEncodedJSONMatchesSpecStructure() throws {
        let metadata = makeSampleMetadata()
        let data = try encoder.encode(metadata)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let processing = try XCTUnwrap(json["device_processing"] as? [String: Any])

        // Version is string "1"
        XCTAssertEqual(processing["version"] as? String, "1")

        // Pipeline ms is integer
        XCTAssertEqual(processing["pipeline_ms"] as? Int, 623)

        // OCR is array of objects with text + confidence
        let ocr = try XCTUnwrap(processing["ocr"] as? [[String: Any]])
        XCTAssertEqual(ocr.count, 2)
        XCTAssertEqual(ocr[0]["text"] as? String, "M3x8 DIN 912")

        // Barcodes have payload + symbology
        let barcodes = try XCTUnwrap(processing["barcodes"] as? [[String: Any]])
        XCTAssertEqual(barcodes[0]["payload"] as? String, "4005176834561")
        XCTAssertEqual(barcodes[0]["symbology"] as? String, "EAN-13")

        // Classifications have label + confidence
        let classifications = try XCTUnwrap(processing["classifications"] as? [[String: Any]])
        XCTAssertEqual(classifications[0]["label"] as? String, "screw")
    }
}
