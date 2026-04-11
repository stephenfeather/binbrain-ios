// ImagePipeline.swift
// Bin Brain
//
// Orchestrates the on-device image processing pipeline: quality gates → optimize → extract.
// Runs as an actor to isolate CIContext reuse and prevent data races.

import CoreGraphics
import CoreImage
import Foundation
import OSLog
import UIKit

private let logger = Logger(subsystem: "com.binbrain.app", category: "ImagePipeline")

// MARK: - Image Pipeline

/// Orchestrates the 4-stage on-device image processing pipeline.
///
/// The pipeline validates image quality (Stage 1), optimizes for upload (Stage 2),
/// and extracts metadata — OCR, barcodes, classifications (Stage 3). Stage 4 (upload)
/// is handled by the caller.
///
/// The actor owns a reusable `CIContext` (expensive to create) and coordinates
/// the sequential stages. All Vision work is dispatched to dedicated queues
/// by the stage implementations to avoid blocking the cooperative thread pool.
actor ImagePipeline {

    // MARK: - Dependencies

    /// Reusable Core Image context for Stage 2 rendering.
    private let context: CIContext

    /// Stage 1: quality gate checks.
    private let qualityGates: QualityGates

    /// Stage 2: smart crop, auto-enhance, resize, JPEG encode.
    private let optimizer: ImageOptimizer

    /// Stage 3: OCR, barcode, classification extraction.
    private let extractors: MetadataExtractors

    // MARK: - Constants

    /// Maximum input dimension before the pipeline downscales.
    /// Caps 48MP images to ~12MP to avoid ~200MB uncompressed RGBA memory spikes.
    private static let maxInputLongestSide: CGFloat = 4032

    // MARK: - Init

    /// Creates a new pipeline with a shared `CIContext`.
    init() {
        self.context = CIContext(options: [.useSoftwareRenderer: false])
        self.qualityGates = QualityGates()
        self.optimizer = ImageOptimizer()
        self.extractors = MetadataExtractors()
    }

    // MARK: - Public API

    /// Runs the full pipeline: quality gates → optimize → extract → package metadata.
    ///
    /// - Parameter imageData: Raw JPEG bytes from the camera capture.
    /// - Returns: A `PipelineResult` with optimized image data, metadata sidecar, and quality scores.
    /// - Throws: `PipelineError.qualityGateFailed` if a quality check fails,
    ///   or `PipelineError.invalidImageData` if the input cannot be decoded.
    func process(_ imageData: Data) async throws -> PipelineResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Decode and cap input resolution
        var cgImage = try decodeCGImage(from: imageData)
        cgImage = capResolution(cgImage)

        // Stage 1: Quality gates
        let validation = try await qualityGates.validate(cgImage)
        if let failure = validation.failure {
            throw PipelineError.qualityGateFailed(failure)
        }

        // Stage 2: Optimize for upload
        let optimized = optimizer.optimize(
            cgImage,
            saliencyBoundingBox: validation.saliencyBoundingBox,
            context: context
        )

        // Stage 3: Extract metadata from original (pre-optimize) image
        let extraction = try await extractors.extract(from: cgImage)

        // Release the full-resolution image before building the result
        let pipelineMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

        return buildResult(
            optimizedData: optimized.jpegData,
            cropInfo: optimized.cropInfo,
            scores: validation.scores,
            extraction: extraction,
            pipelineMs: pipelineMs
        )
    }

    /// Runs the pipeline without quality gates. Used when the user taps "Upload Anyway."
    ///
    /// - Parameter imageData: Raw JPEG bytes from the camera capture.
    /// - Returns: A `PipelineResult` with optimized image data and metadata.
    /// - Throws: `PipelineError.invalidImageData` if the input cannot be decoded.
    func processSkippingQualityGates(_ imageData: Data) async throws -> PipelineResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Decode and cap input resolution
        var cgImage = try decodeCGImage(from: imageData)
        cgImage = capResolution(cgImage)

        // Run saliency for smart crop (without the full gate validation)
        let saliencyBox: CGRect?
        do {
            saliencyBox = try await qualityGates.checkSaliencyOnly(cgImage)
        } catch {
            logger.error("Saliency check failed, proceeding without smart crop: \(error.localizedDescription)")
            saliencyBox = nil
        }

        // Stage 2: Optimize
        let optimized = optimizer.optimize(
            cgImage,
            saliencyBoundingBox: saliencyBox,
            context: context
        )

        // Stage 3: Extract metadata
        let extraction = try await extractors.extract(from: cgImage)

        let pipelineMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

        // Use zero scores since gates were skipped
        let scores = QualityScores(
            blurVariance: 0,
            exposureMean: 0,
            saliencyCoverage: 0,
            shortestSide: min(cgImage.width, cgImage.height)
        )

        return buildResult(
            optimizedData: optimized.jpegData,
            cropInfo: optimized.cropInfo,
            scores: scores,
            extraction: extraction,
            pipelineMs: pipelineMs
        )
    }

    // MARK: - Private Helpers

    /// Decodes raw image data into a CGImage.
    private func decodeCGImage(from data: Data) throws -> CGImage {
        guard let uiImage = UIImage(data: data), let cgImage = uiImage.cgImage else {
            throw PipelineError.invalidImageData
        }
        return cgImage
    }

    /// Downscales a CGImage if its longest side exceeds the input cap (4032px).
    /// This prevents ~200MB uncompressed RGBA memory spikes from 48MP cameras
    /// while preserving enough resolution for OCR and barcode detection.
    private func capResolution(_ cgImage: CGImage) -> CGImage {
        let longestSide = CGFloat(max(cgImage.width, cgImage.height))
        guard longestSide > Self.maxInputLongestSide else { return cgImage }

        let scale = Self.maxInputLongestSide / longestSide
        let newWidth = Int(CGFloat(cgImage.width) * scale)
        let newHeight = Int(CGFloat(cgImage.height) * scale)

        let ciImage = CIImage(cgImage: cgImage)
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        if let result = context.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: newWidth, height: newHeight)) {
            return result
        }
        return cgImage
    }

    /// Assembles the final `PipelineResult` from stage outputs.
    private func buildResult(
        optimizedData: Data,
        cropInfo: CropInfo?,
        scores: QualityScores,
        extraction: (ocr: [OCRResult], barcodes: [BarcodeResult], classifications: [ClassificationResult]),
        pipelineMs: Int
    ) -> PipelineResult {
        let deviceProcessing = DeviceProcessing(
            version: "1",
            pipelineMs: pipelineMs,
            iosVersion: Self.iosVersion,
            deviceModel: Self.deviceModel,
            qualityScores: scores,
            ocr: extraction.ocr,
            barcodes: extraction.barcodes,
            classifications: extraction.classifications,
            cropApplied: cropInfo
        )

        let metadata = DeviceMetadata(deviceProcessing: deviceProcessing)

        return PipelineResult(
            optimizedImageData: optimizedData,
            deviceMetadata: metadata,
            qualityScores: scores
        )
    }

    // MARK: - Static Device Info

    /// Cached iOS version string, resolved once via ProcessInfo (nonisolated).
    private static let iosVersion: String = ProcessInfo.processInfo.operatingSystemVersionString

    /// Cached hardware model identifier (e.g., "iPhone16,1").
    private static let deviceModel: String = {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "unknown"
            }
        }
    }()
}
