import Accelerate
import DomainKit

/// Deterministic, ROI-local quality measurements for one owned RGBA8 frame.
///
/// The caller owns scheduling and the clock. A valid first frame, or a valid
/// frame whose geometry differs from its predecessor, returns `holdSteady`;
/// malformed input or a negative stable duration returns `analyzerUnavailable`.
public struct LocalQualityAnalyzer: Sendable {
    public struct Thresholds: Sendable, Equatable {
        public let minimumBrightness: Double
        public let maximumBrightness: Double
        public let minimumLaplacianVariance: Double
        public let maximumFrameDelta: Double
        public let requiredStableDurationMilliseconds: Int
        public let maxROIExtent: Int

        public static let `default` = Thresholds(
            uncheckedMinimumBrightness: 45,
            maximumBrightness: 215,
            minimumLaplacianVariance: 24,
            maximumFrameDelta: 0.020,
            requiredStableDurationMilliseconds: 600,
            maxROIExtent: 320
        )

        public init(
            minimumBrightness: Double = 45,
            maximumBrightness: Double = 215,
            minimumLaplacianVariance: Double = 24,
            maximumFrameDelta: Double = 0.020,
            requiredStableDurationMilliseconds: Int = 600,
            maxROIExtent: Int = 320
        ) throws {
            guard minimumBrightness.isFinite, maximumBrightness.isFinite,
                  minimumBrightness >= 0, maximumBrightness <= 255,
                  minimumBrightness <= maximumBrightness,
                  minimumLaplacianVariance.isFinite, minimumLaplacianVariance >= 0,
                  maximumFrameDelta.isFinite, (0...1).contains(maximumFrameDelta),
                  requiredStableDurationMilliseconds >= 0,
                  (1...320).contains(maxROIExtent)
            else {
                throw DomainValidationError.invalidValue("invalid local quality thresholds")
            }

            self.minimumBrightness = minimumBrightness
            self.maximumBrightness = maximumBrightness
            self.minimumLaplacianVariance = minimumLaplacianVariance
            self.maximumFrameDelta = maximumFrameDelta
            self.requiredStableDurationMilliseconds = requiredStableDurationMilliseconds
            self.maxROIExtent = maxROIExtent
        }

        private init(
            uncheckedMinimumBrightness minimumBrightness: Double,
            maximumBrightness: Double,
            minimumLaplacianVariance: Double,
            maximumFrameDelta: Double,
            requiredStableDurationMilliseconds: Int,
            maxROIExtent: Int
        ) {
            self.minimumBrightness = minimumBrightness
            self.maximumBrightness = maximumBrightness
            self.minimumLaplacianVariance = minimumLaplacianVariance
            self.maximumFrameDelta = maximumFrameDelta
            self.requiredStableDurationMilliseconds = requiredStableDurationMilliseconds
            self.maxROIExtent = maxROIExtent
        }
    }

    public struct RGBA8Frame: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let bytes: [UInt8]

        public init(width: Int, height: Int, bytes: [UInt8]) throws {
            guard width > 0, height > 0,
                  let pixelCount = Self.product(width, height),
                  let byteCount = Self.product(pixelCount, 4),
                  bytes.count == byteCount
            else {
                throw DomainValidationError.invalidValue("invalid RGBA8 frame dimensions or byte count")
            }

            self.width = width
            self.height = height
            self.bytes = bytes
        }

