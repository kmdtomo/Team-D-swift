import Foundation

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
}
#endif

public struct FileOriginalImageImporter: CaptureImporting {
    private let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func loadOriginal() async throws -> ImportedCapture {
        let bytes = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        #if canImport(ImageIO)
        return .init(originalFileData: bytes, metadata: OriginalImageMetadataReader.metadata(for: bytes))
        #else
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
    public init(item: PhotosPickerItem) { self.item = item }

    public func loadOriginal() async throws -> ImportedCapture {
        guard let bytes = try await item.loadTransferable(type: Data.self) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return .init(originalFileData: bytes, metadata: OriginalImageMetadataReader.metadata(for: bytes))
    }
}
#endif
