import Accelerate
import CoreGraphics
import CoreImage
import DomainKit
import Foundation
import ImageIO
import simd
import Vision

/// Apple-framework measurement work begins at milestone M0.
public enum MeasurementKitModule {
    public static let fixtureArtifactVersion = "d588e48+3f64bb3+187cced"
}

public struct MeasurementPixelPoint: Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var isFinite: Bool { x.isFinite && y.isFinite }
}

public struct MeasurementQuadrilateral: Equatable, Sendable {
    public let topLeft: MeasurementPixelPoint
    public let topRight: MeasurementPixelPoint
    public let bottomRight: MeasurementPixelPoint
    public let bottomLeft: MeasurementPixelPoint

    public init(
        topLeft: MeasurementPixelPoint,
        topRight: MeasurementPixelPoint,
        bottomRight: MeasurementPixelPoint,
        bottomLeft: MeasurementPixelPoint
    ) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    public init?(ordering points: [MeasurementPixelPoint]) {
        guard points.count == 4, points.allSatisfy(\.isFinite) else { return nil }
        let byVerticalPosition = points.sorted {
            if abs($0.y - $1.y) > 0.000_001 { return $0.y < $1.y }
            return $0.x < $1.x
        }
        let top = byVerticalPosition.prefix(2).sorted { $0.x < $1.x }
        let bottom = byVerticalPosition.suffix(2).sorted { $0.x < $1.x }
        self.init(
            topLeft: top[0],
            topRight: top[1],
            bottomRight: bottom[1],
            bottomLeft: bottom[0]
        )
    }

    public var points: [MeasurementPixelPoint] {
        [topLeft, topRight, bottomRight, bottomLeft]
    }

    public var sideLengths: [Double] {
        zip(points, Array(points.dropFirst()) + [topLeft]).map(distance)
    }

    public var minimumSideLength: Double { sideLengths.min() ?? 0 }
    public var maximumSideLength: Double { sideLengths.max() ?? 0 }
    public var sideRatio: Double {
        guard maximumSideLength > 0 else { return 0 }
        return minimumSideLength / maximumSideLength
    }

    public var center: MeasurementPixelPoint {
        MeasurementPixelPoint(
            x: points.map(\.x).reduce(0, +) / 4,
            y: points.map(\.y).reduce(0, +) / 4
        )
    }

    public var bounds: CGRect {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        return CGRect(
            x: xs.min() ?? 0,
            y: ys.min() ?? 0,
            width: (xs.max() ?? 0) - (xs.min() ?? 0),
            height: (ys.max() ?? 0) - (ys.min() ?? 0)
        )
    }

    /// The square side represented by the quadrilateral after projective
    /// correction. Area is less biased than an axis-aligned bounding box for
    /// the shallow perspective used by the measurement corpus.
    public var rectifiedSideEstimate: Double {
        let vertices = points
        var signedDoubleArea = 0.0
        for index in vertices.indices {
            let current = vertices[index]
            let next = vertices[(index + 1) % vertices.count]
            signedDoubleArea += current.x * next.y - next.x * current.y
        }
        return sqrt(abs(signedDoubleArea) / 2)
    }

    public func bilinearPoint(u: Double, v: Double) -> MeasurementPixelPoint {
        let oneMinusU = 1 - u
        let oneMinusV = 1 - v
        return MeasurementPixelPoint(
            x: topLeft.x * oneMinusU * oneMinusV
                + topRight.x * u * oneMinusV
                + bottomRight.x * u * v
                + bottomLeft.x * oneMinusU * v,
            y: topLeft.y * oneMinusU * oneMinusV
                + topRight.y * u * oneMinusV
                + bottomRight.y * u * v
                + bottomLeft.y * oneMinusU * v
        )
    }
}

public struct MeasurementMarkerCandidate: Equatable, Sendable {
    public let corners: MeasurementQuadrilateral

    public init(corners: MeasurementQuadrilateral) {
        self.corners = corners
    }
}

public struct MeasurementMarkerEvidence: Equatable, Sendable {
    public let candidates: [MeasurementMarkerCandidate]
    public let hasOccludedMarkerEvidence: Bool

