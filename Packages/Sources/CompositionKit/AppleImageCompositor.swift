import CoreGraphics
import Foundation

/// The platform image boundary for the deterministic compositor. Callers must
/// supply the EXIF orientation captured with each decoded image; `CGImage`
/// deliberately does not carry that metadata itself.
public struct AppleImageCompositionInput: @unchecked Sendable {
    public let front: CGImage
    public let frontOrientation: RasterOrientation
    public let mask: CGImage
    public let maskOrientation: RasterOrientation
    public let background: CGImage
    public let backgroundOrientation: RasterOrientation

    public init(
        front: CGImage,
        frontOrientation: RasterOrientation = .up,
        mask: CGImage,
        maskOrientation: RasterOrientation = .up,
        background: CGImage,
        backgroundOrientation: RasterOrientation = .up
    ) {
        self.front = front
        self.frontOrientation = frontOrientation
        self.mask = mask
        self.maskOrientation = maskOrientation
        self.background = background
        self.backgroundOrientation = backgroundOrientation
    }
}

/// Apple image input for a background-independent transparent cutout. EXIF
/// orientation remains explicit because `CGImage` does not retain it.
public struct AppleTransparentCutoutInput: @unchecked Sendable {
    public let front: CGImage
    public let frontOrientation: RasterOrientation
    public let mask: CGImage
    public let maskOrientation: RasterOrientation

    public init(
        front: CGImage,
        frontOrientation: RasterOrientation = .up,
        mask: CGImage,
        maskOrientation: RasterOrientation = .up
    ) {
        self.front = front
        self.frontOrientation = frontOrientation
        self.mask = mask
        self.maskOrientation = maskOrientation
    }
}

/// Converts Apple image types at one strict boundary, then delegates all blend
/// and crop math to `FrontImageCompositor`. It never draws, fills, or retouches
/// foreground pixels: the core's only foreground input is `front`.
public enum AppleImageCompositor {
    /// Produces an opaque, lossless sRGB `CGImage` suitable for either preview
    /// or a later PNG/JPEG export. The returned pixels are deterministic for a
    /// fixed input image, orientation, mask, and background.
    @available(macOS 10.15, iOS 13, *)
    public static func compose(
        _ input: AppleImageCompositionInput,
        cancellationProbe: @escaping CompositionCancellationProbe = { Task<Never, Never>.isCancelled }
    ) throws -> CGImage {
        try checkCancellation(cancellationProbe)
        let front = try decodeRGBA(input.front, orientation: input.frontOrientation, cancellationProbe: cancellationProbe)
        let mask = try decodeMask(input.mask, orientation: input.maskOrientation, cancellationProbe: cancellationProbe)
        let background = try decodeRGBA(input.background, orientation: input.backgroundOrientation, cancellationProbe: cancellationProbe)
        let raster = try FrontImageCompositor.compose(
            .init(front: front, mask: mask, background: background),
            cancellationProbe: cancellationProbe
        )
        try checkCancellation(cancellationProbe)
        return try makeSRGBImage(from: raster, alphaInfo: .noneSkipLast)
    }

    /// Preview and final output intentionally share the exact lossless render
    /// path so users compare the same pixels they can later approve for export.
    @available(macOS 10.15, iOS 13, *)
    public static func renderPreview(
        _ input: AppleImageCompositionInput,
        cancellationProbe: @escaping CompositionCancellationProbe = { Task<Never, Never>.isCancelled }
    ) throws -> CGImage {
        try compose(input, cancellationProbe: cancellationProbe)
    }

    @available(macOS 10.15, iOS 13, *)
    public static func renderOutput(
        _ input: AppleImageCompositionInput,
        cancellationProbe: @escaping CompositionCancellationProbe = { Task<Never, Never>.isCancelled }
    ) throws -> CGImage {
        try compose(input, cancellationProbe: cancellationProbe)
    }

