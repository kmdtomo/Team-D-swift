import CoreGraphics
import DomainKit
import Foundation

/// Engine-neutral pixel mask for the garment in upright or corrected image coordinates.
/// Values are coverage bytes (`0` is background and `255` is opaque garment).
public struct MeasurementGarmentMask: Equatable, Sendable {
  public let width: Int
  public let height: Int
  public let pixels: [UInt8]
  public let contour: [MeasurementPixelPoint]

  public init(
    width: Int,
    height: Int,
    pixels: [UInt8],
    contour: [MeasurementPixelPoint]
  ) throws {
    guard width > 0, height > 0,
      width <= Int.max / height,
      pixels.count == width * height,
      contour.count >= 3,
      contour.allSatisfy(\.isFinite),
      pixels.contains(where: { $0 > 0 }),
      pixels.contains(where: { $0 < 255 })
    else {
      throw MeasurementGarmentMaskValidationError.invalidMask
    }
    self.width = width
    self.height = height
    self.pixels = pixels
    self.contour = contour
  }

  /// A garment on the source or corrected frame boundary is not wholly in frame.
  public var touchesFrame: Bool {
    if contour.contains(where: {
      $0.x <= 0 || $0.y <= 0
        || $0.x >= Double(width - 1)
        || $0.y >= Double(height - 1)
    }) {
      return true
    }
    guard width > 1, height > 1 else { return true }
    for x in 0..<width where pixels[x] > 0 || pixels[(height - 1) * width + x] > 0 {
      return true
    }
    for y in 0..<height where pixels[y * width] > 0 || pixels[y * width + width - 1] > 0 {
      return true
    }
    return false
  }
}

public enum MeasurementGarmentMaskValidationError: Error, Equatable, Sendable {
  case invalidMask
}

public enum MeasurementGarmentMaskEvidence: Equatable, Sendable {
  case mask(MeasurementGarmentMask)
  case outOfFrame
  case unavailable
}

/// Full corrected plane returned by whichever image engine T11-03 selects.
/// The renderer must apply the supplied Double-precision homography to both artifacts.
public struct MeasurementPlaneRectification {
  public let image: CGImage
  public let garmentMask: MeasurementGarmentMask

  public init(image: CGImage, garmentMask: MeasurementGarmentMask) {
    self.image = image
    self.garmentMask = garmentMask
  }
}

/// The only integration seam that depends on the T11-03 engine decision.
///
/// The pipeline owns validation, scale, transforms, and finite failure mapping. An adapter owns
/// framework calls and raster rendering, but cannot bypass the product thresholds.
public protocol MeasurementGeometryPipelineEngine {
  func uprightImage(
    from image: CGImage,
    orientation: MeasurementImageOrientation
  ) throws -> CGImage

  func analyzeQuality(in uprightImage: CGImage) throws -> MeasurementImageQuality
  func detectMarkerEvidence(in uprightImage: CGImage) throws -> MeasurementMarkerEvidence
  func detectGarmentMask(in uprightImage: CGImage) throws -> MeasurementGarmentMaskEvidence

  func rectifyPlane(
    image: CGImage,
    garmentMask: MeasurementGarmentMask,
    sourceToCorrected: MeasurementProjectiveTransform,
    outputSize: CorrectedMeasurementImageSize
  ) throws -> MeasurementPlaneRectification
}

public protocol MeasurementGeometryPipelineCancellationChecking {
  func checkCancellation() throws
}

public struct TaskMeasurementGeometryPipelineCancellationChecker:
  MeasurementGeometryPipelineCancellationChecking
{
  public init() {}

  public func checkCancellation() throws {
    try Task.checkCancellation()
  }
}

public struct MeasurementGeometryPipelineConfiguration: Equatable, Sendable {
  public let knownMarkerSideCentimeters: Double
  public let minimumMarkerSidePixels: Double
  public let edgeMarginPixels: Double
  public let minimumMarkerSideRatio: Double
  public let minimumGarmentMarkerGapPixels: Double

  public init(
    knownMarkerSideCentimeters: Double = 5,
    minimumMarkerSidePixels: Double = 80,
    edgeMarginPixels: Double = 16,
    minimumMarkerSideRatio: Double = 0.65,
    minimumGarmentMarkerGapPixels: Double = 24
  ) {
    self.knownMarkerSideCentimeters = knownMarkerSideCentimeters
    self.minimumMarkerSidePixels = minimumMarkerSidePixels
    self.edgeMarginPixels = edgeMarginPixels
    self.minimumMarkerSideRatio = minimumMarkerSideRatio
    self.minimumGarmentMarkerGapPixels = minimumGarmentMarkerGapPixels
  }

