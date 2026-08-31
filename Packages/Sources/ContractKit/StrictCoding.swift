import Foundation

public enum ContractKitModule {}

public enum WireValidationError: Error, Equatable, Sendable {
    case unknownKey(String)
    case invalidValue(String)
}

struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

func key(_ name: String) -> AnyCodingKey {
    AnyCodingKey(stringValue: name)!
}

/// Preflight each decoded object because `Codable` otherwise accepts unknown keys.
func requireOnlyKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    if let unknown = container.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
        throw WireValidationError.unknownKey(unknown.stringValue)
    }
}

func decodeEnum<T: RawRepresentable>(
    _ container: KeyedDecodingContainer<AnyCodingKey>,
    key: AnyCodingKey,
    _: T.Type
) throws -> T where T.RawValue == String {
    guard let value = T(rawValue: try container.decode(String.self, forKey: key)) else {
        throw WireValidationError.invalidValue(key.stringValue)
    }
    return value
}

func requireNonblank(_ value: String, _ name: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw WireValidationError.invalidValue(name)
    }
}

func requireUnit(_ value: Double, _ name: String) throws {
    guard value.isFinite, (0 ... 1).contains(value) else {
        throw WireValidationError.invalidValue(name)
    }
}

func requirePositiveFinite(_ value: Double, _ name: String) throws {
    guard value.isFinite, value > 0 else {
        throw WireValidationError.invalidValue(name)
    }
}
