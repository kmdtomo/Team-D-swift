import Foundation
import Testing
@testable import ContractKit
@testable import DomainKit

@Test func pointRejectsMissingUnknownWrongAndNonfiniteValues() throws {
    let point: [String: Any] = ["x": 0.0, "y": 1.0]
    for key in ["x", "y"] { expectRejected(NormalizedPoint.self, removing(key, from: point)) }
    expectRejected(NormalizedPoint.self, setting("extra", to: 1, in: point))
    expectRejected(NormalizedPoint.self, setting("x", to: "0", in: point))
    for invalid in [Double.nan, Double.infinity, -Double.infinity, -0.01, 1.01] {
        #expect(throws: Error.self) { try NormalizedPoint(x: invalid, y: 0) }
    }
    _ = try NormalizedPoint(x: 0, y: 1)
}

@Test func measurementRejectsAllRootAndNestedMissingAndUnknownKeys() throws {
    let draft = try jsonObject(golden("measurement-draft-marker-null"))
    for key in ["imageId", "marker", "length", "width", "source", "status"] { expectRejected(MeasurementDraft.self, removing(key, from: draft)) }
    expectRejected(MeasurementDraft.self, setting("extra", to: true, in: draft))
    let markerDraft = setting("marker", to: ["knownSideCm": 5.0, "corners": [["x": 0.0, "y": 0.0], ["x": 1.0, "y": 0.0], ["x": 1.0, "y": 1.0], ["x": 0.0, "y": 1.0]], "pxPerCm": 10.0], in: draft)
    for key in ["knownSideCm", "corners", "pxPerCm"] { expectRejected(MeasurementDraft.self, removing(path: ["marker", key], from: markerDraft)) }
    for key in ["start", "end", "valueCm"] { expectRejected(MeasurementDraft.self, removing(path: ["length", key], from: draft)) }
    for key in ["x", "y"] { expectRejected(MeasurementDraft.self, removing(path: ["length", "start", key], from: draft)) }
    expectRejected(MeasurementDraft.self, setting(path: ["length", "start", "extra"], to: 1, in: draft))
}

@Test func endpointsRejectEveryMissingRequiredKeyAndUnknownTopKey() throws {
    let object = try jsonObject(golden("measurement-endpoints"))
    for key in ["lengthStart", "lengthEnd", "widthStart", "widthEnd"] { expectRejected(MeasurementEndpoints.self, removing(key, from: object)) }
    expectRejected(MeasurementEndpoints.self, setting("extra", to: true, in: object))
    expectRejected(MeasurementEndpoints.self, setting(path: ["lengthStart", "extra"], to: true, in: object))
}

@Test func markerAndMeasurementDirectValidationAndEnumsAreExhaustive() throws {
    let point = try NormalizedPoint(x: 0, y: 0)
    for corners in [[], [point, point, point], [point, point, point, point, point]] {
        #expect(throws: Error.self) { try MeasurementMarker(knownSideCm: 5, corners: corners, pxPerCm: 1) }
    }
    #expect(throws: Error.self) { try MeasurementMarker(knownSideCm: 4.9, corners: [point, point, point, point], pxPerCm: 1) }
    #expect(throws: Error.self) { try MeasurementMarker(knownSideCm: 5, corners: [point, point, point, point], pxPerCm: 0) }
    for invalid in [Double.nan, Double.infinity, -Double.infinity, 0.0] { #expect(throws: Error.self) { try MeasurementLine(start: point, end: point, valueCm: invalid) } }
    let draft = try jsonObject(golden("measurement-draft-marker-null"))
    for source in MeasurementSource.allCases { _ = try decode(MeasurementDraft.self, setting("source", to: source.rawValue, in: draft)) }
    for status in MeasurementStatus.allCases { _ = try decode(MeasurementDraft.self, setting("status", to: status.rawValue, in: draft)) }
}