  fileprivate var isValid: Bool {
    knownMarkerSideCentimeters.isFinite && knownMarkerSideCentimeters > 0
      && minimumMarkerSidePixels.isFinite && minimumMarkerSidePixels > 0
      && edgeMarginPixels.isFinite && edgeMarginPixels >= 0
      && minimumMarkerSideRatio.isFinite
      && (0...1).contains(minimumMarkerSideRatio)
      && minimumGarmentMarkerGapPixels.isFinite
      && minimumGarmentMarkerGapPixels >= 0
  }
}

public enum MeasurementGeometryPipelineStage: Equatable, Sendable {
  case normalization
  case qualityAnalysis
  case markerDetection
  case garmentMaskDetection
  case perspectiveCorrection
}

/// Finite app-owned failures. No failure carries a scale, corrected image, or measurement value.
public enum MeasurementGeometryPipelineError: Error, Sendable {
  case measurement(MeasurementFailure)
  case quality(LocalQualityHint)
  case engineUnavailable(MeasurementGeometryPipelineStage)
  case invalidConfiguration
  case invalidHomography
  case invalidRectification
  case cancelled
}

public struct MeasurementGeometryPipelineOutput {
  public let uprightImage: CGImage
  public let correctedImage: CGImage
  public let correctedGarmentMask: MeasurementGarmentMask
  public let sourceMarkerCorners: MeasurementQuadrilateral
  public let correctedMarkerCorners: MeasurementQuadrilateral
  public let correctedImageSize: CorrectedMeasurementImageSize
  public let pixelsPerCentimeter: Double
  public let sourceToCorrected: MeasurementProjectiveTransform
  public let correctedToSource: MeasurementProjectiveTransform

  public init(
    uprightImage: CGImage,
    correctedImage: CGImage,
    correctedGarmentMask: MeasurementGarmentMask,
    sourceMarkerCorners: MeasurementQuadrilateral,
    correctedMarkerCorners: MeasurementQuadrilateral,
    correctedImageSize: CorrectedMeasurementImageSize,
    pixelsPerCentimeter: Double,
    sourceToCorrected: MeasurementProjectiveTransform,
    correctedToSource: MeasurementProjectiveTransform
  ) {
    self.uprightImage = uprightImage
    self.correctedImage = correctedImage
    self.correctedGarmentMask = correctedGarmentMask
    self.sourceMarkerCorners = sourceMarkerCorners
    self.correctedMarkerCorners = correctedMarkerCorners
    self.correctedImageSize = correctedImageSize
    self.pixelsPerCentimeter = pixelsPerCentimeter
    self.sourceToCorrected = sourceToCorrected
    self.correctedToSource = correctedToSource
  }

  public func correctedPoint(
    forSourcePoint point: MeasurementPixelPoint
  ) -> MeasurementPixelPoint? {
    sourceToCorrected.applying(to: point)
  }

  public func sourcePoint(
    forCorrectedPoint point: MeasurementPixelPoint
  ) -> MeasurementPixelPoint? {
    correctedToSource.applying(to: point)
  }
}

public enum MeasurementGeometryPipelineResult {
  case success(MeasurementGeometryPipelineOutput)
  case failure(MeasurementGeometryPipelineError)

  /// Convenience that makes the no-scale-on-invalid contract explicit at call sites.
  public var output: MeasurementGeometryPipelineOutput? {
    guard case .success(let output) = self else { return nil }
    return output
  }
}

/// Double-precision projective transform in top-left-origin pixel coordinates.
public struct MeasurementProjectiveTransform: Equatable, Sendable {
  private let values: [Double]

  public init?(
    source: MeasurementQuadrilateral,
    destination: MeasurementQuadrilateral
  ) {
    let sourcePoints = source.points
    let destinationPoints = destination.points
    var system = [[Double]]()
    system.reserveCapacity(8)

    for (sourcePoint, destinationPoint) in zip(sourcePoints, destinationPoints) {
      let x = sourcePoint.x
      let y = sourcePoint.y
      let u = destinationPoint.x
      let v = destinationPoint.y
      guard x.isFinite, y.isFinite, u.isFinite, v.isFinite else { return nil }
      system.append([x, y, 1, 0, 0, 0, -u * x, -u * y, u])
      system.append([0, 0, 0, x, y, 1, -v * x, -v * y, v])
    }

    guard let solution = Self.solve(system) else { return nil }
    let candidate = solution + [1]
    guard candidate.allSatisfy(\.isFinite),
      Self.isInvertible(candidate)
    else { return nil }
    values = candidate
  }

