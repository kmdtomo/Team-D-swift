import CoreGraphics
import CoreImage
import Dispatch
import DomainKit
import Foundation
import ImageIO
import MeasurementKit
import Testing
import XCTest

@Test func t1101ArtifactVersionAndManifestArePinned() throws {
    let manifest = try loadCorpusManifest()
    #expect(MeasurementKitModule.fixtureArtifactVersion == "d588e48+3f64bb3+187cced")
    #expect(manifest.schemaVersion == 2)
    #expect(manifest.image.width == 800)
    #expect(manifest.image.height == 800)
    #expect(manifest.cases.count == 18)
    #expect(Set(manifest.cases.map(\.id)).count == manifest.cases.count)
}

@Test func productionApplePipelineClassifiesAllT1101SyntheticCases() throws {
    let manifest = try loadCorpusManifest()
    let pipeline = AppleMeasurementPoCPipeline()
    for fixture in manifest.cases {
        let image = try SyntheticFixtureImage.make(fixture, size: manifest.image.width)
        let annotation = try #require(manifest.annotations[fixture.annotationId])
        let outcome = pipeline.analyze(
            image: image,
            proposedEndpoints: annotation.endpointsPx.orderedPoints
        )
        try assertProduction(outcome: outcome, matches: fixture)
    }
}

@Test func productionApplePipelineIsReproducibleAcrossTheT1101Corpus() throws {
    let manifest = try loadCorpusManifest()
    let pipeline = AppleMeasurementPoCPipeline()
    for fixture in manifest.cases {
        let image = try SyntheticFixtureImage.make(fixture, size: manifest.image.width)
        let annotation = try #require(manifest.annotations[fixture.annotationId])
        let first = pipeline.analyze(
            image: image,
            proposedEndpoints: annotation.endpointsPx.orderedPoints
        )
        let second = pipeline.analyze(
            image: image,
            proposedEndpoints: annotation.endpointsPx.orderedPoints
        )
        #expect(outcomeSummary(first) == outcomeSummary(second), "\(fixture.id)")
    }
}

@Test func pipelineMapsSubsystemErrorsToRecoverableFiniteOutcomes() throws {
    let image = try SyntheticFixtureImage.solid(
        width: 800,
        height: 800,
        color: (234, 232, 224, 255)
    )
    let marker = MeasurementMarkerCandidate(corners: validMarker)
    let garment = MeasurementGarmentContour(points: validGarment)
    let corrected = RectifiedMarkerImage(image: image, rectifiedSidePixels: 100)

    #expect(
        outcomeSummary(AppleMeasurementPoCPipeline(
            markerDetector: ThrowingMarkerDetector(),
            contourDetector: StaticContourDetector(.contour(garment)),
            perspectiveCorrector: StaticPerspectiveCorrector(corrected),
            qualityAnalyzer: StaticQualityAnalyzer(.acceptable)
        ).analyze(image: image)) == "FAILURE:MARKER_MISSING"
    )
    #expect(
        outcomeSummary(AppleMeasurementPoCPipeline(
            markerDetector: StaticMarkerDetector([marker]),
            contourDetector: ThrowingContourDetector(),
            perspectiveCorrector: StaticPerspectiveCorrector(corrected),
            qualityAnalyzer: StaticQualityAnalyzer(.acceptable)
        ).analyze(image: image)) == "FAILURE:SEGMENTATION_FAILED"
    )
    #expect(
        outcomeSummary(AppleMeasurementPoCPipeline(
            markerDetector: StaticMarkerDetector([marker]),
            contourDetector: StaticContourDetector(.contour(garment)),
            perspectiveCorrector: ThrowingPerspectiveCorrector(),
            qualityAnalyzer: StaticQualityAnalyzer(.acceptable)
        ).analyze(image: image)) == "FAILURE:MARKER_MISSING"
    )
    #expect(
        outcomeSummary(AppleMeasurementPoCPipeline(
            markerDetector: StaticMarkerDetector([marker]),
            contourDetector: StaticContourDetector(.contour(garment)),
            perspectiveCorrector: StaticPerspectiveCorrector(corrected),
            qualityAnalyzer: ThrowingQualityAnalyzer()
        ).analyze(image: image)) == "QUALITY:ANALYZER_UNAVAILABLE"
    )
    #expect(
        outcomeSummary(AppleMeasurementPoCPipeline(
            markerDetector: StaticMarkerDetector([marker]),
            contourDetector: StaticContourDetector(.contour(garment)),
            perspectiveCorrector: StaticPerspectiveCorrector(corrected),
            qualityAnalyzer: StaticQualityAnalyzer(.acceptable),
            imageNormalizer: ThrowingImageNormalizer()
        ).analyze(image: image)) == "QUALITY:ANALYZER_UNAVAILABLE"
    )
}

