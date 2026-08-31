import CaptureKit
import DomainKit
import Testing

struct LocalQualityAnalyzerTests {
    @Test func allFiniteHintsAreReachable() throws {
        let defaults = LocalQualityAnalyzer()
        #expect(defaults.thresholds.minimumBrightness == 45)
        #expect(defaults.thresholds.maximumBrightness == 215)
        #expect(defaults.thresholds.minimumLaplacianVariance == 24)
        #expect(defaults.thresholds.maximumFrameDelta == 0.020)
        #expect(defaults.thresholds.requiredStableDurationMilliseconds == 600)
        #expect(defaults.thresholds.maxROIExtent == 320)
        let sharp = try checkerboard(width: 8, height: 8, low: 0, high: 200)
        let mid = try solid(width: 8, height: 8, value: 100)
        #expect(defaults.analyze(frame: try solid(width: 8, height: 8, value: 44), previousFrame: sharp, stableDurationMilliseconds: 600).hint == .tooDark)
        #expect(defaults.analyze(frame: try solid(width: 8, height: 8, value: 216), previousFrame: sharp, stableDurationMilliseconds: 600).hint == .tooBright)
        #expect(defaults.analyze(frame: mid, previousFrame: sharp, stableDurationMilliseconds: 600).hint == .tooBlurry)
        #expect(defaults.analyze(frame: sharp, previousFrame: nil, stableDurationMilliseconds: 600).hint == .holdSteady)
        #expect(defaults.analyze(frame: sharp, previousFrame: sharp, stableDurationMilliseconds: 600).hint == .ready)
        #expect(defaults.analyze(frame: sharp, previousFrame: sharp, stableDurationMilliseconds: -1).hint == .analyzerUnavailable)
        #expect(defaults.analyze(frame: nil, previousFrame: sharp, stableDurationMilliseconds: 600).hint == .analyzerUnavailable)
        #expect(Set(LocalQualityHint.allCases).count == 6)
    }

    @Test func brightnessBoundariesAreInclusiveAndPrecedeBlur() throws {
        let analyzer = LocalQualityAnalyzer()
        let sharp44 = try checkerboard(width: 8, height: 8, low: 0, high: 88)
        let sharp45 = try checkerboard(width: 8, height: 8, low: 0, high: 90)
        let sharp215 = try checkerboard(width: 8, height: 8, low: 175, high: 255)
        let sharp216 = try checkerboard(width: 8, height: 8, low: 177, high: 255)
        #expect(analyzer.analyze(frame: sharp44, previousFrame: sharp44, stableDurationMilliseconds: 600).hint == .tooDark)
        #expect(analyzer.analyze(frame: sharp45, previousFrame: sharp45, stableDurationMilliseconds: 600).hint == .ready)
        #expect(analyzer.analyze(frame: sharp215, previousFrame: sharp215, stableDurationMilliseconds: 600).hint == .ready)
        #expect(analyzer.analyze(frame: sharp216, previousFrame: sharp216, stableDurationMilliseconds: 600).hint == .tooBright)
        #expect(analyzer.analyze(frame: try solid(width: 8, height: 8, value: 44), previousFrame: nil, stableDurationMilliseconds: 0).hint == .tooDark)
    }

    @Test func lumaWeightsAlphaAndKnownLaplacianStencil() throws {
        let thresholds = try LocalQualityAnalyzer.Thresholds(minimumBrightness: 0, maximumBrightness: 255, minimumLaplacianVariance: 0, maximumFrameDelta: 1, requiredStableDurationMilliseconds: 0)
        let analyzer = LocalQualityAnalyzer(thresholds: thresholds)
        let rgb = try frame(width: 1, height: 1, pixels: [(100, 50, 25, 0)])
        let alphaChanged = try frame(width: 1, height: 1, pixels: [(100, 50, 25, 255)])
        #expect(analyzer.analyze(frame: rgb, previousFrame: rgb, stableDurationMilliseconds: 0).metrics?.meanLuma == analyzer.analyze(frame: alphaChanged, previousFrame: alphaChanged, stableDurationMilliseconds: 0).metrics?.meanLuma)
        #expect(analyzer.analyze(frame: rgb, previousFrame: rgb, stableDurationMilliseconds: 0).metrics?.meanLuma == 62)

        var stencilPixels = Array(repeating: (UInt8(0), UInt8(0), UInt8(0), UInt8(0)), count: 16)
        stencilPixels[5] = (255, 255, 255, 0)
        let stencil = try frame(width: 4, height: 4, pixels: stencilPixels)
        #expect(analyzer.analyze(frame: stencil, previousFrame: stencil, stableDurationMilliseconds: 0).metrics?.laplacianPopulationVariance == 276_356.25)
    }