  private init?(values: [Double]) {
    guard values.count == 9,
      values.allSatisfy(\.isFinite),
      Self.isInvertible(values)
    else { return nil }
    self.values = values
  }

  public func applying(to point: MeasurementPixelPoint) -> MeasurementPixelPoint? {
    guard point.isFinite else { return nil }
    let denominator = values[6] * point.x + values[7] * point.y + values[8]
    guard denominator.isFinite, abs(denominator) > 1e-12 else { return nil }
    let x = (values[0] * point.x + values[1] * point.y + values[2]) / denominator
    let y = (values[3] * point.x + values[4] * point.y + values[5]) / denominator
    guard x.isFinite, y.isFinite else { return nil }
    return MeasurementPixelPoint(x: x, y: y)
  }

  public var inverted: MeasurementProjectiveTransform? {
    let a = values[0]
    let b = values[1]
    let c = values[2]
    let d = values[3]
    let e = values[4]
    let f = values[5]
    let g = values[6]
    let h = values[7]
    let i = values[8]
    let determinant =
      a * (e * i - f * h)
      - b * (d * i - f * g)
      + c * (d * h - e * g)
    guard determinant.isFinite, abs(determinant) > 1e-12 else { return nil }
    return MeasurementProjectiveTransform(values: [
      (e * i - f * h) / determinant,
      (c * h - b * i) / determinant,
      (b * f - c * e) / determinant,
      (f * g - d * i) / determinant,
      (a * i - c * g) / determinant,
      (c * d - a * f) / determinant,
      (d * h - e * g) / determinant,
      (b * g - a * h) / determinant,
      (a * e - b * d) / determinant,
    ])
  }

  fileprivate func translated(x: Double, y: Double) -> MeasurementProjectiveTransform? {
    guard x.isFinite, y.isFinite else { return nil }
    return MeasurementProjectiveTransform(values: [
      values[0] + x * values[6],
      values[1] + x * values[7],
      values[2] + x * values[8],
      values[3] + y * values[6],
      values[4] + y * values[7],
      values[5] + y * values[8],
      values[6], values[7], values[8],
    ])
  }

  private static func isInvertible(_ values: [Double]) -> Bool {
    let determinant =
      values[0] * (values[4] * values[8] - values[5] * values[7])
      - values[1] * (values[3] * values[8] - values[5] * values[6])
      + values[2] * (values[3] * values[7] - values[4] * values[6])
    return determinant.isFinite && abs(determinant) > 1e-12
  }

  private static func solve(_ input: [[Double]]) -> [Double]? {
    guard input.count == 8, input.allSatisfy({ $0.count == 9 }) else { return nil }
    var matrix = input
    for column in 0..<8 {
      guard
        let pivot = (column..<8).max(by: {
          abs(matrix[$0][column]) < abs(matrix[$1][column])
        }), abs(matrix[pivot][column]) > 1e-12
      else { return nil }
      if pivot != column { matrix.swapAt(pivot, column) }

      let divisor = matrix[column][column]
      for index in column..<9 { matrix[column][index] /= divisor }
      for row in 0..<8 where row != column {
        let factor = matrix[row][column]
        guard factor.isFinite else { return nil }
        for index in column..<9 {
          matrix[row][index] -= factor * matrix[column][index]
        }
      }
    }
    let solution = matrix.map { $0[8] }
    return solution.allSatisfy(\.isFinite) ? solution : nil
  }
}

public struct MeasurementGeometryPipeline {
  private let engine: any MeasurementGeometryPipelineEngine
  private let cancellationChecker: any MeasurementGeometryPipelineCancellationChecking
  private let configuration: MeasurementGeometryPipelineConfiguration

  public init(
    engine: any MeasurementGeometryPipelineEngine,
    cancellationChecker: any MeasurementGeometryPipelineCancellationChecking =
      TaskMeasurementGeometryPipelineCancellationChecker(),
    configuration: MeasurementGeometryPipelineConfiguration =
      MeasurementGeometryPipelineConfiguration()
  ) {
    self.engine = engine
    self.cancellationChecker = cancellationChecker
    self.configuration = configuration
  }