@Test func polygonClearanceRejects23PixelsAndAccepts24Pixels() throws {
    let image = try SyntheticFixtureImage.solid(
        width: 800,
        height: 800,
        color: (234, 232, 224, 255)
    )
    let garment = MeasurementGarmentContour(points: [
        MeasurementPixelPoint(x: 110, y: 130),
        MeasurementPixelPoint(x: 550, y: 130),
        MeasurementPixelPoint(x: 550, y: 710),
        MeasurementPixelPoint(x: 110, y: 710),
    ])
    let corrector = StaticPerspectiveCorrector(
        RectifiedMarkerImage(image: image, rectifiedSidePixels: 100)
    )
    func outcome(markerLeft: Double) -> MeasurementPoCOutcome {
        let marker = MeasurementMarkerCandidate(corners: MeasurementQuadrilateral(
            topLeft: MeasurementPixelPoint(x: markerLeft, y: 610),
            topRight: MeasurementPixelPoint(x: markerLeft + 100, y: 610),
            bottomRight: MeasurementPixelPoint(x: markerLeft + 100, y: 710),
            bottomLeft: MeasurementPixelPoint(x: markerLeft, y: 710)
        ))
        return AppleMeasurementPoCPipeline(
            markerDetector: StaticMarkerDetector([marker]),
            contourDetector: StaticContourDetector(.contour(garment)),
            perspectiveCorrector: corrector,
            qualityAnalyzer: StaticQualityAnalyzer(.acceptable)
        ).analyze(image: image)
    }
    #expect(outcomeSummary(outcome(markerLeft: 573)) == "FAILURE:GARMENT_MARKER_OVERLAP")
    guard case .success = outcome(markerLeft: 574) else {
        Issue.record("24px polygon clearance must be accepted")
        return
    }
}

@Test func cornerOrderingAndSIMDProjectionAreStable() throws {
    let expected = MeasurementQuadrilateral(
        topLeft: MeasurementPixelPoint(x: 575, y: 600),
        topRight: MeasurementPixelPoint(x: 680, y: 615),
        bottomRight: MeasurementPixelPoint(x: 665, y: 715),
        bottomLeft: MeasurementPixelPoint(x: 560, y: 695)
    )
    for ordering in permutations(expected.points) {
        #expect(MeasurementQuadrilateral(ordering: ordering) == Optional(expected))
    }
    #expect(MeasurementQuadrilateral(ordering: [
        MeasurementPixelPoint(x: 0, y: 0),
        MeasurementPixelPoint(x: 100, y: 0),
        MeasurementPixelPoint(x: 50, y: 25),
        MeasurementPixelPoint(x: 0, y: 100),
    ]) == nil)
    let source = expected

    let square = MeasurementQuadrilateral(
        topLeft: MeasurementPixelPoint(x: 0, y: 0),
        topRight: MeasurementPixelPoint(x: 100, y: 0),
        bottomRight: MeasurementPixelPoint(x: 100, y: 100),
        bottomLeft: MeasurementPixelPoint(x: 0, y: 100)
    )
    let transform = try #require(SIMDProjectiveTransform(source: source, destination: square))
    for pair in zip(source.points, square.points) {
        let projected = try #require(transform.applying(to: pair.0))
        #expect(abs(projected.x - pair.1.x) < 0.000_001)
        #expect(abs(projected.y - pair.1.y) < 0.000_001)
    }
}

@Test func coreImagePerspectiveCorrectionProducesDeterministicSquareAndScale() throws {
    let manifest = try loadCorpusManifest()
    let fixture = try #require(manifest.cases.first { $0.id == "perspective-valid" })
    let image = try SyntheticFixtureImage.make(fixture, size: manifest.image.width)
    let corners = try #require(fixture.quadrilateral)
    let corrector = CoreImageMarkerPerspectiveCorrector(
        context: CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    )
    let first = try corrector.rectifyMarker(in: image, corners: corners)
    let second = try corrector.rectifyMarker(in: image, corners: corners)

    #expect(first.image.width == first.image.height)
    #expect(first.image.width == 99)
    let frozenPixelsPerCentimeter = 20.0
    let observedPixelsPerCentimeter = first.rectifiedSidePixels / 5
    #expect(
        abs(observedPixelsPerCentimeter - frozenPixelsPerCentimeter)
            / frozenPixelsPerCentimeter <= 0.01
    )
    #expect(first.rectifiedSidePixels == second.rectifiedSidePixels)
    #expect(try rgbaBytes(first.image) == rgbaBytes(second.image))
}