    public init(candidates: [MeasurementMarkerCandidate], hasOccludedMarkerEvidence: Bool = false) {
        self.candidates = candidates
        self.hasOccludedMarkerEvidence = hasOccludedMarkerEvidence
    }
}

public struct MeasurementGarmentContour: Equatable, Sendable {
    public let points: [MeasurementPixelPoint]

    public init(points: [MeasurementPixelPoint]) {
        self.points = points
    }

    public var bounds: CGRect {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        return CGRect(
            x: xs.min() ?? 0,
            y: ys.min() ?? 0,
            width: (xs.max() ?? 0) - (xs.min() ?? 0),
            height: (ys.max() ?? 0) - (ys.min() ?? 0)
        )
    }
}

public enum MeasurementGarmentContourEvidence: Equatable, Sendable {
    case contour(MeasurementGarmentContour)
    case outOfFrame
    case unavailable
}

public enum MeasurementImageQuality: Equatable, Sendable {
    case acceptable
    case tooDark
    case tooBlurry
}

public struct RectifiedMarkerImage {
    public let image: CGImage
    public let rectifiedSidePixels: Double

    public init(image: CGImage, rectifiedSidePixels: Double) {
        self.image = image
        self.rectifiedSidePixels = rectifiedSidePixels
    }
}

public protocol MeasurementMarkerDetecting {
    func detectMarkerEvidence(in image: CGImage) throws -> MeasurementMarkerEvidence
}

public protocol MeasurementGarmentContourDetecting {
    func detectGarmentContour(in image: CGImage) throws -> MeasurementGarmentContourEvidence
}

public protocol MeasurementPerspectiveCorrecting {
    func rectifyMarker(in image: CGImage, corners: MeasurementQuadrilateral) throws -> RectifiedMarkerImage
}

public protocol MeasurementImageQualityAnalyzing {
    func analyzeQuality(in image: CGImage) throws -> MeasurementImageQuality
}

public struct MeasurementPoCConfiguration: Equatable, Sendable {
    public let knownMarkerSideCentimeters: Double
    public let minimumMarkerSidePixels: Double
    public let edgeMarginPixels: Double
    public let minimumMarkerSideRatio: Double
    public let minimumGarmentMarkerGapPixels: Double
    public let endpointTolerancePixels: Double

    public init(
        knownMarkerSideCentimeters: Double = 5,
        minimumMarkerSidePixels: Double = 80,
        edgeMarginPixels: Double = 16,
        minimumMarkerSideRatio: Double = 0.65,
        minimumGarmentMarkerGapPixels: Double = 24,
        endpointTolerancePixels: Double = 0.5
    ) {
        self.knownMarkerSideCentimeters = knownMarkerSideCentimeters
        self.minimumMarkerSidePixels = minimumMarkerSidePixels
        self.edgeMarginPixels = edgeMarginPixels
        self.minimumMarkerSideRatio = minimumMarkerSideRatio
        self.minimumGarmentMarkerGapPixels = minimumGarmentMarkerGapPixels
        self.endpointTolerancePixels = endpointTolerancePixels
    }
}

public struct MeasurementPoCSuccess: Equatable, Sendable {
    public let markerCorners: MeasurementQuadrilateral
    public let pixelsPerCentimeter: Double
    public let rectifiedWidth: Int
    public let rectifiedHeight: Int

    public init(
        markerCorners: MeasurementQuadrilateral,
        pixelsPerCentimeter: Double,
        rectifiedWidth: Int,
        rectifiedHeight: Int
    ) {
        self.markerCorners = markerCorners
        self.pixelsPerCentimeter = pixelsPerCentimeter
        self.rectifiedWidth = rectifiedWidth
        self.rectifiedHeight = rectifiedHeight
    }
}

public enum MeasurementPoCOutcome {
    case success(MeasurementPoCSuccess)
    case failure(MeasurementFailure)
    case qualityRejected(LocalQualityHint)
}

