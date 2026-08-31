import Foundation

/// Shared domain boundary. Product domain types begin in T03-01.
public enum DomainKitModule {}

/// Build-selected execution mode. A live composition must never substitute the
/// fixture composition after an error.
public enum CameraFlowMode: Equatable, Sendable {
    case fixture
    case live
}

/// The app-owned representation of the four camera authorization outcomes.
/// This intentionally does not expose AVFoundation to camera-flow UI or tests.
public enum CameraAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

/// The only legal cold-launch destinations for the camera-first session.
/// Later workflow states belong to the capture state machine, not this root.
public enum CameraFlowEntryRoute: Equatable, Sendable {
    case captureFront
    case requestPermission
    case permissionDenied
    case permissionRestricted
}

public enum CameraFlowEntry {
    public static func route(for status: CameraAuthorizationStatus) -> CameraFlowEntryRoute {
        switch status {
        case .authorized: .captureFront
        case .notDetermined: .requestPermission
        case .denied: .permissionDenied
        case .restricted: .permissionRestricted
        }
    }
}

public protocol CameraAuthorizationProviding: Sendable {
    func authorizationStatus() -> CameraAuthorizationStatus
    func requestAuthorization() async -> CameraAuthorizationStatus
}

public protocol SessionClock: Sendable {
    func now() -> Date
}

public protocol SessionIdentifierProviding: Sendable {
    func makeSessionIdentifier() -> UUID
}

/// The image store is intentionally session-scoped. Its image operations are
/// introduced with the capture state/store task, rather than persisted here.
public protocol SessionImageStoring: Sendable {
    func discardSessionContents()
}

public struct CameraFlowDependencies: Sendable {
    public let mode: CameraFlowMode
    public let cameraAuthorization: any CameraAuthorizationProviding
    public let clock: any SessionClock
    public let sessionIdentifiers: any SessionIdentifierProviding
    public let imageStore: any SessionImageStoring

    public init(
        mode: CameraFlowMode,
        cameraAuthorization: any CameraAuthorizationProviding,
        clock: any SessionClock,
        sessionIdentifiers: any SessionIdentifierProviding,
        imageStore: any SessionImageStoring
    ) {
        self.mode = mode
        self.cameraAuthorization = cameraAuthorization
        self.clock = clock
        self.sessionIdentifiers = sessionIdentifiers
        self.imageStore = imageStore
    }
}

/// Root composition owns mode selection. Feature views receive only this
/// dependency container and never inspect process environment or global state.
public enum CameraFlowComposition {
    public static func fixture(
        cameraAuthorization: any CameraAuthorizationProviding = FixtureCameraAuthorizationProvider(),
        clock: any SessionClock = SystemClock(),
        sessionIdentifiers: any SessionIdentifierProviding = SystemSessionIdentifierProvider(),
        imageStore: any SessionImageStoring = InMemorySessionImageStore()
    ) -> CameraFlowDependencies {
        CameraFlowDependencies(
            mode: .fixture,
            cameraAuthorization: cameraAuthorization,
            clock: clock,
            sessionIdentifiers: sessionIdentifiers,
            imageStore: imageStore
        )
    }

    public static func live(
        cameraAuthorization: any CameraAuthorizationProviding,
        clock: any SessionClock = SystemClock(),
        sessionIdentifiers: any SessionIdentifierProviding = SystemSessionIdentifierProvider(),
        imageStore: any SessionImageStoring = InMemorySessionImageStore()
    ) -> CameraFlowDependencies {
        CameraFlowDependencies(
            mode: .live,
            cameraAuthorization: cameraAuthorization,
            clock: clock,
            sessionIdentifiers: sessionIdentifiers,
            imageStore: imageStore
        )
    }
}

public struct FixtureCameraAuthorizationProvider: CameraAuthorizationProviding {
    public init() {}

    public func authorizationStatus() -> CameraAuthorizationStatus { .authorized }
    public func requestAuthorization() async -> CameraAuthorizationStatus { .authorized }
}

public struct SystemClock: SessionClock {
    public init() {}
    public func now() -> Date { Date() }
}

public struct SystemSessionIdentifierProvider: SessionIdentifierProviding {
    public init() {}
    public func makeSessionIdentifier() -> UUID { UUID() }
}

/// A value type avoids Objective-C runtime class duplication between the app
/// bundle and XCTest's package product framework.
public struct InMemorySessionImageStore: SessionImageStoring {
    public init() {}
    public func discardSessionContents() {}
}
