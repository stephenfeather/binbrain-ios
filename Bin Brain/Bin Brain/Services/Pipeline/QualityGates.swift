// QualityGates.swift
// Bin Brain
//
// Stage 1 of the on-device image pipeline: validates image quality before upload.
// Gates run sequentially (cheapest first): resolution → blur → exposure → saliency.
// All computed scores are returned even on failure (needed for the metadata sidecar).

import Foundation
import CoreGraphics
import CoreImage
import Accelerate
import Vision
import OSLog

/// Logger for blur-gate variance telemetry (Finding #4 calibration pass).
/// Subsystem/category match the app convention so Console filters are stable.
/// `Logger` is `Sendable`, so a plain `let` is safe from nonisolated contexts.
nonisolated private let blurGateLogger = Logger(subsystem: "com.binbrain.app", category: "quality")

// MARK: - Thresholds

/// Blur detection threshold for a 1024px shortest side.
/// Variance below this value indicates a blurry image.
/// Scale proportionally for other resolutions.
nonisolated let kBlurVarianceThresholdAt1024: Double = 2.0

/// Minimum shortest side in pixels for the resolution gate.
nonisolated let kMinimumShortestSide: Int = 1024

/// Fraction of pixels in extreme bins that triggers exposure failure.
nonisolated let kExposureExtremeFraction: Double = 0.70

/// Number of bottom/top histogram bins considered "extreme."
nonisolated let kExposureExtremeBinCount: Int = 26 // ~10% of 256

// MARK: - Quality Gates

