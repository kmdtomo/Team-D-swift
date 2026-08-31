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

@Test(arguments: MeasurementEndpoint.allCases)
func accessibilityAdjustmentUsesEachEndpointMeaningfulAxisAndKeepsDraftUnapproved(
    endpoint: MeasurementEndpoint
) throws {
    var editor = try makeEditor()
    let initial = editor.point(for: endpoint)
    let initialMeasurements = editor.measurements
    let result = try editor.adjust(endpoint, by: .increment)
    let adjusted = editor.point(for: endpoint)

    switch endpoint.accessibilityAdjustmentAxis {
    case .vertical:
        #expect(adjusted.x == initial.x)
        #expect(adjusted.y < initial.y)
    case .horizontal:
        #expect(adjusted.x > initial.x)
        #expect(adjusted.y == initial.y)
    }
    #expect(editor.measurements == result)
    #expect(editor.measurements != initialMeasurements)
    #expect((result.length.centimeters * 10).rounded() == result.length.centimeters * 10)
    #expect((result.width.centimeters * 10).rounded() == result.width.centimeters * 10)
    #expect(editor.status == .needsReview)
}

@Test(arguments: MeasurementEndpoint.allCases)
func accessibilityAdjustmentDecrementMovesEachEndpointBackAlongItsMeaningfulAxis(
    endpoint: MeasurementEndpoint
) throws {
    var editor = try makeEditor()
    let initial = editor.point(for: endpoint)
    _ = try editor.adjust(endpoint, by: .decrement)
    let adjusted = editor.point(for: endpoint)

    switch endpoint.accessibilityAdjustmentAxis {
    case .vertical:
        #expect(adjusted.x == initial.x)
        #expect(adjusted.y > initial.y)
    case .horizontal:
        #expect(adjusted.x < initial.x)
        #expect(adjusted.y == initial.y)
    }
}

@Test func accessibilityAdjustmentClampsAtImageBounds() throws {
    let cases: [(MeasurementEndpoint, MeasurementEndpointAccessibilityAdjustment, SessionNormalizedPoint)] = [
        (.lengthStart, .increment, try editorPoint(0.5, 0)),
        (.lengthEnd, .decrement, try editorPoint(0.5, 1)),
        (.widthStart, .decrement, try editorPoint(0, 0.5)),
        (.widthEnd, .increment, try editorPoint(1, 0.5)),
    ]
    for (endpoint, adjustment, expected) in cases {
        var editor = try makeEditor()
        try editor.update(endpoint, to: expected)
        _ = try editor.adjust(endpoint, by: adjustment)
        #expect(editor.point(for: endpoint) == expected)
    }
}

@Test func accessibilityEndpointsExposeStableSemanticLabelsAndAxisHints() {
    #expect(MeasurementEndpoint.lengthStart.accessibilityLabel == "着丈の開始点")
    #expect(MeasurementEndpoint.lengthEnd.accessibilityLabel == "着丈の終了点")
    #expect(MeasurementEndpoint.widthStart.accessibilityLabel == "身幅の左端")
    #expect(MeasurementEndpoint.widthEnd.accessibilityLabel == "身幅の右端")
    #expect(MeasurementEndpoint.lengthStart.accessibilityAdjustmentHint.contains("上へ"))
    #expect(MeasurementEndpoint.widthStart.accessibilityAdjustmentHint.contains("右へ"))
}

@Test func accessibilityValuesExposeAdjustedMeasurementAndPendingApprovalWithoutCoordinateNoise() throws {
    var editor = try makeEditor()
    let before = editor.accessibilityValue(for: .widthEnd)
    _ = try editor.adjust(.widthEnd, by: .increment)
    let after = editor.accessibilityValue(for: .widthEnd)
    #expect(before.contains("身幅"))
    #expect(before.contains("承認待ち"))
    #expect(after.contains("身幅"))
    #expect(after.contains("承認待ち"))
    #expect(!after.contains("x:"))
    #expect(!after.contains("y:"))
}

@Test func initialDraftAndAllEditorInteractionsRemainNeedsReview() throws {
    var editor = try makeEditor()
    #expect(editor.status == .needsReview)
    try editor.update(.widthEnd, to: editorPoint(0.85, 0.5))
    #expect(editor.status == .needsReview)
    try editor.adjust(.widthEnd, by: .decrement)
    #expect(editor.status == .needsReview)
}

@Test func editingAnApprovedDraftRevokesApproval() throws {
    let garmentPolygon = CorrectedMeasurementGarmentPolygon(points: [
        MeasurementPixelPoint(x: 0, y: 0),
        MeasurementPixelPoint(x: 1_000, y: 0),
        MeasurementPixelPoint(x: 1_000, y: 2_000),
        MeasurementPixelPoint(x: 0, y: 2_000),
    ])
    var editor = try makeEditor()
    #expect(
        editor.requestCVApproval(garmentPolygon: garmentPolygon)
            == .approved(event: .approveMeasurementCV)
    )
    #expect(editor.status == .approvedCV)

    let firstEdit = try editor.updateForWorkflow(
        .widthEnd,
        to: editorPoint(0.75, 0.5)
    )
    #expect(editor.status == .needsReview)
    #expect(firstEdit.workflowEvent == .measurementChanged)

    let secondEdit = try editor.updateForWorkflow(
        .widthEnd,
        to: editorPoint(0.70, 0.5)
    )
    #expect(secondEdit.workflowEvent == nil)
}

@Test func neverApprovedEndpointEditsDoNotEmitMeasurementChanged() throws {
    var editor = try makeEditor()
    let drag = try editor.updateForWorkflow(
        .widthEnd,
        to: editorPoint(0.75, 0.5)
    )
    let accessibility = try editor.adjustForWorkflow(.widthEnd, by: .decrement)

    #expect(editor.status == .needsReview)
    #expect(drag.workflowEvent == nil)
    #expect(accessibility.workflowEvent == nil)
}

@Test func touchingAnApprovedEndpointWithoutMovingDoesNotRevokeApproval() throws {
    let garmentPolygon = CorrectedMeasurementGarmentPolygon(points: [
        MeasurementPixelPoint(x: 0, y: 0),
        MeasurementPixelPoint(x: 1_000, y: 0),
        MeasurementPixelPoint(x: 1_000, y: 2_000),
        MeasurementPixelPoint(x: 0, y: 2_000),
    ])
    var editor = try makeEditor()
    _ = editor.requestCVApproval(garmentPolygon: garmentPolygon)

    let unchanged = try editor.updateForWorkflow(
        .widthEnd,
        to: editor.point(for: .widthEnd)
    )

    #expect(editor.status == .approvedCV)
    #expect(unchanged.workflowEvent == nil)
}
