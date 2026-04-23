// CameraMetadataExtractor.swift
// Bin Brain
//
// Extracts camera-state telemetry from an AVCapturePhoto into a
// CameraCaptureContext for the ImagePipeline.
//
// DataScannerViewController owns the AVCaptureSession and does not expose the
// underlying AVCaptureDevice, so live-device state (zoom, torch, HDR, focus
// mode, lens position, device type) cannot be sampled directly. This extractor
// pulls everything the EXIF/TIFF dictionaries on AVCapturePhoto.metadata
// expose: ISO, exposure duration, focal length, flash status, and the lens
// model string (used to infer camera position + device type for Apple
// hardware).

import AVFoundation
import Foundation
import ImageIO

enum CameraMetadataExtractor {

    /// Builds a `CameraCaptureContext` from an `AVCapturePhoto`.
    ///
    /// Returns `nil` only when the photo carries no metadata at all (a true
    /// no-signal case). Otherwise returns a context with as many fields
    /// populated as the metadata supports.
    static func context(from photo: AVCapturePhoto) -> CameraCaptureContext? {
        let metadata = photo.metadata
        guard !metadata.isEmpty else { return nil }

        let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]

        let lensModel = tiff[kCGImagePropertyTIFFModel as String] as? String
            ?? (exif[kCGImagePropertyExifLensModel as String] as? String)

        return CameraCaptureContext(
            cameraDeviceType: inferDeviceType(fromLensModel: lensModel),
            cameraPosition: inferPosition(fromLensModel: lensModel),
            zoomFactor: nil,
            flashUsed: flashFired(from: exif),
            torchUsed: nil,
            hdrEnabled: nil,
            iso: iso(from: exif),
            exposureDurationMs: exposureDurationMs(from: exif),
            focusMode: nil,
            lensPosition: nil,
            focalLengthMm: focalLengthMm(from: exif)
        )
    }

    // MARK: - EXIF Field Parsers

    private static func iso(from exif: [String: Any]) -> Double? {
        if let array = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber],
           let first = array.first {
            return first.doubleValue
        }
        return (exif[kCGImagePropertyExifISOSpeedRatings as String] as? NSNumber)?.doubleValue
    }

    private static func exposureDurationMs(from exif: [String: Any]) -> Double? {
        guard let seconds = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue else {
            return nil
        }
        return seconds * 1000.0
    }

    private static func focalLengthMm(from exif: [String: Any]) -> Double? {
        (exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue
    }

    /// EXIF Flash is a bit field; bit 0 = flash fired (per EXIF 2.3 spec).
    private static func flashFired(from exif: [String: Any]) -> Bool? {
        guard let raw = (exif[kCGImagePropertyExifFlash as String] as? NSNumber)?.intValue else {
            return nil
        }
        return (raw & 0x1) != 0
    }

    // MARK: - Lens Model Inference

    /// Infers a coarse camera position ("front" / "back") from Apple's lens
    /// model strings. Apple lens models look like:
    /// "iPhone 16 Pro Max back triple camera 6.86mm f/1.78"
    /// "iPhone 16 Pro Max front camera 2.69mm f/1.9"
    private static func inferPosition(fromLensModel lensModel: String?) -> String? {
        guard let lensModel else { return nil }
        let lower = lensModel.lowercased()
        if lower.contains("back") { return "back" }
        if lower.contains("front") { return "front" }
        return nil
    }

    /// Infers an `AVCaptureDevice.DeviceType`-style identifier from the lens
    /// model string. Falls back to the raw lens model when no Apple-specific
    /// keyword is recognized so the field is never silently dropped.
    private static func inferDeviceType(fromLensModel lensModel: String?) -> String? {
        guard let lensModel else { return nil }
        let lower = lensModel.lowercased()
        if lower.contains("ultra wide") || lower.contains("ultrawide") {
            return "ultraWideCamera"
        }
        if lower.contains("telephoto") {
            return "telephotoCamera"
        }
        if lower.contains("triple camera") {
            return "tripleCamera"
        }
        if lower.contains("dual wide") {
            return "dualWideCamera"
        }
        if lower.contains("dual camera") {
            return "dualCamera"
        }
        if lower.contains("true depth") || lower.contains("truedepth") {
            return "trueDepthCamera"
        }
        if lower.contains("wide") {
            return "wideAngleCamera"
        }
        return lensModel
    }
}
