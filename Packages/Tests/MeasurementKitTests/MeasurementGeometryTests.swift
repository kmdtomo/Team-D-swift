import DomainKit
import Testing
@testable import MeasurementKit

private func point(_ x: Double, _ y: Double) throws -> SessionNormalizedPoint {
    try SessionNormalizedPoint(x: x, y: y)
}

private func endpoints(
    lengthStart: (Double, Double) = (0, 0),
    lengthEnd: (Double, Double) = (0.3, 0.4),
    widthStart: (Double, Double) = (0.1, 0.5),
    widthEnd: (Double, Double) = (0.6, 0.5)
) throws -> MeasurementGeometryEndpoints {
    try MeasurementGeometryEndpoints(
        lengthStart: point(lengthStart.0, lengthStart.1),
        lengthEnd: point(lengthEnd.0, lengthEnd.1),
        widthStart: point(widthStart.0, widthStart.1),
        widthEnd: point(widthEnd.0, widthEnd.1)
    )
}

private func imageSize(_ width: Int = 100, _ height: Int = 100) throws -> CorrectedMeasurementImageSize {
    try CorrectedMeasurementImageSize(width: width, height: height)
}

@Test func knownThreeFourFiveGeometryProducesFlatLengthAndWidth() throws {
    let result = try MeasurementGeometry.calculate(endpoints: endpoints(), imageSize: imageSize(), pixelsPerCentimeter: 10)
    #expect(result.length.centimeters == 5)
    #expect(result.width.centimeters == 5)
}

@Test func nonSquareImageMapsXByWidthAndYByHeight() throws {
    let result = try MeasurementGeometry.calculate(
        endpoints: endpoints(lengthEnd: (0.5, 0.5), widthStart: (0, 0.5), widthEnd: (1, 0.5)),
        imageSize: imageSize(200, 100),
        pixelsPerCentimeter: 10
    )
    #expect(result.length.centimeters == 11.2)
    #expect(result.width.centimeters == 20)
}

@Test func widthIsNotDoubled() throws {
    let result = try MeasurementGeometry.calculate(
        endpoints: endpoints(widthStart: (0.2, 0.5), widthEnd: (0.4, 0.5)), imageSize: imageSize(), pixelsPerCentimeter: 10
    )
    #expect(result.width.centimeters == 2)
}

@Test(arguments: [(1.049, 1.0), (1.05, 1.1), (1.051, 1.1), (1.06, 1.1), (1.15, 1.2)])
func roundsToNearestTenthWithHalfTiesAwayFromZero(_ input: Double, _ expected: Double) throws {
    let result = try MeasurementGeometry.calculate(
        endpoints: endpoints(lengthEnd: (input / 10, 0), widthStart: (0, 0.5), widthEnd: (0.5, 0.5)),
        imageSize: imageSize(),
        pixelsPerCentimeter: 10
    )
    #expect(result.length.centimeters == expected)
}

@Test func scalingImageDimensionsAndPixelsPerCentimeterTogetherIsInvariant() throws {
    let points = try endpoints(lengthEnd: (0.6, 0.8), widthStart: (0.1, 0.5), widthEnd: (0.9, 0.5))
    let small = try MeasurementGeometry.calculate(endpoints: points, imageSize: imageSize(100, 200), pixelsPerCentimeter: 10)
    let large = try MeasurementGeometry.calculate(endpoints: points, imageSize: imageSize(200, 400), pixelsPerCentimeter: 20)
    #expect(small == large)
}

@Test func allNormalizedPointBoundariesAreValidGeometryInputs() throws {
    let result = try MeasurementGeometry.calculate(
        endpoints: endpoints(lengthStart: (0, 0), lengthEnd: (1, 1), widthStart: (0, 1), widthEnd: (1, 0)),
        imageSize: imageSize(),
        pixelsPerCentimeter: 10
    )
    #expect(result.length.centimeters == 14.1)
    #expect(result.width.centimeters == 14.1)
}

@Test(arguments: [(0, 100), (-1, 100), (100, 0), (100, -1)])
func invalidImageSizesAreRejected(_ width: Int, _ height: Int) {
    #expect(throws: MeasurementGeometryError.invalidImageSize) { try CorrectedMeasurementImageSize(width: width, height: height) }
}

@Test(arguments: [0.0, -1.0, Double.nan, Double.infinity, -Double.infinity])
func invalidScalesAreRejected(_ scale: Double) throws {
    #expect(throws: MeasurementGeometryError.invalidScale) {
        try MeasurementGeometry.calculate(endpoints: endpoints(), imageSize: imageSize(), pixelsPerCentimeter: scale)
    }
}

@Test(arguments: [(Double.nan, 0.5), (Double.infinity, 0.5), (-Double.infinity, 0.5), (-0.001, 0.5), (1.001, 0.5), (0.5, -0.001), (0.5, 1.001)])
func nonFiniteAndOutOfRangePointsAreRejectedBeforeGeometry(_ x: Double, _ y: Double) {
    #expect(throws: Error.self) { try SessionNormalizedPoint(x: x, y: y) }
}

@Test func identicalAndTinyLinesThatRoundToZeroAreRejected() throws {
    #expect(throws: MeasurementGeometryError.zeroOrTooShortLength) {
        try MeasurementGeometry.calculate(endpoints: endpoints(lengthStart: (0.5, 0.5), lengthEnd: (0.5, 0.5)), imageSize: imageSize(), pixelsPerCentimeter: 10)
    }
    #expect(throws: MeasurementGeometryError.zeroOrTooShortWidth) {
        try MeasurementGeometry.calculate(endpoints: endpoints(widthStart: (0.5, 0.5), widthEnd: (0.501, 0.5)), imageSize: imageSize(), pixelsPerCentimeter: 100)
    }
}

@Test func extremeFiniteInputsThatProduceNonFiniteCentimetersAreRejected() throws {
    #expect(throws: MeasurementGeometryError.invalidCalculation) {
        try MeasurementGeometry.calculate(
            endpoints: endpoints(lengthEnd: (1, 1), widthStart: (0, 1), widthEnd: (1, 0)),
            imageSize: imageSize(Int.max, Int.max),
            pixelsPerCentimeter: .leastNonzeroMagnitude
        )
    }
}

@Test func repeatedCalculationIsDeterministic() throws {
    let input = try endpoints(lengthEnd: (0.63, 0.84), widthStart: (0.12, 0.5), widthEnd: (0.88, 0.5))
    let expected = try MeasurementGeometry.calculate(endpoints: input, imageSize: imageSize(1_000, 800), pixelsPerCentimeter: 37)
    for _ in 0..<100 {
        #expect(try MeasurementGeometry.calculate(endpoints: input, imageSize: imageSize(1_000, 800), pixelsPerCentimeter: 37) == expected)
    }
}
