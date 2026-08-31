import CompositionKit
import Testing

struct TransparentCutoutTests {
    @Test func preservesEveryFrontRGBByteAndCopiesMaskEdgeValuesToAlpha() throws {
        let frontBytes: [UInt8] = [
            10, 20, 30, 255,
            40, 50, 60, 255,
            70, 80, 90, 255,
            100, 110, 120, 255,
            130, 140, 150, 255,
            160, 170, 180, 255,
        ]
        let maskBytes: [UInt8] = [0, 1, 127, 128, 254, 255]
        let output = try FrontImageCompositor.makeTransparentCutout(.init(
            front: raster(6, 1, frontBytes),
            mask: mask(6, 1, maskBytes)
        ))

        #expect(output.width == 6)
        #expect(output.height == 1)
        #expect(output.orientation == .up)
        #expect(output.colorSpace == .sRGB)
        for pixel in maskBytes.indices {
            let offset = pixel * 4
            #expect(
                Array(output.pixels[offset ..< offset + 3])
                    == Array(frontBytes[offset ..< offset + 3]),
                "pixel=\(pixel)"
            )
            #expect(output.pixels[offset + 3] == maskBytes[pixel], "pixel=\(pixel)")
        }
    }

    @Test func normalizesEveryExifOrientationForFrontRGBAndMaskAlphaTogether() throws {
        let sourceFront: [UInt8] = (0 ..< 6).flatMap { index in
            [UInt8(10 + index), UInt8(30 + index), UInt8(50 + index), 255]
        }
        let sourceMask: [UInt8] = [0, 51, 102, 153, 204, 255]
        let cases: [(RasterOrientation, [Int], (Int, Int))] = [
            (.up, [0, 1, 2, 3, 4, 5], (3, 2)),
            (.upMirrored, [2, 1, 0, 5, 4, 3], (3, 2)),
            (.down, [5, 4, 3, 2, 1, 0], (3, 2)),
            (.downMirrored, [3, 4, 5, 0, 1, 2], (3, 2)),
            (.leftMirrored, [0, 3, 1, 4, 2, 5], (2, 3)),
            (.right, [3, 0, 4, 1, 5, 2], (2, 3)),
            (.rightMirrored, [5, 2, 4, 1, 3, 0], (2, 3)),
            (.left, [2, 5, 1, 4, 0, 3], (2, 3)),
        ]

        for (orientation, sourceIndices, size) in cases {
            let output = try FrontImageCompositor.makeTransparentCutout(.init(
                front: raster(3, 2, sourceFront, orientation: orientation),
                mask: mask(3, 2, sourceMask, orientation: orientation)
            ))
            #expect((output.width, output.height) == size)
            let expected = sourceIndices.flatMap { index in
                let offset = index * 4
                return [
                    sourceFront[offset],
                    sourceFront[offset + 1],
                    sourceFront[offset + 2],
                    sourceMask[index],
                ]
            }
            #expect(output.pixels == expected, "orientation=\(orientation)")
        }
    }

    @Test func invalidMasksFailClosedWithoutReturningPreviewPixels() {
        let front = opaque(2, 2)
        let cases: [(CompositionError, Mask8Raster)] = [
            (.emptyMask, mask(2, 2, [0, 0, 0, 0])),
            (.fullMask, mask(2, 2, [255, 255, 255, 255])),
            (.dimensionMismatch, mask(1, 2, [0, 255])),
            (.invalidMaskByteCount, mask(2, 2, [0, 255])),
            (.unsupportedMaskColorSpace, mask(2, 2, [0, 1, 2, 3], colorSpace: .unsupported)),
            (.unsupportedOrientation, mask(2, 2, [0, 1, 2, 3], orientation: .unsupported)),
        ]

        for (expected, invalidMask) in cases {
            #expect(throws: expected) {
                try FrontImageCompositor.makeTransparentCutout(.init(front: front, mask: invalidMask))
            }
        }
    }

    @Test func isDeterministicAndObservesInjectedAndTaskCancellation() async throws {
        let input = TransparentCutoutInput(
            front: opaque(3, 2),
            mask: mask(3, 2, [0, 1, 64, 128, 254, 255])
        )
        let first = try FrontImageCompositor.makeTransparentCutout(input)
        let second = try FrontImageCompositor.makeTransparentCutout(input)
        #expect(first == second)

        #expect(throws: CompositionError.cancelled) {
            try FrontImageCompositor.makeTransparentCutout(input, cancellationProbe: { true })
        }
        let probe = CutoutCountingProbe(cancelAt: 4)
        #expect(throws: CompositionError.cancelled) {
            try FrontImageCompositor.makeTransparentCutout(
                input,
                cancellationProbe: { probe.shouldCancel() }
            )
        }

        let task = Task { () -> Result<RGBA8Raster, Error> in
            withUnsafeCurrentTask { $0?.cancel() }
            return Result { try FrontImageCompositor.makeTransparentCutout(input) }
        }
        let result = await task.value
        #expect(throws: CompositionError.cancelled) { try result.get() }
    }

    private func opaque(_ width: Int, _ height: Int) -> RGBA8Raster {
        let pixels: [UInt8] = (0 ..< width * height).flatMap { index in
            [UInt8(10 + index), UInt8(30 + index), UInt8(50 + index), 255]
        }
        return raster(width, height, pixels)
    }

    private func raster(
        _ width: Int,
        _ height: Int,
        _ pixels: [UInt8],
        orientation: RasterOrientation = .up
    ) -> RGBA8Raster {
        .init(width: width, height: height, pixels: pixels, orientation: orientation)
    }

    private func mask(
        _ width: Int,
        _ height: Int,
        _ pixels: [UInt8],
        colorSpace: MaskColorSpace = .grayscale8,
        orientation: RasterOrientation = .up
    ) -> Mask8Raster {
        .init(
            width: width,
            height: height,
            pixels: pixels,
            orientation: orientation,
            colorSpace: colorSpace
        )
    }
}

private final class CutoutCountingProbe: @unchecked Sendable {
    private var count = 0
    private let cancelAt: Int

    init(cancelAt: Int) {
        self.cancelAt = cancelAt
    }

    func shouldCancel() -> Bool {
        count += 1
        return count >= cancelAt
    }
}
