#if os(iOS)
@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import UIKit

public extension AnalysisNormalizationPlan {
    /// This creates an analysis-only CIImage. It never encodes, writes, or
    /// mutates `originalFileData`; the captured JPEG remains the export source.
    func makeUprightAnalysisImage() -> CIImage? {
        guard let image = CIImage(data: originalFileData, options: [.applyOrientationProperty: false]) else { return nil }
        return image.oriented(forExifOrientation: Int32(exifOrientation.rawValue))
    }
}

public extension CaptureOrientationMapper {
    static func videoOrientation(interface: UIInterfaceOrientation) -> CaptureVideoOrientation? {
        switch interface {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: nil
        }
    }
}

/// Thin adapter around AVFoundation's coordinate conversion. It intentionally
/// delegates orientation handling to the configured preview-layer connection.
public struct AVFoundationPreviewCoordinateAdapter {
    public let previewLayer: AVCaptureVideoPreviewLayer
    public init(previewLayer: AVCaptureVideoPreviewLayer) { self.previewLayer = previewLayer }

    @discardableResult public func apply(previewRotation rotation: PreviewConnectionRotationAngle, to connection: AVCaptureConnection) -> Bool {
        apply(angle: rotation.degrees, to: connection)
    }

    @discardableResult public func apply(captureRotation rotation: CaptureConnectionRotationAngle, to connection: AVCaptureConnection) -> Bool {
        apply(angle: rotation.degrees, to: connection)
    }

    private func apply(angle: Double, to connection: AVCaptureConnection) -> Bool {
        guard connection.isVideoRotationAngleSupported(angle) else { return false }
        connection.videoRotationAngle = angle
        return true
    }

    public func previewPoint(captureDevicePoint: CaptureDeviceNormalizedPoint) -> CGPoint {
        previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: captureDevicePoint.x, y: captureDevicePoint.y))
    }

    public func captureDevicePoint(previewPoint: CGPoint) throws -> CaptureDeviceNormalizedPoint? {
        guard previewPoint.x.isFinite, previewPoint.y.isFinite else { throw OrientationCoordinateError.nonFinite }
        let point = previewLayer.captureDevicePointConverted(fromLayerPoint: previewPoint)
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        return try CaptureDeviceNormalizedPoint(x: point.x, y: point.y)
    }
}

/// Reads rotation independently for the display and recorded-photo paths.
/// The coordinator accounts for the active device, external cameras, horizon
/// level and preview layer; callers must not derive these angles from an
/// interface-orientation enum or reuse one value for both connections.
@available(iOS 17.0, *)
public final class AVFoundationRotationCoordinatorAdapter {
    private let coordinator: AVCaptureDevice.RotationCoordinator

    public init(device: AVCaptureDevice, previewLayer: AVCaptureVideoPreviewLayer) {
        coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
    }

    public func previewRotation() throws -> PreviewConnectionRotationAngle {
        try PreviewConnectionRotationAngle(degrees: Double(coordinator.videoRotationAngleForHorizonLevelPreview))
    }

    public func captureRotation() throws -> CaptureConnectionRotationAngle {
        try CaptureConnectionRotationAngle(degrees: Double(coordinator.videoRotationAngleForHorizonLevelCapture))
    }
}
#endif