@available(macOS 11.0, *)
public struct AppleMeasurementPoCPipeline {
    private let markerDetector: any MeasurementMarkerDetecting
    private let contourDetector: any MeasurementGarmentContourDetecting
    private let perspectiveCorrector: any MeasurementPerspectiveCorrecting
    private let qualityAnalyzer: any MeasurementImageQualityAnalyzing
    private let configuration: MeasurementPoCConfiguration

    public init(
        markerDetector: any MeasurementMarkerDetecting = VisionRectangleMarkerDetector(),
        contourDetector: any MeasurementGarmentContourDetecting = VisionGarmentContourDetector(),
        perspectiveCorrector: any MeasurementPerspectiveCorrecting = CoreImageMarkerPerspectiveCorrector(),
        qualityAnalyzer: any MeasurementImageQualityAnalyzing = AccelerateMeasurementQualityAnalyzer(),
        configuration: MeasurementPoCConfiguration = MeasurementPoCConfiguration()
    ) {
        self.markerDetector = markerDetector
        self.contourDetector = contourDetector
        self.perspectiveCorrector = perspectiveCorrector
        self.qualityAnalyzer = qualityAnalyzer
        self.configuration = configuration
    }

    public func analyze(
        image: CGImage,
        proposedEndpoints: [MeasurementPixelPoint]? = nil
    ) throws -> MeasurementPoCOutcome {
        switch try qualityAnalyzer.analyzeQuality(in: image) {
        case .tooDark:
            return .qualityRejected(.tooDark)
        case .tooBlurry:
            return .qualityRejected(.tooBlurry)
        case .acceptable:
            break
        }

        let evidence = try markerDetector.detectMarkerEvidence(in: image)
        guard !evidence.candidates.isEmpty else {
            return .failure(evidence.hasOccludedMarkerEvidence ? .markerOccluded : .markerMissing)
        }
        guard evidence.candidates.count == 1 else { return .failure(.markerMultiple) }

        let marker = evidence.candidates[0].corners
        if marker.minimumSideLength < configuration.minimumMarkerSidePixels {
            return .failure(.markerTooSmall)
        }
        guard marker.sideRatio >= configuration.minimumMarkerSideRatio,
              markerIsInsideRequiredMargin(marker, image: image) else {
            // R5 exposes no separate skew/edge enum. T11-01 freezes these as
            // "no valid marker candidate accepted", compatibly MARKER_MISSING.
            return .failure(.markerMissing)
        }

        let garment: MeasurementGarmentContour
        switch try contourDetector.detectGarmentContour(in: image) {
        case let .contour(value):
            garment = value
        case .outOfFrame:
            return .failure(.garmentOutOfFrame)
        case .unavailable:
            return .failure(.segmentationFailed)
        }

        guard rectangleGap(between: garment.bounds, and: marker.bounds)
                >= configuration.minimumGarmentMarkerGapPixels else {
            return .failure(.garmentMarkerOverlap)
        }

        if let proposedEndpoints,
           proposedEndpoints.contains(where: {
               !contains($0, in: garment.points, tolerance: configuration.endpointTolerancePixels)
           }) {
            return .failure(.endpointsInvalid)
        }

        let rectified = try perspectiveCorrector.rectifyMarker(in: image, corners: marker)
        guard rectified.rectifiedSidePixels.isFinite,
              rectified.rectifiedSidePixels > 0,
              configuration.knownMarkerSideCentimeters > 0 else {
            return .failure(.markerMissing)
        }
        return .success(
            MeasurementPoCSuccess(
                markerCorners: marker,
                pixelsPerCentimeter: rectified.rectifiedSidePixels
                    / configuration.knownMarkerSideCentimeters,
                rectifiedWidth: rectified.image.width,
                rectifiedHeight: rectified.image.height
            )
        )
    }

    private func markerIsInsideRequiredMargin(_ marker: MeasurementQuadrilateral, image: CGImage) -> Bool {
        let width = Double(image.width)
        let height = Double(image.height)
        return marker.points.allSatisfy {
            $0.x > configuration.edgeMarginPixels
                && $0.y > configuration.edgeMarginPixels
                && $0.x < width - configuration.edgeMarginPixels
                && $0.y < height - configuration.edgeMarginPixels
        }
    }
}

