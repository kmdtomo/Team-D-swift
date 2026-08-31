/// A deterministic, in-memory image compositor for the T15 fixture slice.
///
/// This module deliberately has no API, persistence, UI, or Core Graphics
/// dependency.  An eventual platform adapter must convert decoded images into
/// these normalized values before calling the core.
public enum CompositionKitModule {}

/// The finite set of EXIF-equivalent pixel orientations understood by the core.
/// Orientation is normalized before dimensions are compared or pixels blended.
public enum RasterOrientation: Sendable, Equatable {
    case up
    case upMirrored
    case down
    case downMirrored
    case leftMirrored
    case right
    case rightMirrored
    case left
    /// Represents decoder metadata the fixture core does not understand.
    case unsupported
}

/// The fixture compositor only blends byte sRGB.  Decoders must explicitly
/// convert other color spaces at the platform boundary rather than guessing.
public enum RasterColorSpace: Sendable, Equatable {
    case sRGB
    case displayP3
    case unsupported
}

/// A straight-alpha, row-major RGBA8 raster. Photographed front and background
/// inputs are expected to be opaque RGB images. A composite remains opaque,
/// while a transparent cutout keeps the normalized front RGB and replaces only
/// its alpha channel with the validated mask.
public struct RGBA8Raster: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    public let orientation: RasterOrientation
    public let colorSpace: RasterColorSpace

    public init(
        width: Int,
        height: Int,
        pixels: [UInt8],
        orientation: RasterOrientation = .up,
        colorSpace: RasterColorSpace = .sRGB
    ) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.orientation = orientation
        self.colorSpace = colorSpace
    }
}

public enum MaskColorSpace: Sendable, Equatable {
    case grayscale8
    case alpha8
    case unsupported
}

/// A row-major, one-byte mask where 0 is background and 255 is foreground.
public struct Mask8Raster: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    public let orientation: RasterOrientation
    public let colorSpace: MaskColorSpace

    public init(
        width: Int,
        height: Int,
        pixels: [UInt8],
        orientation: RasterOrientation = .up,
        colorSpace: MaskColorSpace = .grayscale8
    ) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.orientation = orientation
        self.colorSpace = colorSpace
    }
}

public struct CompositionInput: Sendable, Equatable {
    public let front: RGBA8Raster
    public let mask: Mask8Raster
    public let background: RGBA8Raster

    public init(front: RGBA8Raster, mask: Mask8Raster, background: RGBA8Raster) {
        self.front = front
        self.mask = mask
        self.background = background
    }
}

/// The only two pixel sources permitted for the background-independent cutout.
/// The result is an intermediate preview artifact, never an approval or export
/// candidate by itself.
public struct TransparentCutoutInput: Sendable, Equatable {
    public let front: RGBA8Raster
    public let mask: Mask8Raster

    public init(front: RGBA8Raster, mask: Mask8Raster) {
        self.front = front
        self.mask = mask
    }
}

public enum CompositionError: Error, Sendable, Equatable {
    case zeroDimensions
    case invalidRGBAByteCount
    case invalidMaskByteCount
    case unsupportedRasterColorSpace
    case unsupportedMaskColorSpace
    case unsupportedOrientation
    case nonOpaqueRaster
    case dimensionMismatch
    case emptyMask
    case fullMask
    case cancelled
}

public typealias CompositionCancellationProbe = @Sendable () -> Bool

/// Composites only original front RGB, a mask, and a supplied background.
///
/// Background placement is center-crop then nearest-neighbor resize. For each
/// target pixel, its centre is mapped into the centred source crop and floored
/// to a source pixel. Crop mapping uses exact integer rational arithmetic.
/// For a mask value `m`, each output RGB channel is:
/// `(front * m + background * (255 - m) + 127) / 255`.
/// Thus `m == 255` is byte-for-byte front RGB, `m == 0` is background RGB, and
/// there is no generation, completion, retouching, or input other than front.
public enum FrontImageCompositor {
    @available(macOS 10.15, iOS 13, *)
    public static func compose(
        _ input: CompositionInput,
        cancellationProbe: @escaping CompositionCancellationProbe = { Task<Never, Never>.isCancelled }
    ) throws -> RGBA8Raster {
        try checkCancellation(cancellationProbe)
        let front = try normalize(input.front, cancellationProbe: cancellationProbe)
        let mask = try normalize(input.mask, cancellationProbe: cancellationProbe)
        let background = try normalize(input.background, cancellationProbe: cancellationProbe)

        try validateMask(mask, matches: front, cancellationProbe: cancellationProbe)

        var output = [UInt8](repeating: 0, count: front.pixels.count)
        for y in 0 ..< front.height {
            try checkCancellation(cancellationProbe)
            for x in 0 ..< front.width {
                let frontOffset = (y * front.width + x) * 4
                let backgroundOffset = backgroundOffset(
                    x: x,
                    y: y,
                    targetWidth: front.width,
                    targetHeight: front.height,
                    backgroundWidth: background.width,
                    backgroundHeight: background.height
                )
                let alpha = Int(mask.pixels[y * mask.width + x])
                let inverseAlpha = 255 - alpha
                for channel in 0 ..< 3 {
                    let source = Int(front.pixels[frontOffset + channel])
                    let replacement = Int(background.pixels[backgroundOffset + channel])
                    output[frontOffset + channel] = UInt8(
                        (source * alpha + replacement * inverseAlpha + 127) / 255
                    )
                }
                output[frontOffset + 3] = 255
            }
        }
        return RGBA8Raster(width: front.width, height: front.height, pixels: output)
    }

