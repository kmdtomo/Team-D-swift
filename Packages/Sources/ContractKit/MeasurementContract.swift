import DomainKit

public struct NormalizedPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) throws {
        try requireUnit(x, "x")
        try requireUnit(y, "y")
        self.x = x
        self.y = y
    }

    public init(from decoder: Decoder) throws {
        try requireOnlyKeys(decoder, allowed: ["x", "y"])
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try self.init(x: container.decode(Double.self, forKey: key("x")), y: container.decode(Double.self, forKey: key("y")))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(x, forKey: key("x"))
        try container.encode(y, forKey: key("y"))
    }
}

public struct MeasurementLine: Codable, Equatable, Sendable {
    public let start: NormalizedPoint
    public let end: NormalizedPoint
    public let valueCm: Double

    public init(start: NormalizedPoint, end: NormalizedPoint, valueCm: Double) throws {
        try requirePositiveFinite(valueCm, "valueCm")
        self.start = start
        self.end = end
        self.valueCm = valueCm
    }

    public init(from decoder: Decoder) throws {
        try requireOnlyKeys(decoder, allowed: ["start", "end", "valueCm"])
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try self.init(start: container.decode(NormalizedPoint.self, forKey: key("start")), end: container.decode(NormalizedPoint.self, forKey: key("end")), valueCm: container.decode(Double.self, forKey: key("valueCm")))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(start, forKey: key("start"))
        try container.encode(end, forKey: key("end"))
        try container.encode(valueCm, forKey: key("valueCm"))
    }
}

public struct MeasurementMarker: Codable, Equatable, Sendable {
    public let knownSideCm: Double
    public let corners: [NormalizedPoint]
    public let pxPerCm: Double

    public init(knownSideCm: Double, corners: [NormalizedPoint], pxPerCm: Double) throws {
        guard knownSideCm == 5, corners.count == 4 else { throw WireValidationError.invalidValue("marker") }
        try requirePositiveFinite(pxPerCm, "pxPerCm")
        self.knownSideCm = knownSideCm
        self.corners = corners
        self.pxPerCm = pxPerCm
    }

    public init(from decoder: Decoder) throws {
        try requireOnlyKeys(decoder, allowed: ["knownSideCm", "corners", "pxPerCm"])
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try self.init(knownSideCm: container.decode(Double.self, forKey: key("knownSideCm")), corners: container.decode([NormalizedPoint].self, forKey: key("corners")), pxPerCm: container.decode(Double.self, forKey: key("pxPerCm")))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(knownSideCm, forKey: key("knownSideCm"))
        try container.encode(corners, forKey: key("corners"))
        try container.encode(pxPerCm, forKey: key("pxPerCm"))
    }
}

public struct MeasurementEndpoints: Codable, Equatable, Sendable {
    public let lengthStart: NormalizedPoint
    public let lengthEnd: NormalizedPoint
    public let widthStart: NormalizedPoint
    public let widthEnd: NormalizedPoint

    public init(lengthStart: NormalizedPoint, lengthEnd: NormalizedPoint, widthStart: NormalizedPoint, widthEnd: NormalizedPoint) {
        self.lengthStart = lengthStart
        self.lengthEnd = lengthEnd
        self.widthStart = widthStart
        self.widthEnd = widthEnd
    }

    public init(from decoder: Decoder) throws {
        try requireOnlyKeys(decoder, allowed: ["lengthStart", "lengthEnd", "widthStart", "widthEnd"])
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        self.init(lengthStart: try container.decode(NormalizedPoint.self, forKey: key("lengthStart")), lengthEnd: try container.decode(NormalizedPoint.self, forKey: key("lengthEnd")), widthStart: try container.decode(NormalizedPoint.self, forKey: key("widthStart")), widthEnd: try container.decode(NormalizedPoint.self, forKey: key("widthEnd")))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(lengthStart, forKey: key("lengthStart"))
        try container.encode(lengthEnd, forKey: key("lengthEnd"))
        try container.encode(widthStart, forKey: key("widthStart"))
        try container.encode(widthEnd, forKey: key("widthEnd"))
    }
}

public struct MeasurementDraft: Codable, Equatable, Sendable {
    public let imageId: String
    public let marker: MeasurementMarker?
    public let length: MeasurementLine
    public let width: MeasurementLine
    public let source: MeasurementSource
    public let status: MeasurementStatus

    public init(imageId: String, marker: MeasurementMarker?, length: MeasurementLine, width: MeasurementLine, source: MeasurementSource, status: MeasurementStatus) throws {
        try requireNonblank(imageId, "imageId")
        self.imageId = imageId
        self.marker = marker
        self.length = length
        self.width = width
        self.source = source
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        try requireOnlyKeys(decoder, allowed: ["imageId", "marker", "length", "width", "source", "status"])
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let markerKey = key("marker")
        guard container.contains(markerKey) else { throw WireValidationError.invalidValue("marker missing") }
        try self.init(imageId: container.decode(String.self, forKey: key("imageId")), marker: container.decodeNil(forKey: markerKey) ? nil : container.decode(MeasurementMarker.self, forKey: markerKey), length: container.decode(MeasurementLine.self, forKey: key("length")), width: container.decode(MeasurementLine.self, forKey: key("width")), source: decodeEnum(container, key: key("source"), MeasurementSource.self), status: decodeEnum(container, key: key("status"), MeasurementStatus.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(imageId, forKey: key("imageId"))
        try container.encode(marker, forKey: key("marker"))
        try container.encode(length, forKey: key("length"))
        try container.encode(width, forKey: key("width"))
        try container.encode(source.rawValue, forKey: key("source"))
        try container.encode(status.rawValue, forKey: key("status"))
    }
}
