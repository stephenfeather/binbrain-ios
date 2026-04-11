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

/// A quality gate failure with a user-facing message.
struct QualityGateFailure: Equatable {
    /// Which gate failed.
    let gate: QualityGate
    /// A user-facing message explaining the failure and suggesting a fix.
    let message: String
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
    /// Crop information, if a smart crop was applied.
    let cropApplied: CropInfo?

    enum CodingKeys: String, CodingKey {
        case version
        case pipelineMs = "pipeline_ms"
        case iosVersion = "ios_version"
        case deviceModel = "device_model"
        case qualityScores = "quality_scores"
        case ocr
        case barcodes
        case classifications
        case cropApplied = "crop_applied"
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
