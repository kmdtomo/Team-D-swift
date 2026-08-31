import DomainKit

/// An injected clock keeps guidance settling deterministic in fixture and live
/// compositions. It is deliberately separate from the transport expiry clock.
public protocol CaptureCoachPresentationClock: Sendable {
    func nowMilliseconds() -> Int64
}

public enum CaptureCoachPresentationError: Error, Equatable, Sendable {
    case invalidHysteresis
    case clockMovedBackward
}

/// Timing policy for the one stable instruction shown above the shutter.
/// `readyEnterMilliseconds` is clamped to the product's 600ms minimum so a
/// caller cannot accidentally surface READY from a shorter observation.
public struct CaptureCoachPresentationConfiguration: Equatable, Sendable {
    public let enterMilliseconds: Int64
    public let clearMilliseconds: Int64
    public let readyEnterMilliseconds: Int64

    public init(
        enterMilliseconds: Int64 = 180,
        clearMilliseconds: Int64 = 360,
        readyEnterMilliseconds: Int64 = 600
    ) throws {
        guard enterMilliseconds >= 0, clearMilliseconds >= 0, readyEnterMilliseconds >= 0 else {
            throw CaptureCoachPresentationError.invalidHysteresis
        }
        self.enterMilliseconds = enterMilliseconds
        self.clearMilliseconds = clearMilliseconds
        self.readyEnterMilliseconds = max(600, readyEnterMilliseconds)
    }

    public static let `default` = try! CaptureCoachPresentationConfiguration()
}

/// App-owned Japanese copy. Agent message and confidence never enter this type.
public enum CaptureCoachInstruction: String, CaseIterable, Equatable, Sendable {
    case moveCloser
    case moveFarther
    case centerGarment
    case showFullGarment
    case wrongSide
    case moveToTag
    case placeMarker
    case markerNotVisible
    case flattenGarment
    case cameraOverhead
    case holdSteady
    case ready
    case tooDark
    case tooBright
    case tooBlurry

    public var localizedText: String {
        switch self {
        case .moveCloser: "もう少し近づけてください"
        case .moveFarther: "少し離してください"
        case .centerGarment: "衣類を中央に置いてください"
        case .showFullGarment: "衣類全体を写してください"
        case .wrongSide: "指定した面を上にしてください"
        case .moveToTag: "タグに移動してください"
        case .placeMarker: "右下に50mmマーカーを置いてください"
        case .markerNotVisible: "50mmマーカー全体を写してください"
        case .flattenGarment: "しわを伸ばしてください"
        case .cameraOverhead: "真上から撮影してください"
        case .holdSteady: "動かさずに待ってください"
        case .ready: "そのまま撮影できます"
        case .tooDark: "明るい場所に移してください"
        case .tooBright: "明るさを少し抑えてください"
        case .tooBlurry: "ピントが合うまで動かさずに待ってください"
        }
    }

    fileprivate var priority: Int {
        switch self {
        case .wrongSide, .moveToTag, .placeMarker, .markerNotVisible: 0
        case .showFullGarment: 1
        case .moveCloser, .moveFarther, .centerGarment: 2
        case .cameraOverhead, .flattenGarment: 3
        case .tooDark, .tooBright, .tooBlurry: 4
        case .holdSteady: 5
        case .ready: 6
        }
    }

    fileprivate static func from(agent code: GuidanceCode) -> Self? {
        switch code {
        case .moveCloser: .moveCloser
        case .moveFarther: .moveFarther
        case .centerGarment: .centerGarment
        case .showFullGarment: .showFullGarment
        case .wrongSide: .wrongSide
        case .moveToTag: .moveToTag
        case .placeMarker: .placeMarker
        case .markerNotVisible: .markerNotVisible
        case .flattenGarment: .flattenGarment
        case .cameraOverhead: .cameraOverhead
        case .holdSteady: .holdSteady
        case .ready: .ready
        // Availability is communicated by the orthogonal connection status.
        case .agentUnavailable: nil
        }
    }

    fileprivate static func from(local hint: LocalQualityHint) -> Self? {
        switch hint {
        case .tooDark: .tooDark
        case .tooBright: .tooBright
        case .tooBlurry: .tooBlurry
        case .holdSteady: .holdSteady
        case .ready: .ready
        // A local analyzer failure must not masquerade as quality guidance.
        case .analyzerUnavailable: nil
        }
    }
}

public struct CaptureCoachInput: Equatable, Sendable {
    public let shot: Shot
    public let acceptedShots: Set<Shot>
    public let agentGuidance: GuidanceDisplayInput?
    public let localQualityHint: LocalQualityHint?
    public let connection: GuidanceConnectionState
    public let isCameraTechnicallyAvailable: Bool
    public let isCaptureInFlight: Bool
    public let isRetake: Bool

