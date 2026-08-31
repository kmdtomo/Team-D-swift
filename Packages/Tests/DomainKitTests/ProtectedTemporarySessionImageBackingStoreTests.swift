import Foundation
import Testing
@testable import DomainKit

@Test func protectedTemporaryStoreStoresLoadsAndDiscardsOneHandle() async throws {
    let fixture = try TemporaryStoreFixture()
    let store = try fixture.makeStore()
    let handle = try fixture.handle(session: "session-secret", lifecycle: 1, request: "request-secret", image: "image-secret", version: 1)

    try await store.store(Data([1, 2, 3]), handle: handle)
    #expect(await store.load(handle: handle) == Data([1, 2, 3]))
    try await store.store(Data([4, 5, 6]), handle: handle)
    #expect(await store.load(handle: handle) == Data([4, 5, 6]))
    try await store.discard(handle: handle)
    #expect(await store.load(handle: handle) == nil)
    #expect(fixture.ownedContents().isEmpty)
    #expect(fixture.callerMarkerExists)
}

@Test func protectedTemporaryStoreDiscardsOnlyExactLifecycleNamespace() async throws {
    let fixture = try TemporaryStoreFixture()
    let store = try fixture.makeStore()
    let first = try fixture.handle(session: "same-session", lifecycle: 1, request: "old-request", image: "old-image", version: 1)
    let second = try fixture.handle(session: "same-session", lifecycle: 2, request: "new-request", image: "new-image", version: 2)

    try await store.store(Data([1]), handle: first)
    try await store.store(Data([2]), handle: second)
    try await store.discardAll(namespace: first.namespace)

    #expect(await store.load(handle: first) == nil)
    #expect(await store.load(handle: second) == Data([2]))
    #expect(fixture.callerMarkerExists)
}

@Test func protectedTemporaryStoreRecoversAnOrphanedOwnedChildAtStartup() throws {
    let fixture = try TemporaryStoreFixture()
    try fixture.createOrphanedOwnedFile()

    let store = try fixture.makeStore()

    #expect(fixture.ownedDirectoryExists)
    #expect(fixture.ownedContents().isEmpty)
    #expect(fixture.callerMarkerExists)
    withExtendedLifetime(store) {}
}

@Test func protectedTemporaryStoreExplicitCleanupRemovesOnlyOwnedChild() async throws {
    let fixture = try TemporaryStoreFixture()
    let store = try fixture.makeStore()
    let handle = try fixture.handle(session: "end", lifecycle: 1, request: "request", image: "image", version: 1)
    try await store.store(Data([7]), handle: handle)

    try await store.cleanup()

    #expect(!fixture.ownedDirectoryExists)
    #expect(fixture.callerMarkerExists)
    await #expect(throws: ProtectedTemporarySessionImageBackingStoreError.cleanedUp) {
        try await store.store(Data([8]), handle: handle)
    }
}

@Test func protectedTemporaryStoreDeinitRemovesOnlyOwnedChild() async throws {
    let fixture = try TemporaryStoreFixture()
    let handle = try fixture.handle(session: "deinit", lifecycle: 1, request: "request", image: "image", version: 1)
    weak var weakStore: ProtectedTemporarySessionImageBackingStore?
    do {
        let store = try fixture.makeStore()
        weakStore = store
        try await store.store(Data([5]), handle: handle)
    }

    #expect(weakStore == nil)
    #expect(!fixture.ownedDirectoryExists)
    #expect(fixture.callerMarkerExists)
}

@Test func protectedTemporaryStoreHasProtectionAndBackupPolicy() async throws {
    let fixture = try TemporaryStoreFixture()
    let store = try fixture.makeStore()
    let handle = try fixture.handle(session: "policy", lifecycle: 1, request: "request", image: "image", version: 1)
    try await store.store(Data([1]), handle: handle)

    #expect(store.policy == .protectedTemporaryFiles)
    #expect(store.fileProtectionPolicy == .completeUntilFirstUserAuthentication)
    #expect(store.excludesFromBackup)
    #expect(try fixture.ownedDirectoryURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    #expect(try fixture.fileURL(lifecycle: 1, operation: 1).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
}

