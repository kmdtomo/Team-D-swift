import DomainKit
import MeasurementKit
import Testing

private func approvalPoint(_ x: Double, _ y: Double) throws -> SessionNormalizedPoint {
    try SessionNormalizedPoint(x: x, y: y)
}

private func approvalImageSize() throws -> CorrectedMeasurementImageSize {
    try CorrectedMeasurementImageSize(width: 1_000, height: 1_000)
}

private func approvalEndpoints(
    lengthCentimeters: Double = 60,
    widthCentimeters: Double = 60,
    pixelsPerCentimeter: Double = 10
) throws -> MeasurementGeometryEndpoints {
    let lengthFraction = lengthCentimeters * pixelsPerCentimeter / 1_000
    let widthFraction = widthCentimeters * pixelsPerCentimeter / 1_000
    return MeasurementGeometryEndpoints(
        lengthStart: try approvalPoint(0.5, (1 - lengthFraction) / 2),
        lengthEnd: try approvalPoint(0.5, (1 + lengthFraction) / 2),
        widthStart: try approvalPoint((1 - widthFraction) / 2, 0.5),
        widthEnd: try approvalPoint((1 + widthFraction) / 2, 0.5)
    )
}

private func approvalEditor(
    endpoints: MeasurementGeometryEndpoints? = nil,
    pixelsPerCentimeter: Double = 10
) throws -> MeasurementEndpointEditor {
    try MeasurementEndpointEditor(
        endpoints: endpoints ?? approvalEndpoints(
            pixelsPerCentimeter: pixelsPerCentimeter
        ),
        imageSize: approvalImageSize(),
        pixelsPerCentimeter: pixelsPerCentimeter
    )
}

private func insetGarmentPolygon() -> CorrectedMeasurementGarmentPolygon {
    CorrectedMeasurementGarmentPolygon(points: [
        MeasurementPixelPoint(x: 100, y: 100),
        MeasurementPixelPoint(x: 900, y: 100),
        MeasurementPixelPoint(x: 900, y: 900),
        MeasurementPixelPoint(x: 100, y: 900),
    ])
}

private func fullImageGarmentPolygon() -> CorrectedMeasurementGarmentPolygon {
    CorrectedMeasurementGarmentPolygon(points: [
        MeasurementPixelPoint(x: 0, y: 0),
        MeasurementPixelPoint(x: 1_000, y: 0),
        MeasurementPixelPoint(x: 1_000, y: 1_000),
        MeasurementPixelPoint(x: 0, y: 1_000),
    ])
}

private func endpointsWithLengthStart(xPixels: Double) throws -> MeasurementGeometryEndpoints {
    let original = try approvalEndpoints()
    return MeasurementGeometryEndpoints(
        lengthStart: try approvalPoint(xPixels / 1_000, 0.2),
        lengthEnd: original.lengthEnd,
        widthStart: original.widthStart,
        widthEnd: original.widthEnd
    )
}

@Test func endpointToleranceUsesTwoPercentOfCorrectedImageShortSideInclusively() throws {
    #expect(MeasurementEndpointValidator.garmentBoundaryToleranceFraction == 0.02)

    let cases: [(xPixels: Double, isValid: Bool)] = [
        (80.001, true),  // 19.999 px outside
        (80, true),      // exactly 20 px outside
        (79.999, false), // 20.001 px outside
    ]
    for testCase in cases {
        let endpoints = try endpointsWithLengthStart(xPixels: testCase.xPixels)
        let result = MeasurementEndpointValidator.validate(
            endpoints: endpoints,
            imageSize: try approvalImageSize(),
            garmentPolygon: insetGarmentPolygon()
        )
        #expect(result.isValid == testCase.isValid, "x=\(testCase.xPixels)")
        #expect(
            result.invalidEndpoints.contains(.lengthStart) == !testCase.isValid,
            "x=\(testCase.xPixels)"
        )
    }
}

