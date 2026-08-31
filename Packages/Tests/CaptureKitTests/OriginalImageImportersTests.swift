import CaptureKit
import Foundation
import XCTest

#if canImport(ImageIO)
final class OriginalImageImportersTests: XCTestCase {
    func testMetadataReaderPreservesOriginalImageBytes() throws {
        let bytes = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNGBase64))

        let imported = try OriginalImageMetadataReader.importedCapture(for: bytes)

        XCTAssertEqual(imported.originalFileData, bytes)
        XCTAssertEqual(imported.metadata.pixelWidth, 1)
        XCTAssertEqual(imported.metadata.pixelHeight, 1)
        XCTAssertNotNil(imported.metadata.contentType)
    }

    func testMetadataReaderRejectsEmptyMalformedAndOversizedPayloads() throws {
        XCTAssertThrowsError(try OriginalImageMetadataReader.importedCapture(for: Data())) { error in
            XCTAssertEqual(error as? OriginalImageImportError, .emptyData)
        }
        XCTAssertThrowsError(try OriginalImageMetadataReader.importedCapture(for: Data([1, 2, 3]))) { error in
            XCTAssertEqual(error as? OriginalImageImportError, .unsupportedImage)
        }
        let bytes = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNGBase64))
        XCTAssertThrowsError(try OriginalImageMetadataReader.importedCapture(for: bytes, maximumBytes: 1)) { error in
            XCTAssertEqual(error as? OriginalImageImportError, .fileTooLarge(maximumBytes: 1))
        }
    }

    func testFileImporterReadsSecurityScopedStyleURLWithoutReencoding() async throws {
        let bytes = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNGBase64))
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("teamd-t05-03-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try bytes.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let imported = try await FileOriginalImageImporter(fileURL: fileURL).loadOriginal()

        XCTAssertEqual(imported.originalFileData, bytes)
        XCTAssertEqual(imported.metadata.pixelWidth, 1)
        XCTAssertEqual(imported.metadata.pixelHeight, 1)
    }

    func testFileImporterRejectsOversizedFileBeforeReadingIt() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("teamd-t05-03-oversized-\(UUID().uuidString)")
        try Data([1, 2, 3]).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        do {
            _ = try await FileOriginalImageImporter(fileURL: fileURL, maximumBytes: 2).loadOriginal()
            XCTFail("oversized source must be rejected")
        } catch {
            XCTAssertEqual(error as? OriginalImageImportError, .fileTooLarge(maximumBytes: 2))
        }
    }

    private static let onePixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
}
#endif
