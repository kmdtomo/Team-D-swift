import Foundation

/// The iOS protection level applied to every temporary session artifact.
/// `completeUntilFirstUserAuthentication` keeps files unavailable until the
/// device has first been unlocked after boot, while allowing the session to
/// continue when the device is subsequently locked.
public enum ProtectedTemporaryFileProtectionPolicy: Equatable, Sendable {
    case completeUntilFirstUserAuthentication
}

public enum ProtectedTemporarySessionImageBackingStoreError: Error, Equatable, Sendable {
    case unsafeContainer
    case unsafeFilename
    case filenameCollision
    case fileProtectionNotApplied
    case cleanedUp
}

/// A filename source deliberately limited to lifecycle and operation versions.
/// It never receives application identifiers or image bytes.
public protocol ProtectedTemporarySessionFilenameStrategy: Sendable {
    func filename(lifecycleGeneration: UInt64, operationVersion: UInt64) -> String
}

public struct NumericSessionImageFilenameStrategy: ProtectedTemporarySessionFilenameStrategy {
    public init() {}

    public func filename(lifecycleGeneration: UInt64, operationVersion: UInt64) -> String {
        "artifact-l\(lifecycleGeneration)-o\(operationVersion).bin"
    }
}

/// Session-only storage below a fixed child of a caller-owned temporary
/// container. Only strict descendants of the injected manager's temporary root
/// are accepted; this type never removes the caller's container. A container
/// has one live owner at a time: startup recovery intentionally removes this
/// fixed child, so callers must not create concurrent adapters for one root.
public actor ProtectedTemporarySessionImageBackingStore: SessionImageBackingStore {
    public static let ownedDirectoryName = "team-d-protected-session-artifacts"

    public nonisolated let policy: SessionImageStoragePolicy = .protectedTemporaryFiles
    public nonisolated let fileProtectionPolicy: ProtectedTemporaryFileProtectionPolicy = .completeUntilFirstUserAuthentication
    public nonisolated let excludesFromBackup = true

    private let ownedDirectory: OwnedTemporaryDirectoryCleanup
    private let filenameStrategy: any ProtectedTemporarySessionFilenameStrategy
    private var urls: [SessionImageHandle: URL] = [:]
    private var cleanedUp = false

    public init(
        temporaryContainerURL: URL,
        fileManager: FileManager = FileManager(),
        filenameStrategy: any ProtectedTemporarySessionFilenameStrategy = NumericSessionImageFilenameStrategy()
    ) throws {
        self.ownedDirectory = try Self.prepareOwnedDirectory(
            temporaryContainerURL: temporaryContainerURL,
            fileManager: fileManager,
            deletionInterceptor: nil
        )
        self.filenameStrategy = filenameStrategy
    }

    /// Internal fault-injection boundary used to verify retryable deletion.
    /// Production clients use the public initializer above.
    init(
        temporaryContainerURL: URL,
        filenameStrategy: any ProtectedTemporarySessionFilenameStrategy = NumericSessionImageFilenameStrategy(),
        deletionInterceptor: @escaping @Sendable (URL) throws -> Void
    ) throws {
        self.ownedDirectory = try Self.prepareOwnedDirectory(
            temporaryContainerURL: temporaryContainerURL,
            fileManager: FileManager(),
            deletionInterceptor: deletionInterceptor
        )
        self.filenameStrategy = filenameStrategy
    }

    private static func prepareOwnedDirectory(
        temporaryContainerURL: URL,
        fileManager: FileManager,
        deletionInterceptor: (@Sendable (URL) throws -> Void)?
    ) throws -> OwnedTemporaryDirectoryCleanup {
        let container = temporaryContainerURL.resolvingSymlinksInPath().standardizedFileURL
        let temporaryRoot = fileManager.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isStrictDescendant(container, of: temporaryRoot),
              fileManager.fileExists(atPath: container.path),
              (try? container.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { throw ProtectedTemporarySessionImageBackingStoreError.unsafeContainer }

        let child = container.appendingPathComponent(Self.ownedDirectoryName, isDirectory: true).standardizedFileURL
        guard child.deletingLastPathComponent() == container else {
            throw ProtectedTemporarySessionImageBackingStoreError.unsafeContainer
        }

        let ownedDirectory = OwnedTemporaryDirectoryCleanup(
            fileManager: fileManager,
            url: child,
            deletionInterceptor: deletionInterceptor
        )
        try ownedDirectory.removeOwnedDirectoryIfPresent()
        try ownedDirectory.createProtectedDirectory()
        return ownedDirectory
    }

    deinit {
        // The Sendable helper owns the only cleanup target and removes it when
        // this actor releases it. It never receives the caller's container.
    }

    public func store(_ bytes: Data, handle: SessionImageHandle) async throws {
        guard !cleanedUp else { throw ProtectedTemporarySessionImageBackingStoreError.cleanedUp }
        let url = try fileURL(for: handle)
        if let existing = urls.first(where: { $0.value == url }), existing.key != handle {
            throw ProtectedTemporarySessionImageBackingStoreError.filenameCollision
        }
        if ownedDirectory.fileExists(at: url), urls[handle] != url {
            throw ProtectedTemporarySessionImageBackingStoreError.filenameCollision
        }

        let previousURL = urls[handle]
        try bytes.write(to: url, options: protectedAtomicWriteOptions)
        do {
            try ownedDirectory.excludeFromBackup(url)
            try ownedDirectory.applyFileProtection(to: url)
            if let previousURL, previousURL != url {
                try? ownedDirectory.removeFile(at: previousURL)
            }
            urls[handle] = url
        } catch {
            // A replacement that cannot be protected must not remain readable.
            urls[handle] = nil
            try? ownedDirectory.removeFile(at: url)
            if let previousURL, previousURL != url {
                try? ownedDirectory.removeFile(at: previousURL)
            }
            throw error
        }
    }

    /// Deletes one artifact and only forgets its mapping after deletion succeeds.
    /// A filesystem error is therefore observable and the same handle remains
    /// available for an explicit retry.
    public func discard(handle: SessionImageHandle) async throws {
        guard let url = urls[handle] else { return }
        try ownedDirectory.removeFileIfPresent(at: url)
        urls[handle] = nil
    }

    public func load(handle: SessionImageHandle) async -> Data? {
        guard let url = urls[handle] else { return nil }
        return try? Data(contentsOf: url, options: .uncached)
    }

    /// Deletes all artifacts in exactly one lifecycle namespace. Failed and
    /// not-yet-attempted mappings remain registered so cleanup can be retried.
    public func discardAll(namespace: SessionStorageNamespace) async throws {
        let matching = urls.keys.filter { $0.namespace == namespace }
        for handle in matching { try await discard(handle: handle) }
    }

    /// Explicit terminal cleanup. Subsequent stores are rejected rather than
    /// silently recreating temporary state.
    public func cleanup() async throws {
        try ownedDirectory.removeOwnedDirectoryIfPresent()
        urls.removeAll()
        cleanedUp = true
    }

    private func fileURL(for handle: SessionImageHandle) throws -> URL {
        let filename = filenameStrategy.filename(
            lifecycleGeneration: handle.namespace.lifecycleGeneration,
            operationVersion: handle.token.version
        )
        guard !filename.isEmpty,
              !filename.contains("/"),
              !filename.contains("\\")
        else { throw ProtectedTemporarySessionImageBackingStoreError.unsafeFilename }

        let url = ownedDirectory.url.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
        guard url.deletingLastPathComponent() == ownedDirectory.url else {
            throw ProtectedTemporarySessionImageBackingStoreError.unsafeFilename
        }
        return url
    }

    private var protectedAtomicWriteOptions: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtection]
        #else
        [.atomic]
        #endif
    }

    private nonisolated static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        guard candidate.isFileURL, root.isFileURL, candidate != root else { return false }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path.hasPrefix(prefix)
    }
}

