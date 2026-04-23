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
    let deviceProcessing: DeviceProcessing

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
    /// Barcodes detected in the image.
    let barcodes: [BarcodeResult]
    /// Image classifications from Vision.
    let classifications: [ClassificationResult]
    /// Structured saliency analysis context and crop decision.
    let saliencyContext: SaliencyContext?
    /// Capture-time facts preserved from the image bytes handed into the pipeline.
    let captureMetadata: CaptureMetadata?
    /// Crop information, if a smart crop was applied.
    let cropApplied: CropInfo?
    /// Original quality-gate failure carried through when the user bypasses it.
    let qualityOverrideContext: QualityOverrideContext?
    /// Optional edge-structure metrics derived from Core Image Canny analysis.
    let cannyMetrics: CannyMetrics?

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
        case cropApplied = "crop_applied"
        case qualityOverrideContext = "quality_override_context"
        case cannyMetrics = "canny_metrics"
    }
}

/// Lightweight metadata about the source image bytes entering the pipeline.
struct CaptureMetadata: Codable, Equatable {
    /// Width of the decoded image before any pipeline downscaling.
    let originalWidth: Int
    /// Height of the decoded image before any pipeline downscaling.
    let originalHeight: Int
    /// Size in bytes of the image payload provided to the pipeline.
    let originalBytes: Int
    /// Best-effort format inferred from the input bytes.
    let inputFormat: String

    enum CodingKeys: String, CodingKey {
        case originalWidth = "original_width"
        case originalHeight = "original_height"
        case originalBytes = "original_bytes"
        case inputFormat = "input_format"
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
}

/// A detected barcode payload.
struct BarcodeResult: Codable, Equatable {
    /// The decoded barcode value.
    let payload: String
    /// The barcode symbology (e.g., "EAN-13", "QR").
    let symbology: String
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