    public init(
        shot: Shot,
        acceptedShots: Set<Shot> = [],
        agentGuidance: GuidanceDisplayInput? = nil,
        localQualityHint: LocalQualityHint? = nil,
        connection: GuidanceConnectionState,
        isCameraTechnicallyAvailable: Bool,
        isCaptureInFlight: Bool,
        isRetake: Bool = false
    ) {
        self.shot = shot
        self.acceptedShots = acceptedShots
        self.agentGuidance = agentGuidance
        self.localQualityHint = localQualityHint
        self.connection = connection
        self.isCameraTechnicallyAvailable = isCameraTechnicallyAvailable
        self.isCaptureInFlight = isCaptureInFlight
        self.isRetake = isRetake
    }
}

public struct CaptureCoachViewState: Equatable, Sendable {
    public let shot: Shot
    public let progressText: String
    public let completedProgressText: String
    public let shotText: String
    public let instruction: CaptureCoachInstruction?
    public let connectionText: String
    public let isShutterEnabled: Bool
    public let isBusy: Bool
    public let isRetake: Bool
    /// Changes only after the primary instruction has settled, avoiding noisy
    /// VoiceOver announcements for raw frames or packets.
    public let announcementID: UInt64

    public init(input: CaptureCoachInput, instruction: CaptureCoachInstruction?, announcementID: UInt64) {
        shot = input.shot
        let index = (Shot.allCases.firstIndex(of: input.shot) ?? 0) + 1
        progressText = "\(index)/4"
        completedProgressText = "完了 \(input.acceptedShots.count)/4"
        shotText = Self.localizedShot(input.shot)
        self.instruction = instruction
        connectionText = Self.localizedConnection(input.connection)
        isShutterEnabled = input.isCameraTechnicallyAvailable && !input.isCaptureInFlight
        isBusy = input.isCaptureInFlight
        isRetake = input.isRetake
        self.announcementID = announcementID
    }

    private static func localizedShot(_ shot: Shot) -> String {
        switch shot {
        case .front: "正面"
        case .back: "背面"
        case .tag: "タグ"
        case .measurement: "採寸"
        }
    }

    private static func localizedConnection(_ state: GuidanceConnectionState) -> String {
        switch state {
        case .connecting: "助言に接続中"
        case .connected: "助言に接続済み"
        case .reconnecting: "助言を再接続中"
        case .disconnected: "助言は接続されていません。端末の確認と撮影は続けられます"
        }
    }
}

/// Selects and settles app-owned guidance. It owns no workflow transition,
/// capture action, or connection mutation.
public struct CaptureCoachPresentation: Sendable {
    private let configuration: CaptureCoachPresentationConfiguration
    private var activeInstruction: CaptureCoachInstruction?
    private var candidateInstruction: CaptureCoachInstruction?
    private var candidateStartedAt: Int64?
    private var lastClockMilliseconds: Int64?
    private var announcementID: UInt64

    public init(configuration: CaptureCoachPresentationConfiguration = .default) {
        self.configuration = configuration
        activeInstruction = nil
        candidateInstruction = nil
        candidateStartedAt = nil
        lastClockMilliseconds = nil
        announcementID = 0
    }

    public mutating func reduce(
        _ input: CaptureCoachInput,
        clock: any CaptureCoachPresentationClock
    ) throws -> CaptureCoachViewState {
        let now = clock.nowMilliseconds()
        guard now >= 0, now >= (lastClockMilliseconds ?? 0) else {
            throw CaptureCoachPresentationError.clockMovedBackward
        }
        lastClockMilliseconds = now
        let desired = Self.select(agent: input.agentGuidance?.code, local: input.localQualityHint)
        settle(desired, at: now)
        return CaptureCoachViewState(input: input, instruction: activeInstruction, announcementID: announcementID)
    }

    public static func select(agent: GuidanceCode?, local: LocalQualityHint?) -> CaptureCoachInstruction? {
        let candidates = [agent.flatMap(CaptureCoachInstruction.from(agent:)), local.flatMap(CaptureCoachInstruction.from(local:))]
        return candidates.compactMap { $0 }.min { lhs, rhs in lhs.priority < rhs.priority }
    }

    private mutating func settle(_ desired: CaptureCoachInstruction?, at now: Int64) {
        guard desired != activeInstruction else {
            candidateInstruction = nil
            candidateStartedAt = nil
            return
        }
        if candidateInstruction != desired {
            candidateInstruction = desired
            candidateStartedAt = now
        }
        let elapsed = now - (candidateStartedAt ?? now)
        let required: Int64
        if desired == nil {
            required = configuration.clearMilliseconds
        } else if desired == .ready {
            required = configuration.readyEnterMilliseconds
        } else {
            required = configuration.enterMilliseconds
        }
        guard elapsed >= required else { return }
        activeInstruction = desired
        candidateInstruction = nil
        candidateStartedAt = nil
        announcementID &+= 1
    }
}