  public func process(
    image: CGImage,
    orientation: MeasurementImageOrientation = .up
  ) -> MeasurementGeometryPipelineResult {
    guard configuration.isValid else { return .failure(.invalidConfiguration) }

    do {
      try cancellationChecker.checkCancellation()
      let upright = try call(stage: .normalization) {
        try engine.uprightImage(from: image, orientation: orientation)
      }
      try cancellationChecker.checkCancellation()

      let quality = try call(stage: .qualityAnalysis) {
        try engine.analyzeQuality(in: upright)
      }
      switch quality {
      case .acceptable:
        break
      case .tooDark:
        throw PipelineAbort(.quality(.tooDark))
      case .tooBlurry:
        throw PipelineAbort(.quality(.tooBlurry))
      }
      try cancellationChecker.checkCancellation()

      let markerEvidence = try call(stage: .markerDetection) {
        try engine.detectMarkerEvidence(in: upright)
      }
      let marker = try validatedMarker(from: markerEvidence, in: upright)
      try cancellationChecker.checkCancellation()

      let maskEvidence = try call(stage: .garmentMaskDetection) {
        try engine.detectGarmentMask(in: upright)
      }
      let sourceMask = try validatedMask(
        from: maskEvidence,
        imageWidth: upright.width,
        imageHeight: upright.height
      )
      guard
        pipelinePolygonGap(sourceMask.contour, marker.points)
          >= configuration.minimumGarmentMarkerGapPixels
      else {
        throw PipelineAbort(.measurement(.garmentMarkerOverlap))
      }
      try cancellationChecker.checkCancellation()

      let geometry = try correctionGeometry(
        imageWidth: upright.width,
        imageHeight: upright.height,
        marker: marker
      )
      let rectification = try call(stage: .perspectiveCorrection) {
        try engine.rectifyPlane(
          image: upright,
          garmentMask: sourceMask,
          sourceToCorrected: geometry.transform,
          outputSize: geometry.size
        )
      }
      try cancellationChecker.checkCancellation()

      guard rectification.image.width == geometry.size.width,
        rectification.image.height == geometry.size.height,
        rectification.garmentMask.width == geometry.size.width,
        rectification.garmentMask.height == geometry.size.height
      else {
        throw PipelineAbort(.invalidRectification)
      }
      guard !rectification.garmentMask.touchesFrame else {
        throw PipelineAbort(.measurement(.garmentOutOfFrame))
      }
      let pixelsPerCentimeter =
        marker.rectifiedSideEstimate
        / configuration.knownMarkerSideCentimeters
      guard pixelsPerCentimeter.isFinite, pixelsPerCentimeter > 0,
        let inverse = geometry.transform.inverted
      else {
        throw PipelineAbort(.invalidHomography)
      }
      let correctedMarker = try transformed(marker, using: geometry.transform)
      return .success(
        MeasurementGeometryPipelineOutput(
          uprightImage: upright,
          correctedImage: rectification.image,
          correctedGarmentMask: rectification.garmentMask,
          sourceMarkerCorners: marker,
          correctedMarkerCorners: correctedMarker,
          correctedImageSize: geometry.size,
          pixelsPerCentimeter: pixelsPerCentimeter,
          sourceToCorrected: geometry.transform,
          correctedToSource: inverse
        ))
    } catch is CancellationError {
      return .failure(.cancelled)
    } catch let abort as PipelineAbort {
      return .failure(abort.error)
    } catch {
      // All component calls are wrapped by `call`; this is fail-closed defense.
      return .failure(.invalidRectification)
    }
  }

  private func call<Value>(
    stage: MeasurementGeometryPipelineStage,
    _ operation: () throws -> Value
  ) throws -> Value {
    do {
      return try operation()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw PipelineAbort(.engineUnavailable(stage))
    }
  }

  private func validatedMarker(
    from evidence: MeasurementMarkerEvidence,
    in image: CGImage
  ) throws -> MeasurementQuadrilateral {
    guard !evidence.candidates.isEmpty else {
      throw PipelineAbort(
        .measurement(
          evidence.hasOccludedMarkerEvidence ? .markerOccluded : .markerMissing
        ))
    }
    guard evidence.candidates.count == 1 else {
      throw PipelineAbort(.measurement(.markerMultiple))
    }
    let marker = evidence.candidates[0].corners
    guard marker.minimumSideLength >= configuration.minimumMarkerSidePixels else {
      throw PipelineAbort(.measurement(.markerTooSmall))
    }
    guard marker.sideRatio + 1e-12 >= configuration.minimumMarkerSideRatio,
      marker.points.allSatisfy({
        $0.x > configuration.edgeMarginPixels
          && $0.y > configuration.edgeMarginPixels
          && $0.x < Double(image.width) - configuration.edgeMarginPixels
          && $0.y < Double(image.height) - configuration.edgeMarginPixels
      })
    else {
      // The frozen vocabulary has no edge/skew case. Reject as no valid marker.
      throw PipelineAbort(.measurement(.markerMissing))
    }
    return marker
  }