@Test func realVisionMarkerDetectionCoversAvailableSyntheticPixelCases() throws {
    let manifest = try loadCorpusManifest()
    let valid = try #require(manifest.cases.first { $0.id == "valid" })
    let perspective = try #require(manifest.cases.first { $0.id == "perspective-valid" })
    let missing = try #require(manifest.cases.first { $0.id == "marker-missing" })
    let detector = VisionRectangleMarkerDetector()

    let validEvidence = try detector.detectMarkerEvidence(
        in: SyntheticFixtureImage.make(valid, size: manifest.image.width)
    )
    let candidate = try #require(validEvidence.candidates.first)
    #expect(validEvidence.candidates.count == 1)
    for pair in zip(candidate.corners.points, try #require(valid.quadrilateral).points) {
        #expect(abs(pair.0.x - pair.1.x) <= 3)
        #expect(abs(pair.0.y - pair.1.y) <= 3)
    }

    let perspectiveEvidence = try detector.detectMarkerEvidence(
        in: SyntheticFixtureImage.make(perspective, size: manifest.image.width)
    )
    let perspectiveCandidate = try #require(perspectiveEvidence.candidates.first)
    for pair in zip(perspectiveCandidate.corners.points, try #require(perspective.quadrilateral).points) {
        #expect(abs(pair.0.x - pair.1.x) <= 4)
        #expect(abs(pair.0.y - pair.1.y) <= 4)
    }

    let missingEvidence = try detector.detectMarkerEvidence(
        in: SyntheticFixtureImage.make(missing, size: manifest.image.width)
    )
    #expect(missingEvidence.candidates.isEmpty)
    #expect(!missingEvidence.hasOccludedMarkerEvidence)
}

@Test func boundedMarkerFallbackRequiresFiveMillimeterNestedFrameAndMapsCoordinates() throws {
    let manifest = try loadCorpusManifest()
    let valid = try #require(manifest.cases.first { $0.id == "valid" })
    let occluded = try #require(manifest.cases.first { $0.id == "marker-occluded" })
    let detector = VisionRectangleMarkerDetector(usesVisionRectangles: false)

    #expect(VisionRectangleMarkerDetector.fallbackMaximumDimension == 320)
    let validEvidence = try detector.detectMarkerEvidence(
        in: SyntheticFixtureImage.make(valid, size: manifest.image.width)
    )
    let validCandidate = try #require(validEvidence.candidates.first)
    #expect(validEvidence.candidates.count == 1)
    for pair in zip(validCandidate.corners.points, try #require(valid.quadrilateral).points) {
        #expect(abs(pair.0.x - pair.1.x) <= 3)
        #expect(abs(pair.0.y - pair.1.y) <= 3)
    }

    let occludedEvidence = try detector.detectMarkerEvidence(
        in: SyntheticFixtureImage.make(occluded, size: manifest.image.width)
    )
    #expect(occludedEvidence.candidates.isEmpty)

    var hollowGraphic = PixelCanvas(width: 800, height: 800, color: (234, 232, 224, 255))
    hollowGraphic.drawMarker(
        x: 580,
        y: 610,
        width: 100,
        height: 100,
        occluded: false,
        borderFraction: 0.02
    )
    let hollowEvidence = try detector.detectMarkerEvidence(in: hollowGraphic.image())
    #expect(hollowEvidence.candidates.isEmpty)

    var large = PixelCanvas(width: 1_600, height: 800, color: (234, 232, 224, 255))
    large.drawMarker(x: 1_200, y: 500, width: 200, height: 200, occluded: false)
    let mapped = try #require(detector.detectMarkerEvidence(in: large.image()).candidates.first)
    let expected = MeasurementQuadrilateral(
        topLeft: MeasurementPixelPoint(x: 1_200, y: 500),
        topRight: MeasurementPixelPoint(x: 1_400, y: 500),
        bottomRight: MeasurementPixelPoint(x: 1_400, y: 700),
        bottomLeft: MeasurementPixelPoint(x: 1_200, y: 700)
    )
    for pair in zip(mapped.corners.points, expected.points) {
        #expect(abs(pair.0.x - pair.1.x) <= 5)
        #expect(abs(pair.0.y - pair.1.y) <= 5)
    }
}

