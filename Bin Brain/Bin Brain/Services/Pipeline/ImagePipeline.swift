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

private nonisolated let logger = Logger(subsystem: "com.binbrain.app", category: "ImagePipeline")
private nonisolated let pipelineSignposter = OSSignposter(subsystem: "com.binbrain.app", category: "ImagePipeline")

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

    /// Additive image-structure telemetry derived from edge analysis.
    private let edgeMetricsExtractor: EdgeMetricsExtractor

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
        self.edgeMetricsExtractor = EdgeMetricsExtractor()
    }

    // MARK: - Public API

    /// Runs the full pipeline: quality gates → optimize → extract → package metadata.
    ///
    /// - Parameter imageData: Raw JPEG bytes from the camera capture.
    /// - Returns: A `PipelineResult` with optimized image data, metadata sidecar, and quality scores.
    /// - Throws: `PipelineError.qualityGateFailed` if a quality check fails,
    ///   or `PipelineError.invalidImageData` if the input cannot be decoded.
    func process(_ imageData: Data) async throws -> PipelineResult {
        let processID = pipelineSignposter.makeSignpostID()
        let processInterval = pipelineSignposter.beginInterval("image_pipeline_process", id: processID)
        defer { pipelineSignposter.endInterval("image_pipeline_process", processInterval) }
        pipelineSignposter.emitEvent(
            "image_pipeline_process",
            id: processID,
            "bytesIn=\(imageData.count, privacy: .public)"
        )
        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            // Decode and cap input resolution
            let decodedImage = try decodeCGImage(from: imageData)
            let captureMetadata = buildCaptureMetadata(from: decodedImage, imageData: imageData)
            let cgImage = capResolution(decodedImage)

            // Stage 1: Quality gates
            let validation = try await qualityGates.validate(cgImage)
            if let failure = validation.failure {
                throw PipelineError.qualityGateFailed(failure)
            }
            let saliencyAnalysis = validation.saliencyAnalysis ?? SaliencyAnalysis(
                status: .notRun,
                objectCount: 0,
                coverage: 0,
                boundingBox: nil,
                failure: nil
            )

            // Stage 2: Optimize for upload
            let optimized = optimizer.optimize(
                cgImage,
                saliencyBoundingBox: saliencyAnalysis.boundingBox,
                context: context
            )
            let saliencyContext = buildSaliencyContext(
                from: saliencyAnalysis,
                cropDecision: optimized.cropDecision
            )

            let cannyMetrics = edgeMetricsExtractor.extract(
                from: cgImage,
                saliencyBoundingBox: saliencyAnalysis.boundingBox,
                cropInfo: optimized.cropInfo,
                context: context
            )

            // Stage 3: Extract metadata from original (pre-optimize) image
            let extraction = try await extractors.extract(from: cgImage)

            // Release the full-resolution image before building the result
            let pipelineMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

            let result = buildResult(
                optimizedData: optimized.jpegData,
                cropInfo: optimized.cropInfo,
                scores: validation.scores,
                extraction: extraction,
                saliencyContext: saliencyContext,
                captureMetadata: captureMetadata,
                optimizedUpload: buildOptimizedUploadStats(
                    from: optimized.uploadInfo,
                    originalBytes: imageData.count
                ),
                qualityOverrideContext: nil,
                cannyMetrics: cannyMetrics,
                pipelineMs: pipelineMs
            )
            pipelineSignposter.emitEvent(
                "image_pipeline_process_done",
                id: processID,
                "bytesOut=\(result.optimizedImageData.count, privacy: .public) pipelineMs=\(pipelineMs, privacy: .public)"
            )
            return result
        } catch {
            pipelineSignposter.emitEvent(
                "image_pipeline_process_failed",
                id: processID,
                "bytesIn=\(imageData.count, privacy: .public)"
            )
            throw error
        }
    }

    /// Runs the pipeline without quality gates. Used when the user taps "Upload Anyway."
    ///
    /// - Parameter imageData: Raw JPEG bytes from the camera capture.
    /// - Returns: A `PipelineResult` with optimized image data and metadata.
    /// - Throws: `PipelineError.invalidImageData` if the input cannot be decoded.
    func processSkippingQualityGates(_ imageData: Data, originalFailure: QualityGateFailure? = nil) async throws -> PipelineResult {
        let processID = pipelineSignposter.makeSignpostID()
        let processInterval = pipelineSignposter.beginInterval("image_pipeline_process_skip_quality", id: processID)
        defer { pipelineSignposter.endInterval("image_pipeline_process_skip_quality", processInterval) }
        pipelineSignposter.emitEvent(
            "image_pipeline_process_skip_quality",
            id: processID,
            "bytesIn=\(imageData.count, privacy: .public)"
        )
        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            // Decode and cap input resolution
            let decodedImage = try decodeCGImage(from: imageData)
            let captureMetadata = buildCaptureMetadata(from: decodedImage, imageData: imageData)
            let cgImage = capResolution(decodedImage)

            // Run saliency for smart crop (without the full gate validation)
            let saliencyAnalysis: SaliencyAnalysis
            do {
                saliencyAnalysis = try await qualityGates.checkSaliency(cgImage)
            } catch {
                logger.error("Saliency check failed, proceeding without smart crop: \(error.localizedDescription, privacy: .private)")
                saliencyAnalysis = SaliencyAnalysis(
                    status: .analysisFailed,
                    objectCount: 0,
                    coverage: 0,
                    boundingBox: nil,
                    failure: nil
                )
            }

            // Stage 2: Optimize
            let optimized = optimizer.optimize(
                cgImage,
                saliencyBoundingBox: saliencyAnalysis.boundingBox,
                context: context
            )
            let saliencyContext = buildSaliencyContext(
                from: saliencyAnalysis,
                cropDecision: saliencyAnalysis.status == .analysisFailed ? .skippedAnalysisFailed : optimized.cropDecision
            )

            let cannyMetrics = edgeMetricsExtractor.extract(
                from: cgImage,
                saliencyBoundingBox: saliencyAnalysis.boundingBox,
                cropInfo: optimized.cropInfo,
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
            let overrideContext: QualityOverrideContext?
            if let originalFailure {
                overrideContext = QualityOverrideContext(from: originalFailure)
            } else {
                overrideContext = nil
            }

            let result = buildResult(
                optimizedData: optimized.jpegData,
                cropInfo: optimized.cropInfo,
                scores: scores,
                extraction: extraction,
                saliencyContext: saliencyContext,
                captureMetadata: captureMetadata,
                optimizedUpload: buildOptimizedUploadStats(
                    from: optimized.uploadInfo,
                    originalBytes: imageData.count
                ),
                qualityOverrideContext: overrideContext,
                cannyMetrics: cannyMetrics,
                pipelineMs: pipelineMs
            )
            pipelineSignposter.emitEvent(
                "image_pipeline_process_skip_quality_done",
                id: processID,
                "bytesOut=\(result.optimizedImageData.count, privacy: .public) pipelineMs=\(pipelineMs, privacy: .public)"
            )
            return result
        } catch {
            pipelineSignposter.emitEvent(
                "image_pipeline_process_skip_quality_failed",
                id: processID,
                "bytesIn=\(imageData.count, privacy: .public)"
            )
            throw error
        }
    }

    // MARK: - Private Helpers

    /// Decodes raw image data into a `CGImage` with EXIF orientation baked into the pixels.
    ///
    /// `UIImage(data:)` parses the EXIF orientation tag into `imageOrientation`, but
    /// `.cgImage` returns the raw sensor bitmap — dropping the tag and producing sideways
    /// pixels for portrait iPhone captures (Finding #29). `UIGraphicsImageRenderer` re-draws
    /// the `UIImage` applying the orientation transform, so the returned `CGImage` has visual
    /// dimensions and pixel layout regardless of the original sensor orientation.
    ///
    /// The `.up` fast-path avoids the re-render overhead for images already in correct
    /// orientation (e.g., the "Upload Anyway" path on a device that captured in landscape).
    ///
    /// `internal` (not `private`) so `ImagePipelineTests` can assert orientation-baking directly.
    func decodeCGImage(from data: Data) throws -> CGImage {
        let transformID = pipelineSignposter.makeSignpostID()
        let transformInterval = pipelineSignposter.beginInterval("media_transform", id: transformID)
        let inputFormat = Self.inferInputFormat(from: data)
        pipelineSignposter.emitEvent(
            "media_transform",
            id: transformID,
            "stage=\("decode_normalize", privacy: .public) bytesIn=\(data.count, privacy: .public) formatIn=\(inputFormat, privacy: .public) formatOut=\("cgimage", privacy: .public)"
        )
        guard let uiImage = UIImage(data: data) else {
            pipelineSignposter.emitEvent(
                "media_transform_failed",
                id: transformID,
                "stage=\("decode_normalize", privacy: .public)"
            )
            pipelineSignposter.endInterval("media_transform", transformInterval)
            throw PipelineError.invalidImageData
        }
        let normalized: UIImage
        if uiImage.imageOrientation == .up {
            normalized = uiImage
        } else {
            // Pin the renderer scale to the image's own scale factor so the
            // output CGImage has the same pixel dimensions as the visual image.
            // UIGraphicsImageRenderer defaults to the device screen scale (2x/3x),
            // which would inflate a scale=1.0 JPEG-decoded image 2–3× in each dimension.
            let format = UIGraphicsImageRendererFormat()
            format.scale = uiImage.scale
            normalized = UIGraphicsImageRenderer(size: uiImage.size, format: format).image { _ in
                uiImage.draw(in: CGRect(origin: .zero, size: uiImage.size))
            }
        }
        guard let cgImage = normalized.cgImage else {
            pipelineSignposter.emitEvent(
                "media_transform_failed",
                id: transformID,
                "stage=\("cgimage_extract", privacy: .public)"
            )
            pipelineSignposter.endInterval("media_transform", transformInterval)
            throw PipelineError.invalidImageData
        }
        pipelineSignposter.emitEvent(
            "media_transform_done",
            id: transformID,
            "stage=\("decode_normalize", privacy: .public) width=\(cgImage.width, privacy: .public) height=\(cgImage.height, privacy: .public) bytesOutApprox=\((cgImage.bytesPerRow * cgImage.height), privacy: .public)"
        )
        pipelineSignposter.endInterval("media_transform", transformInterval)
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
        saliencyContext: SaliencyContext?,
        captureMetadata: CaptureMetadata?,
        optimizedUpload: OptimizedUploadStats?,
        qualityOverrideContext: QualityOverrideContext?,
        cannyMetrics: CannyMetrics?,
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
            saliencyContext: saliencyContext,
            captureMetadata: captureMetadata,
            optimizedUpload: optimizedUpload,
            cropApplied: cropInfo,
            qualityOverrideContext: qualityOverrideContext,
            cannyMetrics: cannyMetrics
        )

        let metadata = DeviceMetadata(deviceProcessing: deviceProcessing)

        return PipelineResult(
            optimizedImageData: optimizedData,
            deviceMetadata: metadata,
            qualityScores: scores
        )
    }

    private func buildCaptureMetadata(from cgImage: CGImage, imageData: Data) -> CaptureMetadata {
        CaptureMetadata(
            originalWidth: cgImage.width,
            originalHeight: cgImage.height,
            originalBytes: imageData.count,
            inputFormat: Self.inferInputFormat(from: imageData)
        )
    }

    private func buildOptimizedUploadStats(
        from uploadInfo: ImageOptimizer.UploadInfo,
        originalBytes: Int
    ) -> OptimizedUploadStats {
        let compressionRatio: Double
        if originalBytes > 0 {
            compressionRatio = Double(uploadInfo.optimizedBytes) / Double(originalBytes)
        } else {
            compressionRatio = 0
        }

        return OptimizedUploadStats(
            optimizedWidth: uploadInfo.optimizedWidth,
            optimizedHeight: uploadInfo.optimizedHeight,
            optimizedBytes: uploadInfo.optimizedBytes,
            uploadFormat: uploadInfo.uploadFormat,
            resizeApplied: uploadInfo.resizeApplied,
            compressionQuality: uploadInfo.compressionQuality,
            compressionRatio: compressionRatio,
            cropFraction: uploadInfo.cropFraction
        )
    }

    private func buildSaliencyContext(
        from analysis: SaliencyAnalysis,
        cropDecision: SaliencyCropDecision
    ) -> SaliencyContext {
        let normalizedBox = analysis.boundingBox.map {
            NormalizedBoundingBox(
                x: Double($0.origin.x),
                y: Double($0.origin.y),
                width: Double($0.width),
                height: Double($0.height)
            )
        }

        return SaliencyContext(
            status: analysis.status,
            objectCount: analysis.objectCount,
            coverage: analysis.coverage,
            unionBoundingBox: normalizedBox,
            cropThreshold: ImageOptimizer.cropThresholdValue,
            cropDecision: cropDecision
        )
    }

    private static func inferInputFormat(from data: Data) -> String {
        guard data.count >= 12 else { return "unknown" }

        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "jpeg"
        }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "png"
        }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return "gif"
        }
        if data.starts(with: [0x49, 0x49, 0x2A, 0x00]) || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return "tiff"
        }
        if data.prefix(4) == Data([0x52, 0x49, 0x46, 0x46]) && data[8...11] == Data([0x57, 0x45, 0x42, 0x50]) {
            return "webp"
        }
        if data[4...7] == Data([0x66, 0x74, 0x79, 0x70]) {
            let brandData = data[8...11]
            if let brand = String(data: brandData, encoding: .ascii) {
                switch brand {
                case "heic", "heix", "hevc", "hevx":
                    return "heic"
                case "mif1", "msf1":
                    return "heif"
                case "avif":
                    return "avif"
                default:
                    break
                }
            }
        }
        return "unknown"
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
