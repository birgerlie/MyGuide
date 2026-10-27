import Foundation

/// Which location fixes walking mode uses. CoreLocation hands out its cached last position first, which can be
/// minutes old; and a fix worse than 50 m cannot tell which place is near.
public enum WalkingFix {
    /// Fixes older than this (seconds) are ignored for buzzes, the track and the status line.
    public static let maxAge: TimeInterval = 15

    /// True unless the fix is more than `maxAge` old. A timestamp ahead of `now` (clock skew) counts as fresh.
    public static func isFresh(_ timestamp: Date, now: Date) -> Bool {
        now.timeIntervalSince(timestamp) <= maxAge
    }

    /// True for an accuracy the buzz engine can use: finite, not negative (CoreLocation's "invalid"), at most 50 m.
    public static func isUsable(accuracy: Double) -> Bool {
        accuracy.isFinite && accuracy >= 0 && accuracy <= BuzzEngine.maxFixAccuracy
    }
}
