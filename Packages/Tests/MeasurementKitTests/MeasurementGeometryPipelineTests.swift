import CoreGraphics
import DomainKit
import Foundation
import MeasurementKit
import Testing

@Test func geometryPipelineAcceptsExactMinimumMarkerSideAndRejectsJustBelow() throws {
  let mask = try sourceMask(maxX: 676)
  let rejected = pipeline(marker: squareMarker(x: 700, y: 700, side: 79), mask: mask)
    .process(image: try testImage())
  try expectMeasurementFailure(rejected, .markerTooSmall)
  expectNoOutput(rejected)

  let accepted = pipeline(marker: squareMarker(x: 700, y: 700, side: 80), mask: mask)
    .process(image: try testImage())
  let output = try requireOutput(accepted)
  #expect(abs(output.pixelsPerCentimeter - 16) < 0.000_001)
}

@Test func geometryPipelineRejectsCornerAtSixteenAndAcceptsSeventeenPixels() throws {
  let mask = try sourceMask(minX: 200, maxX: 600)
  let atBoundary = pipeline(marker: squareMarker(x: 16, y: 200, side: 100), mask: mask)
    .process(image: try testImage())
  try expectMeasurementFailure(atBoundary, .markerMissing)
  expectNoOutput(atBoundary)

  let beyondBoundary = pipeline(marker: squareMarker(x: 17, y: 200, side: 100), mask: mask)
    .process(image: try testImage())
  _ = try requireOutput(beyondBoundary)
}

@Test func geometryPipelineRejectsPointSixFourNineRatioAndAcceptsPointSixFiveZero() throws {
  let mask = try sourceMask(maxX: 676)
  let rejected = pipeline(
    marker: rectangleMarker(x: 700, y: 700, width: 124, height: 124 * 0.649),
    mask: mask
  ).process(image: try testImage())
  try expectMeasurementFailure(rejected, .markerMissing)
  expectNoOutput(rejected)

  let accepted = pipeline(
    marker: rectangleMarker(x: 700, y: 700, width: 124, height: 124 * 0.650),
    mask: mask
  ).process(image: try testImage())
  _ = try requireOutput(accepted)
}

@Test func geometryPipelineRejectsTwentyThreeAndAcceptsTwentyFourPixelGarmentGap() throws {
  let marker = squareMarker(x: 700, y: 700, side: 100)
  let rejected = pipeline(marker: marker, mask: try sourceMask(maxX: 677))
    .process(image: try testImage())
  try expectMeasurementFailure(rejected, .garmentMarkerOverlap)
  expectNoOutput(rejected)

  let accepted = pipeline(marker: marker, mask: try sourceMask(maxX: 676))
    .process(image: try testImage())
  _ = try requireOutput(accepted)
}

@Test func geometryPipelineRequiresWholeGarmentInsideFrame() throws {
  let mask = try rectangularMask(
    width: 1_000,
    height: 1_000,
    minX: 0,
    minY: 100,
    maxX: 600,
    maxY: 800
  )
  let result = pipeline(marker: squareMarker(x: 700, y: 700, side: 100), mask: mask)
    .process(image: try testImage())
  try expectMeasurementFailure(result, .garmentOutOfFrame)
  expectNoOutput(result)
}

@Test func geometryPipelineRejectsMaskWhosePixelSpaceDoesNotMatchTheUprightImage() throws {
  let mismatched = try rectangularMask(
    width: 999,
    height: 1_000,
    minX: 100,
    minY: 100,
    maxX: 675,
    maxY: 850
  )
  let result = pipeline(
    marker: squareMarker(x: 700, y: 700, side: 100),
    mask: mismatched
  ).process(image: try testImage())
  try expectMeasurementFailure(result, .segmentationFailed)
  expectNoOutput(result)
}

