import DomainKit
import ContractKit

/// The transport lifecycle is deliberately independent of the capture workflow.
/// Changing this value cannot accept a slot, select a capture phase, or approve a
/// measurement.
public enum GuidanceConnectionState: CaseIterable, Equatable, Sendable {
    case connecting
    case connected
    case reconnecting
    case disconnected
}

/// Injected so expiry decisions are deterministic in fixture and live compositions.
public protocol GuidanceEpochMillisecondsClock: Sendable {
    func nowEpochMilliseconds() -> Int64
}

/// The only guidance data admitted to presentation. Wire message, confidence, and
/// any future backend action fields are intentionally absent from this value.
public struct GuidanceDisplayInput: Equatable, Sendable {
    public let code: GuidanceCode

    public init(code: GuidanceCode) {
        self.code = code
    }
}

public enum GuidanceFilterRejectionReason: CaseIterable, Equatable, Sendable {
    case sessionMismatch
    case shotMismatch
    case connectionUnavailable
    case sequenceNotNew
    case expired
    case invalidClock
    case clockMovedBackward
}

public enum GuidanceFilterStateError: Error, Equatable, Sendable {
    case invalidSessionIdentifier
    case sessionAlreadyCurrent
}

public enum GuidanceFilterResult: Equatable, Sendable {
    case accepted(GuidanceDisplayInput)
    case rejected(GuidanceFilterRejectionReason)
}

/// Session-scoped, value-semantic reducer state for LiveKit Guidance packets.
/// The wire sequence is monotonic for the entire session, while the per-shot map
/// records the last accepted packet for reconnect synchronization. Both are
/// retained across shot switches and connection changes; only `startNewSession`
/// resets them.
public struct GuidanceFilterState: Equatable, Sendable {
    public private(set) var connection: GuidanceConnectionState
    public private(set) var currentSessionId: String
    public private(set) var currentShot: Shot
    public private(set) var lastAcceptedSequence: Int64?
    public private(set) var lastAcceptedSequenceByShot: [Shot: Int64]
    public private(set) var lastAcceptedClockMilliseconds: Int64?
    public private(set) var latestGuidance: GuidanceDisplayInput?

    public init(
        sessionId: String,
        currentShot: Shot,
        connection: GuidanceConnectionState = .connecting
    ) throws {
        guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GuidanceFilterStateError.invalidSessionIdentifier
        }
        self.connection = connection
        currentSessionId = sessionId
        self.currentShot = currentShot
        lastAcceptedSequence = nil
        lastAcceptedSequenceByShot = [:]
        lastAcceptedClockMilliseconds = nil
        latestGuidance = nil
    }

    /// Connection transitions are intentionally the only mutation performed here.
    public mutating func transitionConnection(to state: GuidanceConnectionState) {
        connection = state
    }

    /// Capture workflow ownership selects a shot explicitly. Watermarks remain so
    /// switching shots cannot replay an older session packet, while presentation
    /// guidance is cleared because it belongs to the previous shot.
    public mutating func setCurrentShot(_ shot: Shot) {
        guard shot != currentShot else { return }
        currentShot = shot
        latestGuidance = nil
    }

    /// A session start is the sole sequence-reset boundary.
    public mutating func startNewSession(id sessionId: String, currentShot: Shot) throws {
        guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GuidanceFilterStateError.invalidSessionIdentifier
        }
        guard sessionId != currentSessionId else {
            throw GuidanceFilterStateError.sessionAlreadyCurrent
        }
        currentSessionId = sessionId
        self.currentShot = currentShot
        lastAcceptedSequence = nil
        lastAcceptedSequenceByShot = [:]
        lastAcceptedClockMilliseconds = nil
        latestGuidance = nil
        connection = .connecting
    }

    /// Reduces one already strict-decoded wire packet. Accepted packets produce a
    /// finite display code only; they never produce a workflow/navigation event.
    public mutating func reduce(
        _ event: GuidanceEvent,
        clock: any GuidanceEpochMillisecondsClock
    ) -> GuidanceFilterResult {
        guard event.sessionId == currentSessionId else { return .rejected(.sessionMismatch) }
        guard event.shot == currentShot else { return .rejected(.shotMismatch) }
        guard connection == .connected else { return .rejected(.connectionUnavailable) }
        guard event.sequence > (lastAcceptedSequence ?? 0) else {
            return .rejected(.sequenceNotNew)
        }
        let now = clock.nowEpochMilliseconds()
        guard now >= 0 else { return .rejected(.invalidClock) }
        if let lastAcceptedClockMilliseconds, now < lastAcceptedClockMilliseconds {
            return .rejected(.clockMovedBackward)
        }
        // GuidanceEvent has already guaranteed non-negative timestamps and
        // expiresAt > observedAt, so this comparison has no overflow path.
        guard now < event.expiresAt else { return .rejected(.expired) }

        lastAcceptedSequence = event.sequence
        lastAcceptedSequenceByShot[event.shot] = event.sequence
        lastAcceptedClockMilliseconds = now
        let displayInput = GuidanceDisplayInput(code: event.code)
        latestGuidance = displayInput
        return .accepted(displayInput)
    }
}
