import CoreGraphics
import DomainKit
import Testing
@testable import MeasurementKit

private func editorPoint(_ x: Double, _ y: Double) throws -> SessionNormalizedPoint {
    try SessionNormalizedPoint(x: x, y: y)
}

private func editorEndpoints() throws -> MeasurementGeometryEndpoints {
    MeasurementGeometryEndpoints(
        lengthStart: try editorPoint(0.5, 0.1),
        lengthEnd: try editorPoint(0.5, 0.9),
        widthStart: try editorPoint(0.2, 0.5),
        widthEnd: try editorPoint(0.8, 0.5)
    )
}

private func editorImageSize() throws -> CorrectedMeasurementImageSize {
    try CorrectedMeasurementImageSize(width: 1_000, height: 2_000)
}

private func makeEditor() throws -> MeasurementEndpointEditor {
    try MeasurementEndpointEditor(endpoints: editorEndpoints(), imageSize: editorImageSize(), pixelsPerCentimeter: 20)
}

@Test func aspectFitCoordinateRoundTripPreservesEveryEndpoint() throws {
    let mapper = try MeasurementImageCoordinateMapper(imageSize: editorImageSize(), viewportSize: CGSize(width: 390, height: 600))
    for endpoint in MeasurementEndpoint.allCases {
        let original = try makeEditor().point(for: endpoint)
        let roundTripped = try mapper.normalizedPoint(for: mapper.viewPoint(for: original))
        #expect(roundTripped == original)
    }
}

@Test func zoomAndPanCoordinateRoundTripPreservesEndpoint() throws {
    let mapper = try MeasurementImageCoordinateMapper(
        imageSize: editorImageSize(),
        viewportSize: CGSize(width: 390, height: 600),
        zoom: 2,
        pan: CGSize(width: -42, height: 63)
    )
    let original = try editorPoint(0.73, 0.36)
    #expect(try mapper.normalizedPoint(for: mapper.viewPoint(for: original)) == original)
}

@Test func outsideCoordinatesAreRejectedAndDragCoordinatesClampToImageBounds() throws {
    let mapper = try MeasurementImageCoordinateMapper(imageSize: editorImageSize(), viewportSize: CGSize(width: 390, height: 600))
    #expect(throws: MeasurementImageCoordinateMapper.Error.pointOutsideImage) {
        try mapper.normalizedPoint(for: CGPoint(x: mapper.imageFrame.minX - 1, y: mapper.imageFrame.midY))
    }
    var editor = try makeEditor()
    try editor.update(.widthStart, fromViewPoint: CGPoint(x: mapper.imageFrame.minX - 50, y: mapper.imageFrame.maxY + 50), mapper: mapper)
    #expect(editor.point(for: .widthStart) == try editorPoint(0, 1))
}

@Test func everyHandleUpdatesOnlyItsPointAndRecalculatesToTenths() throws {
    let updates: [(MeasurementEndpoint, SessionNormalizedPoint)] = [
        (.lengthStart, try editorPoint(0.4, 0.1)),
        (.lengthEnd, try editorPoint(0.5, 0.8)),
        (.widthStart, try editorPoint(0.1, 0.5)),
        (.widthEnd, try editorPoint(0.9, 0.5)),
    ]
    for (endpoint, point) in updates {
        var editor = try makeEditor()
        let before = editor.endpoints
        let result = try editor.update(endpoint, to: point)
        #expect(editor.point(for: endpoint) == point)
        #expect(editor.measurements == result)
        #expect((result.length.centimeters * 10).rounded() == result.length.centimeters * 10)
        #expect((result.width.centimeters * 10).rounded() == result.width.centimeters * 10)
        switch endpoint {
        case .lengthStart: #expect(editor.endpoints.lengthEnd == before.lengthEnd)
        case .lengthEnd: #expect(editor.endpoints.lengthStart == before.lengthStart)
        case .widthStart: #expect(editor.endpoints.widthEnd == before.widthEnd)
        case .widthEnd: #expect(editor.endpoints.widthStart == before.widthStart)
        }
    }
}

@Test func accessibilityAdjustmentUpdatesModelAndKeepsDraftUnapproved() throws {
    var editor = try makeEditor()
    let initial = editor.point(for: .lengthEnd)
    let result = try editor.adjust(.lengthEnd, by: .increment)
    #expect(editor.point(for: .lengthEnd).y < initial.y)
    #expect(editor.measurements == result)
    #expect(editor.status == .needsReview)
}

@Test func initialDraftAndAllEditorInteractionsRemainNeedsReview() throws {
    var editor = try makeEditor()
    #expect(editor.status == .needsReview)
    try editor.update(.widthEnd, to: editorPoint(0.85, 0.5))
    #expect(editor.status == .needsReview)
    try editor.adjust(.widthEnd, by: .decrement)
    #expect(editor.status == .needsReview)
}