@Test func geometryPipelineRejectsDarkAndBlurWithoutReturningScale() throws {
  let mask = try sourceMask(maxX: 676)
  for (quality, expected) in [
    (MeasurementImageQuality.tooDark, LocalQualityHint.tooDark),
    (.tooBlurry, .tooBlurry),
  ] {
    let engine = TestGeometryEngine(
      markerEvidence: .single(squareMarker(x: 700, y: 700, side: 100)),
      maskEvidence: .mask(mask),
      quality: quality
    )
    let result = MeasurementGeometryPipeline(engine: engine)
      .process(image: try testImage())
    let error = try requireFailure(result)
    guard case .quality(let actual) = error else {
      Issue.record("expected a finite quality rejection")
      continue
    }
    #expect(actual.rawValue == expected.rawValue)
    expectNoOutput(result)
    #expect(!engine.calls.contains("rectify"))
  }
}

@Test func geometryPipelineMapsMarkerAndMaskEvidenceToFiniteFailures() throws {
  let mask = try sourceMask(maxX: 676)
  let image = try testImage()
  let cases: [(MeasurementMarkerEvidence, MeasurementFailure)] = [
    (MeasurementMarkerEvidence(candidates: []), .markerMissing),
    (MeasurementMarkerEvidence(candidates: [], hasOccludedMarkerEvidence: true), .markerOccluded),
    (
      MeasurementMarkerEvidence(candidates: [
        MeasurementMarkerCandidate(corners: squareMarker(x: 700, y: 700, side: 100)),
        MeasurementMarkerCandidate(corners: squareMarker(x: 820, y: 700, side: 100)),
      ]), .markerMultiple
    ),
  ]
  for (evidence, expected) in cases {
    let engine = TestGeometryEngine(
      markerEvidence: evidence,
      maskEvidence: .mask(mask)
    )
    let result = MeasurementGeometryPipeline(engine: engine).process(image: image)
    try expectMeasurementFailure(result, expected)
    expectNoOutput(result)
  }

  for (evidence, expected) in [
    (MeasurementGarmentMaskEvidence.outOfFrame, MeasurementFailure.garmentOutOfFrame),
    (.unavailable, .segmentationFailed),
  ] {
    let engine = TestGeometryEngine(
      markerEvidence: .single(squareMarker(x: 700, y: 700, side: 100)),
      maskEvidence: evidence
    )
    let result = MeasurementGeometryPipeline(engine: engine).process(image: image)
    try expectMeasurementFailure(result, expected)
    expectNoOutput(result)
  }
}

@Test func geometryPipelineCanonicalizesCornerOrderAndRoundTripsDoublePoints() throws {
  let corners = [
    MeasurementPixelPoint(x: 700, y: 650),
    MeasurementPixelPoint(x: 830, y: 675),
    MeasurementPixelPoint(x: 805, y: 795),
    MeasurementPixelPoint(x: 680, y: 770),
  ]
  let expected = try #require(MeasurementQuadrilateral(ordering: corners))
  let mask = try sourceMask(maxX: 640)
  var frozenScale: Double?

  for ordering in permutations(corners) {
    let marker = try #require(MeasurementQuadrilateral(ordering: ordering))
    #expect(marker == expected)
    let output = try requireOutput(
      pipeline(marker: marker, mask: mask).process(image: try testImage())
    )
    if let frozenScale {
      #expect(abs(output.pixelsPerCentimeter - frozenScale) < 0.000_001)
    } else {
      frozenScale = output.pixelsPerCentimeter
    }
    let source = MeasurementPixelPoint(x: 413.125, y: 528.875)
    let corrected = try #require(output.correctedPoint(forSourcePoint: source))
    let roundTrip = try #require(output.sourcePoint(forCorrectedPoint: corrected))
    #expect(abs(roundTrip.x - source.x) < 0.000_008)
    #expect(abs(roundTrip.y - source.y) < 0.000_008)
    #expect(corrected.x.isFinite)
    #expect(corrected.y.isFinite)
  }
}

