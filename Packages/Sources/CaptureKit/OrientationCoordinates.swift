import Foundation

/// Coordinate convention shared by preview guides, analysis and measurement:
/// `(0, 0)` is the upper-left pixel corner of an upright image and `(1, 1)` is
/// its lower-right pixel corner. Values are finite and closed over `0...1`.
public struct NormalizedImagePoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite else { throw OrientationCoordinateError.nonFinite }
        guard (0...1).contains(x), (0...1).contains(y) else { throw OrientationCoordinateError.outOfBounds }
        self.x = x
        self.y = y
    }

    /// Use only for user-driven preview touches: non-finite input is rejected;
    /// finite input is intentionally clamped to the image edge.
    public static func clamping(x: Double, y: Double) throws -> Self {
        guard x.isFinite, y.isFinite else { throw OrientationCoordinateError.nonFinite }
        return try Self(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}

public struct ImageSize: Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) throws {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { throw OrientationCoordinateError.invalidSize }
        self.width = width
        self.height = height
    }
}

public enum OrientationCoordinateError: Error, Equatable, Sendable {
    case nonFinite
    case outOfBounds
    case invalidSize
    case missingEXIFOrientation
    case invalidPhotoDimensions
    case unsupportedRotationAngle
    case unsupportedOrientation
}

/// ImageIO/EXIF orientation values. Transformations map encoded-pixel
/// coordinates to the upright coordinate convention above.
public enum ImageEXIFOrientation: Int, CaseIterable, Equatable, Sendable {
    case up = 1
    case upMirrored = 2
    case down = 3
    case downMirrored = 4
    case leftMirrored = 5
    case right = 6
    case rightMirrored = 7
    case left = 8

    public init(exifValue: Int?) throws {
        guard let exifValue else { throw OrientationCoordinateError.missingEXIFOrientation }
        guard let value = Self(rawValue: exifValue) else { throw OrientationCoordinateError.unsupportedOrientation }
        self = value
    }

    public var uprightSizeSwapsAxes: Bool {
        switch self { case .leftMirrored, .right, .rightMirrored, .left: true; default: false }
    }

    public func uprightPoint(fromEncoded point: NormalizedImagePoint) throws -> NormalizedImagePoint {
        let result: (Double, Double)
        switch self {
        case .up: result = (point.x, point.y)
        case .upMirrored: result = (1 - point.x, point.y)
        case .down: result = (1 - point.x, 1 - point.y)
        case .downMirrored: result = (point.x, 1 - point.y)
        case .leftMirrored: result = (point.y, point.x)
        case .right: result = (1 - point.y, point.x)
        case .rightMirrored: result = (1 - point.y, 1 - point.x)
        case .left: result = (point.y, 1 - point.x)
        }
        return try NormalizedImagePoint(x: result.0, y: result.1)
    }

    public func encodedPoint(fromUpright point: NormalizedImagePoint) throws -> NormalizedImagePoint {
        let result: (Double, Double)
        switch self {
        case .up: result = (point.x, point.y)
        case .upMirrored: result = (1 - point.x, point.y)
        case .down: result = (1 - point.x, 1 - point.y)
        case .downMirrored: result = (point.x, 1 - point.y)
        case .leftMirrored: result = (point.y, point.x)
        case .right: result = (point.y, 1 - point.x)
        case .rightMirrored: result = (1 - point.y, 1 - point.x)
        case .left: result = (1 - point.y, point.x)
        }
        return try NormalizedImagePoint(x: result.0, y: result.1)
    }
}

public enum CaptureDeviceOrientation: Equatable, Sendable { case portrait, portraitUpsideDown, landscapeLeft, landscapeRight, faceUp, faceDown, unknown }
public enum CaptureInterfaceOrientation: Equatable, Sendable { case portrait, portraitUpsideDown, landscapeLeft, landscapeRight, unknown }
public enum CaptureVideoOrientation: Equatable, Sendable { case portrait, portraitUpsideDown, landscapeLeft, landscapeRight }
public enum CaptureCameraPosition: Equatable, Sendable { case back, front }

/// AVFoundation capture-device points belong to its preview/focus coordinate
/// system. They are deliberately not upright image points: conversion requires
/// the configured preview connection plus an explicit image-orientation chain.
public struct CaptureDeviceNormalizedPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite else { throw OrientationCoordinateError.nonFinite }
        guard (0...1).contains(x), (0...1).contains(y) else { throw OrientationCoordinateError.outOfBounds }
        self.x = x
        self.y = y
    }
}

/// Each AVFoundation connection accepts only a finite, hardware-supported
/// angle. Preview and capture use distinct types because RotationCoordinator
/// can legitimately provide different values for them.
public struct PreviewConnectionRotationAngle: Equatable, Sendable {
    public let degrees: Double
    public init(degrees: Double) throws {
        guard degrees.isFinite, [0, 90, 180, 270].contains(degrees) else { throw OrientationCoordinateError.unsupportedRotationAngle }
        self.degrees = degrees
    }
}