public struct VisionRectangleMarkerDetector: MeasurementMarkerDetecting {
    public init() {}

    public func detectMarkerEvidence(in image: CGImage) throws -> MeasurementMarkerEvidence {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 32
        request.minimumAspectRatio = 0.5
        request.maximumAspectRatio = 1
        request.minimumSize = 0.004
        request.quadratureTolerance = 35
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])

        let gray = try GrayPixelPlane(image: image)
        var candidates: [MeasurementMarkerCandidate] = []
        for observation in request.results ?? [] {
            guard let corners = quadrilateral(from: observation, image: image),
                  hasDoubleSquareContrast(corners, pixels: gray) else { continue }
            let candidate = MeasurementMarkerCandidate(corners: corners)
            if candidates.contains(where: { distance($0.corners.center, corners.center) < 3 }) {
                continue
            }
            candidates.append(candidate)
        }
        for corners in gray.axisAlignedDoubleSquareCandidates() where
            !candidates.contains(where: { distance($0.corners.center, corners.center) < 3 }) {
            candidates.append(MeasurementMarkerCandidate(corners: corners))
        }

        let partialMarkerThreshold = max(64, image.width * image.height / 20_000)
        return MeasurementMarkerEvidence(
            candidates: candidates.sorted {
                if abs($0.corners.center.y - $1.corners.center.y) > 0.5 {
                    return $0.corners.center.y < $1.corners.center.y
                }
                return $0.corners.center.x < $1.corners.center.x
            },
            hasOccludedMarkerEvidence: candidates.isEmpty
                && gray.count(lessThan: 0.2) >= partialMarkerThreshold
        )
    }

    private func quadrilateral(
        from observation: VNRectangleObservation,
        image: CGImage
    ) -> MeasurementQuadrilateral? {
        func point(_ normalized: CGPoint) -> MeasurementPixelPoint {
            MeasurementPixelPoint(
                x: normalized.x * Double(image.width),
                y: (1 - normalized.y) * Double(image.height)
            )
        }
        return MeasurementQuadrilateral(
            topLeft: point(observation.topLeft),
            topRight: point(observation.topRight),
            bottomRight: point(observation.bottomRight),
            bottomLeft: point(observation.bottomLeft)
        )
    }

    private func hasDoubleSquareContrast(
        _ corners: MeasurementQuadrilateral,
        pixels: GrayPixelPlane
    ) -> Bool {
        let borderSamples = [
            corners.bilinearPoint(u: 0.50, v: 0.05),
            corners.bilinearPoint(u: 0.95, v: 0.50),
            corners.bilinearPoint(u: 0.50, v: 0.95),
            corners.bilinearPoint(u: 0.05, v: 0.50),
        ]
        let innerSamples = [
            corners.bilinearPoint(u: 0.50, v: 0.20),
            corners.bilinearPoint(u: 0.80, v: 0.50),
            corners.bilinearPoint(u: 0.50, v: 0.80),
            corners.bilinearPoint(u: 0.20, v: 0.50),
            corners.center,
        ]
        return borderSamples.allSatisfy { pixels.sample(at: $0) < 0.28 }
            && innerSamples.allSatisfy { pixels.sample(at: $0) > 0.68 }
    }
}

@available(macOS 11.0, *)
public struct VisionGarmentContourDetector: MeasurementGarmentContourDetecting {
    public init() {}

    public func detectGarmentContour(in image: CGImage) throws -> MeasurementGarmentContourEvidence {
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 1
        request.detectsDarkOnLight = true
        request.maximumImageDimension = 512
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else { return .unavailable }

        let minimumArea = Double(image.width * image.height) * 0.04
        let candidates = observation.topLevelContours.compactMap { contour -> MeasurementGarmentContour? in
            let points = contour.normalizedPoints.map {
                MeasurementPixelPoint(
                    x: Double($0.x) * Double(image.width),
                    y: (1 - Double($0.y)) * Double(image.height)
                )
            }
            guard points.count >= 4 else { return nil }
            let value = MeasurementGarmentContour(points: points)
            return value.bounds.width * value.bounds.height >= minimumArea ? value : nil
        }
        guard let largest = candidates.max(by: {
            $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
        }) else { return .unavailable }

        let frameTolerance = 2.0
        if largest.points.contains(where: {
            $0.x <= frameTolerance || $0.y <= frameTolerance
                || $0.x >= Double(image.width) - frameTolerance
                || $0.y >= Double(image.height) - frameTolerance
        }) {
            return .outOfFrame
        }
        return .contour(largest)
    }
}

