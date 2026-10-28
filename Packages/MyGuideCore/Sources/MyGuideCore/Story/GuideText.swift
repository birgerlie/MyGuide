import Foundation

/// Small pure helpers for the guide-voice prompt lines.
public enum GuideText {
    /// The order `osmFacts` prints.
    public static let factTagKeys: [String] = [
        "start_date", "architect", "building:architecture", "artist_name", "inscription", "description",
        "name:etymology", "memorial:type", "material", "heritage", "heritage:operator",
    ]

    /// Removes every whitespace-separated token containing a digit: "Kirkegata 15" → "Kirkegata", "15 Main St" → "Main St".
    /// nil when nothing is left.
    public static func streetName(fromAddressLine line: String?) -> String? {
        guard let line else { return nil }
        let kept = line.split(whereSeparator: \.isWhitespace).filter { token in
            !token.contains { $0.isNumber }
        }
        return kept.isEmpty ? nil : kept.joined(separator: " ")
    }

    /// Side of `bearing` relative to `direction` (compass degrees). nil or unusable direction → compass word.
    public static func side(bearing: Double, direction: Double?) -> String {
        guard let direction, direction.isFinite, direction >= 0, bearing.isFinite else {
            return FieldOfView.compassPoint(bearing.isFinite ? bearing : 0)
        }
        // r = bearing − direction, normalised into (−180, 180].
        var r = (bearing - direction).truncatingRemainder(dividingBy: 360)
        if r > 180 { r -= 360 }
        if r <= -180 { r += 360 }
        let magnitude = abs(r)
        let right = r > 0
        switch magnitude {
        case ...30: return "ahead"
        case ...60: return right ? "ahead-right" : "ahead-left"
        case ...120: return right ? "to your right" : "to your left"
        case ...150: return right ? "behind-right" : "behind-left"
        default: return "behind"
        }
    }

    /// "40 m, to your right" — distance via `BuzzText.roundedDistance`.
    public static func distanceAndSide(distance: Double, bearing: Double, direction: Double?) -> String {
        "\(BuzzText.roundedDistance(distance)) m, \(side(bearing: bearing, direction: direction))"
    }

    /// "12:40 Wednesday" in `timeZone`, 24-hour, English weekday.
    public static func time(_ date: Date, timeZone: TimeZone) -> String {
        format(date, "HH:mm EEEE", timeZone)
    }

    /// "HH:mm" in `timeZone`.
    public static func clock(_ date: Date, timeZone: TimeZone) -> String {
        format(date, "HH:mm", timeZone)
    }

    /// "OSM: start_date=1697; architect=…" from the fact keys present, nil when none. Values are collapsed to one line and, over 200 characters, cut.
    public static func osmFacts(_ tags: [String: String]?) -> String? {
        guard let tags else { return nil }
        let parts = factTagKeys.compactMap { key -> String? in
            // OSM values are untrusted and may span lines; keep each place's facts on one line.
            guard let raw = tags[key] else { return nil }
            let value = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !value.isEmpty else { return nil }
            return "\(key)=\(TextTrim.truncate(value, maxCharacters: 200))"
        }
        return parts.isEmpty ? nil : "OSM: " + parts.joined(separator: "; ")
    }

    private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }
}
