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

    /// Slowest speed (m/s) at which a fix counts as walking for `RouteMemory`.
    public static let routeMinSpeed = 0.5
    /// Worst horizontal accuracy (metres) a fix may have to go into `RouteMemory`.
    public static let routeMaxAccuracy = 20.0

    /// True for a fix that may go into `RouteMemory`: moving (speed at least `routeMinSpeed`; CoreLocation's unknown −1
    /// is not) and accurate (0…`routeMaxAccuracy`), so GPS jitter while standing still makes no path, bearing or lookup.
    public static func isRouteFix(speed: Double, accuracy: Double) -> Bool {
        speed.isFinite && speed >= routeMinSpeed && accuracy.isFinite && accuracy >= 0 && accuracy <= routeMaxAccuracy
    }
}