@Test func geometryPipelineRectifiesKnownFiveCentimeterMarkerAndMaskTogether() throws {
  let marker = squareMarker(x: 700, y: 700, side: 100)
  let engine = TestGeometryEngine(
    markerEvidence: .single(marker),
    maskEvidence: .mask(try sourceMask(maxX: 676))
  )
  let output = try requireOutput(
    MeasurementGeometryPipeline(engine: engine).process(image: try testImage())
  )

  #expect(abs(output.pixelsPerCentimeter - 20) < 0.000_001)
  #expect(output.correctedImage.width == output.correctedImageSize.width)
  #expect(output.correctedImage.height == output.correctedImageSize.height)
  #expect(output.correctedGarmentMask.width == output.correctedImageSize.width)
  #expect(output.correctedGarmentMask.height == output.correctedImageSize.height)
  let correctedSides = output.correctedMarkerCorners.sideLengths
  #expect(correctedSides.allSatisfy { abs($0 - 100) < 0.000_008 })
  #expect(engine.calls == ["upright", "quality", "marker", "mask", "rectify"])
}

@Test func geometryPipelineFailsClosedWhenRendererReturnsWrongDimensions() throws {
  let engine = TestGeometryEngine(
    markerEvidence: .single(squareMarker(x: 700, y: 700, side: 100)),
    maskEvidence: .mask(try sourceMask(maxX: 676)),
    rectificationMode: .wrongDimensions
  )
  let result = MeasurementGeometryPipeline(engine: engine)
    .process(image: try testImage())
  let error = try requireFailure(result)
  guard case .invalidRectification = error else {
    Issue.record("wrong raster dimensions must fail without an output")
    return
  }
  expectNoOutput(result)
}

@Test func geometryPipelineMapsEngineErrorsWithoutLeakingPartialValues() throws {
  let image = try testImage()
  let mask = try sourceMask(maxX: 676)
  for stage in MeasurementGeometryPipelineStage.testCases {
    let engine = TestGeometryEngine(
      markerEvidence: .single(squareMarker(x: 700, y: 700, side: 100)),
      maskEvidence: .mask(mask),
      failingStage: stage
    )
    let result = MeasurementGeometryPipeline(engine: engine).process(image: image)
    let error = try requireFailure(result)
    guard case .engineUnavailable(let actual) = error else {
      Issue.record("expected engineUnavailable for \(stage)")
      continue
    }
    #expect(actual == stage)
    expectNoOutput(result)
  }
}

@Test func geometryPipelineObservesCancellationBetweenBoundedStages() throws {
  let checker = StepCancellationChecker(cancelAtCheck: 4)
  let engine = TestGeometryEngine(
    markerEvidence: .single(squareMarker(x: 700, y: 700, side: 100)),
    maskEvidence: .mask(try sourceMask(maxX: 676))
  )
  let result = MeasurementGeometryPipeline(
    engine: engine,
    cancellationChecker: checker
  ).process(image: try testImage())
  let error = try requireFailure(result)
  guard case .cancelled = error else {
    Issue.record("cancellation must be a finite failure")
    return
  }
  #expect(engine.calls == ["upright", "quality", "marker"])
  #expect(!engine.calls.contains("mask"))
  #expect(!engine.calls.contains("rectify"))
  expectNoOutput(result)
}

@Test func projectiveTransformRejectsDegenerateGeometryAndNonFinitePoints() throws {
  let valid = squareMarker(x: 0, y: 0, side: 100)
  let degenerate = MeasurementQuadrilateral(
    topLeft: MeasurementPixelPoint(x: 0, y: 0),
    topRight: MeasurementPixelPoint(x: 1, y: 0),
    bottomRight: MeasurementPixelPoint(x: 2, y: 0),
    bottomLeft: MeasurementPixelPoint(x: 3, y: 0)
  )
  #expect(MeasurementProjectiveTransform(source: degenerate, destination: valid) == nil)
  let transform = try #require(MeasurementProjectiveTransform(source: valid, destination: valid))
  #expect(transform.applying(to: MeasurementPixelPoint(x: .infinity, y: 1)) == nil)
}