@Test func protectedTemporaryStoreNeverPlacesRawIdentifiersInRelativeFilenames() async throws {
    let fixture = try TemporaryStoreFixture()
    let store = try fixture.makeStore()
    let sessionSecret = "session-secret-DO-NOT-LEAK"
    let requestSecret = "request-secret-DO-NOT-LEAK"
    let imageSecret = "image-secret-DO-NOT-LEAK"
    let handle = try fixture.handle(session: sessionSecret, lifecycle: 87, request: requestSecret, image: imageSecret, version: 99)

    try await store.store(Data([4]), handle: handle)
    let names = fixture.ownedContents().map(\.lastPathComponent)

    #expect(names == ["artifact-l87-o99.bin"])
    for name in names {
        #expect(!name.contains(sessionSecret))
        #expect(!name.contains(requestSecret))
        #expect(!name.contains(imageSecret))
    }
}

@Test func protectedTemporaryStoreRejectsUnsafeContainersWithoutDeletingThem() throws {
    let manager = FileManager.default
    let temporaryRoot = manager.temporaryDirectory
    let fixture = try TemporaryStoreFixture()
    let outside = URL(fileURLWithPath: "/Users", isDirectory: true)

    for candidate in [URL(fileURLWithPath: "/", isDirectory: true), temporaryRoot, outside] {
        #expect(throws: ProtectedTemporarySessionImageBackingStoreError.unsafeContainer) {
            try ProtectedTemporarySessionImageBackingStore(temporaryContainerURL: candidate)
        }
    }
    #expect(fixture.callerMarkerExists)
}

@Test func protectedTemporaryStoreRejectsUnsafeFilenamesAndPreservesCallerContainer() async throws {
    let fixture = try TemporaryStoreFixture()
    let handle = try fixture.handle(session: "filename", lifecycle: 1, request: "request", image: "image", version: 1)

    for name in ["", "/absolute.bin", "../escape.bin", "folder/file.bin", "folder\\file.bin"] {
        let store = try fixture.makeStore(filenameStrategy: FixedFilenameStrategy(name))
        await #expect(throws: ProtectedTemporarySessionImageBackingStoreError.unsafeFilename) {
            try await store.store(Data([1]), handle: handle)
        }
        #expect(fixture.callerMarkerExists)
    }
}

@Test func protectedTemporaryStoreRejectsFilenameCollisionWithoutOverwriting() async throws {
    let fixture = try TemporaryStoreFixture()
    let store = try fixture.makeStore(filenameStrategy: FixedFilenameStrategy("same.bin"))
    let first = try fixture.handle(session: "collision", lifecycle: 1, request: "first", image: "first", version: 1)
    let second = try fixture.handle(session: "collision", lifecycle: 1, request: "second", image: "second", version: 2)

    try await store.store(Data([1]), handle: first)
    await #expect(throws: ProtectedTemporarySessionImageBackingStoreError.filenameCollision) {
        try await store.store(Data([2]), handle: second)
    }

    #expect(await store.load(handle: first) == Data([1]))
    #expect(await store.load(handle: second) == nil)
    #expect(fixture.callerMarkerExists)
}

@Test func protectedTemporaryStoreFailedDiscardKeepsMappingForRetry() async throws {
    let failures = RemovalFailureController()
    let fixture = try TemporaryStoreFixture(removalFailures: failures)
    let store = try fixture.makeStore()
    let handle = try fixture.handle(session: "discard", lifecycle: 1, request: "request", image: "image", version: 1)
    try await store.store(Data([1]), handle: handle)
    failures.failNextRemoval()

    await #expect(throws: InjectedRemovalError.failed) {
        try await store.discard(handle: handle)
    }
    #expect(await store.load(handle: handle) == Data([1]))
    #expect(try fixture.fileURL(lifecycle: 1, operation: 1).checkResourceIsReachable())

    try await store.discard(handle: handle)
    #expect(await store.load(handle: handle) == nil)
}

