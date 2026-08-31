import Foundation
import DomainKit

/// Insets reserved for system UI. The camera preview may remain full-bleed,
/// while fixed guide geometry stays inside this safe region.
public struct GuideSafeAreaInsets: Equatable, Sendable {
    public let top: Double; public let leading: Double; public let bottom: Double; public let trailing: Double
    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) throws {
        guard [top, leading, bottom, trailing].allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw FixedGuideError.invalidInsets }
        self.top = top; self.leading = leading; self.bottom = bottom; self.trailing = trailing
    }
}

/// A finite rectangle in preview-layer points, deliberately distinct from image coordinates.
public struct PreviewGuideRect: Equatable, Sendable {
    public let x: Double; public let y: Double; public let width: Double; public let height: Double
    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { throw FixedGuideError.invalidRect }
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var maxX: Double { x + width }; public var maxY: Double { y + height }
    func intersection(with other: Self) throws -> Self? {
        let minX = max(x, other.x), minY = max(y, other.y), maxX = min(maxX, other.maxX), maxY = min(maxY, other.maxY)
        guard maxX > minX, maxY > minY else { return nil }
        return try Self(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// A closed upright-image ROI, sharing T05-02's normalized-coordinate contract.
public struct NormalizedImageROI: Equatable, Sendable {
    public let topLeading: NormalizedImagePoint; public let bottomTrailing: NormalizedImagePoint
    public init(topLeading: NormalizedImagePoint, bottomTrailing: NormalizedImagePoint) throws {
        guard bottomTrailing.x > topLeading.x, bottomTrailing.y > topLeading.y else { throw FixedGuideError.invalidROI }
        self.topLeading = topLeading; self.bottomTrailing = bottomTrailing
    }
}

public enum FixedGuideError: Error, Equatable, Sendable { case invalidInsets, safeAreaConsumesPreview, invalidRect, guideOutsideVisibleImage, invalidROI }
public enum FixedGuideKind: Equatable, Sendable { case garment, tag, markerPlacement50mm }
public struct FixedGuideRegion: Equatable, Sendable { public let kind: FixedGuideKind; public let previewRect: PreviewGuideRect; public let uprightImageROI: NormalizedImageROI }

/// Explicitly changes when callers must reset local-quality/stability history.
public struct FixedGuideLayoutKey: Equatable, Sendable {
    public let shot: Shot; public let previewSize: ImageSize; public let safeAreaInsets: GuideSafeAreaInsets; public let imageSize: ImageSize; public let uprightOrientation: ImageEXIFOrientation; public let contentMode: PreviewContentMode
    public init(shot: Shot, previewSize: ImageSize, safeAreaInsets: GuideSafeAreaInsets, imageSize: ImageSize, uprightOrientation: ImageEXIFOrientation, contentMode: PreviewContentMode) {
        self.shot = shot; self.previewSize = previewSize; self.safeAreaInsets = safeAreaInsets; self.imageSize = imageSize; self.uprightOrientation = uprightOrientation; self.contentMode = contentMode
    }
}

public struct FixedGuideLayout: Equatable, Sendable {
    public let key: FixedGuideLayoutKey; public let primary: FixedGuideRegion; public let markerPlacement: FixedGuideRegion?

    /// This is preview geometry only: no `CapturedPhoto` bytes can enter this API.
    public init(shot: Shot, previewGeometry: PreviewImageGeometry, uprightOrientation: ImageEXIFOrientation, safeAreaInsets: GuideSafeAreaInsets) throws {
        key = .init(shot: shot, previewSize: previewGeometry.previewSize, safeAreaInsets: safeAreaInsets, imageSize: previewGeometry.imageSize, uprightOrientation: uprightOrientation, contentMode: previewGeometry.contentMode)
        let safeRect = try Self.safeRect(size: previewGeometry.previewSize, insets: safeAreaInsets)
        let visibleImageRect = try PreviewGuideRect(
            x: max(0, previewGeometry.contentOriginX), y: max(0, previewGeometry.contentOriginY),
            width: min(previewGeometry.previewSize.width, previewGeometry.contentOriginX + previewGeometry.contentSize.width) - max(0, previewGeometry.contentOriginX),
            height: min(previewGeometry.previewSize.height, previewGeometry.contentOriginY + previewGeometry.contentSize.height) - max(0, previewGeometry.contentOriginY)
        )
        guard let available = try safeRect.intersection(with: visibleImageRect) else { throw FixedGuideError.guideOutsideVisibleImage }
        switch shot {
        case .front, .back:
            primary = try Self.region(kind: .garment, fraction: (0.10, 0.11, 0.80, 0.78), in: available, geometry: previewGeometry); markerPlacement = nil
        case .tag:
            primary = try Self.region(kind: .tag, fraction: (0.19, 0.26, 0.62, 0.48), in: available, geometry: previewGeometry); markerPlacement = nil
        case .measurement:
            primary = try Self.region(kind: .garment, fraction: (0.07, 0.08, 0.67, 0.82), in: available, geometry: previewGeometry)
            markerPlacement = try Self.region(kind: .markerPlacement50mm, fraction: (0.77, 0.69, 0.16, 0.16), in: available, geometry: previewGeometry)
        }
    }

    private static func safeRect(size: ImageSize, insets: GuideSafeAreaInsets) throws -> PreviewGuideRect {
        let width = size.width - insets.leading - insets.trailing, height = size.height - insets.top - insets.bottom
        guard width > 0, height > 0 else { throw FixedGuideError.safeAreaConsumesPreview }
        return try PreviewGuideRect(x: insets.leading, y: insets.top, width: width, height: height)
    }
    private static func region(kind: FixedGuideKind, fraction: (Double, Double, Double, Double), in available: PreviewGuideRect, geometry: PreviewImageGeometry) throws -> FixedGuideRegion {
        let rect = try PreviewGuideRect(x: available.x + available.width * fraction.0, y: available.y + available.height * fraction.1, width: available.width * fraction.2, height: available.height * fraction.3)
        guard let topLeading = try geometry.normalizedPoint(previewX: rect.x, previewY: rect.y), let bottomTrailing = try geometry.normalizedPoint(previewX: rect.maxX, previewY: rect.maxY) else { throw FixedGuideError.guideOutsideVisibleImage }
        return .init(kind: kind, previewRect: rect, uprightImageROI: try .init(topLeading: topLeading, bottomTrailing: bottomTrailing))
    }
}
