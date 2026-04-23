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
                    OCRResult(
                        text: "M3x8 DIN 912",
                        confidence: 0.94,
                        boundingBox: NormalizedBoundingBox(x: 0.12, y: 0.44, width: 0.41, height: 0.09)
                    ),
                    OCRResult(
                        text: "Würth",
                        confidence: 0.87,
                        boundingBox: NormalizedBoundingBox(x: 0.18, y: 0.31, width: 0.22, height: 0.07)
                    )
                ],
                barcodes: [
                    BarcodeResult(
                        payload: "4005176834561",
                        symbology: "EAN-13",
                        boundingBox: NormalizedBoundingBox(x: 0.58, y: 0.14, width: 0.27, height: 0.18)
                    )
                ],
                classifications: [
                    ClassificationResult(label: "screw", confidence: 0.82),
                    ClassificationResult(label: "nail", confidence: 0.11)
                ],
                saliencyContext: SaliencyContext(
                    status: .detected,
                    objectCount: 3,
                    coverage: 0.42,
                    unionBoundingBox: NormalizedBoundingBox(
                        x: 0.12,
                        y: 0.18,
                        width: 0.56,
                        height: 0.74
                    ),
                    cropThreshold: 0.60,
                    cropDecision: .applied
                ),
                captureMetadata: CaptureMetadata(
                    originalWidth: 4032,
                    originalHeight: 3024,
                    originalBytes: 2_481_144,
                    inputFormat: "jpeg",
                    cameraDeviceType: "tripleCamera",
                    cameraPosition: "back",
                    zoomFactor: 1.0,
                    flashUsed: false,
                    torchUsed: false,
                    hdrEnabled: true,
                    iso: 320,
                    exposureDurationMs: 16.6,
                    focusMode: "continuousAutoFocus",
                    lensPosition: 0.42,
                    focalLengthMm: 6.86
                ),
                optimizedUpload: OptimizedUploadStats(
                    optimizedWidth: 2048,
                    optimizedHeight: 1536,
                    optimizedBytes: 512_240,
                    uploadFormat: "jpeg",
                    resizeApplied: true,
                    compressionQuality: 0.85,
                    compressionRatio: 0.2065,
                    cropFraction: 0.6349
                ),
                cropApplied: CropInfo(
                    originalSize: [4032, 3024],
                    cropRect: [420, 310, 3200, 2400]
                ),
                qualityOverrideContext: QualityOverrideContext(
                    bypassed: true,
                    failedGate: .blur,
                    message: "Image is too blurry — hold still and retake",
                    measured: 1.28,
                    threshold: 2.0,
                    label: "Blur variance",
                    thresholdLabel: "minimum"
                ),
                cannyMetrics: CannyMetrics(
                    analysisLongestSide: 512,
                    gaussianSigma: 1.6,
                    thresholdLow: 0.02,
                    thresholdHigh: 0.05,
                    hysteresisPasses: 1,
                    fullFrameEdgeDensity: 0.084,
                    saliencyEdgeDensity: 0.137,
                    uploadFrameEdgeDensity: 0.121
                ),
                userBehavior: UserBehavior(
                    retakeCount: 2,
                    qualityBypassCount: 1
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
        XCTAssertNotNil(processing["saliency_context"])
        XCTAssertNotNil(processing["capture_metadata"])
        XCTAssertNotNil(processing["optimized_upload"])
        XCTAssertNotNil(processing["crop_applied"])
        XCTAssertNotNil(processing["quality_override_context"])
        XCTAssertNotNil(processing["canny_metrics"])
        XCTAssertNotNil(processing["user_behavior"])

        // Quality scores level
        let scores = try XCTUnwrap(processing["quality_scores"] as? [String: Any])
        XCTAssertNotNil(scores["blur_variance"])
        XCTAssertNotNil(scores["exposure_mean"])
        XCTAssertNotNil(scores["saliency_coverage"])
        XCTAssertNotNil(scores["shortest_side"])

        let saliency = try XCTUnwrap(processing["saliency_context"] as? [String: Any])
        XCTAssertNotNil(saliency["status"])
        XCTAssertNotNil(saliency["object_count"])
        XCTAssertNotNil(saliency["coverage"])
        XCTAssertNotNil(saliency["union_bounding_box"])
        XCTAssertNotNil(saliency["crop_threshold"])
        XCTAssertNotNil(saliency["crop_decision"])

        let capture = try XCTUnwrap(processing["capture_metadata"] as? [String: Any])
        XCTAssertNotNil(capture["original_width"])
        XCTAssertNotNil(capture["original_height"])
        XCTAssertNotNil(capture["original_bytes"])
        XCTAssertNotNil(capture["input_format"])
        XCTAssertNotNil(capture["camera_device_type"])
        XCTAssertNotNil(capture["camera_position"])
        XCTAssertNotNil(capture["zoom_factor"])
        XCTAssertNotNil(capture["flash_used"])
        XCTAssertNotNil(capture["torch_used"])
        XCTAssertNotNil(capture["hdr_enabled"])
        XCTAssertNotNil(capture["iso"])
        XCTAssertNotNil(capture["exposure_duration_ms"])
        XCTAssertNotNil(capture["focus_mode"])
        XCTAssertNotNil(capture["lens_position"])
        XCTAssertNotNil(capture["focal_length_mm"])
        XCTAssertNil(capture["cameraDeviceType"], "Should not have camelCase key")
        XCTAssertNil(capture["zoomFactor"], "Should not have camelCase key")

        let optimized = try XCTUnwrap(processing["optimized_upload"] as? [String: Any])
        XCTAssertNotNil(optimized["optimized_width"])
        XCTAssertNotNil(optimized["optimized_height"])
        XCTAssertNotNil(optimized["optimized_bytes"])
        XCTAssertNotNil(optimized["upload_format"])
        XCTAssertNotNil(optimized["resize_applied"])
        XCTAssertNotNil(optimized["compression_quality"])
        XCTAssertNotNil(optimized["compression_ratio"])
        XCTAssertNotNil(optimized["crop_fraction"])

        // Crop info level
        let crop = try XCTUnwrap(processing["crop_applied"] as? [String: Any])
        XCTAssertNotNil(crop["original_size"])
        XCTAssertNotNil(crop["crop_rect"])

        let override = try XCTUnwrap(processing["quality_override_context"] as? [String: Any])
        XCTAssertNotNil(override["bypassed"])
        XCTAssertNotNil(override["failed_gate"])
        XCTAssertNotNil(override["threshold_label"])

        let canny = try XCTUnwrap(processing["canny_metrics"] as? [String: Any])
        XCTAssertNotNil(canny["analysis_longest_side"])
        XCTAssertNotNil(canny["full_frame_edge_density"])
        XCTAssertNotNil(canny["saliency_edge_density"])
        XCTAssertNotNil(canny["upload_frame_edge_density"])
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
                saliencyContext: nil,
                captureMetadata: nil,
                optimizedUpload: nil,
                cropApplied: nil,
                qualityOverrideContext: nil,
                cannyMetrics: nil,
                userBehavior: nil
            )
        )
        let data = try encoder.encode(metadata)
        let decoded = try decoder.decode(DeviceMetadata.self, from: data)
        XCTAssertEqual(metadata, decoded)
        XCTAssertNil(decoded.deviceProcessing.cropApplied)
        XCTAssertNil(decoded.deviceProcessing.cannyMetrics)
        XCTAssertNil(decoded.deviceProcessing.userBehavior)
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

        let saliency = try XCTUnwrap(processing["saliency_context"] as? [String: Any])
        XCTAssertEqual(saliency["status"] as? String, "detected")
        XCTAssertEqual(saliency["object_count"] as? Int, 3)
        XCTAssertEqual(try XCTUnwrap(saliency["crop_threshold"] as? Double), 0.60, accuracy: 1e-10)
        XCTAssertEqual(saliency["crop_decision"] as? String, "applied")

        let unionBox = try XCTUnwrap(saliency["union_bounding_box"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(unionBox["x"] as? Double), 0.12, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(unionBox["y"] as? Double), 0.18, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(unionBox["width"] as? Double), 0.56, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(unionBox["height"] as? Double), 0.74, accuracy: 1e-10)

        let capture = try XCTUnwrap(processing["capture_metadata"] as? [String: Any])
        XCTAssertEqual(capture["original_width"] as? Int, 4032)
        XCTAssertEqual(capture["original_height"] as? Int, 3024)
        XCTAssertEqual(capture["original_bytes"] as? Int, 2_481_144)
        XCTAssertEqual(capture["input_format"] as? String, "jpeg")

        let optimized = try XCTUnwrap(processing["optimized_upload"] as? [String: Any])
        XCTAssertEqual(optimized["optimized_width"] as? Int, 2048)
        XCTAssertEqual(optimized["optimized_height"] as? Int, 1536)
        XCTAssertEqual(optimized["optimized_bytes"] as? Int, 512_240)
        XCTAssertEqual(optimized["upload_format"] as? String, "jpeg")
        XCTAssertEqual(optimized["resize_applied"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(optimized["compression_quality"] as? Double), 0.85, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(optimized["compression_ratio"] as? Double), 0.2065, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(optimized["crop_fraction"] as? Double), 0.6349, accuracy: 1e-10)

        // OCR is array of objects with text + confidence
        let ocr = try XCTUnwrap(processing["ocr"] as? [[String: Any]])
        XCTAssertEqual(ocr.count, 2)
        XCTAssertEqual(ocr[0]["text"] as? String, "M3x8 DIN 912")
        XCTAssertNotNil(ocr[0]["bounding_box"])

        // Barcodes have payload + symbology
        let barcodes = try XCTUnwrap(processing["barcodes"] as? [[String: Any]])
        XCTAssertEqual(barcodes[0]["payload"] as? String, "4005176834561")
        XCTAssertEqual(barcodes[0]["symbology"] as? String, "EAN-13")
        XCTAssertNotNil(barcodes[0]["bounding_box"])

        // Classifications have label + confidence
        let classifications = try XCTUnwrap(processing["classifications"] as? [[String: Any]])
        XCTAssertEqual(classifications[0]["label"] as? String, "screw")

        let override = try XCTUnwrap(processing["quality_override_context"] as? [String: Any])
        XCTAssertEqual(override["bypassed"] as? Bool, true)
        XCTAssertEqual(override["failed_gate"] as? String, "blur")
        XCTAssertEqual(override["threshold_label"] as? String, "minimum")

        let canny = try XCTUnwrap(processing["canny_metrics"] as? [String: Any])
        XCTAssertEqual(canny["analysis_longest_side"] as? Int, 512)
    }

    // MARK: - Capture Metadata Camera Fields

    func testCaptureMetadataEncodesCameraFields() throws {
        let metadata = makeSampleMetadata()
        let data = try encoder.encode(metadata)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let processing = try XCTUnwrap(json["device_processing"] as? [String: Any])
        let capture = try XCTUnwrap(processing["capture_metadata"] as? [String: Any])

        XCTAssertEqual(capture["camera_device_type"] as? String, "tripleCamera")
        XCTAssertEqual(capture["camera_position"] as? String, "back")
        XCTAssertEqual(try XCTUnwrap(capture["zoom_factor"] as? Double), 1.0, accuracy: 1e-10)
        XCTAssertEqual(capture["flash_used"] as? Bool, false)
        XCTAssertEqual(capture["torch_used"] as? Bool, false)
        XCTAssertEqual(capture["hdr_enabled"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(capture["iso"] as? Double), 320, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(capture["exposure_duration_ms"] as? Double), 16.6, accuracy: 1e-10)
        XCTAssertEqual(capture["focus_mode"] as? String, "continuousAutoFocus")
        XCTAssertEqual(try XCTUnwrap(capture["lens_position"] as? Double), 0.42, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(capture["focal_length_mm"] as? Double), 6.86, accuracy: 1e-10)
    }

    // MARK: - User Behavior

    func testUserBehaviorRoundTripsAndEncodesSnakeCase() throws {
        let original = UserBehavior(retakeCount: 3, qualityBypassCount: 1)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(UserBehavior.self, from: data)
        XCTAssertEqual(original, decoded)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["retake_count"] as? Int, 3)
        XCTAssertEqual(json["quality_bypass_count"] as? Int, 1)
        XCTAssertNil(json["retakeCount"], "Should not have camelCase key")
    }

    func testDeviceMetadataUserBehaviorEncodesAtSidecarRoot() throws {
        let metadata = makeSampleMetadata()
        let data = try encoder.encode(metadata)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let processing = try XCTUnwrap(json["device_processing"] as? [String: Any])
        let behavior = try XCTUnwrap(processing["user_behavior"] as? [String: Any])
        XCTAssertEqual(behavior["retake_count"] as? Int, 2)
        XCTAssertEqual(behavior["quality_bypass_count"] as? Int, 1)
    }

    /// Backward compatibility: a CaptureMetadata built without any camera
    /// fields must round-trip with all camera fields nil and omit them from
    /// the encoded JSON entirely (since `JSONEncoder` defaults to skipping
    /// nil optional values).
    func testCaptureMetadataWithoutCameraFieldsRoundTrips() throws {
        let original = CaptureMetadata(
            originalWidth: 1024,
            originalHeight: 768,
            originalBytes: 100_000,
            inputFormat: "jpeg"
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(CaptureMetadata.self, from: data)
        XCTAssertEqual(original, decoded)
        XCTAssertNil(decoded.cameraDeviceType)
        XCTAssertNil(decoded.iso)
        XCTAssertNil(decoded.focalLengthMm)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["camera_device_type"])
        XCTAssertNil(json["iso"])
        XCTAssertNil(json["focal_length_mm"])
    }
}