  private func validatedMask(
    from evidence: MeasurementGarmentMaskEvidence,
    imageWidth: Int,
    imageHeight: Int
  ) throws -> MeasurementGarmentMask {
    switch evidence {
    case .mask(let mask):
      guard mask.width == imageWidth, mask.height == imageHeight else {
        throw PipelineAbort(.measurement(.segmentationFailed))
      }
      guard !mask.touchesFrame else {
        throw PipelineAbort(.measurement(.garmentOutOfFrame))
      }
      return mask
    case .outOfFrame:
      throw PipelineAbort(.measurement(.garmentOutOfFrame))
    case .unavailable:
      throw PipelineAbort(.measurement(.segmentationFailed))
    }
  }

  private func correctionGeometry(
    imageWidth: Int,
    imageHeight: Int,
    marker: MeasurementQuadrilateral
  ) throws -> (
    transform: MeasurementProjectiveTransform,
    size: CorrectedMeasurementImageSize
  ) {
    let side = marker.rectifiedSideEstimate
    guard side.isFinite, side > 0 else { throw PipelineAbort(.invalidHomography) }
    let destination = MeasurementQuadrilateral(
      topLeft: MeasurementPixelPoint(x: 0, y: 0),
      topRight: MeasurementPixelPoint(x: side, y: 0),
      bottomRight: MeasurementPixelPoint(x: side, y: side),
      bottomLeft: MeasurementPixelPoint(x: 0, y: side)
    )
    guard
      let unshifted = MeasurementProjectiveTransform(
        source: marker,
        destination: destination
      )
    else { throw PipelineAbort(.invalidHomography) }

    let sourceBounds = [
      MeasurementPixelPoint(x: 0, y: 0),
      MeasurementPixelPoint(x: Double(imageWidth), y: 0),
      MeasurementPixelPoint(x: Double(imageWidth), y: Double(imageHeight)),
      MeasurementPixelPoint(x: 0, y: Double(imageHeight)),
    ]
    let projected = try sourceBounds.map { point -> MeasurementPixelPoint in
      guard let transformed = unshifted.applying(to: point) else {
        throw PipelineAbort(.invalidHomography)
      }
      return transformed
    }
    guard let minimumX = projected.map(\.x).min(),
      let maximumX = projected.map(\.x).max(),
      let minimumY = projected.map(\.y).min(),
      let maximumY = projected.map(\.y).max(),
      let transform = unshifted.translated(x: -minimumX, y: -minimumY),
      maximumX > minimumX, maximumY > minimumY,
      maximumX - minimumX <= Double(Int32.max),
      maximumY - minimumY <= Double(Int32.max)
    else {
      throw PipelineAbort(.invalidHomography)
    }
    do {
      return (
        transform,
        try CorrectedMeasurementImageSize(
          width: max(1, Int(ceil(maximumX - minimumX))),
          height: max(1, Int(ceil(maximumY - minimumY)))
        )
      )
    } catch {
      throw PipelineAbort(.invalidHomography)
    }
  }

  private func transformed(
    _ quadrilateral: MeasurementQuadrilateral,
    using transform: MeasurementProjectiveTransform
  ) throws -> MeasurementQuadrilateral {
    let points = try quadrilateral.points.map { point -> MeasurementPixelPoint in
      guard let transformed = transform.applying(to: point) else {
        throw PipelineAbort(.invalidHomography)
      }
      return transformed
    }
    return MeasurementQuadrilateral(
      topLeft: points[0],
      topRight: points[1],
      bottomRight: points[2],
      bottomLeft: points[3]
    )
  }
}

private struct PipelineAbort: Error {
  let error: MeasurementGeometryPipelineError

  init(_ error: MeasurementGeometryPipelineError) {
    self.error = error
  }
}

