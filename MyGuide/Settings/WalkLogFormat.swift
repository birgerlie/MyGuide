import Foundation
import MyGuideCore

/// Text for the walk log screens: local time of day, distance and duration.
enum WalkLogFormat {
    static func time(_ date: Date, seconds: Bool = false) -> String {
        if seconds {
            return date.formatted(.verbatim("\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
                                            locale: .current, timeZone: .current, calendar: .current))
        }
        return date.formatted(.verbatim("\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                                        locale: .current, timeZone: .current, calendar: .current))
    }

    /// Metres under 1 000 ("640 m"), else "1.3 km".
    static func distance(_ metres: Double) -> String {
        guard metres.isFinite, metres > 0 else { return "0 m" }
        if metres < 1000 { return "\(Int(metres.rounded())) m" }
        return String(format: "%.1f km", metres / 1000)
    }

    /// "45 s", "12 min" or "1 h 05 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded())
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }

    static func stopReason(_ reason: WalkStopReason, _ language: StoryLanguage) -> String {
        SettingsTexts.stopReason(reason, language)
    }

    /// The timeline text of an event; a stop reason reads as words in `language` instead of its raw value. Every
    /// other event is the log's own line (data).
    static func timelineText(_ kind: WalkLogEvent.Kind, _ language: StoryLanguage) -> String {
        if case .stopped(let reason, let source) = kind {
            return stopReason(reason, language) + (source.map { " (\($0.rawValue))" } ?? "")
        }
        return WalkLogText.line(kind)
    }
}
