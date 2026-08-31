import CompositionKit
import CoreGraphics
import Foundation
import Testing

struct AppleImageCompositorTests {
    @Test func preservesOpaqueFrontRGBAndUsesMaskOutsideBackground() throws {
        let front = try rgbaImage(2, 2, [10,20,30,255, 40,50,60,255, 70,80,90,255, 100,110,120,255])
        let background = try rgbaImage(2, 2, [200,210,220,255, 1,2,3,255, 4,5,6,255, 250,240,230,255])
        let mask = try grayImage(2, 2, [255,128,0,64])
        let output = try AppleImageCompositor.renderOutput(.init(front: front, mask: mask, background: background))
        #expect(rgbaBytes(output) == [10,20,30,255, 21,26,32,255, 4,5,6,255, 212,207,202,255])
    }

    @Test func normalizesOrientationAndConvertsDisplayP3ToSRGBOutput() throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let front = try rgbaImage(2, 1, [255,255,255,255, 40,50,60,255], colorSpace: p3)
        let background = try rgbaImage(1, 2, [200,0,0,255, 100,0,0,255])
        let mask = try grayImage(2, 1, [255,0])
        let output = try AppleImageCompositor.compose(.init(
            front: front, frontOrientation: .right,
            mask: mask, maskOrientation: .right,
            background: background
        ))
        #expect((output.width, output.height) == (1, 2))
        #expect(output.colorSpace?.name == CGColorSpace.sRGB)
        let bytes = try rgbaBytes(output)
        #expect(Array(bytes[0 ..< 3]) == [255,255,255])
        #expect(Array(bytes[4 ..< 7]) == [100,0,0])
    }

    @Test func previewAndOutputAreLosslessAndDeterministic() throws {
        let input = try input(mask: [255, 128, 0, 64])
        let preview = try AppleImageCompositor.renderPreview(input)
        let first = try AppleImageCompositor.renderOutput(input)
        let second = try AppleImageCompositor.renderOutput(input)
        #expect(rgbaBytes(preview) == rgbaBytes(first))
        #expect(rgbaBytes(first) == rgbaBytes(second))
    }

    @Test func rejectsInvalidMaskOrientationAndColorSpacesWithFiniteErrors() throws {
        let valid = try input(mask: [255, 128, 0, 64])
        let rgbMask = try rgbaImage(2, 2, [0,0,0,255, 255,255,255,255, 0,0,0,255, 0,0,0,255])
        let grayFront = try grayImage(2, 2, [1,2,3,4])
        #expect(throws: CompositionError.unsupportedMaskColorSpace) {
            try AppleImageCompositor.compose(.init(front: valid.front, mask: rgbMask, background: valid.background))
        }
        #expect(throws: CompositionError.unsupportedOrientation) {
            try AppleImageCompositor.compose(.init(front: valid.front, mask: valid.mask, maskOrientation: .unsupported, background: valid.background))
        }
        #expect(throws: CompositionError.unsupportedRasterColorSpace) {
            try AppleImageCompositor.compose(.init(front: grayFront, mask: valid.mask, background: valid.background))
        }
    }

    @Test func rejectsInvalidMaskDimensionsAndObservesCancellation() throws {
        let valid = try input(mask: [255, 128, 0, 64])
        let narrowMask = try grayImage(1, 2, [0, 255])
        #expect(throws: CompositionError.dimensionMismatch) {
            try AppleImageCompositor.compose(.init(front: valid.front, mask: narrowMask, background: valid.background))
        }
        #expect(throws: CompositionError.cancelled) {
            try AppleImageCompositor.compose(valid, cancellationProbe: { true })
        }
    }

    private func input(mask: [UInt8]) throws -> AppleImageCompositionInput {
        .init(
            front: try rgbaImage(2, 2, [10,20,30,255, 40,50,60,255, 70,80,90,255, 100,110,120,255]),
            mask: try grayImage(2, 2, mask),
            background: try rgbaImage(2, 2, [200,210,220,255, 1,2,3,255, 4,5,6,255, 250,240,230,255])
        )
    }

    private func rgbaImage(_ width: Int, _ height: Int, _ bytes: [UInt8], colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw FixtureError.imageCreation
        }
        return image
    }

    private func grayImage(_ width: Int, _ height: Int, _ bytes: [UInt8]) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw FixtureError.imageCreation
        }
        return image
    }

    private func rgbaBytes(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    private enum FixtureError: Error { case imageCreation }
}