private enum RectificationMode {
  case valid
  case wrongDimensions
}

private enum TestGeometryEngineError: Error {
  case injected
}

private final class TestGeometryEngine: MeasurementGeometryPipelineEngine {
  let markerEvidence: MeasurementMarkerEvidence
  let maskEvidence: MeasurementGarmentMaskEvidence
  let quality: MeasurementImageQuality
  let rectificationMode: RectificationMode
  let failingStage: MeasurementGeometryPipelineStage?
  var calls: [String] = []

  init(
    markerEvidence: MeasurementMarkerEvidence,
    maskEvidence: MeasurementGarmentMaskEvidence,
    quality: MeasurementImageQuality = .acceptable,
    rectificationMode: RectificationMode = .valid,
    failingStage: MeasurementGeometryPipelineStage? = nil
  ) {
    self.markerEvidence = markerEvidence
    self.maskEvidence = maskEvidence
    self.quality = quality
    self.rectificationMode = rectificationMode
    self.failingStage = failingStage
  }

  func uprightImage(
    from image: CGImage,
    orientation: MeasurementImageOrientation
  ) throws -> CGImage {
    calls.append("upright")
    if failingStage == .normalization { throw TestGeometryEngineError.injected }
    return image
  }

  func analyzeQuality(in uprightImage: CGImage) throws -> MeasurementImageQuality {
    calls.append("quality")
    if failingStage == .qualityAnalysis { throw TestGeometryEngineError.injected }
    return quality
  }

  func detectMarkerEvidence(in uprightImage: CGImage) throws -> MeasurementMarkerEvidence {
    calls.append("marker")
    if failingStage == .markerDetection { throw TestGeometryEngineError.injected }
    return markerEvidence
  }

  func detectGarmentMask(in uprightImage: CGImage) throws -> MeasurementGarmentMaskEvidence {
    calls.append("mask")
    if failingStage == .garmentMaskDetection { throw TestGeometryEngineError.injected }
    return maskEvidence
  }

  func rectifyPlane(
    image: CGImage,
    garmentMask: MeasurementGarmentMask,
    sourceToCorrected: MeasurementProjectiveTransform,
    outputSize: CorrectedMeasurementImageSize
  ) throws -> MeasurementPlaneRectification {
    calls.append("rectify")
    if failingStage == .perspectiveCorrection { throw TestGeometryEngineError.injected }
    let width = rectificationMode == .valid ? outputSize.width : outputSize.width + 1
    let correctedImage = try testImage(width: width, height: outputSize.height)
    let correctedMask = try rectangularMask(
      width: outputSize.width,
      height: outputSize.height,
      minX: max(1, outputSize.width / 10),
      minY: max(1, outputSize.height / 10),
      maxX: max(2, outputSize.width * 6 / 10),
      maxY: max(2, outputSize.height * 8 / 10)
    )
    return MeasurementPlaneRectification(
      image: correctedImage,
      garmentMask: correctedMask
    )
  }
}

private final class StepCancellationChecker: MeasurementGeometryPipelineCancellationChecking {
  let cancelAtCheck: Int
  var checkCount = 0

  init(cancelAtCheck: Int) {
    self.cancelAtCheck = cancelAtCheck
  }

  func checkCancellation() throws {
    checkCount += 1
    if checkCount == cancelAtCheck { throw CancellationError() }
  }
}

extension MeasurementMarkerEvidence {
  fileprivate static func single(_ quadrilateral: MeasurementQuadrilateral) -> Self {
    MeasurementMarkerEvidence(candidates: [MeasurementMarkerCandidate(corners: quadrilateral)])
  }
}

extension MeasurementGeometryPipelineStage {
  fileprivate static let testCases: [Self] = [
    .normalization,
    .qualityAnalysis,
    .markerDetection,
    .garmentMaskDetection,
    .perspectiveCorrection,
  ]
}

