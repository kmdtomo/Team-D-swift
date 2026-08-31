import CoreGraphics
import DomainKit
import Foundation

/// The four semantic points a person can correct on the rectified measurement image.
public enum MeasurementEndpoint: CaseIterable, Hashable, Sendable {
    case lengthStart
    case lengthEnd
    case widthStart
    case widthEnd

    public var accessibilityLabel: String {
        switch self {
        case .lengthStart: "着丈の開始点"
        case .lengthEnd: "着丈の終了点"
        case .widthStart: "身幅の左端"
        case .widthEnd: "身幅の右端"
        }
    }

    /// VoiceOver adjustments follow the meaningful axis of each measurement line.
    /// This keeps width endpoints independently correctable without requiring a drag.
    public var accessibilityAdjustmentAxis: MeasurementEndpointAccessibilityAxis {
        switch self {
        case .lengthStart, .lengthEnd: .vertical
        case .widthStart, .widthEnd: .horizontal
        }
    }

    public var accessibilityAdjustmentHint: String {
        switch accessibilityAdjustmentAxis {
        case .vertical:
            "上スワイプで上へ、下スワイプで下へ微調整します。"
        case .horizontal:
            "上スワイプで右へ、下スワイプで左へ微調整します。"
        }
    }
}

public enum MeasurementEndpointAccessibilityAxis: Equatable, Sendable {
    case vertical
    case horizontal
}

/// A deliberately small VoiceOver adjustment along an endpoint's meaningful measurement axis.
public enum MeasurementEndpointAccessibilityAdjustment: Equatable, Sendable {
    case increment
    case decrement
}

/// Maps corrected-image normalized coordinates to an aspect-fit image that can be zoomed
/// and panned inside a SwiftUI viewport. It is independent of SwiftUI so its round trips
/// remain deterministic in focused tests.
public struct MeasurementImageCoordinateMapper: Equatable {
    public enum Error: Swift.Error, Equatable {
        case invalidViewport
        case invalidZoom
        case pointOutsideImage
    }

    public let imageSize: CorrectedMeasurementImageSize
    public let viewportSize: CGSize
    public let zoom: CGFloat
    public let pan: CGSize

    public init(
        imageSize: CorrectedMeasurementImageSize,
        viewportSize: CGSize,
        zoom: CGFloat = 1,
        pan: CGSize = .zero
    ) throws {
        guard viewportSize.width.isFinite, viewportSize.height.isFinite,
              viewportSize.width > 0, viewportSize.height > 0 else {
            throw Error.invalidViewport
        }
        guard zoom.isFinite, zoom >= 1 else { throw Error.invalidZoom }
        self.imageSize = imageSize
        self.viewportSize = viewportSize
        self.zoom = zoom
        self.pan = pan
    }

    /// The visible rect of the corrected image after aspect-fit, zoom, and pan.
    public var imageFrame: CGRect {
        let fit = min(
            viewportSize.width / CGFloat(imageSize.width),
            viewportSize.height / CGFloat(imageSize.height)
        )
        let size = CGSize(
            width: CGFloat(imageSize.width) * fit * zoom,
            height: CGFloat(imageSize.height) * fit * zoom
        )
        return CGRect(
            x: (viewportSize.width - size.width) / 2 + pan.width,
            y: (viewportSize.height - size.height) / 2 + pan.height,
            width: size.width,
            height: size.height
        )
    }

    public func viewPoint(for normalizedPoint: SessionNormalizedPoint) -> CGPoint {
        CGPoint(
            x: imageFrame.minX + CGFloat(normalizedPoint.x) * imageFrame.width,
            y: imageFrame.minY + CGFloat(normalizedPoint.y) * imageFrame.height
        )
    }

    /// Converts a point in the editor viewport to corrected-image coordinates.
    /// Points outside the displayed image are rejected rather than silently accepted.
    public func normalizedPoint(for viewPoint: CGPoint) throws -> SessionNormalizedPoint {
        guard viewPoint.x.isFinite, viewPoint.y.isFinite,
              viewPoint.x >= imageFrame.minX, viewPoint.x <= imageFrame.maxX,
              viewPoint.y >= imageFrame.minY, viewPoint.y <= imageFrame.maxY else {
            throw Error.pointOutsideImage
        }
        return try SessionNormalizedPoint(
            x: Double((viewPoint.x - imageFrame.minX) / imageFrame.width),
            y: Double((viewPoint.y - imageFrame.minY) / imageFrame.height)
        )
    }

