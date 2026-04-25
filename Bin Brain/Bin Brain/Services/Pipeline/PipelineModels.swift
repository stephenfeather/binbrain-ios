// PipelineModels.swift
// Bin Brain
//
// Value types for the on-device image processing pipeline.
// All Codable types use snake_case keys to match the server's device_metadata JSON format.

import Foundation
import CoreGraphics

// MARK: - Pipeline Result

/// The output of a successful pipeline run, containing the optimized image and extraction metadata.
struct PipelineResult {
    /// The optimized JPEG image data ready for upload (Stage 2 output).
    let optimizedImageData: Data
    /// The metadata sidecar containing extraction results and quality scores (Stage 3 output).
    let deviceMetadata: DeviceMetadata
    /// The quality gate scores from Stage 1.
    let qualityScores: QualityScores
}

// MARK: - Pipeline Errors

/// Errors that can occur during pipeline processing.
enum PipelineError: Error {
    /// A quality gate check failed. The associated failure contains the gate and user-facing message.
    case qualityGateFailed(QualityGateFailure)
    /// The input data could not be decoded as a valid image.
    case invalidImageData
}

// MARK: - Quality Gates

/// Identifies which quality gate was checked.
enum QualityGate: String, CaseIterable, Codable {
    case resolution
    case blur
    case exposure
    case saliency
}

/// Numeric detail attached to a quality gate failure so the UI can show
/// the user exactly what was measured and what the threshold is.
struct QualityGateMetrics: Equatable {
    /// The value actually measured (variance, pixel fraction, side length, etc.).
    let measured: Double
    /// The threshold the measurement was compared against.
    let threshold: Double
    /// User-facing label for the measured value (e.g. "Blur variance", "Short side").
    let label: String
    /// Describes the direction of the threshold ("minimum" | "maximum" | "required").
    let thresholdLabel: String
}

/// A quality gate failure with a user-facing message and diagnostic metrics.
struct QualityGateFailure: Equatable {
    /// Which gate failed.
    let gate: QualityGate
    /// A user-facing message explaining the failure and suggesting a fix.
    let message: String
    /// Numeric detail for the rejection-screen metric readout.
    let metrics: QualityGateMetrics
}

/// Numeric scores from quality gate evaluation.
struct QualityScores: Codable, Equatable {
    /// Laplacian variance of the image (higher = sharper).
    let blurVariance: Double
    /// Mean exposure level (0.0 = black, 1.0 = white).
    let exposureMean: Double
    /// Fraction of the image covered by salient objects (0.0–1.0).
    let saliencyCoverage: Double
    /// Length of the shortest side in pixels.
    let shortestSide: Int

    enum CodingKeys: String, CodingKey {
        case blurVariance = "blur_variance"
        case exposureMean = "exposure_mean"
        case saliencyCoverage = "saliency_coverage"
        case shortestSide = "shortest_side"
    }
}

/// High-level outcome of the saliency analysis stage.
enum SaliencyDetectionStatus: String, Codable, Equatable {
    case detected = "detected"
    case noObjects = "no_objects"
    case analysisFailed = "analysis_failed"
    case notRun = "not_run"
}

/// Captures how the optimizer handled the saliency result when deciding whether to crop.
enum SaliencyCropDecision: String, Codable, Equatable {
    case applied = "applied"
    case skippedThresholdMet = "skipped_threshold_met"
    case skippedNoBoundingBox = "skipped_no_bounding_box"
    case skippedAnalysisFailed = "skipped_analysis_failed"
    case skippedCropFailed = "skipped_crop_failed"
}