public enum MeasurementPerspectiveError: Error, Equatable {
    case invalidCorners
    case correctionUnavailable
    case renderFailed
}

public struct CoreImageMarkerPerspectiveCorrector: MeasurementPerspectiveCorrecting {
    private let context: CIContext

    public init(context: CIContext = CIContext(options: [.cacheIntermediates: false])) {
        self.context = context
    }

    public func rectifyMarker(
        in image: CGImage,
        corners: MeasurementQuadrilateral
    ) throws -> RectifiedMarkerImage {
        let targetSide = corners.rectifiedSideEstimate
        guard targetSide.isFinite, targetSide > 0 else { throw MeasurementPerspectiveError.invalidCorners }

        let height = Double(image.height)
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
            throw MeasurementPerspectiveError.correctionUnavailable
        }
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        filter.setValue(ciVector(corners.topLeft, imageHeight: height), forKey: "inputTopLeft")
        filter.setValue(ciVector(corners.topRight, imageHeight: height), forKey: "inputTopRight")
        filter.setValue(ciVector(corners.bottomRight, imageHeight: height), forKey: "inputBottomRight")
        filter.setValue(ciVector(corners.bottomLeft, imageHeight: height), forKey: "inputBottomLeft")
        guard let output = filter.outputImage else { throw MeasurementPerspectiveError.correctionUnavailable }

        let extent = output.extent.standardized
        guard extent.width > 0, extent.height > 0 else { throw MeasurementPerspectiveError.correctionUnavailable }
        let translated = output.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        )
        let scaled = translated.transformed(
            by: CGAffineTransform(
                scaleX: targetSide / extent.width,
                y: targetSide / extent.height
            )
        )
        let side = max(1, Int(targetSide.rounded()))
        let renderExtent = CGRect(x: 0, y: 0, width: side, height: side)
        guard let rendered = context.createCGImage(scaled, from: renderExtent) else {
            throw MeasurementPerspectiveError.renderFailed
        }
        return RectifiedMarkerImage(image: rendered, rectifiedSidePixels: targetSide)
    }

    private func ciVector(_ point: MeasurementPixelPoint, imageHeight: Double) -> CIVector {
        CIVector(x: point.x, y: imageHeight - point.y)
    }
}

public struct SIMDProjectiveTransform: Equatable, Sendable {
    private let matrix: simd_double3x3

    public init?(source: MeasurementQuadrilateral, destination: MeasurementQuadrilateral) {
        guard let sourceMatrix = Self.unitSquareToQuadrilateral(source),
              let destinationMatrix = Self.unitSquareToQuadrilateral(destination) else { return nil }
        let candidate = destinationMatrix * sourceMatrix.inverse
        guard (0..<3).allSatisfy({ column in
            (0..<3).allSatisfy { candidate[column][$0].isFinite }
        }) else { return nil }
        matrix = candidate
    }

    public func applying(to point: MeasurementPixelPoint) -> MeasurementPixelPoint? {
        let homogeneous = matrix * SIMD3(point.x, point.y, 1)
        guard homogeneous.z.isFinite, abs(homogeneous.z) > 1e-12 else { return nil }
        let x = homogeneous.x / homogeneous.z
        let y = homogeneous.y / homogeneous.z
        guard x.isFinite, y.isFinite else { return nil }
        return MeasurementPixelPoint(x: x, y: y)
    }

