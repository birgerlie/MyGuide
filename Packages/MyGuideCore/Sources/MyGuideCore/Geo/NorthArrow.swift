import Foundation

/// The map's north arrow (spec 14, amended 2026-10-30): it shows north as seen from the phone, and moves only when
/// the phone's heading is at least `step` degrees from what it shows, so it holds still while the phone wavers.
public enum NorthArrow {
    /// Degrees the heading must move from the shown one before the arrow follows.
    public static let step: Double = 10

    /// The heading the arrow shows next, in 0..<360: `heading` when nothing is shown yet or it is at least `step` from
    /// `shown` (either way round north), otherwise `shown`. A heading that is not finite keeps `shown`.
    public static func next(shown: Double?, heading: Double) -> Double? {
        guard heading.isFinite else { return shown }
        let heading = GeoMath.normalizedDegrees(heading)
        guard let shown else { return heading }
        return abs(GeoMath.signedOffset(from: shown, to: heading)) >= step ? heading : shown
    }
}