/// A normalized 0...1 bounding box with origin at the bottom-left.
struct NormalizedBoundingBox: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// Structured saliency telemetry preserved alongside other device-processing metadata.
struct SaliencyContext: Codable, Equatable {
    /// Whether saliency produced objects, found none, or failed internally.
    let status: SaliencyDetectionStatus
    /// Number of salient objects returned by Vision.
    let objectCount: Int
    /// Fraction of the image covered by the union bounding box.
    let coverage: Double
    /// Union bounding box for all salient objects, when present.
    let unionBoundingBox: NormalizedBoundingBox?
    /// Coverage threshold used to decide whether to crop.
    let cropThreshold: Double
    /// The crop decision taken by the optimizer.
    let cropDecision: SaliencyCropDecision

    enum CodingKeys: String, CodingKey {
        case status
        case objectCount = "object_count"
        case coverage
        case unionBoundingBox = "union_bounding_box"
        case cropThreshold = "crop_threshold"
        case cropDecision = "crop_decision"
    }
}

// MARK: - Metadata Sidecar

/// Top-level metadata sidecar sent alongside the photo upload.
struct DeviceMetadata: Codable, Equatable {
    var deviceProcessing: DeviceProcessing

    enum CodingKeys: String, CodingKey {
        case deviceProcessing = "device_processing"
    }
}

/// Detailed on-device processing results.
struct DeviceProcessing: Codable, Equatable {
    /// Schema version for this metadata format.
    let version: String
    /// Total pipeline execution time in milliseconds.
    let pipelineMs: Int
    /// iOS version string (e.g., "18.4").
    let iosVersion: String
    /// Device model identifier (e.g., "iPhone16,1").
    let deviceModel: String
    /// Quality gate scores.
    let qualityScores: QualityScores
    /// OCR text recognized in the image.
    let ocr: [OCRResult]
    /// Barcodes detected in the image, optionally augmented with payloads
    /// the live `DataScannerViewController` decoded before the user pressed
    /// the shutter (so a UPC the user aimed at but did not retain in-frame
    /// still ships with `/ingest`).
    var barcodes: [BarcodeResult]
    /// Image classifications from Vision.
    let classifications: [ClassificationResult]
    /// Structured saliency analysis context and crop decision.
    let saliencyContext: SaliencyContext?
    /// Capture-time facts preserved from the image bytes handed into the pipeline.
    let captureMetadata: CaptureMetadata?
    /// Facts about the optimized upload image handed to the server.
    let optimizedUpload: OptimizedUploadStats?
    /// Crop information, if a smart crop was applied.
    let cropApplied: CropInfo?
    /// Original quality-gate failure carried through when the user bypasses it.
    let qualityOverrideContext: QualityOverrideContext?
    /// Optional edge-structure metrics derived from Core Image Canny analysis.
    let cannyMetrics: CannyMetrics?
    /// Cataloging-session supervision signals (retakes, quality bypasses).
    let userBehavior: UserBehavior?

    enum CodingKeys: String, CodingKey {
        case version
        case pipelineMs = "pipeline_ms"
        case iosVersion = "ios_version"
        case deviceModel = "device_model"
        case qualityScores = "quality_scores"
        case ocr
        case barcodes
        case classifications
        case saliencyContext = "saliency_context"
        case captureMetadata = "capture_metadata"
        case optimizedUpload = "optimized_upload"
        case cropApplied = "crop_applied"
        case qualityOverrideContext = "quality_override_context"
        case cannyMetrics = "canny_metrics"
        case userBehavior = "user_behavior"
    }
}

/// Cataloging-session supervision telemetry. Counts survive across quality
/// retries but reset when the cataloging sheet is dismissed.
struct UserBehavior: Codable, Equatable {
    /// Number of Retake Photo taps in this cataloging session before the
    /// current photo was captured.
    let retakeCount: Int
    /// Cumulative Upload Anyway (quality bypass) taps in this cataloging
    /// session, including the current photo if it was bypassed.
    let qualityBypassCount: Int

    enum CodingKeys: String, CodingKey {
        case retakeCount = "retake_count"
        case qualityBypassCount = "quality_bypass_count"
    }
}

