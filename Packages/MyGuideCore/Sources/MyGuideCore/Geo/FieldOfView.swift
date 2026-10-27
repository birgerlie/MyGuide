import Foundation

public enum FieldOfView {
    /// Spec 8.1.3: a heading worse than this (degrees) is treated as unknown.
    public static let maxUsableHeadingAccuracy = 45.0
    /// Assumed horizontal FOV of the main camera in landscape, degrees.
    public static let landscapeFOV = 69.4

    private static let compassPoints = [
        "north", "north-east", "east", "south-east",
        "south", "south-west", "west", "north-west"
    ]

    /// Horizontal FOV of a portrait (3:4) frame given the landscape (4:3) horizontal FOV.
    public static func portraitHorizontalFOV(landscapeFOV: Double) -> Double {
        let half = landscapeFOV / 2 * .pi / 180
        return 2 * atan(tan(half) * 3 / 4) * 180 / .pi
    }

    /// Horizontal FOV after a digital zoom crop: 2·atan(tan(F/2)/z). A zoom below 1 or invalid leaves F unchanged.
    public static func zoomedHorizontalFOV(_ fov: Double, zoomFactor: Double) -> Double {
        guard zoomFactor.isFinite, zoomFactor > 1 else { return fov }
        let half = fov / 2 * .pi / 180
        return 2 * atan(tan(half) / zoomFactor) * 180 / .pi
    }

    /// Landscape (or square) images use the landscape FOV; portrait images the derived one.
    public static func assumedHorizontalFOV(pixelWidth: Int, pixelHeight: Int) -> Double {
        pixelWidth >= pixelHeight ? landscapeFOV : portraitHorizontalFOV(landscapeFOV: landscapeFOV)
    }

    /// Half-angle of the view cone: half the camera FOV plus twice the heading accuracy.
    public static func coneHalfWidth(horizontalFOV: Double, headingAccuracy: Double) -> Double {
        horizontalFOV / 2 + 2 * headingAccuracy
    }

    /// The heading if it is known and its accuracy is within 0...45 degrees, else nil.
    public static func usableHeading(_ heading: Double?, accuracy: Double?) -> Double? {
        guard let heading, let accuracy,
              accuracy >= 0, accuracy <= maxUsableHeadingAccuracy else { return nil }
        return heading
    }

    public static func isInView(bearing: Double, heading: Double, halfWidth: Double) -> Bool {
        GeoMath.angularDifference(bearing, heading) <= halfWidth
    }

    /// Eight-point compass name for a heading in degrees (any real value; wrapped to 0..<360).
    public static func compassPoint(_ degrees: Double) -> String {
        let normalised = (degrees.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        return compassPoints[Int((normalised + 22.5) / 45) % 8]
    }
}

public struct CompassReading: Sendable, Equatable {
    public var heading: Double
    public var accuracy: Double?

    public init(heading: Double, accuracy: Double?) {
        self.heading = heading
        self.accuracy = accuracy
    }

    /// CoreLocation conventions: trueHeading < 0 means unavailable (use magnetic);
    /// headingAccuracy < 0 means invalid (accuracy nil).
    public init(trueHeading: Double, magneticHeading: Double, headingAccuracy: Double) {
        self.heading = trueHeading >= 0 ? trueHeading : magneticHeading
        self.accuracy = headingAccuracy >= 0 ? headingAccuracy : nil
    }
}
