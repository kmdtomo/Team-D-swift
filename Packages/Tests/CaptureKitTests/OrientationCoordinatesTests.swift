import XCTest
@testable import CaptureKit

final class OrientationCoordinatesTests: XCTestCase {
    func testAllEXIFOrientationsMapKnownCornerAndRoundTrip() throws {
        let source = try NormalizedImagePoint(x: 0.25, y: 0.75)
        let expected: [ImageEXIFOrientation: NormalizedImagePoint] = [
            .up: try .init(x: 0.25, y: 0.75),
            .upMirrored: try .init(x: 0.75, y: 0.75),
            .down: try .init(x: 0.75, y: 0.25),
            .downMirrored: try .init(x: 0.25, y: 0.25),
            .leftMirrored: try .init(x: 0.75, y: 0.25),
            .right: try .init(x: 0.25, y: 0.25),
            .rightMirrored: try .init(x: 0.25, y: 0.75),
            .left: try .init(x: 0.75, y: 0.75),
        ]
        for orientation in ImageEXIFOrientation.allCases {
            let upright = try orientation.uprightPoint(fromEncoded: source)
            XCTAssertEqual(upright, expected[orientation], "EXIF \(orientation.rawValue)")
            XCTAssertEqual(try orientation.encodedPoint(fromUpright: upright), source, "EXIF \(orientation.rawValue) inverse")
            for corner in [
                try NormalizedImagePoint(x: 0, y: 0),
                try NormalizedImagePoint(x: 1, y: 0),
                try NormalizedImagePoint(x: 0, y: 1),
                try NormalizedImagePoint(x: 1, y: 1),
            ] {
                XCTAssertEqual(try orientation.encodedPoint(fromUpright: orientation.uprightPoint(fromEncoded: corner)), corner, "EXIF \(orientation.rawValue) corner round-trip")
            }
        }
        XCTAssertTrue(ImageEXIFOrientation.right.uprightSizeSwapsAxes)
        XCTAssertFalse(ImageEXIFOrientation.down.uprightSizeSwapsAxes)
    }

    func testOrientationMapperKeepsBackCameraUnmirroredAndMapsLandscape() {
        XCTAssertFalse(CaptureOrientationMapper.isMirrored(camera: .back))
        XCTAssertTrue(CaptureOrientationMapper.isMirrored(camera: .front))
        XCTAssertEqual(CaptureOrientationMapper.videoOrientation(interface: .landscapeLeft), .landscapeLeft)
        XCTAssertEqual(CaptureOrientationMapper.videoOrientation(device: .landscapeLeft), .landscapeRight)
        XCTAssertEqual(CaptureOrientationMapper.videoOrientation(device: .landscapeRight), .landscapeLeft)
        XCTAssertNil(CaptureOrientationMapper.videoOrientation(device: .faceUp))
        XCTAssertNil(CaptureOrientationMapper.videoOrientation(interface: .unknown))
        let previewAngle = try? PreviewConnectionRotationAngle(degrees: 0)
        let captureAngle = try? CaptureConnectionRotationAngle(degrees: 90)
        XCTAssertEqual(previewAngle?.degrees, 0)
        XCTAssertEqual(captureAngle?.degrees, 90, "preview and capture fixtures may differ")
        XCTAssertThrowsError(try PreviewConnectionRotationAngle(degrees: 45)) { XCTAssertEqual($0 as? OrientationCoordinateError, .unsupportedRotationAngle) }
    }

    func testAspectFillAndAspectFitCoordinatesAndRoundTrips() throws {
        let image = try ImageSize(width: 4, height: 3)
        let square = try ImageSize(width: 300, height: 300)
        let fill = try PreviewImageGeometry(imageSize: image, previewSize: square, contentMode: .aspectFill)
        XCTAssertEqual(fill.contentSize, try ImageSize(width: 400, height: 300))
        XCTAssertEqual(try fill.normalizedPoint(previewX: 0, previewY: 150), try .init(x: 0.125, y: 0.5))
        XCTAssertNil(fill.visiblePreviewPoint(normalized: try .init(x: 0, y: 0.5)), "cropped image edge has no on-screen overlay point")

        let fit = try PreviewImageGeometry(imageSize: image, previewSize: square, contentMode: .aspectFit)
        XCTAssertEqual(fit.contentSize, try ImageSize(width: 300, height: 225))
        XCTAssertNil(try fit.normalizedPoint(previewX: 150, previewY: 10), "top letterbox rejects touch")
        let point = try NormalizedImagePoint(x: 0.2, y: 0.8)
        let preview = fit.previewPoint(normalized: point)
        let returned = try XCTUnwrap(try fit.normalizedPoint(previewX: preview.x, previewY: preview.y))
        XCTAssertEqual(returned.x, point.x, accuracy: 0.000_000_1)
        XCTAssertEqual(returned.y, point.y, accuracy: 0.000_000_1)

        let landscapePreview = try PreviewImageGeometry(imageSize: try .init(width: 3, height: 4), previewSize: try .init(width: 844, height: 390), contentMode: .aspectFill)
        let center = try NormalizedImagePoint(x: 0.5, y: 0.5)
        let centerPreview = landscapePreview.previewPoint(normalized: center)
        let centerRoundTrip = try XCTUnwrap(try landscapePreview.normalizedPoint(previewX: centerPreview.x, previewY: centerPreview.y))
        XCTAssertEqual(centerRoundTrip, center)

        let wideFit = try PreviewImageGeometry(imageSize: try .init(width: 16, height: 9), previewSize: try .init(width: 300, height: 600), contentMode: .aspectFit)
        XCTAssertNil(try wideFit.normalizedPoint(previewX: 10, previewY: 10))
        let widePoint = try NormalizedImagePoint(x: 0.9, y: 0.1)
        let widePreview = wideFit.previewPoint(normalized: widePoint)
        XCTAssertEqual(try XCTUnwrap(try wideFit.normalizedPoint(previewX: widePreview.x, previewY: widePreview.y)), widePoint)
    }