/// Cataloging-session supervision snapshot supplied by the capture layer to
/// the pipeline. Mirrors `UserBehavior` but is a pure input value type.
struct UserBehaviorContext: Equatable, Sendable {
    let retakeCount: Int
    let qualityBypassCount: Int

    init(retakeCount: Int = 0, qualityBypassCount: Int = 0) {
        self.retakeCount = retakeCount
        self.qualityBypassCount = qualityBypassCount
    }
}

/// Lightweight metadata about the source image bytes entering the pipeline.
///
/// Camera-state fields (`cameraDeviceType` and below) are optional because they
/// depend on capture-stack access. `DataScannerViewController` doesn't expose
/// the underlying `AVCaptureDevice`, so live-device state (zoom, torch, HDR,
/// focus mode, lens position) cannot be sampled today and stays `nil`. EXIF-
/// derivable fields (iso, exposureDurationMs, focalLengthMm, flashUsed) are
/// populated from `AVCapturePhoto.metadata` when available.
struct CaptureMetadata: Codable, Equatable {
    /// Width of the decoded image before any pipeline downscaling.
    let originalWidth: Int
    /// Height of the decoded image before any pipeline downscaling.
    let originalHeight: Int
    /// Size in bytes of the image payload provided to the pipeline.
    let originalBytes: Int
    /// Best-effort format inferred from the input bytes.
    let inputFormat: String
    /// AVCaptureDevice.DeviceType identifier (e.g., "wideAngleCamera",
    /// "ultraWideCamera"); inferred from EXIF lens model when not available.
    let cameraDeviceType: String?
    /// "front" or "back".
    let cameraPosition: String?
    /// Effective zoom factor at capture time.
    let zoomFactor: Double?
    /// True if the flash actually fired.
    let flashUsed: Bool?
    /// True if the torch was on at capture time.
    let torchUsed: Bool?
    /// True if HDR/auto-bracketing was enabled.
    let hdrEnabled: Bool?
    /// ISO sensitivity reported by the sensor.
    let iso: Double?
    /// Exposure duration in milliseconds.
    let exposureDurationMs: Double?
    /// AVCaptureDevice.FocusMode raw value (e.g., "continuousAutoFocus").
    let focusMode: String?
    /// Lens position (0.0–1.0) when manual focus is in use.
    let lensPosition: Double?
    /// Effective focal length in millimeters.
    let focalLengthMm: Double?

    nonisolated init(
        originalWidth: Int,
        originalHeight: Int,
        originalBytes: Int,
        inputFormat: String,
        cameraDeviceType: String? = nil,
        cameraPosition: String? = nil,
        zoomFactor: Double? = nil,
        flashUsed: Bool? = nil,
        torchUsed: Bool? = nil,
        hdrEnabled: Bool? = nil,
        iso: Double? = nil,
        exposureDurationMs: Double? = nil,
        focusMode: String? = nil,
        lensPosition: Double? = nil,
        focalLengthMm: Double? = nil
    ) {
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
        self.originalBytes = originalBytes
        self.inputFormat = inputFormat
        self.cameraDeviceType = cameraDeviceType
        self.cameraPosition = cameraPosition
        self.zoomFactor = zoomFactor
        self.flashUsed = flashUsed
        self.torchUsed = torchUsed
        self.hdrEnabled = hdrEnabled
        self.iso = iso
        self.exposureDurationMs = exposureDurationMs
        self.focusMode = focusMode
        self.lensPosition = lensPosition
        self.focalLengthMm = focalLengthMm
    }

    enum CodingKeys: String, CodingKey {
        case originalWidth = "original_width"
        case originalHeight = "original_height"
        case originalBytes = "original_bytes"
        case inputFormat = "input_format"
        case cameraDeviceType = "camera_device_type"
        case cameraPosition = "camera_position"
        case zoomFactor = "zoom_factor"
        case flashUsed = "flash_used"
        case torchUsed = "torch_used"
        case hdrEnabled = "hdr_enabled"
        case iso
        case exposureDurationMs = "exposure_duration_ms"
        case focusMode = "focus_mode"
        case lensPosition = "lens_position"
        case focalLengthMm = "focal_length_mm"
    }
}

