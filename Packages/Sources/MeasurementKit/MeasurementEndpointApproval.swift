import DomainKit
import Foundation

/// Garment boundary after the same perspective correction used by the endpoint
/// editor. A dedicated type prevents an upright pre-correction contour from being
/// compared with corrected-image endpoint coordinates by accident.
public struct CorrectedMeasurementGarmentPolygon: Equatable, Sendable {
    public let points: [MeasurementPixelPoint]

    public init(points: [MeasurementPixelPoint]) {
        self.points = points
    }
}

/// The fixed T13-02 endpoint contract in corrected-image pixel coordinates.
/// An endpoint is accepted when it lies in the garment polygon or no farther
/// than two percent of the corrected image's shorter side from its boundary.
public enum MeasurementEndpointValidator {
    public static let garmentBoundaryToleranceFraction = 0.02

    public static func validate(
        endpoints: MeasurementGeometryEndpoints,
        imageSize: CorrectedMeasurementImageSize,
        garmentPolygon: CorrectedMeasurementGarmentPolygon
    ) -> MeasurementEndpointValidationResult {
        let polygon = garmentPolygon.points
        guard isUsablePolygon(polygon, imageSize: imageSize) else {
            return MeasurementEndpointValidationResult(
                invalidEndpoints: Set(MeasurementEndpoint.allCases)
            )
        }

        let tolerance = Double(min(imageSize.width, imageSize.height))
            * garmentBoundaryToleranceFraction
        let invalidEndpoints = Set(MeasurementEndpoint.allCases.filter { endpoint in
            let point = pixelPoint(
                for: point(for: endpoint, in: endpoints),
                imageSize: imageSize
            )
            guard isInsideImage(point, imageSize: imageSize) else { return true }
            return !contains(point, in: polygon, boundaryTolerance: tolerance)
        })
        return MeasurementEndpointValidationResult(invalidEndpoints: invalidEndpoints)
    }

    private static func point(
        for endpoint: MeasurementEndpoint,
        in endpoints: MeasurementGeometryEndpoints
    ) -> SessionNormalizedPoint {
        switch endpoint {
        case .lengthStart: endpoints.lengthStart
        case .lengthEnd: endpoints.lengthEnd
        case .widthStart: endpoints.widthStart
        case .widthEnd: endpoints.widthEnd
        }
    }

    private static func pixelPoint(
        for point: SessionNormalizedPoint,
        imageSize: CorrectedMeasurementImageSize
    ) -> MeasurementPixelPoint {
        MeasurementPixelPoint(
            x: point.x * Double(imageSize.width),
            y: point.y * Double(imageSize.height)
        )
    }

    private static func isInsideImage(
        _ point: MeasurementPixelPoint,
        imageSize: CorrectedMeasurementImageSize
    ) -> Bool {
        point.isFinite
            && point.x >= 0
            && point.x <= Double(imageSize.width)
            && point.y >= 0
            && point.y <= Double(imageSize.height)
    }

    private static func isUsablePolygon(
        _ polygon: [MeasurementPixelPoint],
        imageSize: CorrectedMeasurementImageSize
    ) -> Bool {
        guard polygon.count >= 3,
              polygon.allSatisfy({ isInsideImage($0, imageSize: imageSize) }) else {
            return false
        }
        var signedDoubleArea = 0.0
        for index in polygon.indices {
            let current = polygon[index]
            let next = polygon[(index + 1) % polygon.count]
            signedDoubleArea += current.x * next.y - next.x * current.y
        }
        return signedDoubleArea.isFinite && abs(signedDoubleArea) > 0.000_001
    }

