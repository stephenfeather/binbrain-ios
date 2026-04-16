// MetadataExtractors.swift
// Bin Brain
//
// Stage 3 of the on-device image pipeline: extracts OCR text, barcodes,
// and classifications from a captured photo using the Vision framework.
// All three requests run in a single VNImageRequestHandler.perform() call
// for efficient Neural Engine batching.

import CoreGraphics
import Foundation
import Vision

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
        try await withCheckedThrowingContinuation { continuation in
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

                    continuation.resume(returning: (ocrResults, barcodeResults, classificationResults))
                } catch {
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

    /// Maps Vision OCR observations to `OCRResult` values, filtering low-confidence
    /// results and deduplicating near-identical strings.
    ///
    /// - Parameter observations: Raw observations from `VNRecognizeTextRequest`.
    /// - Returns: Filtered and deduplicated OCR results.
    static func mapOCRResults(_ observations: [VNRecognizedTextObservation]) -> [OCRResult] {
        let candidates: [OCRResult] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            guard candidate.confidence >= ocrConfidenceThreshold else { return nil }
            return OCRResult(text: candidate.string, confidence: candidate.confidence)
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
        observations.compactMap { observation in
            guard let payload = observation.payloadStringValue else { return nil }
            return BarcodeResult(
                payload: payload,
                symbology: observation.symbology.rawValue
            )
        }
    }

    /// Maps Vision classification observations to `ClassificationResult` values,
    /// filtering below the confidence threshold and taking the top results.
    ///
    /// - Parameter observations: Raw observations from `VNClassifyImageRequest`.
    /// - Returns: Top classifications above the confidence threshold.
    static func mapClassificationResults(_ observations: [VNClassificationObservation]) -> [ClassificationResult] {
        filterClassifications(observations)
    }

    /// Filters classification observations by confidence threshold and returns the top N.
    ///
    /// - Parameter observations: Raw classification observations (typically sorted by confidence descending).
    /// - Returns: Up to `classificationMaxResults` entries above `classificationConfidenceThreshold`.
    static func filterClassifications(_ observations: [VNClassificationObservation]) -> [ClassificationResult] {
        observations
            .filter { $0.confidence >= classificationConfidenceThreshold }
            .prefix(classificationMaxResults)
            .map { ClassificationResult(label: $0.identifier, confidence: $0.confidence) }
    }
}