/// Validates image quality through a series of sequential gate checks.
///
/// Each gate computes a numeric score and optionally fails with a user-facing message.
/// All scores are returned regardless of failure status so the metadata sidecar
/// can record them.
nonisolated struct QualityGates: Sendable {

    /// Serial queue for dispatching synchronous Vision requests off the cooperative thread pool.
    private let visionQueue = DispatchQueue(label: "com.binbrain.pipeline.quality")

    /// Validates the given image against all quality gates in order.
    ///
    /// - Parameter cgImage: The image to validate.
    /// - Returns: A tuple of all computed scores and an optional failure.
    func validate(_ cgImage: CGImage) async throws -> (scores: QualityScores, failure: QualityGateFailure?, saliencyBoundingBox: CGRect?) {
        var blurVariance: Double = 0
        var exposureMean: Double = 0
        var saliencyCoverage: Double = 0
        let shortestSide = min(cgImage.width, cgImage.height)

        // Gate 1: Resolution
        if let failure = checkResolution(cgImage) {
            let scores = QualityScores(
                blurVariance: blurVariance,
                exposureMean: exposureMean,
                saliencyCoverage: saliencyCoverage,
                shortestSide: shortestSide
            )
            return (scores, failure, nil)
        }

        // Gate 2: Blur
        let blurResult = checkBlur(cgImage)
        blurVariance = blurResult.variance
        if let failure = blurResult.failure {
            let scores = QualityScores(
                blurVariance: blurVariance,
                exposureMean: exposureMean,
                saliencyCoverage: saliencyCoverage,
                shortestSide: shortestSide
            )
            return (scores, failure, nil)
        }

        // Gate 3: Exposure
        let exposureResult = checkExposure(cgImage)
        exposureMean = exposureResult.mean
        if let failure = exposureResult.failure {
            let scores = QualityScores(
                blurVariance: blurVariance,
                exposureMean: exposureMean,
                saliencyCoverage: saliencyCoverage,
                shortestSide: shortestSide
            )
            return (scores, failure, nil)
        }

        // Gate 4: Saliency
        let saliencyResult = try await checkSaliency(cgImage)
        saliencyCoverage = saliencyResult.coverage
        if let failure = saliencyResult.failure {
            let scores = QualityScores(
                blurVariance: blurVariance,
                exposureMean: exposureMean,
                saliencyCoverage: saliencyCoverage,
                shortestSide: shortestSide
            )
            return (scores, failure, saliencyResult.boundingBox)
        }

        let scores = QualityScores(
            blurVariance: blurVariance,
            exposureMean: exposureMean,
            saliencyCoverage: saliencyCoverage,
            shortestSide: shortestSide
        )
        return (scores, nil, saliencyResult.boundingBox)
    }

    // MARK: - Gate 1: Resolution

    /// Checks that the shortest side of the image meets the minimum pixel requirement.
    ///
    /// - Parameter cgImage: The image to check.
    /// - Returns: A failure if the shortest side is below the threshold, otherwise nil.
    func checkResolution(_ cgImage: CGImage) -> QualityGateFailure? {
        let shortest = min(cgImage.width, cgImage.height)
        guard shortest >= kMinimumShortestSide else {
            return QualityGateFailure(
                gate: .resolution,
                message: "Move closer — photo is too small for detail"
            )
        }
        return nil
    }

    // MARK: - Gate 2: Blur

    /// Computes the Laplacian variance of the image as a sharpness metric.
    ///
    /// Uses Accelerate's `vImageConvolve` with a 3×3 Laplacian kernel, then computes
    /// the variance of the result. The threshold scales proportionally with resolution.
    ///
    /// - Parameter cgImage: The image to check.
    /// - Returns: The computed variance and an optional failure.
    func checkBlur(_ cgImage: CGImage) -> (variance: Double, failure: QualityGateFailure?) {
        let width = cgImage.width
        let height = cgImage.height

        // Convert to single-channel grayscale float buffer
        guard let grayscale = grayscaleBuffer(from: cgImage) else {
            // If we can't convert, be lenient and pass
            return (0, nil)
        }

        let pixelCount = width * height

        // Apply 3x3 Laplacian kernel
        var sourceBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: grayscale),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: width * MemoryLayout<Float>.size
        )

        let destData = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        defer { destData.deallocate() }

        var destBuffer = vImage_Buffer(
            data: destData,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: width * MemoryLayout<Float>.size
        )

        let kernel: [Float] = [0, 1, 0, 1, -4, 1, 0, 1, 0]
        let error = vImageConvolve_PlanarF(
            &sourceBuffer,
            &destBuffer,
            nil,
            0, 0,
            kernel,
            3, 3,
            0,
            vImage_Flags(kvImageEdgeExtend)
        )

        grayscale.deallocate()

        guard error == kvImageNoError else {
            return (0, nil)
        }

        // Compute variance using vDSP
        let laplacianValues = UnsafeBufferPointer(start: destData, count: pixelCount)
        let array = Array(laplacianValues)
        var mean: Float = 0
        var meanSquare: Float = 0
        vDSP_meanv(array, 1, &mean, vDSP_Length(pixelCount))
        vDSP_measqv(array, 1, &meanSquare, vDSP_Length(pixelCount))
        let variance = Double(meanSquare - mean * mean)

        // Scale threshold proportionally to resolution
        let shortest = Double(min(width, height))
        let scaledThreshold = Self.scaledBlurThreshold(
            shortestSide: shortest,
            baseThresholdAt1024: kBlurVarianceThresholdAt1024
        )

        // Swift2_004 Step 1 — re-enable the blur gate so the quality-gate
        // visibility UI (Steps 2-4) has a real failure path to exercise.
        // Stephen's n=7 calibration showed overlapping distributions;
        // that's expected — the "Upload Anyway" path is the release valve
        // and the signal for future tuning. Do NOT adjust kBlurVarianceThresholdAt1024
        // in this task.
        let passed = Self.blurGatePasses(variance: variance, scaledThreshold: scaledThreshold)

        blurGateLogger.debug(
            """
            blur_gate variance=\(variance, privacy: .public) \
            threshold=\(scaledThreshold, privacy: .public) \
            base_threshold=\(kBlurVarianceThresholdAt1024, privacy: .public) \
            shortest_side=\(Int(shortest), privacy: .public) \
            passed=\(passed, privacy: .public) \
            gate_enabled=true
            """
        )

        if !passed {
            return (variance, QualityGateFailure(
                gate: .blur,
                message: "Image is too blurry — hold still and retake"
            ))
        }
        return (variance, nil)
    }

    /// Pure function: scale the 1024px-shortest-side blur threshold for a given resolution.
    ///
    /// Exposed `static` so tests can exercise the threshold math without constructing
    /// a CGImage. The live path in `checkBlur(_:)` is the sole production caller.
    static func scaledBlurThreshold(shortestSide: Double, baseThresholdAt1024: Double) -> Double {
        baseThresholdAt1024 * (shortestSide / 1024.0)
    }

    /// Pure function: given a Laplacian variance and the scaled threshold, return
    /// whether the blur gate passes. Used by tests to validate the decision logic
    /// independently of the vImage-based variance computation.
    static func blurGatePasses(variance: Double, scaledThreshold: Double) -> Bool {
        variance >= scaledThreshold
    }

    // MARK: - Gate 3: Exposure

    /// Analyzes the image histogram to detect under- or over-exposure.
    ///
    /// Uses Core Image's `CIAreaHistogram` with 256 bins. Fails if more than 70% of pixels
    /// fall in the bottom 10% (underexposed) or top 10% (overexposed) of the luminance range.
    ///
    /// - Parameter cgImage: The image to check.
    /// - Returns: The mean exposure level and an optional failure.
    func checkExposure(_ cgImage: CGImage) -> (mean: Double, failure: QualityGateFailure?) {
        let ciImage = CIImage(cgImage: cgImage)
        let context = CIContext(options: [.useSoftwareRenderer: true])

        let histogramFilter = CIFilter(name: "CIAreaHistogram")!
        histogramFilter.setValue(ciImage, forKey: kCIInputImageKey)
        histogramFilter.setValue(CIVector(cgRect: ciImage.extent), forKey: "inputExtent")
        histogramFilter.setValue(256, forKey: "inputCount")
        histogramFilter.setValue(1.0, forKey: "inputScale")

        guard let outputImage = histogramFilter.outputImage else {
            return (0.5, nil)
        }

        // Render the 256x1 histogram image to a pixel buffer
        var histogramPixels = [Float](repeating: 0, count: 256 * 4) // RGBA
        context.render(
            outputImage,
            toBitmap: &histogramPixels,
            rowBytes: 256 * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: 256, height: 1),
            format: .RGBAf,
            colorSpace: nil
        )

        // Extract luminance channel (use red channel as proxy from grayscale histogram,
        // or average RGB). The histogram counts are in the R channel for grayscale input.
        // For color images, average the RGB channels per bin.
        var binCounts = [Float](repeating: 0, count: 256)
        for i in 0..<256 {
            let r = histogramPixels[i * 4]
            let g = histogramPixels[i * 4 + 1]
            let b = histogramPixels[i * 4 + 2]
            binCounts[i] = (r + g + b) / 3.0
        }

        var totalPixels: Float = 0
        vDSP_sve(binCounts, 1, &totalPixels, vDSP_Length(256))

        guard totalPixels > 0 else {
            return (0.5, nil)
        }

        // Compute mean exposure (weighted average of bin positions)
        var weightedSum: Float = 0
        for i in 0..<256 {
            weightedSum += Float(i) * binCounts[i]
        }
        let mean = Double(weightedSum / (totalPixels * 255.0))

        // Check bottom 10% (bins 0..<26)
        var bottomSum: Float = 0
        vDSP_sve(binCounts, 1, &bottomSum, vDSP_Length(kExposureExtremeBinCount))
        let bottomFraction = Double(bottomSum / totalPixels)

        if bottomFraction > kExposureExtremeFraction {
            return (mean, QualityGateFailure(
                gate: .exposure,
                message: "Too dark — try better lighting"
            ))
        }

        // Check top 10% (bins 230..<256)
        let topStartIndex = 256 - kExposureExtremeBinCount
        var topSum: Float = 0
        binCounts.withUnsafeBufferPointer { ptr in
            vDSP_sve(ptr.baseAddress! + topStartIndex, 1, &topSum, vDSP_Length(kExposureExtremeBinCount))
        }
        let topFraction = Double(topSum / totalPixels)

        if topFraction > kExposureExtremeFraction {
            return (mean, QualityGateFailure(
                gate: .exposure,
                message: "Too bright — reduce glare"
            ))
        }

        return (mean, nil)
    }

    // MARK: - Gate 4: Saliency

    /// Detects salient objects using Vision's objectness-based saliency.
    ///
    /// Dispatches the synchronous `VNImageRequestHandler.perform()` to a dedicated
    /// serial queue to avoid blocking the cooperative thread pool.
    ///
    /// - Parameter cgImage: The image to check.
    /// - Returns: The saliency coverage, the bounding box of the most salient region, and an optional failure.
    func checkSaliency(_ cgImage: CGImage) async throws -> (coverage: Double, boundingBox: CGRect?, failure: QualityGateFailure?) {
        try await withCheckedThrowingContinuation { continuation in
            visionQueue.async {
                let request = VNGenerateObjectnessBasedSaliencyImageRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observation = request.results?.first else {
                    continuation.resume(returning: (
                        0,
                        nil,
                        QualityGateFailure(
                            gate: .saliency,
                            message: "No objects detected — make sure the bin contents are visible"
                        )
                    ))
                    return
                }

                let salientObjects = observation.salientObjects ?? []
                if salientObjects.isEmpty {
                    continuation.resume(returning: (
                        0,
                        nil,
                        QualityGateFailure(
                            gate: .saliency,
                            message: "No objects detected — make sure the bin contents are visible"
                        )
                    ))
                    return
                }

                // Compute total coverage as union of all salient bounding boxes (simplified)
                // Use the largest bounding box as the primary region
                let largestObject = salientObjects.max(by: {
                    $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
                })!

                let coverage = Double(largestObject.boundingBox.width * largestObject.boundingBox.height)

                continuation.resume(returning: (coverage, largestObject.boundingBox, nil))
            }
        }
    }

    // MARK: - Convenience

    /// Runs only the saliency check and returns the bounding box, ignoring the gate result.
    ///
    /// Used by the pipeline's "skip quality gates" path to obtain the saliency box
    /// for smart crop without running all four gates.
    func checkSaliencyOnly(_ cgImage: CGImage) async throws -> CGRect? {
        let result = try await checkSaliency(cgImage)
        return result.boundingBox
    }

    // MARK: - Helpers

    /// Converts a CGImage to a planar float grayscale buffer.
    ///
    /// - Parameter cgImage: The source image.
    /// - Returns: A pointer to the grayscale float data, or nil if conversion failed. Caller must deallocate.
    private func grayscaleBuffer(from cgImage: CGImage) -> UnsafeMutablePointer<Float>? {
        let width = cgImage.width
        let height = cgImage.height
        let pixelCount = width * height

        // Render to 8-bit grayscale
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let pixelData = context.data else {
            return nil
        }

        // Convert UInt8 grayscale to Float
        let uint8Pointer = pixelData.bindMemory(to: UInt8.self, capacity: pixelCount)
        let floatPointer = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)

        var source = vImage_Buffer(
            data: UnsafeMutableRawPointer(uint8Pointer),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: width
        )
        var dest = vImage_Buffer(
            data: floatPointer,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: width * MemoryLayout<Float>.size
        )

        let convertError = vImageConvert_Planar8toPlanarF(&source, &dest, 0, 1, vImage_Flags(kvImageNoFlags))
        guard convertError == kvImageNoError else {
            floatPointer.deallocate()
            return nil
        }

        return floatPointer
    }
}