    @Test func varianceThresholdAndFrameDeltaBoundaries() throws {
        let sharp = try checkerboard(width: 8, height: 8, low: 0, high: 200)
        let base = try LocalQualityAnalyzer.Thresholds(minimumBrightness: 0, maximumBrightness: 255, minimumLaplacianVariance: 0, maximumFrameDelta: 0.020, requiredStableDurationMilliseconds: 600)
        let analyzer = LocalQualityAnalyzer(thresholds: base)
        let metrics = try #require(analyzer.analyze(frame: sharp, previousFrame: sharp, stableDurationMilliseconds: 600).metrics)
        let equalVariance = try LocalQualityAnalyzer.Thresholds(minimumBrightness: 0, maximumBrightness: 255, minimumLaplacianVariance: metrics.laplacianPopulationVariance, maximumFrameDelta: 0.020, requiredStableDurationMilliseconds: 600)
        #expect(LocalQualityAnalyzer(thresholds: equalVariance).analyze(frame: sharp, previousFrame: sharp, stableDurationMilliseconds: 600).hint == .ready)
        let deltaBase = try grayscale(values: Array(repeating: 100, count: 10))
        let below = try grayscale(values: [150] + Array(repeating: 100, count: 9))
        let equal = try grayscale(values: [151] + Array(repeating: 100, count: 9))
        let above = try grayscale(values: [152] + Array(repeating: 100, count: 9))
        #expect(analyzer.analyze(frame: below, previousFrame: deltaBase, stableDurationMilliseconds: 600).metrics?.normalizedFrameDifference == 50.0 / (10 * 255))
        #expect(analyzer.analyze(frame: below, previousFrame: deltaBase, stableDurationMilliseconds: 600).hint == .ready)
        #expect(analyzer.analyze(frame: equal, previousFrame: deltaBase, stableDurationMilliseconds: 600).metrics?.normalizedFrameDifference == 0.020)
        #expect(analyzer.analyze(frame: equal, previousFrame: deltaBase, stableDurationMilliseconds: 600).hint == .holdSteady)
        #expect((analyzer.analyze(frame: above, previousFrame: deltaBase, stableDurationMilliseconds: 600).metrics?.normalizedFrameDifference ?? 0) > 0.020)
        #expect(analyzer.analyze(frame: above, previousFrame: deltaBase, stableDurationMilliseconds: 600).hint == .holdSteady)
        #expect(analyzer.analyze(frame: sharp, previousFrame: sharp, stableDurationMilliseconds: 599).hint == .holdSteady)
        #expect(analyzer.analyze(frame: sharp, previousFrame: sharp, stableDurationMilliseconds: 600).hint == .ready)
    }