    /// Returns a straight-alpha sRGB image suitable for the non-approvable
    /// transparent preview. The adapter normalizes orientation and color space,
    /// then preserves every normalized front RGB byte while using only mask
    /// coverage for alpha. No background generation is involved.
    @available(macOS 10.15, iOS 13, *)
    public static func renderTransparentCutout(
        _ input: AppleTransparentCutoutInput,
        cancellationProbe: @escaping CompositionCancellationProbe = { Task<Never, Never>.isCancelled }
    ) throws -> CGImage {
        try checkCancellation(cancellationProbe)
        let front = try decodeRGBA(
            input.front,
            orientation: input.frontOrientation,
            cancellationProbe: cancellationProbe
        )
        let mask = try decodeMask(
            input.mask,
            orientation: input.maskOrientation,
            cancellationProbe: cancellationProbe
        )
        let raster = try FrontImageCompositor.makeTransparentCutout(
            .init(front: front, mask: mask),
            cancellationProbe: cancellationProbe
        )
        try checkCancellation(cancellationProbe)
        return try makeSRGBImage(from: raster, alphaInfo: .last)
    }

    private static func decodeRGBA(
        _ image: CGImage,
        orientation: RasterOrientation,
        cancellationProbe: CompositionCancellationProbe
    ) throws -> RGBA8Raster {
        guard orientation != .unsupported else { throw CompositionError.unsupportedOrientation }
        guard image.width > 0, image.height > 0 else { throw CompositionError.zeroDimensions }
        guard image.colorSpace?.model == .rgb else {
            throw CompositionError.unsupportedRasterColorSpace
        }
        let pixels = try renderRGBA(image, cancellationProbe: cancellationProbe)
        guard pixels.enumerated().allSatisfy({ $0.offset % 4 != 3 || $0.element == 255 }) else {
            throw CompositionError.nonOpaqueRaster
        }
        return .init(width: image.width, height: image.height, pixels: pixels, orientation: orientation, colorSpace: .sRGB)
    }

    private static func decodeMask(
        _ image: CGImage,
        orientation: RasterOrientation,
        cancellationProbe: CompositionCancellationProbe
    ) throws -> Mask8Raster {
        guard orientation != .unsupported else { throw CompositionError.unsupportedOrientation }
        guard image.width > 0, image.height > 0 else { throw CompositionError.zeroDimensions }
        // `kCGImageAlphaOnly` is not imported as a Swift enum case on every
        // Apple SDK, but its Core Graphics bitmap flag is stable.
        let alphaOnly = image.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue == 7
        guard alphaOnly || image.colorSpace?.model == .monochrome else {
            throw CompositionError.unsupportedMaskColorSpace
        }
        let rgba = try renderRGBA(image, cancellationProbe: cancellationProbe)
        var pixels = [UInt8]()
        pixels.reserveCapacity(try expectedByteCount(width: image.width, height: image.height, channels: 1, error: .invalidMaskByteCount))
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            try checkCancellation(cancellationProbe)
            pixels.append(alphaOnly ? rgba[offset + 3] : rgba[offset])
        }
        return .init(width: image.width, height: image.height, pixels: pixels, orientation: orientation, colorSpace: alphaOnly ? .alpha8 : .grayscale8)
    }

    private static func renderRGBA(_ image: CGImage, cancellationProbe: CompositionCancellationProbe) throws -> [UInt8] {
        try checkCancellation(cancellationProbe)
        let byteCount = try expectedByteCount(width: image.width, height: image.height, channels: 4, error: .invalidRGBAByteCount)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard let context = bytes.withUnsafeMutableBytes({ raw in
            CGContext(
                data: raw.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }) else { throw CompositionError.invalidRGBAByteCount }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        try checkCancellation(cancellationProbe)
        return bytes
    }

    private static func makeSRGBImage(
        from raster: RGBA8Raster,
        alphaInfo: CGImageAlphaInfo
    ) throws -> CGImage {
        let expected = try expectedByteCount(width: raster.width, height: raster.height, channels: 4, error: .invalidRGBAByteCount)
        guard raster.pixels.count == expected,
              let provider = CGDataProvider(data: Data(raster.pixels) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw CompositionError.invalidRGBAByteCount
        }
        guard let image = CGImage(
            width: raster.width,
            height: raster.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: raster.width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { throw CompositionError.invalidRGBAByteCount }
        return image
    }

    private static func expectedByteCount(width: Int, height: Int, channels: Int, error: CompositionError) throws -> Int {
        guard width > 0, height > 0 else { throw CompositionError.zeroDimensions }
        let (area, areaOverflow) = width.multipliedReportingOverflow(by: height)
        let (count, countOverflow) = area.multipliedReportingOverflow(by: channels)
        guard !areaOverflow, !countOverflow else { throw error }
        return count
    }

    private static func checkCancellation(_ probe: CompositionCancellationProbe) throws {
        if probe() { throw CompositionError.cancelled }
    }
}
