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
    /// `bearing` and `course` are compass degrees; a course is usable when it is finite and not negative.
    public static func detail(distance: Double, bearing: Double, course: Double?) -> String {
        let d = roundedDistance(distance)
        guard let course, course.isFinite, course >= 0, bearing.isFinite else { return "\(d) m away" }
        // r = bearing − course, normalised into (−180, 180].
        var r = (bearing - course).truncatingRemainder(dividingBy: 360)
        if r > 180 { r -= 360 }
        if r <= -180 { r += 360 }
        switch r {
        case -30...30: return "\(d) m ahead"
        case 30...150: return "\(d) m right"
        case -150 ... -30: return "\(d) m left"
        default: return "\(d) m behind you"
        }
    }
}