@Test func protectedTemporaryStoreFailedDiscardAllKeepsMappingForRetry() async throws {
    let failures = RemovalFailureController()
    let fixture = try TemporaryStoreFixture(removalFailures: failures)
    let store = try fixture.makeStore()
    let handle = try fixture.handle(session: "discard-all", lifecycle: 1, request: "request", image: "image", version: 1)
    try await store.store(Data([2]), handle: handle)
    failures.failNextRemoval()

    await #expect(throws: InjectedRemovalError.failed) {
        try await store.discardAll(namespace: handle.namespace)
    }
    #expect(await store.load(handle: handle) == Data([2]))

    try await store.discardAll(namespace: handle.namespace)
    #expect(await store.load(handle: handle) == nil)
}

@Test func protectedTemporaryStoreFailedCleanupPreservesStateForRetry() async throws {
    let failures = RemovalFailureController()
    let fixture = try TemporaryStoreFixture(removalFailures: failures)
    let store = try fixture.makeStore()
    let handle = try fixture.handle(session: "cleanup", lifecycle: 1, request: "request", image: "image", version: 1)
    try await store.store(Data([3]), handle: handle)
    failures.failNextRemoval()

    await #expect(throws: InjectedRemovalError.failed) {
        try await store.cleanup()
    }
    #expect(await store.load(handle: handle) == Data([3]))
    #expect(fixture.ownedDirectoryExists)

    try await store.cleanup()
    #expect(!fixture.ownedDirectoryExists)
    await #expect(throws: ProtectedTemporarySessionImageBackingStoreError.cleanedUp) {
        try await store.store(Data([4]), handle: handle)
    }
}

@Test func protectedTemporaryStorePostWriteFailureIsQuarantinedForEveryCleanupPath() async throws {
    let failures = RemovalFailureController()
    let fixture = try TemporaryStoreFixture(removalFailures: failures)
    let store = try fixture.makeStore()
    let discardHandle = try fixture.handle(session: "quarantine", lifecycle: 1, request: "discard", image: "discard", version: 1)
    let discardAllHandle = try fixture.handle(session: "quarantine", lifecycle: 1, request: "discard-all", image: "discard-all", version: 2)
    let cleanupHandle = try fixture.handle(session: "quarantine", lifecycle: 1, request: "cleanup", image: "cleanup", version: 3)

    failures.failNextMetadataUpdate()
    failures.failNextRemoval()
    await #expect(throws: InjectedRemovalError.failed) {
        try await store.store(Data([1]), handle: discardHandle)
    }
    #expect(await store.load(handle: discardHandle) == nil)
    #expect(try fixture.fileURL(lifecycle: 1, operation: 1).checkResourceIsReachable())
    try await store.discard(handle: discardHandle)
    #expect((try? fixture.fileURL(lifecycle: 1, operation: 1).checkResourceIsReachable()) != true)

    failures.failNextMetadataUpdate()
    failures.failNextRemoval()
    await #expect(throws: InjectedRemovalError.failed) {
        try await store.store(Data([2]), handle: discardAllHandle)
    }
    #expect(await store.load(handle: discardAllHandle) == nil)
    #expect(try fixture.fileURL(lifecycle: 1, operation: 2).checkResourceIsReachable())
    try await store.discardAll(namespace: discardAllHandle.namespace)
    #expect((try? fixture.fileURL(lifecycle: 1, operation: 2).checkResourceIsReachable()) != true)

    failures.failNextMetadataUpdate()
    failures.failNextRemoval()
    await #expect(throws: InjectedRemovalError.failed) {
        try await store.store(Data([3]), handle: cleanupHandle)
    }
    #expect(await store.load(handle: cleanupHandle) == nil)
    #expect(try fixture.fileURL(lifecycle: 1, operation: 3).checkResourceIsReachable())
    try await store.cleanup()
    #expect(!fixture.ownedDirectoryExists)
}

private struct FixedFilenameStrategy: ProtectedTemporarySessionFilenameStrategy {
    let value: String
    init(_ value: String) { self.value = value }
    func filename(lifecycleGeneration: UInt64, operationVersion: UInt64) -> String { value }
}

