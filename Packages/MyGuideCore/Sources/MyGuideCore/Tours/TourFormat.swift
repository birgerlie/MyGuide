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
        return kilometres(metres, language: language)
    }

    /// Kilometres with one decimal, rounded to the nearest tenth: «5,2 km» / «5.2 km». `metres` is finite and capped.
    private static func kilometres(_ metres: Double, language: StoryLanguage) -> String {
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
    // MARK: - During a tour (tours spec 6)

    /// The distance to the next stop, coarser than `distance` so the line does not change with every few steps: under
    /// a kilometre in steps of 50 m («300 m»), at least «50 m» for a positive distance; from there in kilometres with
    /// one decimal («1,5 km»). Zero, negative or not finite → «0 m».
    public static func approachDistance(_ metres: Double, language: StoryLanguage) -> String {
        guard let step = approachStep(metres) else { return "0 m" }
        let fifties = step * 50
        guard fifties >= 1000 else { return "\(fifties) m" }
        return kilometres(min(metres, maxMetres), language: language)
    }

    /// The 50 m step `approachDistance` rounds to (at least 1; capped like `distance`); nil for zero, negative or not
    /// finite. The watch's line changes only when this step does (`TourDistanceSteps`).
    public static func approachStep(_ metres: Double) -> Int? {
        guard metres.isFinite, metres > 0 else { return nil }
        return max(1, Int((min(metres, maxMetres) / 50).rounded()))
    }

    /// «Neste: Pantheon · 300 m», or «Neste: Pantheon» without a distance (no position yet).
    public static func nextStop(_ name: String, metres: Double?, language: StoryLanguage) -> String {
        let label = language == .norwegian ? "Neste" : "Next"
        guard let metres else { return "\(label): \(name)" }
        return "\(label): \(name) · \(approachDistance(metres, language: language))"
    }

    /// «2 av 6» / «2 of 6»: stops done of all. Negative counts count as 0.
    public static func progress(done: Int, total: Int, language: StoryLanguage) -> String {
        "\(max(0, done)) \(language == .norwegian ? "av" : "of") \(max(0, total))"
    }

    /// «Turen er ferdig · 6 stopp · 1 t 31 min», the walking time without pauses. With no stop visited it says so
    /// rather than calling the tour done: «Turen er avsluttet · ingen stopp besøkt · 25 min».
    public static func finished(stops count: Int, seconds: Double, language: StoryLanguage) -> String {
        let time = duration(seconds, language: language)
        guard count > 0 else {
            return language == .norwegian ? "Turen er avsluttet · ingen stopp besøkt · \(time)"
                                          : "Tour ended · no stops visited · \(time)"
        }
        let head = language == .norwegian ? "Turen er ferdig" : "Tour finished"
        return "\(head) · \(stops(count, language: language)) · \(time)"
    }
}