private func pipeline(
  marker: MeasurementQuadrilateral,
  mask: MeasurementGarmentMask
) -> MeasurementGeometryPipeline {
  MeasurementGeometryPipeline(
    engine: TestGeometryEngine(
      markerEvidence: .single(marker),
      maskEvidence: .mask(mask)
    ))
}

private func squareMarker(
  x: Double,
  y: Double,
  side: Double
) -> MeasurementQuadrilateral {
  rectangleMarker(x: x, y: y, width: side, height: side)
}

private func rectangleMarker(
  x: Double,
  y: Double,
  width: Double,
  height: Double
) -> MeasurementQuadrilateral {
  MeasurementQuadrilateral(
    topLeft: MeasurementPixelPoint(x: x, y: y),
    topRight: MeasurementPixelPoint(x: x + width, y: y),
    bottomRight: MeasurementPixelPoint(x: x + width, y: y + height),
    bottomLeft: MeasurementPixelPoint(x: x, y: y + height)
  )
}

private func sourceMask(
  minX: Int = 100,
  maxX: Int,
  minY: Int = 100,
  maxY: Int = 850
) throws -> MeasurementGarmentMask {
  try rectangularMask(
    width: 1_000,
    height: 1_000,
    minX: minX,
    minY: minY,
    maxX: maxX,
    maxY: maxY
  )
}

private func rectangularMask(
  width: Int,
  height: Int,
  minX: Int,
  minY: Int,
  maxX: Int,
  maxY: Int
) throws -> MeasurementGarmentMask {
  var pixels = [UInt8](repeating: 0, count: width * height)
  if minX <= maxX, minY <= maxY {
    for y in max(0, minY)...min(height - 1, maxY) {
      for x in max(0, minX)...min(width - 1, maxX) {
        pixels[y * width + x] = 255
      }
    }
  }
  return try MeasurementGarmentMask(
    width: width,
    height: height,
    pixels: pixels,
    contour: [
      MeasurementPixelPoint(x: Double(minX), y: Double(minY)),
      MeasurementPixelPoint(x: Double(maxX), y: Double(minY)),
      MeasurementPixelPoint(x: Double(maxX), y: Double(maxY)),
      MeasurementPixelPoint(x: Double(minX), y: Double(maxY)),
    ]
  )
}

private func testImage(width: Int = 1_000, height: Int = 1_000) throws -> CGImage {
  let colorSpace = CGColorSpaceCreateDeviceGray()
  guard
    let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.none.rawValue
    )
  else { throw TestGeometryEngineError.injected }
  context.setFillColor(gray: 0.8, alpha: 1)
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  guard let image = context.makeImage() else { throw TestGeometryEngineError.injected }
  return image
}

private func requireOutput(
  _ result: MeasurementGeometryPipelineResult
) throws -> MeasurementGeometryPipelineOutput {
  guard case .success(let output) = result else {
    Issue.record("expected pipeline success")
    throw TestGeometryEngineError.injected
  }
  return output
}

private func requireFailure(
  _ result: MeasurementGeometryPipelineResult
) throws -> MeasurementGeometryPipelineError {
  guard case .failure(let error) = result else {
    Issue.record("expected pipeline failure")
    throw TestGeometryEngineError.injected
  }
  return error
}

private func expectMeasurementFailure(
  _ result: MeasurementGeometryPipelineResult,
  _ expected: MeasurementFailure
) throws {
  let error = try requireFailure(result)
  guard case .measurement(let actual) = error else {
    Issue.record("expected measurement failure \(expected.rawValue)")
    return
  }
  #expect(actual.rawValue == expected.rawValue)
}

private func expectNoOutput(_ result: MeasurementGeometryPipelineResult) {
  if case .success = result {
    Issue.record("invalid pipeline result must not expose scale or corrected values")
  }
}

private func permutations<T>(_ values: [T]) -> [[T]] {
  guard values.count > 1 else { return [values] }
  return values.indices.flatMap { index -> [[T]] in
    var remaining = values
    let head = remaining.remove(at: index)
    return permutations(remaining).map { [head] + $0 }
  }
}
