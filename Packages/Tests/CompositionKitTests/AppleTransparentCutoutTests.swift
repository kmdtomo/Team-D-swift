import CompositionKit
import CoreGraphics
import Foundation
import Testing

struct AppleTransparentCutoutTests {
    @Test func returnsStraightAlphaImageWithOriginalFrontRGBAndMaskAlpha() throws {
        let frontBytes: [UInt8] = [
            10, 20, 30, 255,
            40, 50, 60, 255,
            70, 80, 90, 255,
            100, 110, 120, 255,
        ]
        let maskBytes: [UInt8] = [0, 1, 128, 255]
        let output = try AppleImageCompositor.renderTransparentCutout(.init(
            front: try rgbaImage(2, 2, frontBytes),
            mask: try grayImage(2, 2, maskBytes)
        ))

        #expect(output.alphaInfo == .last)
        #expect(output.colorSpace?.name == CGColorSpace.sRGB)
        let outputBytes = try providerBytes(output)
        for pixel in maskBytes.indices {
            let offset = pixel * 4
            #expect(
                Array(outputBytes[offset ..< offset + 3])
                    == Array(frontBytes[offset ..< offset + 3]),
                "pixel=\(pixel)"
            )
            #expect(outputBytes[offset + 3] == maskBytes[pixel], "pixel=\(pixel)")
        }
    }

    @Test func normalizesOrientationAndRemainsDeterministic() throws {
        let input = AppleTransparentCutoutInput(
            front: try rgbaImage(2, 1, [10, 20, 30, 255, 40, 50, 60, 255]),
            frontOrientation: .right,
            mask: try grayImage(2, 1, [0, 255]),
            maskOrientation: .right
        )
        let first = try AppleImageCompositor.renderTransparentCutout(input)
        let second = try AppleImageCompositor.renderTransparentCutout(input)
        let firstBytes = try providerBytes(first)
        let secondBytes = try providerBytes(second)

        #expect((first.width, first.height) == (1, 2))
        #expect(firstBytes == secondBytes)
        #expect(firstBytes == [10, 20, 30, 0, 40, 50, 60, 255])
    }

    @Test func invalidMasksAndCancellationNeverReturnAnApplePreview() throws {
        let front = try rgbaImage(2, 2, [
            10, 20, 30, 255,
            40, 50, 60, 255,
            70, 80, 90, 255,
            100, 110, 120, 255,
        ])
        let validMask = try grayImage(2, 2, [0, 1, 128, 255])
        let cases: [(CompositionError, AppleTransparentCutoutInput)] = [
            (.emptyMask, .init(front: front, mask: try grayImage(2, 2, [0, 0, 0, 0]))),
            (.fullMask, .init(front: front, mask: try grayImage(2, 2, [255, 255, 255, 255]))),
            (.dimensionMismatch, .init(front: front, mask: try grayImage(1, 2, [0, 255]))),
            (.unsupportedMaskColorSpace, .init(front: front, mask: try rgbaImage(2, 2, [0, 0, 0, 255, 1, 1, 1, 255, 2, 2, 2, 255, 3, 3, 3, 255]))),
            (.unsupportedOrientation, .init(front: front, mask: validMask, maskOrientation: .unsupported)),
        ]

        for (expected, input) in cases {
            #expect(throws: expected) {
                try AppleImageCompositor.renderTransparentCutout(input)
            }
        }
        #expect(throws: CompositionError.cancelled) {
            try AppleImageCompositor.renderTransparentCutout(
                .init(front: front, mask: validMask),
                cancellationProbe: { true }
            )
        }
    }

    @Test func previewSemanticsAreJapaneseStableAndNonInteractive() {
        #expect(TransparentCutoutPreviewSemantics.title == "背景を透明にした確認画像")
        #expect(TransparentCutoutPreviewSemantics.detail.contains("透明"))
        #expect(TransparentCutoutPreviewSemantics.restriction.contains("選択・承認・保存はできません"))
        #expect(TransparentCutoutPreviewSemantics.accessibilityLabel.contains("透明"))
        #expect(TransparentCutoutPreviewSemantics.accessibilityIdentifier == "editing.transparent-cutout-preview")
        #expect(!TransparentCutoutPreviewSemantics.permitsSelection)
        #expect(!TransparentCutoutPreviewSemantics.permitsApproval)
        #expect(!TransparentCutoutPreviewSemantics.permitsExport)
    }

    private func rgbaImage(_ width: Int, _ height: Int, _ bytes: [UInt8]) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw FixtureError.imageCreation
        }
        return image
    }

    private func grayImage(_ width: Int, _ height: Int, _ bytes: [UInt8]) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 8,
                  bytesPerRow: width,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw FixtureError.imageCreation
        }
        return image
    }

    private func providerBytes(_ image: CGImage) throws -> [UInt8] {
        guard let data = image.dataProvider?.data else {
            throw FixtureError.missingProviderData
        }
        let count = CFDataGetLength(data)
        guard let bytes = CFDataGetBytePtr(data) else {
            throw FixtureError.missingProviderData
        }
        return Array(UnsafeBufferPointer(start: bytes, count: count))
    }

    private enum FixtureError: Error {
        case imageCreation
        case missingProviderData
    }
}
