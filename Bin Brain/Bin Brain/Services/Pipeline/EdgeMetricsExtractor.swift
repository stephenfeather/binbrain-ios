// EdgeMetricsExtractor.swift
// Bin Brain
//
// Extracts non-blocking image-structure telemetry from a decoded image using
// Core Image's Canny edge detector. Metrics are additive metadata only and
// must never block upload if extraction fails.

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

nonisolated struct EdgeMetricsExtractor: Sendable {

    static let analysisLongestSide: CGFloat = 512
    static let gaussianSigma: Float = 1.6
    static let thresholdLow: Float = 0.02
    static let thresholdHigh: Float = 0.05
    static let hysteresisPasses: Int = 1

    func extract(
        from cgImage: CGImage,
        saliencyBoundingBox: CGRect?,
        cropInfo: CropInfo?,
        context: CIContext
    ) -> CannyMetrics? {
        let inputImage = CIImage(cgImage: cgImage)
        let analysisImage = downscaleForAnalysis(inputImage)
        guard let edgeImage = makeEdgeImage(from: analysisImage) else { return nil }
        guard let fullFrameEdgeDensity = meanIntensity(of: edgeImage, context: context) else { return nil }

        let saliencyEdgeDensity = saliencyBoundingBox.flatMap { boundingBox -> Double? in
            let roi = denormalize(boundingBox, in: edgeImage.extent)
            guard !roi.isEmpty else { return nil }
            return meanIntensity(of: edgeImage.cropped(to: roi), context: context)
        }

        let uploadFrameEdgeDensity = cropInfo.flatMap { info -> Double? in
            let roi = scaledCropRect(from: info, into: edgeImage.extent)
            guard !roi.isEmpty else { return nil }
            return meanIntensity(of: edgeImage.cropped(to: roi), context: context)
        }

        let analysisLongestSide = Int(max(edgeImage.extent.width, edgeImage.extent.height).rounded())
        return CannyMetrics(
            analysisLongestSide: analysisLongestSide,
            gaussianSigma: Double(Self.gaussianSigma),
            thresholdLow: Double(Self.thresholdLow),
            thresholdHigh: Double(Self.thresholdHigh),
            hysteresisPasses: Self.hysteresisPasses,
            fullFrameEdgeDensity: fullFrameEdgeDensity,
            saliencyEdgeDensity: saliencyEdgeDensity,
            uploadFrameEdgeDensity: uploadFrameEdgeDensity
        )
    }

    private func downscaleForAnalysis(_ image: CIImage) -> CIImage {
        let extent = image.extent.integral
        let longestSide = max(extent.width, extent.height)
        guard longestSide > Self.analysisLongestSide else { return image }

        let scale = Self.analysisLongestSide / longestSide
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image
        filter.scale = Float(scale)
        filter.aspectRatio = 1.0
        return filter.outputImage ?? image
    }

    private func makeEdgeImage(from image: CIImage) -> CIImage? {
        let filter = CIFilter.cannyEdgeDetector()
        filter.inputImage = image
        filter.gaussianSigma = Self.gaussianSigma
        filter.perceptual = false
        filter.thresholdLow = Self.thresholdLow
        filter.thresholdHigh = Self.thresholdHigh
        filter.hysteresisPasses = Self.hysteresisPasses
        return filter.outputImage?.cropped(to: image.extent)
    }

    private func meanIntensity(of image: CIImage, context: CIContext) -> Double? {
        guard !image.extent.isEmpty else { return nil }
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = image.extent
        guard let outputImage = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            outputImage,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return Double(pixel[0]) / 255.0
    }

    private func denormalize(_ normalizedRect: CGRect, in extent: CGRect) -> CGRect {
        CGRect(
            x: extent.minX + normalizedRect.origin.x * extent.width,
            y: extent.minY + normalizedRect.origin.y * extent.height,
            width: normalizedRect.width * extent.width,
            height: normalizedRect.height * extent.height
        )
        .intersection(extent)
    }

    private func scaledCropRect(from cropInfo: CropInfo, into extent: CGRect) -> CGRect {
        guard cropInfo.originalSize.count == 2, cropInfo.cropRect.count == 4 else { return .null }

        let originalWidth = CGFloat(cropInfo.originalSize[0])
        let originalHeight = CGFloat(cropInfo.originalSize[1])
        guard originalWidth > 0, originalHeight > 0 else { return .null }

        let scaleX = extent.width / originalWidth
        let scaleY = extent.height / originalHeight
        let x = extent.minX + CGFloat(cropInfo.cropRect[0]) * scaleX
        let topY = CGFloat(cropInfo.cropRect[1]) * scaleY
        let width = CGFloat(cropInfo.cropRect[2]) * scaleX
        let height = CGFloat(cropInfo.cropRect[3]) * scaleY
        let y = extent.maxY - topY - height

        return CGRect(x: x, y: y, width: width, height: height).intersection(extent)
    }
}