/// Camera-state snapshot captured at the moment of shutter, supplied by the
/// capture layer to the pipeline. Pure value type so it is safe to cross actor
/// boundaries. Any field may be `nil` when the capture stack cannot supply it.
struct CameraCaptureContext: Equatable, Sendable {
    let cameraDeviceType: String?
    let cameraPosition: String?
    let zoomFactor: Double?
    let flashUsed: Bool?
    let torchUsed: Bool?
    let hdrEnabled: Bool?
    let iso: Double?
    let exposureDurationMs: Double?
    let focusMode: String?
    let lensPosition: Double?
    let focalLengthMm: Double?

    init(
        cameraDeviceType: String? = nil,
        cameraPosition: String? = nil,
        zoomFactor: Double? = nil,
        flashUsed: Bool? = nil,
        torchUsed: Bool? = nil,
        hdrEnabled: Bool? = nil,
        iso: Double? = nil,
        exposureDurationMs: Double? = nil,
        focusMode: String? = nil,
        lensPosition: Double? = nil,
        focalLengthMm: Double? = nil
    ) {
        self.cameraDeviceType = cameraDeviceType
        self.cameraPosition = cameraPosition
        self.zoomFactor = zoomFactor
        self.flashUsed = flashUsed
        self.torchUsed = torchUsed
        self.hdrEnabled = hdrEnabled
        self.iso = iso
        self.exposureDurationMs = exposureDurationMs
        self.focusMode = focusMode
        self.lensPosition = lensPosition
        self.focalLengthMm = focalLengthMm
    }
}

/// Facts about the final optimized upload image and how it was produced.
struct OptimizedUploadStats: Codable, Equatable {
    /// Width of the upload image in pixels.
    let optimizedWidth: Int
    /// Height of the upload image in pixels.
    let optimizedHeight: Int
    /// Size in bytes of the upload payload.
    let optimizedBytes: Int
    /// Image format sent to the server.
    let uploadFormat: String
    /// Whether the image was resized during optimization.
    let resizeApplied: Bool
    /// JPEG compression quality used for the final encode.
    let compressionQuality: Double
    /// Ratio of optimized bytes to the original input bytes.
    let compressionRatio: Double
    /// Fraction of original image area retained after cropping.
    let cropFraction: Double

    enum CodingKeys: String, CodingKey {
        case optimizedWidth = "optimized_width"
        case optimizedHeight = "optimized_height"
        case optimizedBytes = "optimized_bytes"
        case uploadFormat = "upload_format"
        case resizeApplied = "resize_applied"
        case compressionQuality = "compression_quality"
        case compressionRatio = "compression_ratio"
        case cropFraction = "crop_fraction"
    }
}

/// Captures the original gate failure when the user chooses "Upload Anyway."
struct QualityOverrideContext: Codable, Equatable {
    /// True when the user bypassed the quality gate and continued.
    let bypassed: Bool
    /// The gate that originally failed.
    let failedGate: QualityGate
    /// User-facing explanation shown at the rejection screen.
    let message: String
    /// The measured value that tripped the gate.
    let measured: Double
    /// The threshold the measured value was compared against.
    let threshold: Double
    /// User-facing label for the metric.
    let label: String
    /// User-facing threshold direction label.
    let thresholdLabel: String

    nonisolated init(
        bypassed: Bool = true,
        failedGate: QualityGate,
        message: String,
        measured: Double,
        threshold: Double,
        label: String,
        thresholdLabel: String
    ) {
        self.bypassed = bypassed
        self.failedGate = failedGate
        self.message = message
        self.measured = measured
        self.threshold = threshold
        self.label = label
        self.thresholdLabel = thresholdLabel
    }

