import CompositionKit
import Testing

/// Fixture-only regression contract for T15-02. These inputs contain no user
/// images or network assets, and deliberately exercise only the compositor's
/// three allowed inputs: front, mask, and background.
struct CompositionProvenanceTests {
    @Test func everyMaskByteUsesOnlyFrontAndBackgroundByTheDocumentedFormula() throws {
        let width = 16
        let height = 16
        let frontBytes = rgbaFixture(width: width, height: height, seed: 17)
        let backgroundBytes = rgbaFixture(width: width, height: height, seed: 91)
        let maskBytes = (0 ... 255).map(UInt8.init)
        let input = CompositionInput(
            front: raster(width, height, frontBytes),
            mask: mask(width, height, maskBytes),
            background: raster(width, height, backgroundBytes)
        )

        let output = try FrontImageCompositor.compose(input)
        for pixel in 0 ..< maskBytes.count {
            let offset = pixel * 4
            let coverage = Int(maskBytes[pixel])
            for channel in 0 ..< 3 {
                let expected = UInt8(
                    (Int(frontBytes[offset + channel]) * coverage
                        + Int(backgroundBytes[offset + channel]) * (255 - coverage) + 127) / 255
                )
                #expect(output.pixels[offset + channel] == expected, "pixel=\(pixel), channel=\(channel)")
            }
            #expect(output.pixels[offset + 3] == 255, "pixel=\(pixel) must remain opaque")
        }
    }

    @Test func opaqueInteriorAndMaskOutsideHaveExactAndDistinctProvenance() throws {
        let frontBytes = rgbaFixture(width: 5, height: 5, seed: 11)
        let backgroundBytes = rgbaFixture(width: 5, height: 5, seed: 93)
        var maskBytes = [UInt8](repeating: 0, count: 25)
        for y in 1 ... 3 {
            for x in 1 ... 3 { maskBytes[y * 5 + x] = 255 }
        }
        maskBytes[4] = 128
        let output = try FrontImageCompositor.compose(.init(
            front: raster(5, 5, frontBytes),
            mask: mask(5, 5, maskBytes),
            background: raster(5, 5, backgroundBytes)
        ))

        for y in 1 ... 3 {
            for x in 1 ... 3 {
                let offset = (y * 5 + x) * 4
                #expect(Array(output.pixels[offset ..< offset + 3]) == Array(frontBytes[offset ..< offset + 3]))
            }
        }
        #expect(Array(output.pixels[0 ..< 3]) == Array(backgroundBytes[0 ..< 3]))
        let edgeOffset = 4 * 4
        let expectedEdge128 = blend(
            front: Array(frontBytes[edgeOffset ..< edgeOffset + 3]),
            background: Array(backgroundBytes[edgeOffset ..< edgeOffset + 3]),
            mask: 128
        )
        #expect(Array(output.pixels[edgeOffset ..< edgeOffset + 3]) == expectedEdge128)
        #expect(Array(output.pixels[edgeOffset ..< edgeOffset + 3]) != Array(frontBytes[edgeOffset ..< edgeOffset + 3]))
        #expect(Array(output.pixels[edgeOffset ..< edgeOffset + 3]) != Array(backgroundBytes[edgeOffset ..< edgeOffset + 3]))
    }

    @Test func repeatedCompositionAndAllSourceFixturesRemainByteStable() throws {
        let frontBytes = rgbaFixture(width: 4, height: 4, seed: 7)
        let maskBytes: [UInt8] = [255, 0, 127, 32, 64, 128, 192, 254, 1, 2, 3, 4, 5, 6, 7, 8]
        let backgroundBytes = rgbaFixture(width: 4, height: 4, seed: 41)
        let sentinelSlots: [String: [UInt8]] = [
            "back": [0xBA, 0xC1, 0x00, 0x01],
            "tag": [0x7A, 0x61, 0x99],
            "measurement": [0x4D, 0x45, 0x41, 0x53],
        ]
        let sourceHashes = [fnv1a(frontBytes), fnv1a(maskBytes), fnv1a(backgroundBytes)]
        let sentinelHashes = sentinelSlots.mapValues(fnv1a)
        let input = CompositionInput(
            front: raster(4, 4, frontBytes), mask: mask(4, 4, maskBytes), background: raster(4, 4, backgroundBytes)
        )

        let outputs = try (0 ..< 4).map { _ in try FrontImageCompositor.compose(input) }
        #expect(outputs.dropFirst().allSatisfy { $0 == outputs[0] })
        #expect([fnv1a(frontBytes), fnv1a(maskBytes), fnv1a(backgroundBytes)] == sourceHashes)
        #expect(sentinelSlots.mapValues(fnv1a) == sentinelHashes)

        // CompositionInput intentionally exposes no back/tag/measurement field:
        // those slot bytes cannot enter FrontImageCompositor.compose at all.
        #expect(outputs[0].pixels != sentinelSlots["back"]!)
    }