public struct CaptureConnectionRotationAngle: Equatable, Sendable {
    public let degrees: Double
    public init(degrees: Double) throws {
        guard degrees.isFinite, [0, 90, 180, 270].contains(degrees) else { throw OrientationCoordinateError.unsupportedRotationAngle }
        self.degrees = degrees
    }
}

public enum CaptureOrientationMapper {
    /// Interface orientation is authoritative for preview connections.
    public static func videoOrientation(interface: CaptureInterfaceOrientation) -> CaptureVideoOrientation? {
        switch interface {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .unknown: nil
        }
    }

    /// Device landscape names describe the device's top edge and are therefore
    /// opposite to AVCapture's landscape video names.
    public static func videoOrientation(device: CaptureDeviceOrientation) -> CaptureVideoOrientation? {
        switch device {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        case .faceUp, .faceDown, .unknown: nil
        }
    }

    public static func isMirrored(camera: CaptureCameraPosition) -> Bool { camera == .front }
}

public enum PreviewContentMode: Equatable, Sendable { case aspectFill, aspectFit }

/// Pure preview geometry. Aspect-fill crop and aspect-fit letterbox are derived
/// once here; callers must not reproduce CSS/object-fit arithmetic.
public struct PreviewImageGeometry: Equatable, Sendable {
    public let imageSize: ImageSize
    public let previewSize: ImageSize
    public let contentMode: PreviewContentMode
    public let contentOriginX: Double
    public let contentOriginY: Double
    public let contentSize: ImageSize

    public init(imageSize: ImageSize, previewSize: ImageSize, contentMode: PreviewContentMode) throws {
        self.imageSize = imageSize; self.previewSize = previewSize; self.contentMode = contentMode
        let scaleX = previewSize.width / imageSize.width
        let scaleY = previewSize.height / imageSize.height
        let scale = contentMode == .aspectFill ? max(scaleX, scaleY) : min(scaleX, scaleY)
        guard scale.isFinite, scale > 0 else { throw OrientationCoordinateError.invalidSize }
        let size = try ImageSize(width: imageSize.width * scale, height: imageSize.height * scale)
        contentSize = size
        contentOriginX = (previewSize.width - size.width) / 2
        contentOriginY = (previewSize.height - size.height) / 2
    }

    /// A point is nil in aspect-fit letterbox. Aspect-fill points always map to
    /// source pixels, then clamp to image edges for floating point drift.
    public func normalizedPoint(previewX: Double, previewY: Double) throws -> NormalizedImagePoint? {
        guard previewX.isFinite, previewY.isFinite else { throw OrientationCoordinateError.nonFinite }
        guard (0...previewSize.width).contains(previewX), (0...previewSize.height).contains(previewY) else { return nil }
        let rawX = (previewX - contentOriginX) / contentSize.width
        let rawY = (previewY - contentOriginY) / contentSize.height
        if contentMode == .aspectFit, !(0...1).contains(rawX) || !(0...1).contains(rawY) { return nil }
        return try NormalizedImagePoint.clamping(x: rawX, y: rawY)
    }

    /// This can return a point outside the preview when aspect-fill has cropped
    /// the requested source point; use `visiblePreviewPoint` for overlay work.
    public func previewPoint(normalized: NormalizedImagePoint) -> (x: Double, y: Double) {
        (contentOriginX + normalized.x * contentSize.width, contentOriginY + normalized.y * contentSize.height)
    }

    public func visiblePreviewPoint(normalized: NormalizedImagePoint) -> (x: Double, y: Double)? {
        let point = previewPoint(normalized: normalized)
        guard (0...previewSize.width).contains(point.x), (0...previewSize.height).contains(point.y) else { return nil }
        return point
    }
}

/// Keeps camera-produced bytes untouched. The plan records the only permitted
/// conversion boundary: an upright, analysis-only image representation.
public struct AnalysisNormalizationPlan: Equatable, Sendable {
    public let originalFileData: Data
    public let exifOrientation: ImageEXIFOrientation
    public let encodedSize: ImageSize?

    public init(photo: CapturedPhoto) throws {
        originalFileData = photo.originalFileData
        exifOrientation = try ImageEXIFOrientation(exifValue: photo.metadata.orientation)
        switch (photo.metadata.pixelWidth, photo.metadata.pixelHeight) {
        case (nil, nil): encodedSize = nil
        case let (.some(width), .some(height)):
            guard width > 0, height > 0 else { throw OrientationCoordinateError.invalidPhotoDimensions }
            encodedSize = try ImageSize(width: Double(width), height: Double(height))
        default: throw OrientationCoordinateError.invalidPhotoDimensions
        }
    }

    public var uprightSize: ImageSize? {
        guard let encodedSize else { return nil }
        return exifOrientation.uprightSizeSwapsAxes ? try? ImageSize(width: encodedSize.height, height: encodedSize.width) : encodedSize
    }
}
