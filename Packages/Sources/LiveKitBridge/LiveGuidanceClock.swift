import Foundation

/// Epoch clock adapter used only at the injected live-guidance boundary.
/// Deterministic tests supply their own closure; production uses `Date` without
/// exposing wall-clock reads inside the connection state machine.
public struct SystemGuidanceEpochMillisecondsClock: GuidanceEpochMillisecondsClock {
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func nowEpochMilliseconds() -> Int64 {
        let milliseconds = now().timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds < Double(Int64.max)
        else { return -1 }
        return Int64(milliseconds.rounded(.down))
    }
}