private func pipelineDistance(
  _ lhs: MeasurementPixelPoint,
  _ rhs: MeasurementPixelPoint
) -> Double {
  hypot(lhs.x - rhs.x, lhs.y - rhs.y)
}

private func pipelinePolygonGap(
  _ lhs: [MeasurementPixelPoint],
  _ rhs: [MeasurementPixelPoint]
) -> Double {
  guard lhs.count >= 3, rhs.count >= 3 else { return 0 }
  if pipelinePolygonsIntersect(lhs, rhs) { return 0 }
  var minimum = Double.infinity
  for point in lhs {
    for index in rhs.indices {
      minimum = min(
        minimum,
        pipelinePointSegmentDistance(
          point,
          rhs[index],
          rhs[(index + 1) % rhs.count]
        ))
    }
  }
  for point in rhs {
    for index in lhs.indices {
      minimum = min(
        minimum,
        pipelinePointSegmentDistance(
          point,
          lhs[index],
          lhs[(index + 1) % lhs.count]
        ))
    }
  }
  return minimum
}

private func pipelinePolygonsIntersect(
  _ lhs: [MeasurementPixelPoint],
  _ rhs: [MeasurementPixelPoint]
) -> Bool {
  if pipelinePointInPolygon(lhs[0], polygon: rhs)
    || pipelinePointInPolygon(rhs[0], polygon: lhs)
  {
    return true
  }
  for lhsIndex in lhs.indices {
    for rhsIndex in rhs.indices
    where pipelineSegmentsIntersect(
      lhs[lhsIndex], lhs[(lhsIndex + 1) % lhs.count],
      rhs[rhsIndex], rhs[(rhsIndex + 1) % rhs.count]
    ) {
      return true
    }
  }
  return false
}

private func pipelineSegmentsIntersect(
  _ a: MeasurementPixelPoint,
  _ b: MeasurementPixelPoint,
  _ c: MeasurementPixelPoint,
  _ d: MeasurementPixelPoint
) -> Bool {
  func cross(
    _ p: MeasurementPixelPoint,
    _ q: MeasurementPixelPoint,
    _ r: MeasurementPixelPoint
  ) -> Double {
    (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
  }
  let first = cross(a, b, c)
  let second = cross(a, b, d)
  let third = cross(c, d, a)
  let fourth = cross(c, d, b)
  let epsilon = 1e-9
  func contains(
    _ point: MeasurementPixelPoint,
    between start: MeasurementPixelPoint,
    and end: MeasurementPixelPoint
  ) -> Bool {
    point.x >= min(start.x, end.x) - epsilon
      && point.x <= max(start.x, end.x) + epsilon
      && point.y >= min(start.y, end.y) - epsilon
      && point.y <= max(start.y, end.y) + epsilon
  }
  if abs(first) <= epsilon, contains(c, between: a, and: b) { return true }
  if abs(second) <= epsilon, contains(d, between: a, and: b) { return true }
  if abs(third) <= epsilon, contains(a, between: c, and: d) { return true }
  if abs(fourth) <= epsilon, contains(b, between: c, and: d) { return true }
  return ((first > epsilon && second < -epsilon) || (first < -epsilon && second > epsilon))
    && ((third > epsilon && fourth < -epsilon) || (third < -epsilon && fourth > epsilon))
}

private func pipelinePointInPolygon(
  _ point: MeasurementPixelPoint,
  polygon: [MeasurementPixelPoint]
) -> Bool {
  var inside = false
  var previous = polygon.count - 1
  for current in polygon.indices {
    let first = polygon[current]
    let second = polygon[previous]
    if (first.y > point.y) != (second.y > point.y) {
      let intersectionX =
        (second.x - first.x) * (point.y - first.y)
        / (second.y - first.y) + first.x
      if point.x < intersectionX { inside.toggle() }
    }
    previous = current
  }
  return inside
}

private func pipelinePointSegmentDistance(
  _ point: MeasurementPixelPoint,
  _ start: MeasurementPixelPoint,
  _ end: MeasurementPixelPoint
) -> Double {
  let dx = end.x - start.x
  let dy = end.y - start.y
  let lengthSquared = dx * dx + dy * dy
  guard lengthSquared > 0 else { return pipelineDistance(point, start) }
  let projection =
    ((point.x - start.x) * dx + (point.y - start.y) * dy)
    / lengthSquared
  let clamped = min(1, max(0, projection))
  return pipelineDistance(
    point,
    MeasurementPixelPoint(x: start.x + clamped * dx, y: start.y + clamped * dy)
  )
}
