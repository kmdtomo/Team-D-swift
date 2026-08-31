import Foundation

public enum OriginalImageImportError: Error, Equatable, Sendable {
    case emptyData
    case fileTooLarge(maximumBytes: Int)
    case unsupportedImage
}

public enum OriginalImageImportPolicy {
    /// High-resolution originals remain untouched, while an unexpectedly huge
    /// provider payload cannot consume the whole session memory budget.
    public static let maximumBytes = 64 * 1_024 * 1_024
}

#if canImport(ImageIO)
import ImageIO

public enum OriginalImageMetadataReader {
    /// Metadata is extracted without decoding/re-encoding pixel data.
    public static func metadata(for originalFileData: Data) -> CapturePhotoMetadata {
        guard let source = CGImageSourceCreateWithData(originalFileData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return .init() }
        return .init(
            contentType: CGImageSourceGetType(source).map { $0 as String },
            orientation: properties[kCGImagePropertyOrientation] as? Int,
            colorSpaceName: properties[kCGImagePropertyColorModel] as? String,
            pixelWidth: properties[kCGImagePropertyPixelWidth] as? Int,
            pixelHeight: properties[kCGImagePropertyPixelHeight] as? Int
        )
    }

    public static func importedCapture(
        for originalFileData: Data,
        maximumBytes: Int = OriginalImageImportPolicy.maximumBytes
    ) throws -> ImportedCapture {
        guard !originalFileData.isEmpty else { throw OriginalImageImportError.emptyData }
        guard originalFileData.count <= maximumBytes else {
            throw OriginalImageImportError.fileTooLarge(maximumBytes: maximumBytes)
        }
        guard let source = CGImageSourceCreateWithData(originalFileData as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0
        else { throw OriginalImageImportError.unsupportedImage }
        return .init(originalFileData: originalFileData, metadata: metadata(for: originalFileData))
    }
}
#endif

public struct FileOriginalImageImporter: CaptureImporting {
    private let fileURL: URL
    private let maximumBytes: Int
    public init(fileURL: URL, maximumBytes: Int = OriginalImageImportPolicy.maximumBytes) {
        self.fileURL = fileURL
        self.maximumBytes = maximumBytes
    }

    public func loadOriginal() async throws -> ImportedCapture {
        let didAccessSecurityScope = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope { fileURL.stopAccessingSecurityScopedResource() }
        }
        if let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maximumBytes {
            throw OriginalImageImportError.fileTooLarge(maximumBytes: maximumBytes)
        }
        // Copy the bounded original while the security scope is open so the
        // session does not retain an external file mapping after dismissal.
        let bytes = try Data(contentsOf: fileURL)
        #if canImport(ImageIO)
        return try OriginalImageMetadataReader.importedCapture(for: bytes, maximumBytes: maximumBytes)
        #else
        guard !bytes.isEmpty else { throw OriginalImageImportError.emptyData }
        guard bytes.count <= maximumBytes else {
            throw OriginalImageImportError.fileTooLarge(maximumBytes: maximumBytes)
        }
        return .init(originalFileData: bytes, metadata: .init())
        #endif
    }
}

#if os(iOS)
import PhotosUI

/// PhotosPicker supplies the selected image representation directly to this
/// adapter; CaptureKit preserves that data and only reads its metadata.
@available(iOS 16.0, *)
public struct PhotosPickerOriginalImageImporter: CaptureImporting {
    private let item: PhotosPickerItem
    private let maximumBytes: Int
    public init(item: PhotosPickerItem, maximumBytes: Int = OriginalImageImportPolicy.maximumBytes) {
        self.item = item
        self.maximumBytes = maximumBytes
    }

    public func loadOriginal() async throws -> ImportedCapture {
        guard let bytes = try await item.loadTransferable(type: Data.self) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return try OriginalImageMetadataReader.importedCapture(for: bytes, maximumBytes: maximumBytes)
    }
}
#endif