@Test func polygonInteriorAndBoundaryAreValidButMalformedPolygonIsRejected() throws {
    let endpoints = try approvalEndpoints()
    let boundaryEndpoints = MeasurementGeometryEndpoints(
        lengthStart: try approvalPoint(0.1, 0.2),
        lengthEnd: endpoints.lengthEnd,
        widthStart: endpoints.widthStart,
        widthEnd: endpoints.widthEnd
    )
    #expect(MeasurementEndpointValidator.validate(
        endpoints: boundaryEndpoints,
        imageSize: try approvalImageSize(),
        garmentPolygon: insetGarmentPolygon()
    ).isValid)

    let malformed = CorrectedMeasurementGarmentPolygon(points: [
        MeasurementPixelPoint(x: 100, y: 100),
        MeasurementPixelPoint(x: 200, y: 200),
        MeasurementPixelPoint(x: 300, y: 300),
    ])
    let invalid = MeasurementEndpointValidator.validate(
        endpoints: endpoints,
        imageSize: try approvalImageSize(),
        garmentPolygon: malformed
    )
    #expect(invalid.failure == .endpointsInvalid)
    #expect(invalid.invalidEndpoints == Set(MeasurementEndpoint.allCases))
}

@Test func acceptedMeasurementRangeBoundariesAreInclusive() throws {
    let boundaryPairs: [(length: Double, width: Double)] = [
        (20, 20),
        (20, 80),
        (100, 20),
        (100, 80),
    ]
    for pair in boundaryPairs {
        let editor = try approvalEditor(
            endpoints: approvalEndpoints(
                lengthCentimeters: pair.length,
                widthCentimeters: pair.width
            )
        )
        let warning = MeasurementRangeWarning(measurements: editor.measurements)
        #expect(!warning.requiresConfirmation, "\(pair.length), \(pair.width)")
    }
}

@Test func valuesImmediatelyOutsideInclusiveRangesRequireWarning() throws {
    let cases: [(length: Double, width: Double, expected: Set<MeasurementRange>)] = [
        (19.9, 40, [.length]),
        (100.1, 40, [.length]),
        (60, 19.9, [.width]),
        (60, 80.1, [.width]),
    ]
    for testCase in cases {
        let editor = try approvalEditor(
            endpoints: approvalEndpoints(
                lengthCentimeters: testCase.length,
                widthCentimeters: testCase.width,
                pixelsPerCentimeter: 5
            ),
            pixelsPerCentimeter: 5
        )
        let warning = MeasurementRangeWarning(measurements: editor.measurements)
        #expect(warning.outOfRangeMeasurements == testCase.expected)
        #expect(warning.lengthCentimeters == testCase.length)
        #expect(warning.widthCentimeters == testCase.width)
    }
}

@Test func validInRangeDraftApprovesOnlyThroughExplicitRequestAndEmitsAppEvent() throws {
    var editor = try approvalEditor()
    #expect(editor.status == .needsReview)

    let outcome = editor.requestCVApproval(
        garmentPolygon: fullImageGarmentPolygon()
    )
    guard case let .approved(event) = outcome else {
        Issue.record("expected approved CV event")
        return
    }
    #expect(event == .approveMeasurementCV)
    #expect(editor.status == .approvedCV)
    #expect(
        editor.requestCVApproval(garmentPolygon: fullImageGarmentPolygon())
            == .alreadyApproved
    )
}

@Test func outOfRangeDraftNeedsASecondExplicitConfirmationBeforeApproval() throws {
    var editor = try approvalEditor(
        endpoints: approvalEndpoints(lengthCentimeters: 19.9, widthCentimeters: 80.1)
    )
    let first = editor.requestCVApproval(garmentPolygon: fullImageGarmentPolygon())
    guard case let .requiresRangeConfirmation(confirmation) = first else {
        Issue.record("expected range confirmation")
        return
    }
    #expect(editor.status == .needsReview)
    #expect(confirmation.warning.outOfRangeMeasurements == [.length, .width])

    let second = editor.confirmCVApproval(
        confirmation,
        garmentPolygon: fullImageGarmentPolygon()
    )
    #expect(second == .approved(event: .approveMeasurementCV))
    #expect(editor.status == .approvedCV)
}