/// `FileManager` is not Sendable, so this narrowly scoped holder owns all
/// filesystem mutation and deinit cleanup. Its URL is always the fixed child.
private final class OwnedTemporaryDirectoryCleanup: @unchecked Sendable {
    let fileManager: FileManager
    let url: URL
    private let deletionInterceptor: (@Sendable (URL) throws -> Void)?

    init(
        fileManager: FileManager,
        url: URL,
        deletionInterceptor: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.url = url
        self.deletionInterceptor = deletionInterceptor
    }

    deinit { try? removeOwnedDirectoryIfPresent() }

    func fileExists(at url: URL) -> Bool { fileManager.fileExists(atPath: url.path) }

    func removeOwnedDirectoryIfPresent() throws {
        if fileManager.fileExists(atPath: url.path) {
            try deletionInterceptor?(url)
            try fileManager.removeItem(at: url)
        }
    }

    func createProtectedDirectory() throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        try excludeFromBackup(url)
        try applyFileProtection(to: url)
    }

    func removeFile(at url: URL) throws {
        try deletionInterceptor?(url)
        try fileManager.removeItem(at: url)
    }

    func removeFileIfPresent(at url: URL) throws {
        if fileManager.fileExists(atPath: url.path) { try removeFile(at: url) }
    }

    func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    func applyFileProtection(to url: URL) throws {
        #if os(iOS)
        let expected = FileProtectionType.completeUntilFirstUserAuthentication
        try fileManager.setAttributes(
            [.protectionKey: expected],
            ofItemAtPath: url.path
        )
        let actual = try fileManager.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
        guard actual == expected else {
            throw ProtectedTemporarySessionImageBackingStoreError.fileProtectionNotApplied
        }
        #endif
    }
}
