import Foundation

/// When a new trip starts (design 7.7): the app is used in a different city than the current trip, or after
/// 3 or more days without use.
public enum TripRule {
    /// 3 days without use: 3 · 24 · 3600 s.
    public static let idleGap: TimeInterval = 259_200

    /// True when `now` begins a new trip. There is no trip yet when `lastUsedAt` is nil. An unknown city on either
    /// side never splits a trip; cities compare without regard to case, diacritics or surrounding space.
    /// A clock that went backwards (`now` before `lastUsedAt`) is not a gap.
    public static func startsNewTrip(lastUsedAt: Date?, tripCity: String?, now: Date, city: String?) -> Bool {
        guard let lastUsedAt else { return true }
        if now.timeIntervalSince(lastUsedAt) >= idleGap { return true }
        guard let tripCity = normalisedCity(tripCity), let city = normalisedCity(city) else { return false }
        return tripCity.compare(city, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
    }

    /// The city trimmed of surrounding whitespace; nil when nothing is left.
    static func normalisedCity(_ city: String?) -> String? {
        guard let trimmed = city?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