@Test func pipelineNormalizesEveryEXIFOrientationIntoUprightCoordinateContract() throws {
    let manifest = try loadCorpusManifest()
    let fixture = try #require(manifest.cases.first { $0.id == "valid" })
    let annotation = try #require(manifest.annotations[fixture.annotationId])
    let upright = try SyntheticFixtureImage.make(fixture, size: manifest.image.width)
    let pipeline = AppleMeasurementPoCPipeline()
    let inverseOrientations: [(Int32, MeasurementImageOrientation)] = [
        (1, .up),
        (2, .upMirrored),
        (3, .down),
        (4, .downMirrored),
        (5, .leftMirrored),
        (6, .left),
        (7, .rightMirrored),
        (8, .right),
    ]
    for (pixelTransform, inputOrientation) in inverseOrientations {
        let transformed = try orientedImage(upright, exifOrientation: pixelTransform)
        let normalized = pipeline.analyze(
            image: transformed,
            orientation: inputOrientation,
            proposedEndpoints: annotation.endpointsPx.orderedPoints
        )
        try assertProduction(outcome: normalized, matches: fixture)
    }
}

@Test func accelerateQualitySeparatesNormalAndDarkFixture() throws {
    let manifest = try loadCorpusManifest()
    let valid = try #require(manifest.cases.first { $0.id == "valid" })
    let dark = try #require(manifest.cases.first { $0.id == "dark" })
    let analyzer = AccelerateMeasurementQualityAnalyzer()

    #expect(try analyzer.analyzeQuality(
        in: SyntheticFixtureImage.make(valid, size: manifest.image.width)
    ) == .acceptable)
    #expect(try analyzer.analyzeQuality(
        in: SyntheticFixtureImage.make(dark, size: manifest.image.width)
    ) == .tooDark)
}

@Test func visionContoursReturnTheSyntheticGarmentRegion() throws {
    let manifest = try loadCorpusManifest()
    let valid = try #require(manifest.cases.first { $0.id == "valid" })
    let evidence = try VisionGarmentContourDetector().detectGarmentContour(
        in: SyntheticFixtureImage.make(valid, size: manifest.image.width)
    )
    guard case let .contour(contour) = evidence else {
        Issue.record("expected a garment contour from the deterministic valid fixture")
        return
    }
    #expect(contour.bounds.width >= 400)
    #expect(contour.bounds.height >= 400)
    #expect(contour.bounds.minX > 2)
    #expect(contour.bounds.maxY < 798)
}

final class AppleMeasurementPipelinePerformanceTests: XCTestCase {
    func testCorpusRecordsRawP95LatencyAndEnforcesOneSecondPerImageGate() throws {
        let manifest = try loadCorpusManifest()
        let fixtures = try manifest.cases.map { fixture in
            (
                fixture: fixture,
                image: try SyntheticFixtureImage.make(fixture, size: manifest.image.width),
                endpoints: try XCTUnwrap(manifest.annotations[fixture.annotationId]).endpointsPx.orderedPoints
            )
        }
        let pipeline = AppleMeasurementPoCPipeline()
        var samples: [(fixtureID: String, milliseconds: Double)] = []
        samples.reserveCapacity(fixtures.count)

        for fixture in fixtures {
            let started = DispatchTime.now().uptimeNanoseconds
            let outcome = pipeline.analyze(
                image: fixture.image,
                proposedEndpoints: fixture.endpoints
            )
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            try assertProduction(outcome: outcome, matches: fixture.fixture)
            samples.append((fixture.fixture.id, Double(elapsed) / 1_000_000))
        }

        let sorted = samples.map(\.milliseconds).sorted()
        let p95Index = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        let p95Milliseconds = sorted[p95Index]
        let rawRecord = ([
            "engine=apple-vision-core-image-accelerate-simd",
            "corpus_schema=2",
            "sample_count=\(samples.count)",
            "p95_ms=\(p95Milliseconds)",
        ] + samples.map {
            "fixture_\($0.fixtureID)_ms=\($0.milliseconds)"
        }).joined(separator: "\n")
        let attachment = XCTAttachment(string: rawRecord)
        attachment.name = "t11-02-corpus-raw-latency"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertLessThanOrEqual(
            p95Milliseconds,
            1_000,
            "T11-02 baseline-device acceptance requires p95 <= 1 second"
        )
    }

