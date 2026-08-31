import CompositionKit
import Testing

struct FrontImageCompositorTests {
    @Test func blendFormulaPreservesOpaqueProductAndBackgroundPixels() throws {
        let output = try FrontImageCompositor.compose(.init(
            front: rgba(2, 2, [10,20,30,255, 40,50,60,255, 70,80,90,255, 100,110,120,255]),
            mask: mask(2, 2, [255,128,0,64]),
            background: rgba(2, 2, [200,210,220,255, 1,2,3,255, 4,5,6,255, 250,240,230,255])
        ))
        #expect(output.pixels == [10,20,30,255, 21,26,32,255, 4,5,6,255, 212,207,202,255])
    }

    @Test func appliesCenterCropAndNearestNeighborForAllAspectCases() throws {
        let front = opaque(2, 2, 99)
        let partialMask = mask(2, 2, [0,0,0,255])
        let cases: [(String, RGBA8Raster, [UInt8])] = [
            ("wide", rgba(3, 2, [10,0,0,255,20,0,0,255,30,0,0,255, 40,0,0,255,50,0,0,255,60,0,0,255]), [20,30,50,99]),
            ("tall", rgba(2, 3, [10,0,0,255,20,0,0,255, 30,0,0,255,40,0,0,255, 50,0,0,255,60,0,0,255]), [30,40,50,99]),
            ("same", rgba(4, 4, rgbaPixels(width: 4, height: 4)), [60,80,140,99]),
            ("onePixel", rgba(1, 3, [10,0,0,255,20,0,0,255,30,0,0,255]), [20,20,20,99]),
        ]
        for (name, background, expected) in cases {
            let output = try FrontImageCompositor.compose(.init(front: front, mask: partialMask, background: background))
            #expect(red(output) == expected, "case: \(name)")
        }
    }

    @Test func normalizesEveryExifOrientationForFrontAndMask() throws {
        let sourceFront = rgba(3, 2, [200,0,0,255,190,0,0,255,180,0,0,255,170,0,0,255,160,0,0,255,150,0,0,255])
        let sourceMask: [UInt8] = [0,51,102,153,204,255]
        let expectedByIndex: [UInt8] = [0,38,72,102,128,150]
        let cases: [(RasterOrientation, [Int], (Int, Int))] = [
            (.up, [0,1,2,3,4,5], (3,2)), (.upMirrored, [2,1,0,5,4,3], (3,2)),
            (.down, [5,4,3,2,1,0], (3,2)), (.downMirrored, [3,4,5,0,1,2], (3,2)),
            (.leftMirrored, [0,3,1,4,2,5], (2,3)), (.right, [3,0,4,1,5,2], (2,3)),
            (.rightMirrored, [5,2,4,1,3,0], (2,3)), (.left, [2,5,1,4,0,3], (2,3)),
        ]
        for (orientation, indices, size) in cases {
            let output = try FrontImageCompositor.compose(.init(
                front: rgba(3, 2, sourceFront.pixels, orientation: orientation),
                mask: mask(3, 2, sourceMask, orientation: orientation),
                background: opaque(size.0, size.1, 0)
            ))
            #expect((output.width, output.height) == size)
            #expect(red(output) == indices.map { expectedByIndex[$0] })
        }
    }

    @Test func acceptsAlpha8MaskCoverage() throws {
        let output = try FrontImageCompositor.compose(.init(front: opaque(2, 2, 100), mask: mask(2, 2, [255,128,0,64], colorSpace: .alpha8), background: opaque(2, 2, 20)))
        #expect(red(output) == [100,60,20,40])
    }