    private static func unitSquareToQuadrilateral(
        _ quadrilateral: MeasurementQuadrilateral
    ) -> simd_double3x3? {
        let p0 = quadrilateral.topLeft
        let p1 = quadrilateral.topRight
        let p2 = quadrilateral.bottomRight
        let p3 = quadrilateral.bottomLeft
        let dx1 = p1.x - p2.x
        let dx2 = p3.x - p2.x
        let dx3 = p0.x - p1.x + p2.x - p3.x
        let dy1 = p1.y - p2.y
        let dy2 = p3.y - p2.y
        let dy3 = p0.y - p1.y + p2.y - p3.y
        let denominator = dx1 * dy2 - dx2 * dy1

        let g: Double
        let h: Double
        if abs(dx3) < 1e-12, abs(dy3) < 1e-12 {
            g = 0
            h = 0
        } else {
            guard abs(denominator) > 1e-12 else { return nil }
            g = (dx3 * dy2 - dx2 * dy3) / denominator
            h = (dx1 * dy3 - dx3 * dy1) / denominator
        }
        let a = p1.x - p0.x + g * p1.x
        let b = p3.x - p0.x + h * p3.x
        let c = p0.x
        let d = p1.y - p0.y + g * p1.y
        let e = p3.y - p0.y + h * p3.y
        let f = p0.y
        return simd_double3x3(
            SIMD3(a, d, g),
            SIMD3(b, e, h),
            SIMD3(c, f, 1)
        )
    }
}

public struct AccelerateMeasurementQualityAnalyzer: MeasurementImageQualityAnalyzing {
    public struct Configuration: Equatable, Sendable {
        public let darkMeanThreshold: Float
        public let blurLaplacianVarianceThreshold: Float
        public let analysisSide: Int

        public init(
            darkMeanThreshold: Float = 45 / 255,
            blurLaplacianVarianceThreshold: Float = 0.000_35,
            analysisSide: Int = 128
        ) {
            self.darkMeanThreshold = darkMeanThreshold
            self.blurLaplacianVarianceThreshold = blurLaplacianVarianceThreshold
            self.analysisSide = max(16, min(320, analysisSide))
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func analyzeQuality(in image: CGImage) throws -> MeasurementImageQuality {
        let plane = try GrayPixelPlane(image: image, scaledTo: configuration.analysisSide)
        var mean: Float = 0
        vDSP_meanv(plane.values, 1, &mean, vDSP_Length(plane.values.count))
        if mean < configuration.darkMeanThreshold { return .tooDark }

        let width = plane.width
        let height = plane.height
        var laplacian = [Float]()
        laplacian.reserveCapacity(max(0, (width - 2) * (height - 2)))
        if width >= 3, height >= 3 {
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let center = plane.values[y * width + x]
                    let value = plane.values[(y - 1) * width + x]
                        + plane.values[(y + 1) * width + x]
                        + plane.values[y * width + x - 1]
                        + plane.values[y * width + x + 1]
                        - 4 * center
                    laplacian.append(value)
                }
            }
        }
        guard !laplacian.isEmpty else { return .tooBlurry }
        var laplacianMean: Float = 0
        var meanSquare: Float = 0
        vDSP_meanv(laplacian, 1, &laplacianMean, vDSP_Length(laplacian.count))
        vDSP_measqv(laplacian, 1, &meanSquare, vDSP_Length(laplacian.count))
        let variance = max(0, meanSquare - laplacianMean * laplacianMean)
        return variance < configuration.blurLaplacianVarianceThreshold ? .tooBlurry : .acceptable
    }
}

private struct GrayPixelPlane {
    let width: Int
    let height: Int
    let values: [Float]