    func testCorpusRecordsXCTestClockAndMemoryMetrics() throws {
        let manifest = try loadCorpusManifest()
        let fixtures = try manifest.cases.map { fixture in
            (
                image: try SyntheticFixtureImage.make(fixture, size: manifest.image.width),
                endpoints: try XCTUnwrap(manifest.annotations[fixture.annotationId]).endpointsPx.orderedPoints
            )
        }
        let pipeline = AppleMeasurementPoCPipeline()
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(
            metrics: [XCTClockMetric(), XCTMemoryMetric()],
            options: options
        ) {
            for fixture in fixtures {
                _ = pipeline.analyze(
                    image: fixture.image,
                    proposedEndpoints: fixture.endpoints
                )
            }
        }
    }
}

private func assertProduction(outcome: MeasurementPoCOutcome, matches fixture: CorpusCase) throws {
    if fixture.qualityHint == "TOO_DARK" || fixture.qualityHint == "TOO_BLURRY" {
        guard case let .qualityRejected(hint) = outcome else {
            Issue.record("\(fixture.id): expected a quality rejection, got \(outcomeSummary(outcome))")
            return
        }
        #expect(hint.rawValue == fixture.qualityHint)
        #expect(!fixture.scaleAccepted)
        return
    }

    if let expectedFailure = fixture.expectedFailure {
        guard case let .failure(failure) = outcome else {
            Issue.record("\(fixture.id): expected \(expectedFailure), got \(outcomeSummary(outcome))")
            return
        }
        #expect(failure.rawValue == expectedFailure)
        #expect(!fixture.scaleAccepted)
        return
    }

    guard case let .success(success) = outcome else {
        Issue.record("\(fixture.id): expected success, got \(outcomeSummary(outcome))")
        return
    }
    #expect(fixture.scaleAccepted)
    let expectedScale = try #require(fixture.renderedScalePxPerCm)
    #expect(
        abs(success.pixelsPerCentimeter - expectedScale) / expectedScale <= 0.01,
        "\(fixture.id): scale \(success.pixelsPerCentimeter), expected \(expectedScale)"
    )
    let expectedCorners = try #require(fixture.quadrilateral)
    for pair in zip(success.markerCorners.points, expectedCorners.points) {
        #expect(abs(pair.0.x - pair.1.x) <= 4, "\(fixture.id): x corner")
        #expect(abs(pair.0.y - pair.1.y) <= 4, "\(fixture.id): y corner")
    }
}

private func outcomeSummary(_ outcome: MeasurementPoCOutcome) -> String {
    switch outcome {
    case let .success(success):
        return "SUCCESS:\(success.pixelsPerCentimeter):\(success.markerCorners.points)"
    case let .failure(failure):
        return "FAILURE:\(failure.rawValue)"
    case let .qualityRejected(hint):
        return "QUALITY:\(hint.rawValue)"
    }
}

private func permutations(
    _ points: [MeasurementPixelPoint]
) -> [[MeasurementPixelPoint]] {
    guard points.count > 1 else { return [points] }
    return points.indices.flatMap { index -> [[MeasurementPixelPoint]] in
        var remainder = points
        let point = remainder.remove(at: index)
        return permutations(remainder).map { [point] + $0 }
    }
}

private enum TestSubsystemError: Error {
    case unavailable
}

private let validMarker = MeasurementQuadrilateral(
    topLeft: MeasurementPixelPoint(x: 580, y: 610),
    topRight: MeasurementPixelPoint(x: 680, y: 610),
    bottomRight: MeasurementPixelPoint(x: 680, y: 710),
    bottomLeft: MeasurementPixelPoint(x: 580, y: 710)
)

private let validGarment = [
    MeasurementPixelPoint(x: 110, y: 215),
    MeasurementPixelPoint(x: 220, y: 215),
    MeasurementPixelPoint(x: 220, y: 130),
    MeasurementPixelPoint(x: 440, y: 130),
    MeasurementPixelPoint(x: 440, y: 215),
    MeasurementPixelPoint(x: 550, y: 215),
    MeasurementPixelPoint(x: 550, y: 410),
    MeasurementPixelPoint(x: 440, y: 410),
    MeasurementPixelPoint(x: 440, y: 560),
    MeasurementPixelPoint(x: 220, y: 560),
    MeasurementPixelPoint(x: 220, y: 410),
    MeasurementPixelPoint(x: 110, y: 410),
]

