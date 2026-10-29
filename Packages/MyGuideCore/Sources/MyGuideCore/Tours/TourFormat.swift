import Foundation

/// The numbers of a tour preview in words (tours spec 6): «1 t 25 min · 5,2 km · 6 stopp», in the language given (the
/// screen's, `UILanguage.current`).
public enum TourFormat {
    /// Longer durations are shown as this many seconds (≈ 115 days), so no value can trap the `Int` conversion.
    private static let maxSeconds = 1e7
    /// Longer distances are shown as this many metres (10 000 km), for the same reason.
    private static let maxMetres = 1e7

    /// Whole minutes, rounded to the nearest: «45 min», «1 t», «1 t 25 min» («h» in English). A positive time under
    /// half a minute shows «1 min», so a real leg never reads as nothing; zero, negative or not finite → «0 min».
    public static func duration(_ seconds: Double, language: StoryLanguage) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 min" }
        let minutes = max(1, Int((min(seconds, maxSeconds) / 60).rounded()))
        guard minutes >= 60 else { return "\(minutes) min" }
        let hour = language == .norwegian ? "t" : "h"
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) \(hour)" : "\(hours) \(hour) \(rest) min"
    }

    /// Under a kilometre in metres rounded to the nearest 10 («850 m»); from there in kilometres with one decimal,
    /// a decimal comma in Norwegian («5,2 km») and a point in English («5.2 km»). Zero, negative or not finite → «0 m».
    public static func distance(_ metres: Double, language: StoryLanguage) -> String {
        guard metres.isFinite, metres > 0 else { return "0 m" }
        let metres = min(metres, maxMetres)
        let tens = Int((metres / 10).rounded()) * 10
        guard tens >= 1000 else { return "\(tens) m" }
        let tenths = Int((metres / 100).rounded())
        let separator = language == .norwegian ? "," : "."
        return "\(tenths / 10)\(separator)\(tenths % 10) km"
    }

    /// «1 stopp», «6 stopp»; «1 stop», «6 stops». A negative count counts as 0.
    public static func stops(_ count: Int, language: StoryLanguage) -> String {
        let count = max(0, count)
        switch language {
        case .norwegian: return "\(count) stopp"
        case .english: return count == 1 ? "1 stop" : "\(count) stops"
        }
    }

    /// «1 t 25 min · 5,2 km · 6 stopp».
    public static func totals(seconds: Double, metres: Double, stops count: Int, language: StoryLanguage) -> String {
        "\(duration(seconds, language: language)) · \(distance(metres, language: language)) · \(stops(count, language: language))"
    }
}
