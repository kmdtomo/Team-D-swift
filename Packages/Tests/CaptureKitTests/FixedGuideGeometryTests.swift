import Foundation
import XCTest
@testable import CaptureKit

final class FixedGuideGeometryTests: XCTestCase {
    func testEveryShotHasDeterministicGuideAndExpectedKinds() throws {
        let geometry = try portraitFillGeometry()
        let safeArea = try GuideSafeAreaInsets(top: 59, bottom: 34)

        for shot in [Shot.front, .back, .tag, .measurement] {
            let first = try FixedGuideLayout(shot: shot, previewGeometry: geometry, uprightOrientation: .up, safeAreaInsets: safeArea)
            let second = try FixedGuideLayout(shot: shot, previewGeometry: geometry, uprightOrientation: .up, safeAreaInsets: safeArea)
            XCTAssertEqual(first, second)
            XCTAssertEqual(first.key.shot, shot)
            XCTAssertEqual(first.primary.kind, shot == .tag ? .tag : .garment)
            XCTAssertEqual(first.markerPlacement != nil, shot == .measurement)
            XCTAssertTrue(contains(first.primary.previewRect, in: safeAreaRect(geometry.previewSize, safeArea)))
            XCTAssertTrue(contains(first.primary.previewRect, in: visibleContentRect(geometry)))
        }

        let measurement = try FixedGuideLayout(shot: .measurement, previewGeometry: geometry, uprightOrientation: .up, safeAreaInsets: safeArea)
        XCTAssertEqual(measurement.markerPlacement?.kind, .markerPlacement50mm, "This is only the 50 mm marker placement guide; it is not a physical-size estimate.")
        XCTAssertTrue(contains(try XCTUnwrap(measurement.markerPlacement).previewRect, in: safeAreaRect(geometry.previewSize, safeArea)))
    }

    func testNarrowDynamicIslandLandscapeAndSafeAreaLayoutsStayInsideVisiblePreview() throws {
        let cases: [(ImageSize, ImageSize, PreviewContentMode, GuideSafeAreaInsets)] = [
            (try .init(width: 3, height: 4), try .init(width: 320, height: 568), .aspectFill, try .init(top: 20, bottom: 12)),
            (try .init(width: 3, height: 4), try .init(width: 393, height: 852), .aspectFill, try .init(top: 59, bottom: 34)),
            (try .init(width: 4, height: 3), try .init(width: 844, height: 390), .aspectFill, try .init(leading: 59, trailing: 59, bottom: 21)),
            (try .init(width: 16, height: 9), try .init(width: 393, height: 852), .aspectFit, try .init(top: 59, bottom: 34)),
        ]
        for (image, preview, mode, insets) in cases {
            let geometry = try PreviewImageGeometry(imageSize: image, previewSize: preview, contentMode: mode)
            let layout = try FixedGuideLayout(shot: .measurement, previewGeometry: geometry, uprightOrientation: .up, safeAreaInsets: insets)
            let visible = visibleContentRect(geometry), safe = safeAreaRect(preview, insets)
            XCTAssertTrue(contains(layout.primary.previewRect, in: visible))
            XCTAssertTrue(contains(layout.primary.previewRect, in: safe))
            XCTAssertTrue(contains(try XCTUnwrap(layout.markerPlacement).previewRect, in: visible))
            XCTAssertTrue(contains(try XCTUnwrap(layout.markerPlacement).previewRect, in: safe))
        }
    }

    func testAspectFillCropAndAspectFitLetterboxROIsRoundTripThroughSharedGeometry() throws {
        let cases = [
            try PreviewImageGeometry(imageSize: .init(width: 4, height: 3), previewSize: .init(width: 393, height: 852), contentMode: .aspectFill),
            try PreviewImageGeometry(imageSize: .init(width: 16, height: 9), previewSize: .init(width: 393, height: 852), contentMode: .aspectFit),
        ]
        for geometry in cases {
            let layout = try FixedGuideLayout(shot: .tag, previewGeometry: geometry, uprightOrientation: .up, safeAreaInsets: .init(top: 59, bottom: 34))
            let roi = layout.primary.uprightImageROI
            let topLeading = geometry.previewPoint(normalized: roi.topLeading)
            let bottomTrailing = geometry.previewPoint(normalized: roi.bottomTrailing)
            XCTAssertEqual(topLeading.x, layout.primary.previewRect.x, accuracy: 0.000_001)
            XCTAssertEqual(topLeading.y, layout.primary.previewRect.y, accuracy: 0.000_001)
            XCTAssertEqual(bottomTrailing.x, layout.primary.previewRect.maxX, accuracy: 0.000_001)
            XCTAssertEqual(bottomTrailing.y, layout.primary.previewRect.maxY, accuracy: 0.000_001)
        }
    }