private enum InjectedRemovalError: Error {
    case failed
}

private final class RemovalFailureController: @unchecked Sendable {
    private let failureLock = NSLock()
    private var shouldFailNextRemoval = false
    private var shouldFailNextMetadataUpdate = false

    func failNextRemoval() {
        failureLock.lock()
        shouldFailNextRemoval = true
        failureLock.unlock()
    }

    func failNextMetadataUpdate() {
        failureLock.lock()
        shouldFailNextMetadataUpdate = true
        failureLock.unlock()
    }

    func interceptRemoval(at _: URL) throws {
        failureLock.lock()
        let shouldFail = shouldFailNextRemoval
        shouldFailNextRemoval = false
        failureLock.unlock()
        if shouldFail { throw InjectedRemovalError.failed }
    }

    func interceptMetadataUpdate(at _: URL) throws {
        failureLock.lock()
        let shouldFail = shouldFailNextMetadataUpdate
        shouldFailNextMetadataUpdate = false
        failureLock.unlock()
        if shouldFail { throw InjectedMetadataError.failed }
    }
}

private enum InjectedMetadataError: Error {
    case failed
}

private final class TemporaryStoreFixture {
    private let fileManager = FileManager.default
    private let removalFailures: RemovalFailureController?
    let containerURL: URL
    private let callerMarkerURL: URL

    init(removalFailures: RemovalFailureController? = nil) throws {
        self.removalFailures = removalFailures
        containerURL = self.fileManager.temporaryDirectory.appendingPathComponent("team-d-protected-store-test-\(UUID().uuidString)", isDirectory: true)
        try self.fileManager.createDirectory(at: containerURL, withIntermediateDirectories: false)
        callerMarkerURL = containerURL.appendingPathComponent("caller-owned-marker")
        try Data([0]).write(to: callerMarkerURL)
    }

    deinit { try? FileManager.default.removeItem(at: containerURL) }

    var ownedDirectoryURL: URL {
        containerURL.appendingPathComponent(ProtectedTemporarySessionImageBackingStore.ownedDirectoryName, isDirectory: true)
    }

    var ownedDirectoryExists: Bool { fileManager.fileExists(atPath: ownedDirectoryURL.path) }
    var callerMarkerExists: Bool { fileManager.fileExists(atPath: callerMarkerURL.path) }

    func makeStore(filenameStrategy: any ProtectedTemporarySessionFilenameStrategy = NumericSessionImageFilenameStrategy()) throws -> ProtectedTemporarySessionImageBackingStore {
        if let removalFailures {
            return try ProtectedTemporarySessionImageBackingStore(
                temporaryContainerURL: containerURL,
                filenameStrategy: filenameStrategy,
                postWriteMetadataInterceptor: removalFailures.interceptMetadataUpdate(at:),
                deletionInterceptor: removalFailures.interceptRemoval(at:)
            )
        }
        return try ProtectedTemporarySessionImageBackingStore(
            temporaryContainerURL: containerURL,
            filenameStrategy: filenameStrategy
        )
    }

    func createOrphanedOwnedFile() throws {
        try fileManager.createDirectory(at: ownedDirectoryURL, withIntermediateDirectories: false)
        try Data([9]).write(to: ownedDirectoryURL.appendingPathComponent("orphan.bin"))
    }

    func ownedContents() -> [URL] {
        (try? fileManager.contentsOfDirectory(at: ownedDirectoryURL, includingPropertiesForKeys: nil))?.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    func fileURL(lifecycle: UInt64, operation: UInt64) -> URL {
        ownedDirectoryURL.appendingPathComponent("artifact-l\(lifecycle)-o\(operation).bin")
    }

    func handle(session: String, lifecycle: UInt64, request: String, image: String, version: UInt64) throws -> SessionImageHandle {
        let namespace = SessionStorageNamespace(sessionID: try SessionID(session), lifecycleGeneration: lifecycle)
        let token = SessionOperationToken(namespace: namespace, requestID: try RequestID(request), scope: .capture(.front), version: version)
        return SessionImageHandle(imageID: try ImageID(image), token: token)
    }
}
