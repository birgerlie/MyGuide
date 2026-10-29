import Foundation

/// The capture screen's one-line summary of what position and heading will be sent,
/// e.g. "GPS ±8 m · 312° NW ±10°", or "Compass unreliable" when the heading is too inaccurate to use.
public enum CaptureHUD {
    public static func text(fix: LocationFix?, compass: CompassReading?) -> String {
        let gps = fix.map { "GPS ±\(Int($0.accuracy.rounded())) m" } ?? "No GPS fix"
        return "\(gps) · \(headingText(compass))"
    }

    /// Without a valid accuracy the core treats the heading as unusable, so it shows as unavailable.
    private static func headingText(_ compass: CompassReading?) -> String {
        guard let compass, compass.heading.isFinite,
              let accuracy = compass.accuracy, accuracy.isFinite else { return "Compass unavailable" }
        // Matches the core: a heading this inaccurate is not sent as usable (spec 8.1.3).
        guard accuracy <= FieldOfView.maxUsableHeadingAccuracy else { return "Compass unreliable" }
        // Wrap first so any finite heading maps into 0..<360; 359.6 rounds to 360 and shows as 0.
        let wrapped = GeoMath.normalizedDegrees(compass.heading)
        let degrees = Int(wrapped.rounded()) % 360
        return "\(degrees)° \(CompassPoint(degrees: wrapped).abbreviation) ±\(Int(accuracy.rounded()))°"
    }
}