private struct ThrowingMarkerDetector: MeasurementMarkerDetecting {
    func detectMarkerEvidence(in _: CGImage) throws -> MeasurementMarkerEvidence {
        throw TestSubsystemError.unavailable
    }
}

private struct StaticMarkerDetector: MeasurementMarkerDetecting {
    let candidates: [MeasurementMarkerCandidate]

    init(_ candidates: [MeasurementMarkerCandidate]) {
        self.candidates = candidates
    }

    func detectMarkerEvidence(in _: CGImage) throws -> MeasurementMarkerEvidence {
        MeasurementMarkerEvidence(candidates: candidates)
    }
}

private struct ThrowingContourDetector: MeasurementGarmentContourDetecting {
    func detectGarmentContour(in _: CGImage) throws -> MeasurementGarmentContourEvidence {
        throw TestSubsystemError.unavailable
    }
}

private struct StaticContourDetector: MeasurementGarmentContourDetecting {
    let evidence: MeasurementGarmentContourEvidence

    init(_ evidence: MeasurementGarmentContourEvidence) {
        self.evidence = evidence
    }

    func detectGarmentContour(in _: CGImage) throws -> MeasurementGarmentContourEvidence {
        evidence
    }
}

private struct ThrowingPerspectiveCorrector: MeasurementPerspectiveCorrecting {
    func rectifyMarker(in _: CGImage, corners _: MeasurementQuadrilateral) throws -> RectifiedMarkerImage {
        throw TestSubsystemError.unavailable
    }
}

private struct StaticPerspectiveCorrector: MeasurementPerspectiveCorrecting {
    let result: RectifiedMarkerImage

    init(_ result: RectifiedMarkerImage) {
        self.result = result
    }

    func rectifyMarker(in _: CGImage, corners _: MeasurementQuadrilateral) throws -> RectifiedMarkerImage {
        result
    }
}

private struct ThrowingQualityAnalyzer: MeasurementImageQualityAnalyzing {
    func analyzeQuality(in _: CGImage) throws -> MeasurementImageQuality {
        throw TestSubsystemError.unavailable
    }
}

private struct ThrowingImageNormalizer: MeasurementImageNormalizing {
    func uprightImage(
        from _: CGImage,
        orientation _: MeasurementImageOrientation
    ) throws -> CGImage {
        throw TestSubsystemError.unavailable
    }
}

private struct StaticQualityAnalyzer: MeasurementImageQualityAnalyzing {
    let quality: MeasurementImageQuality

    init(_ quality: MeasurementImageQuality) {
        self.quality = quality
    }

    func analyzeQuality(in _: CGImage) throws -> MeasurementImageQuality {
        quality
    }
}

private struct CorpusManifest: Decodable {
    let schemaVersion: Int
    let image: CorpusImageDescription
    let annotations: [String: CorpusAnnotation]
    let cases: [CorpusCase]
}

private struct CorpusImageDescription: Decodable {
    let width: Int
    let height: Int
}

private struct CorpusAnnotation: Decodable {
    let mask: CorpusMask
    let endpointsPx: CorpusEndpoints
}

private struct CorpusMask: Decodable {
    let polygon: [[Double]]?
}

private struct CorpusEndpoints: Decodable {
    let lengthStart: [Double]
    let lengthEnd: [Double]
    let widthStart: [Double]
    let widthEnd: [Double]

    var orderedPoints: [MeasurementPixelPoint] {
        [lengthStart, lengthEnd, widthStart, widthEnd].map(MeasurementPixelPoint.init)
    }
}

private struct CorpusCase: Decodable {
    let id: String
    let markerMode: String
    let markerGeometry: CorpusMarkerGeometry?
    let markerCorners: [[Double]]?
    let renderedScalePxPerCm: Double?
    let scaleAccepted: Bool
    let annotationId: String
    let expectedFailure: String?
    let garmentMode: String?
    let qualityFlag: String?
    let qualityHint: String?

    var quadrilateral: MeasurementQuadrilateral? {
        if let markerCorners {
            return MeasurementQuadrilateral(ordering: markerCorners.map(MeasurementPixelPoint.init))
        }
        guard let markerGeometry else { return nil }
        let height = markerGeometry.height ?? markerGeometry.side
        return MeasurementQuadrilateral(
            topLeft: MeasurementPixelPoint(x: markerGeometry.x, y: markerGeometry.y),
            topRight: MeasurementPixelPoint(x: markerGeometry.x + markerGeometry.side, y: markerGeometry.y),
            bottomRight: MeasurementPixelPoint(x: markerGeometry.x + markerGeometry.side, y: markerGeometry.y + height),
            bottomLeft: MeasurementPixelPoint(x: markerGeometry.x, y: markerGeometry.y + height)
        )
    }
}