        private static func product(_ lhs: Int, _ rhs: Int) -> Int? {
            let result = lhs.multipliedReportingOverflow(by: rhs)
            return result.overflow ? nil : result.partialValue
        }
    }

    public struct Metrics: Sendable, Equatable {
        public let processedWidth: Int
        public let processedHeight: Int
        public let meanLuma: Double
        public let laplacianPopulationVariance: Double
        /// Nil when no geometrically compatible previous frame is available.
        public let normalizedFrameDifference: Double?
    }

    public struct Analysis: Sendable, Equatable {
        public let hint: LocalQualityHint
        public let metrics: Metrics?
    }

    public let thresholds: Thresholds

    public init() {
        self.thresholds = .default
    }

    public init(thresholds: Thresholds) {
        self.thresholds = thresholds
    }

    public func analyze(
        frame: RGBA8Frame?,
        previousFrame: RGBA8Frame?,
        stableDurationMilliseconds: Int
    ) -> Analysis {
        guard stableDurationMilliseconds >= 0, let frame else {
            return Analysis(hint: .analyzerUnavailable, metrics: nil)
        }

        let current = processed(frame)
        let currentMetrics = Metrics(
            processedWidth: current.width,
            processedHeight: current.height,
            meanLuma: mean(current.luma),
            laplacianPopulationVariance: laplacianPopulationVariance(
                current.luma,
                width: current.width,
                height: current.height
            ),
            normalizedFrameDifference: nil
        )

        if currentMetrics.meanLuma < thresholds.minimumBrightness {
            return Analysis(hint: .tooDark, metrics: currentMetrics)
        }
        if currentMetrics.meanLuma > thresholds.maximumBrightness {
            return Analysis(hint: .tooBright, metrics: currentMetrics)
        }
        if currentMetrics.laplacianPopulationVariance < thresholds.minimumLaplacianVariance {
            return Analysis(hint: .tooBlurry, metrics: currentMetrics)
        }

        guard let previousFrame,
              compatible(frame, previousFrame)
        else {
            return Analysis(hint: .holdSteady, metrics: currentMetrics)
        }

        let previous = processed(previousFrame)
        guard current.width == previous.width, current.height == previous.height else {
            return Analysis(hint: .holdSteady, metrics: currentMetrics)
        }

        let difference = normalizedDifference(current.luma, previous.luma)
        let metrics = Metrics(
            processedWidth: current.width,
            processedHeight: current.height,
            meanLuma: currentMetrics.meanLuma,
            laplacianPopulationVariance: currentMetrics.laplacianPopulationVariance,
            normalizedFrameDifference: difference
        )
        guard difference < thresholds.maximumFrameDelta,
              stableDurationMilliseconds >= thresholds.requiredStableDurationMilliseconds
        else {
            return Analysis(hint: .holdSteady, metrics: metrics)
        }
        return Analysis(hint: .ready, metrics: metrics)
    }

    private struct ProcessedFrame: Sendable {
        let width: Int
        let height: Int
        let luma: [Double]
    }

    private func processed(_ frame: RGBA8Frame) -> ProcessedFrame {
        let dimensions = downscaledDimensions(width: frame.width, height: frame.height)
        var luma = [Double]()
        luma.reserveCapacity(dimensions.width * dimensions.height)

        for y in 0 ..< dimensions.height {
            let sourceY = y * frame.height / dimensions.height
            for x in 0 ..< dimensions.width {
                let sourceX = x * frame.width / dimensions.width
                let offset = (sourceY * frame.width + sourceX) * 4
                let weighted = (76 * Int(frame.bytes[offset]))
                    + (150 * Int(frame.bytes[offset + 1]))
                    + (29 * Int(frame.bytes[offset + 2]))
                luma.append(Double(min(255, max(0, Int((Double(weighted) / 255).rounded())))))
            }
        }
        return ProcessedFrame(width: dimensions.width, height: dimensions.height, luma: luma)
    }

    private func downscaledDimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > thresholds.maxROIExtent else { return (width, height) }

        if width >= height {
            return (thresholds.maxROIExtent, scaledDimension(height, by: width))
        }
        return (scaledDimension(width, by: height), thresholds.maxROIExtent)
    }

    private func scaledDimension(_ shorter: Int, by longer: Int) -> Int {
        max(1, Int((Double(shorter) * Double(thresholds.maxROIExtent) / Double(longer)).rounded(.down)))
    }

    private func compatible(_ current: RGBA8Frame, _ previous: RGBA8Frame) -> Bool {
        guard current.width == previous.width, current.height == previous.height else {
            return false
        }
        let left = current.width.multipliedReportingOverflow(by: previous.height)
        let right = previous.width.multipliedReportingOverflow(by: current.height)
        return !left.overflow && !right.overflow && left.partialValue == right.partialValue
    }

    private func mean(_ values: [Double]) -> Double {
        var result = 0.0
        values.withUnsafeBufferPointer { values in
            vDSP_meanvD(values.baseAddress!, 1, &result, vDSP_Length(values.count))
        }
        return result
    }

    private func laplacianPopulationVariance(_ luma: [Double], width: Int, height: Int) -> Double {
        guard width >= 3, height >= 3 else { return 0 }
        var samples = [Double]()
        samples.reserveCapacity((width - 2) * (height - 2))
        for y in 1 ..< height - 1 {
            for x in 1 ..< width - 1 {
                let index = y * width + x
                samples.append(
                    luma[index - width] + luma[index + width] + luma[index - 1] + luma[index + 1] - (4 * luma[index])
                )
            }
        }
        let sampleMean = mean(samples)
        var meanSquare = 0.0
        samples.withUnsafeBufferPointer { samples in
            vDSP_measqvD(samples.baseAddress!, 1, &meanSquare, vDSP_Length(samples.count))
        }
        return max(0, meanSquare - (sampleMean * sampleMean))
    }

    private func normalizedDifference(_ current: [Double], _ previous: [Double]) -> Double {
        var differences = [Double](repeating: 0, count: current.count)
        current.withUnsafeBufferPointer { current in
            previous.withUnsafeBufferPointer { previous in
                differences.withUnsafeMutableBufferPointer { differences in
                    vDSP_vsubD(previous.baseAddress!, 1, current.baseAddress!, 1, differences.baseAddress!, 1, vDSP_Length(current.count))
                    vDSP_vabsD(differences.baseAddress!, 1, differences.baseAddress!, 1, vDSP_Length(current.count))
                    var divisor = 255.0
                    vDSP_vsdivD(differences.baseAddress!, 1, &divisor, differences.baseAddress!, 1, vDSP_Length(current.count))
                }
            }
        }
        return mean(differences)
    }
}