    private static func contains(
        _ point: MeasurementPixelPoint,
        in polygon: [MeasurementPixelPoint],
        boundaryTolerance: Double
    ) -> Bool {
        var isInside = false
        var minimumBoundaryDistance = Double.infinity
        for index in polygon.indices {
            let start = polygon[index]
            let end = polygon[(index + 1) % polygon.count]
            minimumBoundaryDistance = min(
                minimumBoundaryDistance,
                pointToSegmentDistance(point, start: start, end: end)
            )
            let crosses = (start.y > point.y) != (end.y > point.y)
            if crosses {
                let intersectionX = (end.x - start.x) * (point.y - start.y)
                    / (end.y - start.y) + start.x
                if point.x < intersectionX { isInside.toggle() }
            }
        }
        return isInside || minimumBoundaryDistance <= boundaryTolerance
    }

    private static func pointToSegmentDistance(
        _ point: MeasurementPixelPoint,
        start: MeasurementPixelPoint,
        end: MeasurementPixelPoint
    ) -> Double {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let squaredLength = deltaX * deltaX + deltaY * deltaY
        guard squaredLength > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let projection = max(
            0,
            min(
                1,
                ((point.x - start.x) * deltaX + (point.y - start.y) * deltaY)
                    / squaredLength
            )
        )
        let closestX = start.x + projection * deltaX
        let closestY = start.y + projection * deltaY
        return hypot(point.x - closestX, point.y - closestY)
    }
}

public struct MeasurementEndpointValidationResult: Equatable, Sendable {
    public let invalidEndpoints: Set<MeasurementEndpoint>

    public init(invalidEndpoints: Set<MeasurementEndpoint>) {
        self.invalidEndpoints = invalidEndpoints
    }

    public var isValid: Bool { invalidEndpoints.isEmpty }

    public var failure: MeasurementFailure? {
        isValid ? nil : .endpointsInvalid
    }
}

public enum MeasurementRange: String, CaseIterable, Hashable, Sendable {
    case length
    case width
}

/// Inclusive product ranges. Values outside these ranges remain approvable only
/// through the warning-confirmation operation.
public struct MeasurementRangeWarning: Equatable, Sendable {
    public static let acceptedLengthCentimeters = 20.0 ... 100.0
    public static let acceptedWidthCentimeters = 20.0 ... 80.0

    public let outOfRangeMeasurements: Set<MeasurementRange>
    public let lengthCentimeters: Double
    public let widthCentimeters: Double

    public init(measurements: MeasurementGeometryResult) {
        var outOfRange: Set<MeasurementRange> = []
        if !Self.acceptedLengthCentimeters.contains(measurements.length.centimeters) {
            outOfRange.insert(.length)
        }
        if !Self.acceptedWidthCentimeters.contains(measurements.width.centimeters) {
            outOfRange.insert(.width)
        }
        self.outOfRangeMeasurements = outOfRange
        self.lengthCentimeters = measurements.length.centimeters
        self.widthCentimeters = measurements.width.centimeters
    }

    public var requiresConfirmation: Bool { !outOfRangeMeasurements.isEmpty }
}

/// A warning confirmation is tied to one exact set of lines, displayed values,
/// corrected image, and garment polygon. It has no public initializer so callers
/// cannot manufacture a confirmation for a different draft.
public struct MeasurementRangeConfirmation: Equatable, Sendable {
    public let warning: MeasurementRangeWarning
    let snapshot: MeasurementApprovalSnapshot

    init(warning: MeasurementRangeWarning, snapshot: MeasurementApprovalSnapshot) {
        self.warning = warning
        self.snapshot = snapshot
    }
}

public enum MeasurementCVApprovalOutcome: Equatable, Sendable {
    case blocked(failure: MeasurementFailure, invalidEndpoints: Set<MeasurementEndpoint>)
    case requiresRangeConfirmation(MeasurementRangeConfirmation)
    case approved(event: WorkflowEvent)
    case alreadyApproved
    case staleConfirmation
}

struct MeasurementApprovalSnapshot: Equatable, Sendable {
    let endpoints: MeasurementGeometryEndpoints
    let measurements: MeasurementGeometryResult
    let imageSize: CorrectedMeasurementImageSize
    let pixelsPerCentimeter: Double
    let garmentPolygon: [MeasurementPixelPoint]
}