    init(image: CGImage, scaledTo requestedSide: Int? = nil) throws {
        let targetWidth: Int
        let targetHeight: Int
        if let requestedSide {
            let scale = min(1, Double(requestedSide) / Double(max(image.width, image.height)))
            targetWidth = max(1, Int((Double(image.width) * scale).rounded()))
            targetHeight = max(1, Int((Double(image.height) * scale).rounded()))
        } else {
            targetWidth = image.width
            targetHeight = image.height
        }
        var bytes = [UInt8](repeating: 0, count: targetWidth * targetHeight)
        let created = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: targetWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            return true
        }
        guard created else { throw MeasurementPerspectiveError.renderFailed }
        self.width = targetWidth
        self.height = targetHeight
        self.values = bytes.map { Float($0) / 255 }
    }

    func sample(at point: MeasurementPixelPoint) -> Float {
        let x = min(width - 1, max(0, Int(point.x.rounded())))
        let y = min(height - 1, max(0, Int(point.y.rounded())))
        return values[y * width + x]
    }

    func count(lessThan threshold: Float) -> Int {
        values.reduce(into: 0) { count, value in
            if value < threshold { count += 1 }
        }
    }

    func axisAlignedDoubleSquareCandidates() -> [MeasurementQuadrilateral] {
        var visited = [Bool](repeating: false, count: values.count)
        var results: [MeasurementQuadrilateral] = []
        for start in values.indices where !visited[start] && values[start] < 0.2 {
            var queue = [start]
            visited[start] = true
            var cursor = 0
            var minimumX = width
            var minimumY = height
            var maximumX = 0
            var maximumY = 0
            var count = 0
            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                let x = index % width
                let y = index / width
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
                count += 1
                let neighbors = [index - 1, index + 1, index - width, index + width]
                for neighbor in neighbors where neighbor >= 0 && neighbor < values.count {
                    let neighborX = neighbor % width
                    guard abs(neighborX - x) <= 1,
                          !visited[neighbor], values[neighbor] < 0.2 else { continue }
                    visited[neighbor] = true
                    queue.append(neighbor)
                }
            }
            let boundingArea = max(1, (maximumX - minimumX + 1) * (maximumY - minimumY + 1))
            let density = Double(count) / Double(boundingArea)
            guard count >= 64, density >= 0.14, density <= 0.55 else { continue }
            results.append(
                MeasurementQuadrilateral(
                    topLeft: MeasurementPixelPoint(x: Double(minimumX), y: Double(minimumY)),
                    topRight: MeasurementPixelPoint(x: Double(maximumX + 1), y: Double(minimumY)),
                    bottomRight: MeasurementPixelPoint(x: Double(maximumX + 1), y: Double(maximumY + 1)),
                    bottomLeft: MeasurementPixelPoint(x: Double(minimumX), y: Double(maximumY + 1))
                )
            )
        }
        return results
    }
}

private func distance(_ lhs: MeasurementPixelPoint, _ rhs: MeasurementPixelPoint) -> Double {
    hypot(lhs.x - rhs.x, lhs.y - rhs.y)
}

private func rectangleGap(between lhs: CGRect, and rhs: CGRect) -> Double {
    let horizontal: Double
    if lhs.maxX <= rhs.minX {
        horizontal = rhs.minX - lhs.maxX
    } else if rhs.maxX <= lhs.minX {
        horizontal = lhs.minX - rhs.maxX
    } else {
        horizontal = 0
    }
    let vertical: Double
    if lhs.maxY <= rhs.minY {
        vertical = rhs.minY - lhs.maxY
    } else if rhs.maxY <= lhs.minY {
        vertical = lhs.minY - rhs.maxY
    } else {
        vertical = 0
    }
    return hypot(horizontal, vertical)
}

private func contains(
    _ point: MeasurementPixelPoint,
    in polygon: [MeasurementPixelPoint],
    tolerance: Double
) -> Bool {
    guard point.isFinite, polygon.count >= 3 else { return false }
    var isInside = false
    for index in polygon.indices {
        let start = polygon[index]
        let end = polygon[(index + 1) % polygon.count]
        if pointToSegmentDistance(point, start, end) <= tolerance { return true }
        let crosses = (start.y > point.y) != (end.y > point.y)
        if crosses {
            let intersectionX = (end.x - start.x) * (point.y - start.y)
                / (end.y - start.y) + start.x
            if point.x < intersectionX { isInside.toggle() }
        }
    }
    return isInside
}

private func pointToSegmentDistance(
    _ point: MeasurementPixelPoint,
    _ start: MeasurementPixelPoint,
    _ end: MeasurementPixelPoint
) -> Double {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let denominator = dx * dx + dy * dy
    guard denominator > 0 else { return distance(point, start) }
    let projection = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / denominator))
    return distance(
        point,
        MeasurementPixelPoint(x: start.x + projection * dx, y: start.y + projection * dy)
    )
}
