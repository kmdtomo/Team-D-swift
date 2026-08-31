import Foundation

/// Shared domain boundary. Wire decoding belongs to ContractKit.
public enum DomainKitModule {}

/// Build-selected execution mode. A live composition must never substitute
/// fixture composition after an error.
public enum CameraFlowMode: Equatable, Sendable {
    case fixture
    case live
}

public enum CameraAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

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

public struct InMemorySessionImageStore: SessionImageStoring {
    public init() {}
    public func discardSessionContents() {}
}
