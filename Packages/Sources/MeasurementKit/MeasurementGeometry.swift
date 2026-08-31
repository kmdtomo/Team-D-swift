import DomainKit

/// Pixel dimensions of the upright, perspective-corrected measurement image.
public struct CorrectedMeasurementImageSize: Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw MeasurementGeometryError.invalidImageSize }
        self.width = width
        self.height = height
    }
}

/// The two semantically fixed garment measurements expressed in corrected-image coordinates.
/// `length` is back collar-center to hem-center; `width` is the flat left-to-right underarm line.
public struct MeasurementGeometryEndpoints: Hashable, Sendable {
    public let lengthStart: SessionNormalizedPoint
    public let lengthEnd: SessionNormalizedPoint
    public let widthStart: SessionNormalizedPoint
    public let widthEnd: SessionNormalizedPoint

    public init(lengthStart: SessionNormalizedPoint, lengthEnd: SessionNormalizedPoint, widthStart: SessionNormalizedPoint, widthEnd: SessionNormalizedPoint) {
        self.lengthStart = lengthStart
        self.lengthEnd = lengthEnd
        self.widthStart = widthStart
        self.widthEnd = widthEnd
    }
}

public struct MeasurementGeometryResult: Hashable, Sendable {
    public let length: SessionMeasurementLine
    public let width: SessionMeasurementLine

    public init(length: SessionMeasurementLine, width: SessionMeasurementLine) {
        self.length = length
        self.width = width
    }
}

public enum MeasurementGeometryError: Error, Equatable, Sendable {
    case invalidImageSize
    case invalidScale
    case invalidCalculation
    case zeroOrTooShortLength
    case zeroOrTooShortWidth
}

/// Deterministic geometry for a perspective-corrected measurement image.
public enum MeasurementGeometry {
    /// Calculates flat garment length and width in centimeters.
    ///
    /// Values are rounded to the nearest 0.1 cm. Exact positive half-tenth ties are rounded
    /// away from zero (for example, 1.05 cm becomes 1.1 cm); this rule is explicit so the
    /// displayed and session-held measurement cannot silently drift with a platform rounding mode.
    public static func calculate(endpoints: MeasurementGeometryEndpoints, imageSize: CorrectedMeasurementImageSize, pixelsPerCentimeter: Double) throws -> MeasurementGeometryResult {
        guard pixelsPerCentimeter.isFinite, pixelsPerCentimeter > 0 else { throw MeasurementGeometryError.invalidScale }
        let length = try measurementLine(start: endpoints.lengthStart, end: endpoints.lengthEnd, imageSize: imageSize, pixelsPerCentimeter: pixelsPerCentimeter, tooShortError: .zeroOrTooShortLength)
        let width = try measurementLine(start: endpoints.widthStart, end: endpoints.widthEnd, imageSize: imageSize, pixelsPerCentimeter: pixelsPerCentimeter, tooShortError: .zeroOrTooShortWidth)
        return MeasurementGeometryResult(length: length, width: width)
    }

    private static func measurementLine(start: SessionNormalizedPoint, end: SessionNormalizedPoint, imageSize: CorrectedMeasurementImageSize, pixelsPerCentimeter: Double, tooShortError: MeasurementGeometryError) throws -> SessionMeasurementLine {
        let deltaX = (end.x - start.x) * Double(imageSize.width)
        let deltaY = (end.y - start.y) * Double(imageSize.height)
        let pixels = euclideanDistance(deltaX: deltaX, deltaY: deltaY)
        let centimeters = pixels / pixelsPerCentimeter
        guard centimeters.isFinite else { throw MeasurementGeometryError.invalidCalculation }
        let roundedCentimeters = roundedToNearestTenthTiesAwayFromZero(centimeters)
        guard roundedCentimeters.isFinite else { throw MeasurementGeometryError.invalidCalculation }
        guard roundedCentimeters > 0 else { throw tooShortError }
        do {
            return try SessionMeasurementLine(start: start, end: end, centimeters: roundedCentimeters)
        } catch {
            throw MeasurementGeometryError.invalidCalculation
        }
    }

    private static func euclideanDistance(deltaX: Double, deltaY: Double) -> Double {
        let largestComponent = max(abs(deltaX), abs(deltaY))
        guard largestComponent > 0 else { return 0 }
        let scaledX = deltaX / largestComponent
        let scaledY = deltaY / largestComponent
        return largestComponent * (scaledX * scaledX + scaledY * scaledY).squareRoot()
    }

    /// Positive centimeter values use nearest-tenth rounding with half-ties away from zero.
    private static func roundedToNearestTenthTiesAwayFromZero(_ centimeters: Double) -> Double {
        (centimeters * 10).rounded(.toNearestOrAwayFromZero) / 10
    }
}
