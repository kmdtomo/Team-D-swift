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

public enum BackgroundFixedAssetSelection: Equatable, Sendable {
    case unavailable(BackgroundFixedAssetUnavailability)

    public static let repositoryCatalog: BackgroundFixedAssetSelection =
        .unavailable(.noLicenseConfirmedRepositoryAsset)

    public var isSelectable: Bool { false }
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