    func testCoordinateValidationAndClampingPolicy() throws {
        XCTAssertThrowsError(try NormalizedImagePoint(x: .nan, y: 0)) { XCTAssertEqual($0 as? OrientationCoordinateError, .nonFinite) }
        XCTAssertThrowsError(try NormalizedImagePoint(x: 1.1, y: 0)) { XCTAssertEqual($0 as? OrientationCoordinateError, .outOfBounds) }
        XCTAssertEqual(try NormalizedImagePoint.clamping(x: -3, y: 4), try .init(x: 0, y: 1))
        XCTAssertThrowsError(try ImageSize(width: 0, height: 1))
        let geometry = try PreviewImageGeometry(imageSize: try .init(width: 1, height: 1), previewSize: try .init(width: 100, height: 100), contentMode: .aspectFill)
        XCTAssertNil(try geometry.normalizedPoint(previewX: -0.1, previewY: 0))
        XCTAssertThrowsError(try geometry.normalizedPoint(previewX: .infinity, previewY: 0)) { XCTAssertEqual($0 as? OrientationCoordinateError, .nonFinite) }
        XCTAssertThrowsError(try ImageEXIFOrientation(exifValue: 9)) { XCTAssertEqual($0 as? OrientationCoordinateError, .unsupportedOrientation) }
        XCTAssertThrowsError(try ImageEXIFOrientation(exifValue: nil)) { XCTAssertEqual($0 as? OrientationCoordinateError, .missingEXIFOrientation) }
        let devicePoint = try CaptureDeviceNormalizedPoint(x: 0.5, y: 0.25)
        XCTAssertEqual(devicePoint, try CaptureDeviceNormalizedPoint(x: 0.5, y: 0.25))
        XCTAssertThrowsError(try CaptureDeviceNormalizedPoint(x: .infinity, y: 0)) { XCTAssertEqual($0 as? OrientationCoordinateError, .nonFinite) }
    }

    func testAnalysisPlanPreservesOriginalBytesAndOnlyDescribesNormalization() throws {
        let bytes = Data([0xFF, 0xD8, 0x10, 0x00, 0xFF, 0xD9])
        let photo = CapturedPhoto(originalFileData: bytes, metadata: .init(orientation: 6, pixelWidth: 4000, pixelHeight: 3000))
        let plan = try AnalysisNormalizationPlan(photo: photo)
        XCTAssertEqual(plan.originalFileData, bytes)
        XCTAssertEqual(plan.exifOrientation, .right)
        XCTAssertEqual(plan.uprightSize, try ImageSize(width: 3000, height: 4000))
        XCTAssertEqual(photo.originalFileData, bytes, "planning analysis cannot alter original capture bytes")
        XCTAssertThrowsError(try AnalysisNormalizationPlan(photo: .init(originalFileData: bytes, metadata: .init(orientation: 42))))
        XCTAssertThrowsError(try AnalysisNormalizationPlan(photo: .init(originalFileData: bytes, metadata: .init()))) { XCTAssertEqual($0 as? OrientationCoordinateError, .missingEXIFOrientation) }
        XCTAssertThrowsError(try AnalysisNormalizationPlan(photo: .init(originalFileData: bytes, metadata: .init(orientation: 1, pixelWidth: 100)))) { XCTAssertEqual($0 as? OrientationCoordinateError, .invalidPhotoDimensions) }
        XCTAssertThrowsError(try AnalysisNormalizationPlan(photo: .init(originalFileData: bytes, metadata: .init(orientation: 1, pixelHeight: 100)))) { XCTAssertEqual($0 as? OrientationCoordinateError, .invalidPhotoDimensions) }
        XCTAssertThrowsError(try AnalysisNormalizationPlan(photo: .init(originalFileData: bytes, metadata: .init(orientation: 1, pixelWidth: 0, pixelHeight: 100)))) { XCTAssertEqual($0 as? OrientationCoordinateError, .invalidPhotoDimensions) }
    }
}