    /// Dragging beyond the image edge leaves the endpoint on the nearest valid edge.
    public func clampedNormalizedPoint(for viewPoint: CGPoint) throws -> SessionNormalizedPoint {
        let x = min(max(viewPoint.x, imageFrame.minX), imageFrame.maxX)
        let y = min(max(viewPoint.y, imageFrame.minY), imageFrame.maxY)
        return try normalizedPoint(for: CGPoint(x: x, y: y))
    }
}

/// Mutable, UI-owned endpoint and explicit approval state.
public struct MeasurementEndpointEditor: Equatable {
    public private(set) var endpoints: MeasurementGeometryEndpoints
    public private(set) var measurements: MeasurementGeometryResult
    public private(set) var status: MeasurementStatus

    private var pendingRangeConfirmation: MeasurementRangeConfirmation?
    private var approvedSnapshot: MeasurementApprovalSnapshot?

    public let imageSize: CorrectedMeasurementImageSize
    public let pixelsPerCentimeter: Double

    public init(
        endpoints: MeasurementGeometryEndpoints,
        imageSize: CorrectedMeasurementImageSize,
        pixelsPerCentimeter: Double
    ) throws {
        self.endpoints = endpoints
        self.imageSize = imageSize
        self.pixelsPerCentimeter = pixelsPerCentimeter
        self.measurements = try MeasurementGeometry.calculate(
            endpoints: endpoints,
            imageSize: imageSize,
            pixelsPerCentimeter: pixelsPerCentimeter
        )
        // Every draft, including one reconstructed from an earlier result, starts pending.
        self.status = .needsReview
        self.pendingRangeConfirmation = nil
        self.approvedSnapshot = nil
    }

    public func point(for endpoint: MeasurementEndpoint) -> SessionNormalizedPoint {
        switch endpoint {
        case .lengthStart: endpoints.lengthStart
        case .lengthEnd: endpoints.lengthEnd
        case .widthStart: endpoints.widthStart
        case .widthEnd: endpoints.widthEnd
        }
    }

    /// Stable VoiceOver value for an endpoint. It deliberately describes the pending
    /// measurement state rather than transient drag or zoom coordinates.
    public func accessibilityValue(for endpoint: MeasurementEndpoint) -> String {
        let approval = status == .approvedCV ? "承認済み" : "承認待ち"
        switch endpoint {
        case .lengthStart, .lengthEnd:
            "着丈 \(measurements.length.centimeters, format: .number.precision(.fractionLength(1))) cm、\(approval)"
        case .widthStart, .widthEnd:
            "身幅 \(measurements.width.centimeters, format: .number.precision(.fractionLength(1))) cm、\(approval)"
        }
    }

    @discardableResult
    public mutating func update(
        _ endpoint: MeasurementEndpoint,
        to point: SessionNormalizedPoint
    ) throws -> MeasurementGeometryResult {
        let updated = replacing(endpoint, with: point)
        let recalculated = try MeasurementGeometry.calculate(
            endpoints: updated,
            imageSize: imageSize,
            pixelsPerCentimeter: pixelsPerCentimeter
        )
        endpoints = updated
        measurements = recalculated
        invalidateApproval()
        return recalculated
    }

    @discardableResult
    public mutating func update(
        _ endpoint: MeasurementEndpoint,
        fromViewPoint point: CGPoint,
        mapper: MeasurementImageCoordinateMapper
    ) throws -> MeasurementGeometryResult {
        try update(endpoint, to: mapper.clampedNormalizedPoint(for: point))
    }

    @discardableResult
    public mutating func adjust(
        _ endpoint: MeasurementEndpoint,
        by adjustment: MeasurementEndpointAccessibilityAdjustment,
        step: Double = 0.005
    ) throws -> MeasurementGeometryResult {
        precondition(step.isFinite && step > 0, "Accessibility adjustment step must be positive and finite")
        let current = point(for: endpoint)
        let updated: SessionNormalizedPoint
        switch endpoint.accessibilityAdjustmentAxis {
        case .vertical:
            // VoiceOver increment maps to moving upward in image coordinates.
            let signedStep = adjustment == .increment ? -step : step
            updated = try SessionNormalizedPoint(
                x: current.x,
                y: min(max(current.y + signedStep, 0), 1)
            )
        case .horizontal:
            // VoiceOver increment maps to moving right in image coordinates.
            let signedStep = adjustment == .increment ? step : -step
            updated = try SessionNormalizedPoint(
                x: min(max(current.x + signedStep, 0), 1),
                y: current.y
            )
        }
        return try update(endpoint, to: updated)
    }

