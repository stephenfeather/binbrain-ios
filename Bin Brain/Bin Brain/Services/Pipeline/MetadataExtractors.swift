// MetadataExtractors.swift
// Bin Brain
//
// Stage 3 of the on-device image pipeline: extracts OCR text, barcodes,
// and classifications from a captured photo using the Vision framework.
// All three requests run in a single VNImageRequestHandler.perform() call
// for efficient Neural Engine batching.

import CoreGraphics
import Foundation
import OSLog
import Vision

private nonisolated let metadataSignposter = OSSignposter(subsystem: "com.binbrain.app", category: "Vision")

/// Extracts metadata (OCR text, barcodes, image classifications) from a CGImage
/// using the Vision framework.
nonisolated struct MetadataExtractors: Sendable {

    /// Dedicated serial queue for Vision requests. `VNImageRequestHandler.perform()`
    /// is synchronous and must not block the cooperative thread pool.
    private let visionQueue = DispatchQueue(label: "com.binbrain.pipeline.vision")

    /// Runs OCR, barcode detection, and image classification on the provided image.
    ///
    /// All three Vision requests execute in a single `perform()` call for efficient
    /// Neural Engine batching. The work is dispatched to a dedicated serial queue
    /// to avoid blocking Swift concurrency's cooperative thread pool.
    ///
    /// - Parameter cgImage: The source image to analyze (typically full-resolution).
    /// - Returns: A tuple of OCR results, barcode results, and classification results.
    func extract(from cgImage: CGImage) async throws -> (
        ocr: [OCRResult],
        barcodes: [BarcodeResult],
        classifications: [ClassificationResult]
    ) {
        let extractID = metadataSignposter.makeSignpostID()
        let extractInterval = metadataSignposter.beginInterval("vision_extract", id: extractID)
        metadataSignposter.emitEvent(
            "vision_extract",
            id: extractID,
            "width=\(cgImage.width, privacy: .public) height=\(cgImage.height, privacy: .public) ocr=\(true, privacy: .public) barcode=\(true, privacy: .public) classify=\(true, privacy: .public)"
        )
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(
                ocr: [OCRResult],
                barcodes: [BarcodeResult],
                classifications: [ClassificationResult]
            ), Error>) in
            visionQueue.async {
                let ocrRequest = VNRecognizeTextRequest()
                ocrRequest.recognitionLevel = .accurate

                let barcodeRequest = VNDetectBarcodesRequest()
                barcodeRequest.symbologies = [
                    .upce, .ean8, .ean13,
                    .qr, .dataMatrix, .code128
                ]

                let classifyRequest = VNClassifyImageRequest()

                do {
                    let handler = VNImageRequestHandler(cgImage: cgImage)
                    try handler.perform([ocrRequest, barcodeRequest, classifyRequest])

                    let ocrResults = Self.mapOCRResults(ocrRequest.results ?? [])
                    let barcodeResults = Self.mapBarcodeResults(barcodeRequest.results ?? [])
                    let classificationResults = Self.mapClassificationResults(classifyRequest.results ?? [])

                    metadataSignposter.emitEvent(
                        "vision_extract_results",
                        id: extractID,
                        "ocrCount=\(ocrResults.count, privacy: .public) barcodeCount=\(barcodeResults.count, privacy: .public) classificationCount=\(classificationResults.count, privacy: .public)"
                    )
                    metadataSignposter.endInterval("vision_extract", extractInterval)

                    continuation.resume(returning: (ocrResults, barcodeResults, classificationResults))
                } catch {
                    metadataSignposter.emitEvent(
                        "vision_extract_failed",
                        id: extractID,
                        "width=\(cgImage.width, privacy: .public) height=\(cgImage.height, privacy: .public)"
                    )
                    metadataSignposter.endInterval("vision_extract", extractInterval)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Result Mapping

    /// Minimum confidence threshold for OCR results.
    static let ocrConfidenceThreshold: Float = 0.5

    /// Minimum confidence threshold for classification results.
    static let classificationConfidenceThreshold: Float = 0.1

    /// Maximum number of top classification results to keep.
    static let classificationMaxResults = 10

    /// Generic whole-image nouns emitted by Apple's stock `VNClassifyImageRequest`
    /// (an ~1,000-class ImageNet classifier) that are too broad for inventory
    /// cataloging. Dropped AFTER the confidence-threshold filter.
    ///
    /// Seed set — expand from telemetry. Applied ONLY to this stock Vision
    /// classifier path; do NOT re-use for any future custom CoreML model.
    static let genericLabelBlocklist: Set<String> = [
        "box", "package", "container", "carton", "plastic_bag", "paper_bag",
        "envelope", "jar", "bottle", "can", "tin", "wrapper", "packaging"
    ]

    /// Maps Vision OCR observations to `OCRResult` values, filtering low-confidence
    /// results and deduplicating near-identical strings.
    ///
    /// - Parameter observations: Raw observations from `VNRecognizeTextRequest`.
    /// - Returns: Filtered and deduplicated OCR results.
    static func mapOCRResults(_ observations: [VNRecognizedTextObservation]) -> [OCRResult] {
        let candidates: [OCRResult] = observations.compactMap { observation -> OCRResult? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            guard candidate.confidence >= ocrConfidenceThreshold else { return nil }
            return OCRResult(
                text: candidate.string,
                confidence: candidate.confidence,
                boundingBox: normalizedBoundingBox(from: observation.boundingBox)
            )
        }
        return deduplicateOCR(candidates)
    }

    /// Removes near-duplicate OCR results by comparing trimmed, lowercased text.
    /// When duplicates are found, the entry with the highest confidence is kept.
    ///
    /// - Parameter results: OCR results to deduplicate.
    /// - Returns: Deduplicated results preserving insertion order of first occurrence.
    static func deduplicateOCR(_ results: [OCRResult]) -> [OCRResult] {
        var seen: [String: Int] = [:]
        var deduplicated: [OCRResult] = []

        for result in results {
            let normalized = result.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            if let existingIndex = seen[normalized] {
                if result.confidence > deduplicated[existingIndex].confidence {
                    deduplicated[existingIndex] = result
                }
            } else {
                seen[normalized] = deduplicated.count
                deduplicated.append(result)
            }
        }
        return deduplicated
    }

    /// Maps Vision barcode observations to `BarcodeResult` values.
    ///
    /// - Parameter observations: Raw observations from `VNDetectBarcodesRequest`.
    /// - Returns: Barcode results with non-nil payloads.
    static func mapBarcodeResults(_ observations: [VNBarcodeObservation]) -> [BarcodeResult] {
        observations.compactMap { observation -> BarcodeResult? in
            guard let payload = observation.payloadStringValue else { return nil }
            return BarcodeResult(
                payload: payload,
                symbology: observation.symbology.rawValue,
                boundingBox: normalizedBoundingBox(from: observation.boundingBox)
            )
        }
    }

    /// Converts a Vision normalized rectangle into the JSON sidecar bounding-box shape.
    static func normalizedBoundingBox(from rect: CGRect) -> NormalizedBoundingBox? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite else { return nil }
        return NormalizedBoundingBox(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Maps Vision classification observations to `ClassificationResult` values,
    /// filtering below the confidence threshold and taking the top results.
    ///
    /// - Parameter observations: Raw observations from `VNClassifyImageRequest`.
    /// - Returns: Top classifications above the confidence threshold.
    static func mapClassificationResults(_ observations: [VNClassificationObservation]) -> [ClassificationResult] {
        filterClassifications(observations)
    }

    /// Filters classification observations by confidence threshold and blocklist,
    /// returning the top N results.
    ///
    /// Maps to the internal `identifiersAndConfidences:` overload which holds the
    /// testable pure logic. `VNClassificationObservation` cannot be directly
    /// constructed in unit tests, so the pure overload is the test entry point.
    ///
    /// - Parameter observations: Raw classification observations (typically sorted by confidence descending).
    /// - Returns: Up to `classificationMaxResults` entries above `classificationConfidenceThreshold`
    ///   and not in `genericLabelBlocklist`.
    static func filterClassifications(_ observations: [VNClassificationObservation]) -> [ClassificationResult] {
        filterClassifications(
            identifiersAndConfidences: observations.lazy.map { ($0.identifier, $0.confidence) }
        )
    }

    /// Pure filtering logic — confidence threshold then blocklist, top-N cap.
    ///
    /// Internal entry point for unit tests (Vision observations can't be constructed
    /// directly in test targets). Production code goes through the
    /// `VNClassificationObservation` overload above.
    ///
    /// - Parameter identifiersAndConfidences: A sequence of `(identifier, confidence)` pairs.
    /// - Returns: Up to `classificationMaxResults` entries above `classificationConfidenceThreshold`
    ///   whose lowercased identifier is NOT in `genericLabelBlocklist`.
    static func filterClassifications(
        identifiersAndConfidences: some Sequence<(identifier: String, confidence: Float)>
    ) -> [ClassificationResult] {
        identifiersAndConfidences
            .filter { $0.confidence >= classificationConfidenceThreshold }
            .filter { !genericLabelBlocklist.contains($0.identifier.lowercased()) }
            .prefix(classificationMaxResults)
            .map { ClassificationResult(label: $0.identifier, confidence: $0.confidence) }
    }
}
