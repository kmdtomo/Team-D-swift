import Foundation
import Testing
@testable import ContractKit

func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
    try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
}

func golden(_ name: String) throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Golden/v1")))
}

func jsonObject(_ data: Data) throws -> Any {
    try JSONSerialization.jsonObject(with: data)
}

func removing(_ key: String, from object: Any) -> Any {
    var result = object as! [String: Any]
    result.removeValue(forKey: key)
    return result
}

func setting(_ key: String, to value: Any, in object: Any) -> Any {
    var result = object as! [String: Any]
    result[key] = value
    return result
}

func setting(path: [String], to value: Any, in object: Any) -> Any {
    precondition(!path.isEmpty)
    var path = path
    var result = object as! [String: Any]
    let first = path.removeFirst()
    if path.isEmpty {
        result[first] = value
    } else {
        result[first] = setting(path: path, to: value, in: result[first]!)
    }
    return result
}

func removing(path: [String], from object: Any) -> Any {
    precondition(!path.isEmpty)
    var path = path
    var result = object as! [String: Any]
    let first = path.removeFirst()
    if path.isEmpty {
        result.removeValue(forKey: first)
    } else {
        result[first] = removing(path: path, from: result[first]!)
    }
    return result
}

func expectRejected<T: Decodable>(_ type: T.Type, _ object: Any) {
    #expect(throws: Error.self) { try decode(type, object) }
}

func assertGoldenRoundTrip<T: Codable & Equatable>(_ type: T.Type, named name: String) throws {
    let originalData = try golden(name)
    let original = try jsonObject(originalData)
    let decoded = try JSONDecoder().decode(T.self, from: originalData)
    let encoded = try JSONEncoder().encode(decoded)
    let encodedObject = try jsonObject(encoded)
    #expect((original as AnyObject).isEqual(encodedObject))
    let redecoded = try JSONDecoder().decode(T.self, from: encoded)
    #expect(decoded == redecoded)
}