    /// The first explicit approval operation. In-range values approve immediately;
    /// out-of-range values produce a confirmation bound to the current lines and values.
    @discardableResult
    public mutating func requestCVApproval(
        garmentPolygon: CorrectedMeasurementGarmentPolygon
    ) -> MeasurementCVApprovalOutcome {
        let validation = MeasurementEndpointValidator.validate(
            endpoints: endpoints,
            imageSize: imageSize,
            garmentPolygon: garmentPolygon
        )
        guard validation.isValid else {
            invalidateApproval()
            return .blocked(
                failure: .endpointsInvalid,
                invalidEndpoints: validation.invalidEndpoints
            )
        }

        let snapshot = approvalSnapshot(garmentPolygon: garmentPolygon)
        if status == .approvedCV, approvedSnapshot == snapshot {
            return .alreadyApproved
        }

        status = .needsReview
        approvedSnapshot = nil
        let warning = MeasurementRangeWarning(measurements: measurements)
        guard warning.requiresConfirmation else {
            pendingRangeConfirmation = nil
            return approve(snapshot: snapshot)
        }

        let confirmation = MeasurementRangeConfirmation(
            warning: warning,
            snapshot: snapshot
        )
        pendingRangeConfirmation = confirmation
        return .requiresRangeConfirmation(confirmation)
    }

    /// The second explicit operation for a warning value. A token issued before
    /// an edit, cancellation, or contour change cannot approve the current draft.
    @discardableResult
    public mutating func confirmCVApproval(
        _ confirmation: MeasurementRangeConfirmation,
        garmentPolygon: CorrectedMeasurementGarmentPolygon
    ) -> MeasurementCVApprovalOutcome {
        guard pendingRangeConfirmation == confirmation else {
            return .staleConfirmation
        }

        let currentSnapshot = approvalSnapshot(garmentPolygon: garmentPolygon)
        guard confirmation.snapshot == currentSnapshot else {
            invalidateApproval()
            return .staleConfirmation
        }

        let validation = MeasurementEndpointValidator.validate(
            endpoints: endpoints,
            imageSize: imageSize,
            garmentPolygon: garmentPolygon
        )
        guard validation.isValid else {
            invalidateApproval()
            return .blocked(
                failure: .endpointsInvalid,
                invalidEndpoints: validation.invalidEndpoints
            )
        }

        let currentWarning = MeasurementRangeWarning(measurements: measurements)
        guard currentWarning.requiresConfirmation,
              currentWarning == confirmation.warning else {
            invalidateApproval()
            return .staleConfirmation
        }
        pendingRangeConfirmation = nil
        return approve(snapshot: currentSnapshot)
    }

    /// Cancels only the matching visible warning. A stale dialog cannot clear a
    /// newer confirmation.
    @discardableResult
    public mutating func cancelCVApproval(
        _ confirmation: MeasurementRangeConfirmation
    ) -> Bool {
        guard pendingRangeConfirmation == confirmation else { return false }
        invalidateApproval()
        return true
    }

    private mutating func approve(
        snapshot: MeasurementApprovalSnapshot
    ) -> MeasurementCVApprovalOutcome {
        status = .approvedCV
        approvedSnapshot = snapshot
        pendingRangeConfirmation = nil
        return .approved(event: .approveMeasurementCV)
    }

    private mutating func invalidateApproval() {
        status = .needsReview
        pendingRangeConfirmation = nil
        approvedSnapshot = nil
    }

    private func approvalSnapshot(
        garmentPolygon: CorrectedMeasurementGarmentPolygon
    ) -> MeasurementApprovalSnapshot {
        MeasurementApprovalSnapshot(
            endpoints: endpoints,
            measurements: measurements,
            imageSize: imageSize,
            pixelsPerCentimeter: pixelsPerCentimeter,
            garmentPolygon: garmentPolygon.points
        )
    }

    private func replacing(
        _ endpoint: MeasurementEndpoint,
        with point: SessionNormalizedPoint
    ) -> MeasurementGeometryEndpoints {
        switch endpoint {
        case .lengthStart:
            MeasurementGeometryEndpoints(lengthStart: point, lengthEnd: endpoints.lengthEnd, widthStart: endpoints.widthStart, widthEnd: endpoints.widthEnd)
        case .lengthEnd:
            MeasurementGeometryEndpoints(lengthStart: endpoints.lengthStart, lengthEnd: point, widthStart: endpoints.widthStart, widthEnd: endpoints.widthEnd)
        case .widthStart:
            MeasurementGeometryEndpoints(lengthStart: endpoints.lengthStart, lengthEnd: endpoints.lengthEnd, widthStart: point, widthEnd: endpoints.widthEnd)
        case .widthEnd:
            MeasurementGeometryEndpoints(lengthStart: endpoints.lengthStart, lengthEnd: endpoints.lengthEnd, widthStart: endpoints.widthStart, widthEnd: point)
        }
    }
}