    @Test func goldenPatternsKeepMaskOutsideAsCenterCroppedBackgroundOnly() throws {
        let cases: [(name: String, front: [UInt8], mask: [UInt8], background: [UInt8], expected: [UInt8], sourceHashes: [UInt64])] = [
            (
                "wide-crop",
                rgbaFixture(width: 2, height: 2, seed: 2),
                [0, 255, 0, 255],
                [10, 0, 0, 255, 20, 0, 0, 255, 30, 0, 0, 255, 40, 0, 0, 255, 50, 0, 0, 255, 60, 0, 0, 255],
                [20, 0, 0, 255, 33, 49, 61, 255, 50, 0, 0, 255, 95, 143, 179, 255],
                [0xF4A8_59BE_2D1E_95D9, 0xD6B3_707B_F4B8_56ED, 0xD8FB_59E5_8E05_9F23]
            ),
            (
                "tall-crop",
                rgbaFixture(width: 2, height: 2, seed: 3),
                [255, 0, 255, 0],
                [10, 0, 0, 255, 20, 0, 0, 255, 30, 0, 0, 255, 40, 0, 0, 255, 50, 0, 0, 255, 60, 0, 0, 255],
                [3, 3, 3, 255, 40, 0, 0, 255, 65, 97, 121, 255, 60, 0, 0, 255],
                [0xF8C8_450E_0D7C_996D, 0x668D_3A64_8F65_655D, 0xD8FB_59E5_8E05_9F23]
            ),
        ]
        for entry in cases {
            let backgroundSize = entry.name == "wide-crop" ? (3, 2) : (2, 3)
            let output = try FrontImageCompositor.compose(.init(
                front: raster(2, 2, entry.front), mask: mask(2, 2, entry.mask),
                background: raster(backgroundSize.0, backgroundSize.1, entry.background)
            ))
            #expect(output.pixels == entry.expected, "case: \(entry.name)")
            #expect([fnv1a(entry.front), fnv1a(entry.mask), fnv1a(entry.background)] == entry.sourceHashes, "case: \(entry.name)")
        }
    }

    @Test func invalidInputsReturnFiniteErrorsWithoutMutatingAnySource() {
        let frontBytes = rgbaFixture(width: 2, height: 2, seed: 10)
        let backgroundBytes = rgbaFixture(width: 2, height: 2, seed: 20)
        let maskBytes: [UInt8] = [0, 1, 2, 3]
        let sourceHashes = [fnv1a(frontBytes), fnv1a(backgroundBytes), fnv1a(maskBytes)]
        let front = raster(2, 2, frontBytes)
        let background = raster(2, 2, backgroundBytes)
        let valid = CompositionInput(front: front, mask: mask(2, 2, maskBytes), background: background)
        let cases: [(String, CompositionError, () -> Result<RGBA8Raster, Error>)] = [
            ("empty", .emptyMask, { Result { try FrontImageCompositor.compose(.init(front: front, mask: mask(2, 2, [0, 0, 0, 0]), background: background)) } }),
            ("full", .fullMask, { Result { try FrontImageCompositor.compose(.init(front: front, mask: mask(2, 2, [255, 255, 255, 255]), background: background)) } }),
            ("size-mismatch", .dimensionMismatch, { Result { try FrontImageCompositor.compose(.init(front: front, mask: mask(1, 2, [0, 1]), background: background)) } }),
            ("rgba-byte-count", .invalidRGBAByteCount, { Result { try FrontImageCompositor.compose(.init(front: raster(2, 2, [1]), mask: mask(2, 2, maskBytes), background: background)) } }),
            ("mask-byte-count", .invalidMaskByteCount, { Result { try FrontImageCompositor.compose(.init(front: front, mask: mask(2, 2, [1]), background: background)) } }),
            ("orientation", .unsupportedOrientation, { Result { try FrontImageCompositor.compose(.init(front: raster(2, 2, frontBytes, orientation: .unsupported), mask: mask(2, 2, maskBytes), background: background)) } }),
            ("color-space", .unsupportedRasterColorSpace, { Result { try FrontImageCompositor.compose(.init(front: raster(2, 2, frontBytes, colorSpace: .displayP3), mask: mask(2, 2, maskBytes), background: background)) } }),
            ("non-opaque", .nonOpaqueRaster, { Result { try FrontImageCompositor.compose(.init(front: raster(2, 2, [1, 2, 3, 0, 4, 5, 6, 255, 7, 8, 9, 255, 10, 11, 12, 255]), mask: mask(2, 2, maskBytes), background: background)) } }),
            ("cancelled", .cancelled, { Result { try FrontImageCompositor.compose(valid, cancellationProbe: { true }) } }),
        ]
        for (name, expected, operation) in cases {
            switch operation() {
            case .success:
                #expect(Bool(false), "case: \(name) returned a composite")
            case .failure(let error):
                #expect((error as? CompositionError) == expected, "case: \(name)")
            }
            #expect([fnv1a(frontBytes), fnv1a(backgroundBytes), fnv1a(maskBytes)] == sourceHashes, "case: \(name)")
        }
    }

    private func raster(_ width: Int, _ height: Int, _ pixels: [UInt8], orientation: RasterOrientation = .up, colorSpace: RasterColorSpace = .sRGB) -> RGBA8Raster {
        .init(width: width, height: height, pixels: pixels, orientation: orientation, colorSpace: colorSpace)
    }

    private func mask(_ width: Int, _ height: Int, _ pixels: [UInt8]) -> Mask8Raster {
        .init(width: width, height: height, pixels: pixels)
    }

    private func rgbaFixture(width: Int, height: Int, seed: UInt8) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * 4)
        for index in 0 ..< width * height {
            bytes.append(UInt8(truncatingIfNeeded: Int(seed) + index * 31))
            bytes.append(UInt8(truncatingIfNeeded: Int(seed) + index * 47))
            bytes.append(UInt8(truncatingIfNeeded: Int(seed) + index * 59))
            bytes.append(255)
        }
        return bytes
    }

    private func blend(front: [UInt8], background: [UInt8], mask: Int) -> [UInt8] {
        var blended: [UInt8] = []
        blended.reserveCapacity(front.count)
        let inverseMask = 255 - mask
        for index in front.indices {
            let foreground = Int(front[index])
            let replacement = Int(background[index])
            let numerator = foreground * mask + replacement * inverseMask + 127
            blended.append(UInt8(numerator / 255))
        }
        return blended
    }

    private func fnv1a(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
    }
}