    /// Produces a straight-alpha cutout without requiring or consulting a
    /// generated background. Every output RGB byte comes from the normalized
    /// original front image and every output alpha byte comes from the mask.
    /// Invalid empty, full, mismatched, or unsupported masks fail closed.
    @available(macOS 10.15, iOS 13, *)
    public static func makeTransparentCutout(
        _ input: TransparentCutoutInput,
        cancellationProbe: @escaping CompositionCancellationProbe = { Task<Never, Never>.isCancelled }
    ) throws -> RGBA8Raster {
        try checkCancellation(cancellationProbe)
        let front = try normalize(input.front, cancellationProbe: cancellationProbe)
        let mask = try normalize(input.mask, cancellationProbe: cancellationProbe)
        try validateMask(mask, matches: front, cancellationProbe: cancellationProbe)

        var output = front.pixels
        for y in 0 ..< front.height {
            try checkCancellation(cancellationProbe)
            for x in 0 ..< front.width {
                let pixel = y * front.width + x
                output[pixel * 4 + 3] = mask.pixels[pixel]
            }
        }
        return RGBA8Raster(width: front.width, height: front.height, pixels: output)
    }

    private static func checkCancellation(_ probe: CompositionCancellationProbe) throws {
        if probe() {
            throw CompositionError.cancelled
        }
    }

    private static func normalize(
        _ raster: RGBA8Raster,
        cancellationProbe: CompositionCancellationProbe
    ) throws -> RGBA8Raster {
        guard raster.colorSpace == .sRGB else { throw CompositionError.unsupportedRasterColorSpace }
        guard raster.orientation != .unsupported else { throw CompositionError.unsupportedOrientation }
        try validateDimensions(raster.width, raster.height)
        let byteCount = try expectedByteCount(
            width: raster.width,
            height: raster.height,
            channels: 4,
            overflowError: .invalidRGBAByteCount
        )
        guard raster.pixels.count == byteCount else {
            throw CompositionError.invalidRGBAByteCount
        }
        guard raster.pixels.enumerated().allSatisfy({ $0.offset % 4 != 3 || $0.element == 255 }) else {
            throw CompositionError.nonOpaqueRaster
        }
        let dimensions = normalizedDimensions(width: raster.width, height: raster.height, orientation: raster.orientation)
        var pixels = [UInt8](repeating: 0, count: raster.pixels.count)
        for y in 0 ..< dimensions.height {
            try checkCancellation(cancellationProbe)
            for x in 0 ..< dimensions.width {
                let source = sourceCoordinate(x: x, y: y, sourceWidth: raster.width, sourceHeight: raster.height, orientation: raster.orientation)
                let sourceOffset = (source.y * raster.width + source.x) * 4
                let destinationOffset = (y * dimensions.width + x) * 4
                pixels[destinationOffset ..< destinationOffset + 4] = raster.pixels[sourceOffset ..< sourceOffset + 4]
            }
        }
        return RGBA8Raster(width: dimensions.width, height: dimensions.height, pixels: pixels)
    }