    func testLayoutKeyChangesForShotViewportAndImageOrientationInputs() throws {
        let portraitImage = try ImageSize(width: 3, height: 4)
        let portraitPreview = try ImageSize(width: 393, height: 852)
        let landscapePreview = try ImageSize(width: 852, height: 393)
        let safe = try GuideSafeAreaInsets(top: 59, bottom: 34)
        let portrait = try FixedGuideLayout(shot: .front, previewGeometry: .init(imageSize: portraitImage, previewSize: portraitPreview, contentMode: .aspectFill), uprightOrientation: .up, safeAreaInsets: safe)
        let changedShot = try FixedGuideLayout(shot: .back, previewGeometry: .init(imageSize: portraitImage, previewSize: portraitPreview, contentMode: .aspectFill), uprightOrientation: .up, safeAreaInsets: safe)
        let changedViewport = try FixedGuideLayout(shot: .front, previewGeometry: .init(imageSize: portraitImage, previewSize: landscapePreview, contentMode: .aspectFill), uprightOrientation: .up, safeAreaInsets: safe)
        let changedImageOrientation = try FixedGuideLayout(shot: .front, previewGeometry: .init(imageSize: .init(width: 4, height: 3), previewSize: portraitPreview, contentMode: .aspectFill), uprightOrientation: .right, safeAreaInsets: safe)
        let changedExifWithoutSizeChange = try FixedGuideLayout(shot: .front, previewGeometry: .init(imageSize: portraitImage, previewSize: portraitPreview, contentMode: .aspectFill), uprightOrientation: .down, safeAreaInsets: safe)
        XCTAssertNotEqual(portrait.key, changedShot.key)
        XCTAssertNotEqual(portrait.key, changedViewport.key)
        XCTAssertNotEqual(portrait.key, changedImageOrientation.key)
        XCTAssertNotEqual(portrait.key, changedExifWithoutSizeChange.key)
    }

    func testGuideLayoutCannotAlterKnownCapturedPhotoBytesOrHash() throws {
        let bytes = Data("capture-fixture-original-bytes".utf8)
        XCTAssertEqual(fnv1a64(bytes), "b82fb9a0685fdded")
        let photo = CapturedPhoto(originalFileData: bytes, metadata: .init(orientation: 1, pixelWidth: 3000, pixelHeight: 4000))
        _ = try FixedGuideLayout(shot: .front, previewGeometry: portraitFillGeometry(), uprightOrientation: .up, safeAreaInsets: .init(top: 59, bottom: 34))
        XCTAssertEqual(photo.originalFileData, bytes)
        XCTAssertEqual(fnv1a64(photo.originalFileData), "b82fb9a0685fdded")
    }

    func testInvalidSafeAreaIsRejected() throws {
        let geometry = try portraitFillGeometry()
        XCTAssertThrowsError(try FixedGuideLayout(shot: .front, previewGeometry: geometry, uprightOrientation: .up, safeAreaInsets: .init(top: geometry.previewSize.height))) {
            XCTAssertEqual($0 as? FixedGuideError, .safeAreaConsumesPreview)
        }
        XCTAssertThrowsError(try GuideSafeAreaInsets(top: -.infinity)) { XCTAssertEqual($0 as? FixedGuideError, .invalidInsets) }
    }

    private func portraitFillGeometry() throws -> PreviewImageGeometry {
        try .init(imageSize: .init(width: 3, height: 4), previewSize: .init(width: 393, height: 852), contentMode: .aspectFill)
    }

    private func safeAreaRect(_ size: ImageSize, _ insets: GuideSafeAreaInsets) -> PreviewGuideRect {
        try! .init(x: insets.leading, y: insets.top, width: size.width - insets.leading - insets.trailing, height: size.height - insets.top - insets.bottom)
    }

    private func visibleContentRect(_ geometry: PreviewImageGeometry) -> PreviewGuideRect {
        let minX = max(0, geometry.contentOriginX), minY = max(0, geometry.contentOriginY)
        return try! .init(x: minX, y: minY, width: min(geometry.previewSize.width, geometry.contentOriginX + geometry.contentSize.width) - minX, height: min(geometry.previewSize.height, geometry.contentOriginY + geometry.contentSize.height) - minY)
    }

    private func contains(_ inner: PreviewGuideRect, in outer: PreviewGuideRect) -> Bool {
        inner.x >= outer.x && inner.y >= outer.y && inner.maxX <= outer.maxX && inner.maxY <= outer.maxY
    }

    private func fnv1a64(_ data: Data) -> String {
        let value = data.reduce(UInt64(0xcbf29ce484222325)) { partial, byte in
            (partial ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(value, radix: 16)
    }
}