private struct CorpusMarkerGeometry: Decodable {
    let x: Double
    let y: Double
    let side: Double
    let height: Double?
}

private extension MeasurementPixelPoint {
    init(_ values: [Double]) {
        self.init(x: values[0], y: values[1])
    }
}

private func loadCorpusManifest() throws -> CorpusManifest {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = repositoryRoot
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("MeasurementCorpus")
        .appendingPathComponent("corpus-manifest.json")
    return try JSONDecoder().decode(CorpusManifest.self, from: Data(contentsOf: url))
}

private enum SyntheticFixtureImage {
    typealias RGBA = (UInt8, UInt8, UInt8, UInt8)

    static func make(_ fixture: CorpusCase, size: Int) throws -> CGImage {
        var canvas = PixelCanvas(width: size, height: size, color: (234, 232, 224, 255))
        canvas.drawGarment(mode: fixture.garmentMode ?? "complete")
        if let geometry = fixture.markerGeometry {
            if let markerCorners = fixture.markerCorners {
                canvas.drawMarkerPolygon(
                    markerCorners.map { ($0[0], $0[1]) },
                    occluded: fixture.markerMode == "occluded"
                )
            } else {
                canvas.drawMarker(
                    x: Int(geometry.x),
                    y: Int(geometry.y),
                    width: Int(geometry.side),
                    height: Int(geometry.height ?? geometry.side),
                    occluded: fixture.markerMode == "occluded"
                )
            }
            if fixture.markerMode == "multiple" {
                canvas.drawMarker(x: 90, y: 70, width: 100, height: 100, occluded: false)
            }
        }
        if fixture.qualityFlag == "blur" { canvas.applyBlockBlur(size: 8) }
        if fixture.qualityFlag == "dark" { canvas.applyDarkening(divisor: 6) }
        return try canvas.image()
    }

    static func solid(width: Int, height: Int, color: RGBA) throws -> CGImage {
        try PixelCanvas(width: width, height: height, color: color).image()
    }
}

private struct PixelCanvas {
    private let width: Int
    private let height: Int
    private var bytes: [UInt8]

    init(width: Int, height: Int, color: SyntheticFixtureImage.RGBA) {
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        fillRect(x0: 0, y0: 0, x1: width, y1: height, color: color)
    }

    mutating func fillRect(
        x0: Int,
        y0: Int,
        x1: Int,
        y1: Int,
        color: SyntheticFixtureImage.RGBA
    ) {
        let startY = max(0, y0)
        let endY = max(0, min(height, y1))
        let startX = max(0, x0)
        let endX = max(0, min(width, x1))
        guard startY < endY, startX < endX else { return }
        for y in startY..<endY {
            for x in startX..<endX {
                let offset = (y * width + x) * 4
                bytes[offset] = color.0
                bytes[offset + 1] = color.1
                bytes[offset + 2] = color.2
                bytes[offset + 3] = color.3
            }
        }
    }

    mutating func drawGarment(mode: String) {
        let geometry = mode == "out_of_frame"
            ? (-20, 130, 710, 820)
            : (110, 130, 550, 560)
        let color: SyntheticFixtureImage.RGBA = mode == "low_contrast"
            ? (232, 231, 226, 255)
            : (50, 103, 157, 255)
        fillRect(x0: geometry.0 + 110, y0: geometry.1, x1: geometry.2 - 110, y1: geometry.3, color: color)
        fillRect(x0: geometry.0, y0: geometry.1 + 85, x1: geometry.0 + 150, y1: geometry.1 + 280, color: color)
        fillRect(x0: geometry.2 - 150, y0: geometry.1 + 85, x1: geometry.2, y1: geometry.1 + 280, color: color)
        let neck: SyntheticFixtureImage.RGBA = mode == "low_contrast"
            ? (225, 224, 220, 255)
            : (34, 75, 116, 255)
        fillRect(x0: geometry.0 + 230, y0: geometry.1, x1: geometry.2 - 230, y1: geometry.1 + 35, color: neck)
        if mode == "endpoint_invalid" {
            fillRect(x0: 110, y0: 215, x1: 195, y1: 410, color: (234, 232, 224, 255))
        }
    }