    @Test func mismatchesDownscaleInjectionAndRepeatDeterminism() throws {
        let injected = try LocalQualityAnalyzer.Thresholds(minimumBrightness: 0, maximumBrightness: 255, minimumLaplacianVariance: 0, maximumFrameDelta: 1, requiredStableDurationMilliseconds: 0, maxROIExtent: 10)
        let analyzer = LocalQualityAnalyzer(thresholds: injected)
        let landscape = try checkerboard(width: 1000, height: 333, low: 0, high: 200)
        let portrait = try checkerboard(width: 333, height: 1000, low: 0, high: 200)
        let edge = try checkerboard(width: 1, height: 1000, low: 0, high: 200)
        #expect(analyzer.analyze(frame: landscape, previousFrame: landscape, stableDurationMilliseconds: 0).metrics?.processedWidth == 10)
        #expect(analyzer.analyze(frame: landscape, previousFrame: landscape, stableDurationMilliseconds: 0).metrics?.processedHeight == 3)
        #expect(analyzer.analyze(frame: portrait, previousFrame: portrait, stableDurationMilliseconds: 0).metrics?.processedWidth == 3)
        #expect(analyzer.analyze(frame: portrait, previousFrame: portrait, stableDurationMilliseconds: 0).metrics?.processedHeight == 10)
        #expect(analyzer.analyze(frame: edge, previousFrame: edge, stableDurationMilliseconds: 0).metrics?.processedWidth == 1)
        #expect(analyzer.analyze(frame: edge, previousFrame: edge, stableDurationMilliseconds: 0).metrics?.processedHeight == 10)
        #expect(analyzer.analyze(frame: landscape, previousFrame: portrait, stableDurationMilliseconds: 0).hint == .holdSteady)
        #expect(analyzer.analyze(frame: landscape, previousFrame: nil, stableDurationMilliseconds: 0).hint == .holdSteady)
        let stricterBrightness = try LocalQualityAnalyzer.Thresholds(minimumBrightness: 101, maximumBrightness: 200, minimumLaplacianVariance: 0, maximumFrameDelta: 1, requiredStableDurationMilliseconds: 0)
        #expect(LocalQualityAnalyzer(thresholds: stricterBrightness).analyze(frame: landscape, previousFrame: landscape, stableDurationMilliseconds: 0).hint == .tooDark)
        let first = analyzer.analyze(frame: landscape, previousFrame: landscape, stableDurationMilliseconds: 0)
        #expect(first == analyzer.analyze(frame: landscape, previousFrame: landscape, stableDurationMilliseconds: 0))
    }

    @Test func rejectsInvalidFramesAndThresholds() throws {
        #expect(throws: DomainValidationError.self) { try LocalQualityAnalyzer.RGBA8Frame(width: 0, height: 1, bytes: []) }
        #expect(throws: DomainValidationError.self) { try LocalQualityAnalyzer.RGBA8Frame(width: Int.max, height: 2, bytes: []) }
        #expect(throws: DomainValidationError.self) { try LocalQualityAnalyzer.RGBA8Frame(width: 1, height: 1, bytes: [0, 0, 0]) }
        #expect(throws: DomainValidationError.self) { try LocalQualityAnalyzer.Thresholds(minimumBrightness: .nan) }
        #expect(throws: DomainValidationError.self) { try LocalQualityAnalyzer.Thresholds(maximumBrightness: .infinity) }
        #expect(throws: DomainValidationError.self) { try LocalQualityAnalyzer.Thresholds(minimumBrightness: 216, maximumBrightness: 215) }
        #expect(throws: DomainValidationError.self) { try LocalQualityAnalyzer.Thresholds(minimumLaplacianVariance: -1) }
        #expect(throws: DomainValidationError.self) { try LocalQualityAnalyzer.Thresholds(maximumFrameDelta: 1.1) }
        #expect(throws: DomainValidationError.self) { try LocalQualityAnalyzer.Thresholds(requiredStableDurationMilliseconds: -1) }
        #expect(throws: DomainValidationError.self) { try LocalQualityAnalyzer.Thresholds(maxROIExtent: 321) }
    }

    private func solid(width: Int, height: Int, value: UInt8) throws -> LocalQualityAnalyzer.RGBA8Frame {
        try frame(width: width, height: height, pixels: Array(repeating: (value, value, value, 0), count: width * height))
    }

    private func checkerboard(width: Int, height: Int, low: UInt8, high: UInt8) throws -> LocalQualityAnalyzer.RGBA8Frame {
        try frame(width: width, height: height, pixels: (0 ..< width * height).map { index in
            let value = ((index / width) + (index % width)).isMultiple(of: 2) ? low : high
            return (value, value, value, 0)
        })
    }

    private func grayscale(values: [UInt8]) throws -> LocalQualityAnalyzer.RGBA8Frame {
        try frame(width: values.count, height: 1, pixels: values.map { ($0, $0, $0, 0) })
    }

    private func frame(width: Int, height: Int, pixels: [(UInt8, UInt8, UInt8, UInt8)]) throws -> LocalQualityAnalyzer.RGBA8Frame {
        try LocalQualityAnalyzer.RGBA8Frame(width: width, height: height, bytes: pixels.flatMap { [$0.0, $0.1, $0.2, $0.3] })
    }
}