@Test func cancellingRangeWarningKeepsDraftUnapprovedAndInvalidatesConfirmation() throws {
    var editor = try approvalEditor(
        endpoints: approvalEndpoints(lengthCentimeters: 19.9)
    )
    let first = editor.requestCVApproval(garmentPolygon: fullImageGarmentPolygon())
    guard case let .requiresRangeConfirmation(confirmation) = first else {
        Issue.record("expected range confirmation")
        return
    }
    #expect(editor.cancelCVApproval(confirmation))
    #expect(editor.status == .needsReview)
    #expect(editor.confirmCVApproval(
        confirmation,
        garmentPolygon: fullImageGarmentPolygon()
    ) == .staleConfirmation)
}

@Test func editingAfterWarningMakesTheVisibleConfirmationStale() throws {
    var editor = try approvalEditor(
        endpoints: approvalEndpoints(lengthCentimeters: 19.9)
    )
    let first = editor.requestCVApproval(garmentPolygon: fullImageGarmentPolygon())
    guard case let .requiresRangeConfirmation(confirmation) = first else {
        Issue.record("expected range confirmation")
        return
    }

    _ = try editor.update(.lengthStart, to: approvalPoint(0.5, 0.39))
    #expect(editor.status == .needsReview)
    #expect(editor.confirmCVApproval(
        confirmation,
        garmentPolygon: fullImageGarmentPolygon()
    ) == .staleConfirmation)
    #expect(editor.status == .needsReview)
}

@Test func correctedGarmentPolygonChangeMakesConfirmationStale() throws {
    var editor = try approvalEditor(
        endpoints: approvalEndpoints(lengthCentimeters: 19.9)
    )
    let first = editor.requestCVApproval(garmentPolygon: fullImageGarmentPolygon())
    guard case let .requiresRangeConfirmation(confirmation) = first else {
        Issue.record("expected range confirmation")
        return
    }
    let changedPolygon = CorrectedMeasurementGarmentPolygon(points: [
        MeasurementPixelPoint(x: 1, y: 0),
        MeasurementPixelPoint(x: 1_000, y: 0),
        MeasurementPixelPoint(x: 1_000, y: 1_000),
        MeasurementPixelPoint(x: 1, y: 1_000),
    ])
    #expect(editor.confirmCVApproval(
        confirmation,
        garmentPolygon: changedPolygon
    ) == .staleConfirmation)
    #expect(editor.status == .needsReview)
}

@Test func endpointOutsideGarmentToleranceBlocksApprovalWithFiniteFailure() throws {
    var editor = try approvalEditor(endpoints: endpointsWithLengthStart(xPixels: 50))
    let outcome = editor.requestCVApproval(garmentPolygon: insetGarmentPolygon())
    guard case let .blocked(failure, invalidEndpoints) = outcome else {
        Issue.record("expected invalid endpoint failure")
        return
    }
    #expect(failure == .endpointsInvalid)
    #expect(invalidEndpoints == [.lengthStart])
    #expect(editor.status == .needsReview)
}

@Test func approvalEventAdvancesOnlyTheAppOwnedMeasurementWorkflow() throws {
    var editor = try approvalEditor()
    let outcome = editor.requestCVApproval(garmentPolygon: fullImageGarmentPolygon())
    guard case let .approved(event) = outcome else {
        Issue.record("expected approval event")
        return
    }

    var workflow = CaptureWorkflowState()
    try workflow.transition(.captured(.front))
    try workflow.transition(.assessmentAccepted(.front))
    try workflow.transition(.captured(.back))
    try workflow.transition(.assessmentAccepted(.back))
    try workflow.transition(.captured(.tag))
    try workflow.transition(.assessmentAccepted(.tag))
    try workflow.transition(.startMeasurementCapture)
    try workflow.transition(.captured(.measurement))
    try workflow.transition(.measurementValidationSucceeded)
    #expect(workflow.measurementApproval == .unapproved)

    try workflow.transition(event)
    #expect(workflow.measurementApproval == .approvedCV)
    #expect(workflow.phase == .readyToEdit)
    #expect(workflow.isEditUnlocked)
}
