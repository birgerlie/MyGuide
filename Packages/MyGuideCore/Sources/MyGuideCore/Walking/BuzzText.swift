import Foundation

/// The one-line "where is it" text shown with a buzz.
public enum BuzzText {
    /// Metres rounded to the nearest 10 (halves away from zero), never below 10.
    public static func roundedDistance(_ metres: Double) -> Int {
        guard metres.isFinite else { return 10 }
        // Clamp before converting so a huge value cannot trap in Int(_:).
        let tens = (min(metres, 1_000_000) / 10).rounded(.toNearestOrAwayFromZero)
        return max(10, Int(tens) * 10)
    }

    /// "50 m ahead", "50 m right", "50 m left", "90 m behind you", or "50 m away" when there is no usable course.
    /// `bearing` and `course` are compass degrees; the side is `BuzzSide(bearing:course:)`.
    public static func detail(distance: Double, bearing: Double, course: Double?) -> String {
        "\(roundedDistance(distance)) m \(BuzzSide(bearing: bearing, course: course).words(.english))"
    }

    /// "50 m foran deg" / "50 m til høyre" / "50 m til venstre" / "90 m bak deg" / "50 m unna"; English is `detail`.
    /// The same `BuzzSide` as `detail`, so the two languages always agree.
    public static func localizedDetail(distance: Double, bearing: Double, course: Double?, language: StoryLanguage) -> String {
        "\(roundedDistance(distance)) m \(BuzzSide(bearing: bearing, course: course).words(language))"
    }
}

/// Which way a buzzed place lies from the way the owner walks, in the buzz line's four bands. Coarser than
/// `RelativeDirection` on purpose: at 150° the buzz still says "right", where the screen says "behind you to the right".
public enum BuzzSide: Sendable, Equatable {
    case ahead, right, left, behind
    /// No usable course (or bearing): only the distance is known.
    case away

    /// r = bearing − course, wrapped into (−180, 180] (`GeoMath.signedOffset`): −30...30 ahead, 30...150 right,
    /// −150...−30 left, else behind (so ±30 is ahead and ±150 right or left). A course is usable when it is finite
    /// and not negative; without one, or with a bearing that is not finite, `away`.
    public init(bearing: Double, course: Double?) {
        guard let course, course.isFinite, course >= 0, bearing.isFinite else { self = .away; return }
        switch GeoMath.signedOffset(from: course, to: bearing) {
        case -30...30: self = .ahead
        case 30...150: self = .right
        case -150 ... -30: self = .left
        default: self = .behind
        }
    }

    /// The words after the distance: "behind you" / "bak deg".
    public func words(_ language: StoryLanguage) -> String {
        switch language {
        case .english:
            switch self {
            case .ahead: "ahead"
            case .right: "right"
            case .left: "left"
            case .behind: "behind you"
            case .away: "away"
            }
        case .norwegian:
            switch self {
            case .ahead: "foran deg"
            case .right: "til høyre"
            case .left: "til venstre"
            case .behind: "bak deg"
            case .away: "unna"
            }
        }
    }
}
