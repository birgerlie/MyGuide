import Foundation

public enum AutoOffReason: Sendable, Equatable { case timeLimit, lowBattery, pausedTooLong }

/// When walking mode turns itself off: after four hours of active time, an hour paused, or a low battery.
public enum AutoOff {
    public static let maxDuration: TimeInterval = 14_400
    public static let minBattery: Float = 0.15

    public static let maxPause: TimeInterval = 3_600

    /// `activeTime` excludes pauses (see `activeTime(startedAt:now:pausedTotal:pausedSince:)`); `pausedFor` is the
    /// length of the current pause, nil when walking. `batteryLevel` is `UIDevice.batteryLevel`: 0…1, or a negative
    /// number when unknown (never a reason). Order: time limit, paused too long, battery.
    public static func reason(activeTime: TimeInterval, pausedFor: TimeInterval?, batteryLevel: Float) -> AutoOffReason? {
        if activeTime >= maxDuration { return .timeLimit }
        if let pausedFor, pausedFor >= maxPause { return .pausedTooLong }
        if batteryLevel >= 0, batteryLevel < minBattery { return .lowBattery }
        return nil
    }

    /// Time since the start minus finished pauses (`pausedTotal`) minus the pause in progress up to `now`. Never below 0.
    public static func activeTime(startedAt: Date, now: Date, pausedTotal: TimeInterval, pausedSince: Date?) -> TimeInterval {
        let current = pausedSince.map { now.timeIntervalSince($0) } ?? 0
        return max(0, now.timeIntervalSince(startedAt) - pausedTotal - current)
    }

    public static func message(_ reason: AutoOffReason) -> String {
        switch reason {
        case .timeLimit: "Walking mode turned off after 4 hours."
        case .lowBattery: "Walking mode turned off: battery below 15%."
        case .pausedTooLong: "Walking mode turned off after an hour without walking."
        }
    }

    /// `message` in the story language: the auto-off notification follows it (spec 7.1).
    public static func message(_ reason: AutoOffReason, language: StoryLanguage) -> String {
        guard language == .norwegian else { return message(reason) }
        switch reason {
        case .timeLimit: return "Gåmodus slo seg av etter 4 timer."
        case .lowBattery: return "Gåmodus slo seg av: batteriet er under 15 %."
        case .pausedTooLong: return "Gåmodus slo seg av etter en time uten at du gikk."
        }
    }
}
