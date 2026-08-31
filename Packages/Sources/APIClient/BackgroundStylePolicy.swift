import ContractKit
import Foundation

/// Style IDs are a finite client contract. Arbitrary user or model text never
/// crosses the background-generation boundary.
public enum BackgroundStyleID: String, CaseIterable, Hashable, Sendable {
    case cleanWhite = "clean-white"
}

public enum BackgroundStylePolicyError: Error, Equatable, Sendable {
    case unknownStyleID
}

/// Subjects the shared backend's fixed prompt must exclude from every style.
/// These values document policy; they are deliberately absent from the wire
/// request, which contains only `styleId`.
public enum BackgroundPromptExcludedSubject: String, CaseIterable, Hashable, Sendable {
    case product
    case person
    case garment
    case hanger
    case text
    case logo
}

public struct BackgroundFixedPromptContract: Equatable, Sendable {
    public let version: String
    public let purpose: String
    public let excludedSubjects: Set<BackgroundPromptExcludedSubject>

    public static let v1 = BackgroundFixedPromptContract(
        version: "empty-product-photography-background-v1",
        purpose: "empty-product-photography-background",
        excludedSubjects: Set(BackgroundPromptExcludedSubject.allCases)
    )

    private init(
        version: String,
        purpose: String,
        excludedSubjects: Set<BackgroundPromptExcludedSubject>
    ) {
        self.version = version
        self.purpose = purpose
        self.excludedSubjects = excludedSubjects
    }
}

/// The repository currently contains no binary background whose license and
/// inventory entry permit app use. Keep this explicit so UI integration cannot
/// silently invent, download, or bundle an unlicensed fallback.
public enum BackgroundFixedAssetUnavailability: Equatable, Sendable {
    case noLicenseConfirmedRepositoryAsset
}

public enum BackgroundFixedAssetDescriptorError: Error, Equatable, Sendable {
    case invalidAssetID
    case invalidRepositoryRelativePath
    case invalidSHA256
    case invalidLicenseEvidenceID
    case invalidInventoryEvidenceID
}

/// Metadata required before a repository asset can become a selectable fixed
/// fallback. The descriptor carries no image bytes and does not itself add an
/// asset to the repository or its license inventory.
public struct BackgroundFixedAssetDescriptor: Equatable, Sendable {
    public let assetID: String
    public let repositoryRelativePath: String
    public let sha256: String
    public let licenseEvidenceID: String
    public let inventoryEvidenceID: String

    public init(
        assetID: String,
        repositoryRelativePath: String,
        sha256: String,
        licenseEvidenceID: String,
        inventoryEvidenceID: String
    ) throws {
        guard Self.isStableReference(assetID, maximumLength: 96) else {
            throw BackgroundFixedAssetDescriptorError.invalidAssetID
        }
        guard Self.isSafeRepositoryImagePath(repositoryRelativePath) else {
            throw BackgroundFixedAssetDescriptorError.invalidRepositoryRelativePath
        }
        guard sha256.count == 64,
            sha256.allSatisfy({ "0123456789abcdef".contains($0) })
        else {
            throw BackgroundFixedAssetDescriptorError.invalidSHA256
        }
        guard Self.isStableReference(licenseEvidenceID, maximumLength: 256) else {
            throw BackgroundFixedAssetDescriptorError.invalidLicenseEvidenceID
        }
        guard Self.isStableReference(inventoryEvidenceID, maximumLength: 256) else {
            throw BackgroundFixedAssetDescriptorError.invalidInventoryEvidenceID
        }
        self.assetID = assetID
        self.repositoryRelativePath = repositoryRelativePath
        self.sha256 = sha256
        self.licenseEvidenceID = licenseEvidenceID
        self.inventoryEvidenceID = inventoryEvidenceID
    }

    private static func isStableReference(_ value: String, maximumLength: Int) -> Bool {
        guard (1...maximumLength).contains(value.count),
            let first = value.first,
            first.isASCII,
            first.isLetter || first.isNumber
        else {
            return false
        }
        return value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || "._:/#-".contains($0))
        }
    }

    private static func isSafeRepositoryImagePath(_ value: String) -> Bool {
        guard !value.isEmpty,
            value.count <= 512,
            !value.hasPrefix("/"),
            !value.hasPrefix("./"),
            !value.contains("\\"),
            !value.contains("//"),
            value.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || "._-/".contains($0))
            })
        else {
            return false
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            return false
        }
        guard let filename = components.last,
            let separator = filename.lastIndex(of: ".")
        else {
            return false
        }
        let fileExtension = filename[filename.index(after: separator)...].lowercased()
        return ["png", "jpg", "jpeg"].contains(fileExtension)
    }
}

public enum BackgroundFixedAssetSelection: Equatable, Sendable {
    case unavailable(BackgroundFixedAssetUnavailability)
    case licenseConfirmed(BackgroundFixedAssetDescriptor)

    public static let repositoryCatalog: BackgroundFixedAssetSelection =
        .unavailable(.noLicenseConfirmedRepositoryAsset)

    public var isSelectable: Bool {
        switch self {
        case .unavailable: false
        case .licenseConfirmed: true
        }
    }

    public var descriptor: BackgroundFixedAssetDescriptor? {
        switch self {
        case .unavailable: nil
        case .licenseConfirmed(let descriptor): descriptor
        }
    }
}

public struct BackgroundStylePolicy: Equatable, Sendable {
    public let fixedPrompt: BackgroundFixedPromptContract
    public let fixedBackground: BackgroundFixedAssetSelection

    public init(
        fixedPrompt: BackgroundFixedPromptContract = .v1,
        fixedBackground: BackgroundFixedAssetSelection = .repositoryCatalog
    ) {
        self.fixedPrompt = fixedPrompt
        self.fixedBackground = fixedBackground
    }

    public func resolve(_ rawStyleID: String) throws -> BackgroundStyleID {
        guard let style = BackgroundStyleID(rawValue: rawStyleID) else {
            throw BackgroundStylePolicyError.unknownStyleID
        }
        return style
    }

    public func wireRequest(for style: BackgroundStyleID) throws -> BackgroundStyleRequest {
        try BackgroundStyleRequest(styleId: style.rawValue)
    }
}
