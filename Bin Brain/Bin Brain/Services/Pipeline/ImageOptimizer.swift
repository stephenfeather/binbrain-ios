// ImageOptimizer.swift
// Bin Brain
//
// Stage 2 of the on-device image pipeline: smart crop, auto-enhance, resize, and JPEG encode.
// Prepares captured photos for upload to the server.

import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// Crop-debug logger — same subsystem/category as `cropDebugLogger` in
/// `QualityGates.swift`. Filter Console.app with
/// `subsystem:com.binbrain.app category:crop-debug` to see the full
/// per-photo trace: salient objects → union → coverage check → final
/// pixel crop rect → output dims.
nonisolated private let optimizerCropLogger = Logger(subsystem: "com.binbrain.app", category: "crop-debug")
nonisolated private let optimizerSignposter = OSSignposter(subsystem: "com.binbrain.app", category: "MediaPipeline")

// MARK: - Image Optimizer

/// Optimizes a captured photo for upload by applying smart crop, optional auto-enhance,
/// resize, and JPEG compression.
///
/// Operations run in order:
/// 1. Smart crop (if saliency bounding box covers < 60% of the frame)
/// 2. Auto-enhance (disabled by default — effect on server vision model unvalidated)
/// 3. Resize (if longest side > 2048px, downscale preserving aspect ratio)
/// 4. JPEG encode (quality 0.85, always JPEG — server cannot decode HEIC)
nonisolated struct ImageOptimizer: Sendable {

    // MARK: - Constants

    /// Maximum output dimension on the longest side.
    private static let maxLongestSide: CGFloat = 2048

    /// JPEG compression quality (0.0–1.0).
    private static let jpegQuality: CGFloat = 0.85

    /// Minimum saliency coverage to skip cropping (60%).
    private static let cropThreshold: CGFloat = 0.60

    /// Padding factor added around the saliency bounding box.
    private static let cropPadding: CGFloat = 0.15

    // MARK: - Public API

    /// Optimizes a CGImage for upload.
    ///
    /// - Parameters:
    ///   - cgImage: The source image to optimize.
    ///   - saliencyBoundingBox: Normalized bounding box (0.0–1.0, origin bottom-left) from Vision.
    ///     Pass `nil` to skip smart crop.
    ///   - context: A reusable `CIContext` for Core Image rendering.
    ///   - autoEnhance: Whether to apply auto-enhancement filters. Defaults to `false`.
    /// - Returns: A tuple of the final JPEG data and optional crop metadata.
    func optimize(
        _ cgImage: CGImage,
        saliencyBoundingBox: CGRect?,
        context: CIContext,
        autoEnhance: Bool = false
    ) -> (jpegData: Data, cropInfo: CropInfo?) {
        let transformID = optimizerSignposter.makeSignpostID()
        let transformInterval = optimizerSignposter.beginInterval("media_transform", id: transformID)
        let imageWidth = cgImage.width
        let imageHeight = cgImage.height
        let bytesInApprox = cgImage.bytesPerRow * cgImage.height
        optimizerSignposter.emitEvent(
            "media_transform",
            id: transformID,
            "stage=\("optimize", privacy: .public) bytesInApprox=\(bytesInApprox, privacy: .public) formatIn=\("cgimage", privacy: .public) formatOut=\("jpeg", privacy: .public) widthIn=\(imageWidth, privacy: .public) heightIn=\(imageHeight, privacy: .public)"
        )
        var currentImage = cgImage
        var cropInfo: CropInfo?

        // Stage 1: Smart crop
        optimizerCropLogger.notice("[optimize] in image=\(imageWidth, privacy: .public)x\(imageHeight, privacy: .public) bbox=\(saliencyBoundingBox.map { "(\($0.origin.x),\($0.origin.y),\($0.width),\($0.height))" } ?? "nil", privacy: .public)")
        if let box = saliencyBoundingBox {
            let coverage = box.width * box.height
            if coverage < Self.cropThreshold {
                let cropRect = pixelCropRect(
                    from: box,
                    imageWidth: imageWidth,
                    imageHeight: imageHeight
                )
                optimizerCropLogger.notice("[optimize] coverage=\(coverage, privacy: .public) < threshold=\(Self.cropThreshold, privacy: .public) → CROPPING to pixelRect=(x=\(cropRect.origin.x, privacy: .public), y=\(cropRect.origin.y, privacy: .public), w=\(cropRect.width, privacy: .public), h=\(cropRect.height, privacy: .public)) padding=\(Self.cropPadding, privacy: .public)")
                if let cropped = cgImage.cropping(to: cropRect) {
                    cropInfo = CropInfo(
                        originalSize: [imageWidth, imageHeight],
                        cropRect: [
                            Int(cropRect.origin.x),
                            Int(cropRect.origin.y),
                            Int(cropRect.width),
                            Int(cropRect.height)
                        ]
                    )
                    currentImage = cropped
                    optimizerCropLogger.notice("[optimize] cropped result=\(cropped.width, privacy: .public)x\(cropped.height, privacy: .public)")
                } else {
                    optimizerCropLogger.error("[optimize] cgImage.cropping(to:) returned nil — pixelRect may be out of bounds; uploading uncropped frame")
                }
            } else {
                optimizerCropLogger.notice("[optimize] coverage=\(coverage, privacy: .public) ≥ threshold=\(Self.cropThreshold, privacy: .public) → SKIP crop, full frame")
            }
        } else {
            optimizerCropLogger.notice("[optimize] no saliency bbox → SKIP crop, full frame")
        }

        // Stage 2: Auto-enhance (disabled by default)
        var ciImage = CIImage(cgImage: currentImage)
        if autoEnhance {
            ciImage = applyAutoEnhance(to: ciImage)
        }

        // Stage 3: Resize if needed
        let currentWidth = CGFloat(currentImage.width)
        let currentHeight = CGFloat(currentImage.height)
        let longestSide = max(currentWidth, currentHeight)

        if longestSide > Self.maxLongestSide {
            let scale = Self.maxLongestSide / longestSide
            ciImage = applyLanczosResize(to: ciImage, scale: scale)
        }

        // Stage 4: Render and JPEG encode
        let renderedImage = renderToCGImage(ciImage: ciImage, context: context) ?? currentImage
        let jpegData = encodeJPEG(renderedImage)
        optimizerCropLogger.notice("[optimize] out image=\(renderedImage.width, privacy: .public)x\(renderedImage.height, privacy: .public) jpeg=\(jpegData.count, privacy: .public)B")
        optimizerSignposter.emitEvent(
            "media_transform_done",
            id: transformID,
            "stage=\("optimize", privacy: .public) bytesOut=\(jpegData.count, privacy: .public) widthOut=\(renderedImage.width, privacy: .public) heightOut=\(renderedImage.height, privacy: .public) cropped=\((cropInfo != nil), privacy: .public) resized=\((longestSide > Self.maxLongestSide), privacy: .public)"
        )
        optimizerSignposter.endInterval("media_transform", transformInterval)

        return (jpegData: jpegData, cropInfo: cropInfo)
    }

    // MARK: - Smart Crop

    /// Converts a normalized Vision bounding box to pixel coordinates for `CGImage.cropping(to:)`.
    ///
    /// Vision uses normalized coordinates with origin at bottom-left.
    /// CGImage uses pixel coordinates with origin at top-left.
    /// This method converts between the two and adds padding clamped to image bounds.
    private func pixelCropRect(
        from normalizedBox: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect {
        let w = CGFloat(imageWidth)
        let h = CGFloat(imageHeight)

        // Convert normalized to pixel coordinates
        let pixelX = normalizedBox.origin.x * w
        let pixelY = normalizedBox.origin.y * h
        let pixelW = normalizedBox.width * w
        let pixelH = normalizedBox.height * h

        // Add padding
        let padW = pixelW * Self.cropPadding
        let padH = pixelH * Self.cropPadding
        let expandedX = pixelX - padW
        let expandedY = pixelY - padH
        let expandedW = pixelW + padW * 2
        let expandedH = pixelH + padH * 2

        // Clamp to image bounds
        let clampedX = max(0, expandedX)
        let clampedY = max(0, expandedY)
        let clampedW = min(expandedW, w - clampedX)
        let clampedH = min(expandedH, h - clampedY)

        // Flip Y axis: Vision origin is bottom-left, CGImage origin is top-left
        let flippedY = h - clampedY - clampedH

        return CGRect(
            x: floor(clampedX),
            y: floor(max(0, flippedY)),
            width: floor(clampedW),
            height: floor(clampedH)
        )
    }

    // MARK: - Auto-Enhance

    /// Applies Core Image auto-adjustment filters, skipping face-related corrections.
    private func applyAutoEnhance(to image: CIImage) -> CIImage {
        let filters = image.autoAdjustmentFilters(options: [
            .redEye: false,
            .features: [] as [CIFeature]
        ])

        return filters.reduce(image) { current, filter in
            // Skip CIFaceBalance — not relevant for bin photos
            guard filter.name != "CIFaceBalance" else { return current }
            filter.setValue(current, forKey: kCIInputImageKey)
            return filter.outputImage ?? current
        }
    }

    // MARK: - Resize

    /// Applies Lanczos downscale via `CILanczosScaleTransform`.
    private func applyLanczosResize(to image: CIImage, scale: CGFloat) -> CIImage {
        let filter = CIFilter(name: "CILanczosScaleTransform")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        return filter.outputImage ?? image
    }

    // MARK: - Rendering

    /// Renders a CIImage to a CGImage using the provided context.
    private func renderToCGImage(ciImage: CIImage, context: CIContext) -> CGImage? {
        context.createCGImage(ciImage, from: ciImage.extent)
    }

    // MARK: - JPEG Encoding

    /// Encodes a CGImage as JPEG data using ImageIO.
    private func encodeJPEG(_ cgImage: CGImage) -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            // Fallback: return empty data (should not happen with valid CGImage)
            return Data()
        }

        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: Self.jpegQuality
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        CGImageDestinationFinalize(destination)

        return data as Data
    }
}