    private static func normalize(
        _ raster: Mask8Raster,
        cancellationProbe: CompositionCancellationProbe
    ) throws -> Mask8Raster {
        guard raster.colorSpace != .unsupported else { throw CompositionError.unsupportedMaskColorSpace }
        guard raster.orientation != .unsupported else { throw CompositionError.unsupportedOrientation }
        try validateDimensions(raster.width, raster.height)
        let byteCount = try expectedByteCount(
            width: raster.width,
            height: raster.height,
            channels: 1,
            overflowError: .invalidMaskByteCount
        )
        guard raster.pixels.count == byteCount else {
            throw CompositionError.invalidMaskByteCount
        }
        let dimensions = normalizedDimensions(width: raster.width, height: raster.height, orientation: raster.orientation)
        var pixels = [UInt8](repeating: 0, count: raster.pixels.count)
        for y in 0 ..< dimensions.height {
            try checkCancellation(cancellationProbe)
            for x in 0 ..< dimensions.width {
                let source = sourceCoordinate(x: x, y: y, sourceWidth: raster.width, sourceHeight: raster.height, orientation: raster.orientation)
                pixels[y * dimensions.width + x] = raster.pixels[source.y * raster.width + source.x]
            }
        }
        return Mask8Raster(width: dimensions.width, height: dimensions.height, pixels: pixels)
    }

    private static func validateMask(
        _ mask: Mask8Raster,
        matches front: RGBA8Raster,
        cancellationProbe: CompositionCancellationProbe
    ) throws {
        guard front.width == mask.width, front.height == mask.height else {
            throw CompositionError.dimensionMismatch
        }

        var hasForeground = false
        var hasBackground = false
        for y in 0 ..< mask.height {
            try checkCancellation(cancellationProbe)
            let rowStart = y * mask.width
            for x in 0 ..< mask.width {
                let value = mask.pixels[rowStart + x]
                hasForeground = hasForeground || value != 0
                hasBackground = hasBackground || value != 255
                if hasForeground, hasBackground {
                    return
                }
            }
        }
        guard hasForeground else { throw CompositionError.emptyMask }
        guard hasBackground else { throw CompositionError.fullMask }
    }

    private static func validateDimensions(_ width: Int, _ height: Int) throws {
        guard width > 0, height > 0 else { throw CompositionError.zeroDimensions }
    }

    private static func expectedByteCount(
        width: Int,
        height: Int,
        channels: Int,
        overflowError: CompositionError
    ) throws -> Int {
        let (area, areaOverflow) = width.multipliedReportingOverflow(by: height)
        let (count, countOverflow) = area.multipliedReportingOverflow(by: channels)
        guard !areaOverflow, !countOverflow else { throw overflowError }
        return count
    }

    private static func normalizedDimensions(width: Int, height: Int, orientation: RasterOrientation) -> (width: Int, height: Int) {
        switch orientation {
        case .leftMirrored, .right, .rightMirrored, .left:
            (height, width)
        case .up, .upMirrored, .down, .downMirrored, .unsupported:
            (width, height)
        }
    }

    private static func sourceCoordinate(
        x: Int,
        y: Int,
        sourceWidth width: Int,
        sourceHeight height: Int,
        orientation: RasterOrientation
    ) -> (x: Int, y: Int) {
        switch orientation {
        case .up: (x, y)
        case .upMirrored: (width - 1 - x, y)
        case .down: (width - 1 - x, height - 1 - y)
        case .downMirrored: (x, height - 1 - y)
        case .leftMirrored: (y, x)
        case .right: (y, height - 1 - x)
        case .rightMirrored: (width - 1 - y, height - 1 - x)
        case .left: (width - 1 - y, x)
        case .unsupported:
            preconditionFailure("Unsupported orientations are rejected before coordinate mapping")
        }
    }

    private static func backgroundOffset(
        x: Int,
        y: Int,
        targetWidth: Int,
        targetHeight: Int,
        backgroundWidth: Int,
        backgroundHeight: Int
    ) -> Int {
        let sourceX: Int
        let sourceY: Int
        if backgroundWidth * targetHeight > targetWidth * backgroundHeight {
            let denominator = 2 * targetHeight
            sourceX = min(
                backgroundWidth - 1,
                (backgroundWidth * targetHeight - targetWidth * backgroundHeight + (2 * x + 1) * backgroundHeight) / denominator
            )
            sourceY = min(backgroundHeight - 1, (2 * y + 1) * backgroundHeight / denominator)
        } else {
            let denominator = 2 * targetWidth
            sourceX = min(backgroundWidth - 1, (2 * x + 1) * backgroundWidth / denominator)
            sourceY = min(
                backgroundHeight - 1,
                (backgroundHeight * targetWidth - targetHeight * backgroundWidth + (2 * y + 1) * backgroundWidth) / denominator
            )
        }
        return (sourceY * backgroundWidth + sourceX) * 4
    }
}