    @Test func rejectsAllInvalidInputRolesWithFiniteErrors() {
        let front = opaque(2, 2, 1); let maskOK = mask(2, 2, [0,1,2,3]); let background = opaque(2, 2, 2)
        let cases: [(CompositionInput, CompositionError)] = [
            (.init(front: rgba(0,1,[]), mask: maskOK, background: background), .zeroDimensions),
            (.init(front: front, mask: mask(0,1,[]), background: background), .zeroDimensions),
            (.init(front: front, mask: maskOK, background: rgba(0,1,[])), .zeroDimensions),
            (.init(front: rgba(2,2,[1]), mask: maskOK, background: background), .invalidRGBAByteCount),
            (.init(front: front, mask: mask(2,2,[1]), background: background), .invalidMaskByteCount),
            (.init(front: front, mask: maskOK, background: rgba(2,2,[1])), .invalidRGBAByteCount),
            (.init(front: rgba(Int.max,2,[]), mask: maskOK, background: background), .invalidRGBAByteCount),
            (.init(front: front, mask: mask(Int.max,2,[]), background: background), .invalidMaskByteCount),
            (.init(front: front, mask: maskOK, background: rgba(Int.max,2,[])), .invalidRGBAByteCount),
            (.init(front: rgba(2,2,Array(repeating: 1, count: 16), colorSpace: .displayP3), mask: maskOK, background: background), .unsupportedRasterColorSpace),
            (.init(front: front, mask: mask(2,2,[0,1,2,3], colorSpace: .unsupported), background: background), .unsupportedMaskColorSpace),
            (.init(front: front, mask: maskOK, background: rgba(2,2,Array(repeating: 1, count: 16), colorSpace: .unsupported)), .unsupportedRasterColorSpace),
            (.init(front: rgba(2,2,Array(repeating: 1, count: 16), orientation: .unsupported), mask: maskOK, background: background), .unsupportedOrientation),
            (.init(front: front, mask: mask(2,2,[0,1,2,3], orientation: .unsupported), background: background), .unsupportedOrientation),
            (.init(front: front, mask: maskOK, background: rgba(2,2,Array(repeating: 1, count: 16), orientation: .unsupported)), .unsupportedOrientation),
            (.init(front: front, mask: mask(1,2,[1,0]), background: background), .dimensionMismatch),
            (.init(front: front, mask: mask(2,2,[0,0,0,0]), background: background), .emptyMask),
            (.init(front: front, mask: mask(2,2,[255,255,255,255]), background: background), .fullMask),
        ]
        for (input, expected) in cases { #expect(throws: expected) { try FrontImageCompositor.compose(input) } }
    }

    @Test func rejectsNonOpaqueFrontAndBackground() {
        let maskOK = mask(2, 2, [0,1,2,3])
        #expect(throws: CompositionError.nonOpaqueRaster) { try FrontImageCompositor.compose(.init(front: rgba(2,2,[1,1,1,0,1,1,1,255,1,1,1,255,1,1,1,255]), mask: maskOK, background: opaque(2,2,2))) }
        #expect(throws: CompositionError.nonOpaqueRaster) { try FrontImageCompositor.compose(.init(front: opaque(2,2,1), mask: maskOK, background: rgba(2,2,[2,0,0,255,2,0,0,0,2,0,0,255,2,0,0,255]))) }
    }

    @Test func isDeterministicAndObservesInjectedCancellation() throws {
        #expect(try FrontImageCompositor.compose(validInput) == FrontImageCompositor.compose(validInput))
        #expect(throws: CompositionError.cancelled) { try FrontImageCompositor.compose(validInput, cancellationProbe: { true }) }
        let probe = CountingProbe(cancelAt: 4)
        #expect(throws: CompositionError.cancelled) { try FrontImageCompositor.compose(validInput, cancellationProbe: { probe.shouldCancel() }) }
    }

    @Test func observesCancellationFromCurrentTaskByDefault() async {
        let task = Task { () -> Result<RGBA8Raster, Error> in
            withUnsafeCurrentTask { $0?.cancel() }
            return Result { try FrontImageCompositor.compose(validInput) }
        }
        let result = await task.value
        #expect(throws: CompositionError.cancelled) { try result.get() }
    }

    private var validInput: CompositionInput { .init(front: opaque(2,2,1), mask: mask(2,2,[0,1,2,3]), background: opaque(2,2,2)) }
    private func opaque(_ width: Int, _ height: Int, _ red: UInt8) -> RGBA8Raster { rgba(width, height, Array(repeating: [red,0,0,255], count: width * height).flatMap { $0 }) }
    private func rgba(_ width: Int, _ height: Int, _ pixels: [UInt8], orientation: RasterOrientation = .up, colorSpace: RasterColorSpace = .sRGB) -> RGBA8Raster { .init(width: width, height: height, pixels: pixels, orientation: orientation, colorSpace: colorSpace) }
    private func mask(_ width: Int, _ height: Int, _ pixels: [UInt8], orientation: RasterOrientation = .up, colorSpace: MaskColorSpace = .grayscale8) -> Mask8Raster { .init(width: width, height: height, pixels: pixels, orientation: orientation, colorSpace: colorSpace) }
    private func red(_ raster: RGBA8Raster) -> [UInt8] { raster.pixels.enumerated().filter { $0.offset % 4 == 0 }.map(\.element) }
    private func rgbaPixels(width: Int, height: Int) -> [UInt8] { (0 ..< width * height).flatMap { index in [UInt8((index + 1) * 10), 0, 0, 255] } }
}

private final class CountingProbe: @unchecked Sendable {
    private var count = 0; private let cancelAt: Int
    init(cancelAt: Int) { self.cancelAt = cancelAt }
    func shouldCancel() -> Bool { count += 1; return count >= cancelAt }
}