    nonisolated init(from failure: QualityGateFailure) {
        self.init(
            bypassed: true,
            failedGate: failure.gate,
            message: failure.message,
            measured: failure.metrics.measured,
            threshold: failure.metrics.threshold,
            label: failure.metrics.label,
            thresholdLabel: failure.metrics.thresholdLabel
        )
    }

    enum CodingKeys: String, CodingKey {
        case bypassed
        case failedGate = "failed_gate"
        case message
        case measured
        case threshold
        case label
        case thresholdLabel = "threshold_label"
    }
}

// MARK: - Extraction Results

/// A recognized text string from OCR.
struct OCRResult: Codable, Equatable {
    /// The recognized text.
    let text: String
    /// Recognition confidence (0.0–1.0).
    let confidence: Float
    /// Normalized bounding box for the recognized text when Vision provides one.
    let boundingBox: NormalizedBoundingBox?

    nonisolated init(text: String, confidence: Float, boundingBox: NormalizedBoundingBox? = nil) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }

    enum CodingKeys: String, CodingKey {
        case text
        case confidence
        case boundingBox = "bounding_box"
    }
}

/// A detected barcode payload.
struct BarcodeResult: Codable, Equatable {
    /// The decoded barcode value.
    let payload: String
    /// The barcode symbology (e.g., "EAN-13", "QR").
    let symbology: String
    /// Normalized bounding box for the detected barcode when Vision provides one.
    let boundingBox: NormalizedBoundingBox?

    nonisolated init(payload: String, symbology: String, boundingBox: NormalizedBoundingBox? = nil) {
        self.payload = payload
        self.symbology = symbology
        self.boundingBox = boundingBox
    }

    enum CodingKeys: String, CodingKey {
        case payload
        case symbology
        case boundingBox = "bounding_box"
    }
}

/// An image classification label.
struct ClassificationResult: Codable, Equatable {
    /// The classification label (e.g., "screw", "nail").
    let label: String
    /// Classification confidence (0.0–1.0).
    let confidence: Float
}

/// Records the crop applied during image optimization.
struct CropInfo: Codable, Equatable {
    /// Original image dimensions as [width, height].
    let originalSize: [Int]
    /// Crop rectangle as [x, y, width, height].
    let cropRect: [Int]

    enum CodingKeys: String, CodingKey {
        case originalSize = "original_size"
        case cropRect = "crop_rect"
    }
}

/// Edge-structure telemetry derived from Core Image's Canny edge detector.
struct CannyMetrics: Codable, Equatable {
    /// Longest side actually used for edge analysis after optional downscaling.
    let analysisLongestSide: Int
    /// Sigma of the Gaussian smoothing stage.
    let gaussianSigma: Double
    /// Threshold for weak edges.
    let thresholdLow: Double
    /// Threshold for strong edges.
    let thresholdHigh: Double
    /// Number of hysteresis passes used.
    let hysteresisPasses: Int
    /// Mean edge-map intensity across the whole analyzed frame (0.0–1.0).
    let fullFrameEdgeDensity: Double
    /// Mean edge-map intensity within the saliency ROI, when present.
    let saliencyEdgeDensity: Double?
    /// Mean edge-map intensity within the eventual uploaded crop, when present.
    let uploadFrameEdgeDensity: Double?

    enum CodingKeys: String, CodingKey {
        case analysisLongestSide = "analysis_longest_side"
        case gaussianSigma = "gaussian_sigma"
        case thresholdLow = "threshold_low"
        case thresholdHigh = "threshold_high"
        case hysteresisPasses = "hysteresis_passes"
        case fullFrameEdgeDensity = "full_frame_edge_density"
        case saliencyEdgeDensity = "saliency_edge_density"
        case uploadFrameEdgeDensity = "upload_frame_edge_density"
    }
}