    mutating func drawMarker(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        occluded: Bool,
        borderFraction: Double = 0.10
    ) {
        fillRect(x0: x, y0: y, x1: x + width, y1: y + height, color: (0, 0, 0, 255))
        let inset = Int((Double(min(width, height)) * borderFraction).rounded())
        fillRect(
            x0: x + inset,
            y0: y + inset,
            x1: x + width - inset,
            y1: y + height - inset,
            color: (255, 255, 255, 255)
        )
        if occluded {
            fillRect(
                x0: x + width / 2,
                y0: y,
                x1: x + width,
                y1: y + height / 2,
                color: (50, 103, 157, 255)
            )
        }
    }

    mutating func drawMarkerPolygon(_ corners: [(Double, Double)], occluded: Bool) {
        fillPolygon(corners, color: (0, 0, 0, 255))
        let centerX = corners.map(\.0).reduce(0, +) / 4
        let centerY = corners.map(\.1).reduce(0, +) / 4
        let inner = corners.map {
            (($0.0 + (centerX - $0.0) * 0.2).rounded(), ($0.1 + (centerY - $0.1) * 0.2).rounded())
        }
        fillPolygon(inner, color: (255, 255, 255, 255))
        if occluded {
            let a = corners[0]
            let b = corners[1]
            let c = corners[2]
            let d = corners[3]
            fillPolygon(
                [
                    ((a.0 + b.0) / 2, (a.1 + b.1) / 2),
                    b,
                    c,
                    ((c.0 + d.0) / 2, (c.1 + d.1) / 2),
                ],
                color: (50, 103, 157, 255)
            )
        }
    }

    mutating func fillPolygon(_ points: [(Double, Double)], color: SyntheticFixtureImage.RGBA) {
        let yStart = max(0, Int(points.map(\.1).min() ?? 0))
        let yEnd = min(height, Int((points.map(\.1).max() ?? 0).rounded(.up)) + 1)
        for y in yStart..<yEnd {
            var intersections: [Double] = []
            for index in points.indices {
                let start = points[index]
                let end = points[(index + 1) % points.count]
                if (start.1 <= Double(y) && Double(y) < end.1)
                    || (end.1 <= Double(y) && Double(y) < start.1) {
                    intersections.append(
                        start.0 + (Double(y) - start.1) * (end.0 - start.0) / (end.1 - start.1)
                    )
                }
            }
            intersections.sort()
            for index in stride(from: 0, to: intersections.count - 1, by: 2) {
                fillRect(
                    x0: Int(intersections[index].rounded()),
                    y0: y,
                    x1: Int(intersections[index + 1].rounded()) + 1,
                    y1: y + 1,
                    color: color
                )
            }
        }
    }

    mutating func applyBlockBlur(size block: Int) {
        let original = bytes
        for y in stride(from: 0, to: height, by: block) {
            for x in stride(from: 0, to: width, by: block) {
                var sums = [Int](repeating: 0, count: 4)
                var count = 0
                for sampleY in y..<min(height, y + block) {
                    for sampleX in x..<min(width, x + block) {
                        let offset = (sampleY * width + sampleX) * 4
                        for channel in 0..<4 { sums[channel] += Int(original[offset + channel]) }
                        count += 1
                    }
                }
                let average: SyntheticFixtureImage.RGBA = (
                    UInt8(sums[0] / count),
                    UInt8(sums[1] / count),
                    UInt8(sums[2] / count),
                    UInt8(sums[3] / count)
                )
                fillRect(x0: x, y0: y, x1: min(width, x + block), y1: min(height, y + block), color: average)
            }
        }
    }

    mutating func applyDarkening(divisor: UInt8) {
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            bytes[offset] /= divisor
            bytes[offset + 1] /= divisor
            bytes[offset + 2] /= divisor
        }
    }

    func image() throws -> CGImage {
        let data = Data(bytes)
        let provider = try #require(CGDataProvider(data: data as CFData))
        return try #require(
            CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        )
    }
}

private func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let created = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    #expect(created)
    return bytes
}

private func orientedImage(_ image: CGImage, exifOrientation: Int32) throws -> CGImage {
    let oriented = CIImage(cgImage: image).oriented(forExifOrientation: exifOrientation)
    let extent = oriented.extent.standardized.integral
    let translated = oriented.transformed(
        by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
    )
    let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    return try #require(context.createCGImage(
        translated,
        from: CGRect(origin: .zero, size: extent.size)
    ))
}
