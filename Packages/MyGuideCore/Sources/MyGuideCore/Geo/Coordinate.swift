import Foundation

public struct Coordinate: Sendable, Equatable, Hashable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum GeoMath {
    public static let earthRadius = 6_371_000.0

    /// Great-circle distance in metres (haversine).
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let φ1 = a.latitude * .pi / 180
        let φ2 = b.latitude * .pi / 180
        let dφ = φ2 - φ1
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        // Clamp: rounding can push h marginally above 1 for antipodal points.
        return 2 * earthRadius * asin(min(1, h.squareRoot()))
    }

    /// Initial bearing from `from` to `to` in degrees clockwise from true north, 0..<360.
    public static func bearing(from: Coordinate, to: Coordinate) -> Double {
        let φ1 = from.latitude * .pi / 180
        let φ2 = to.latitude * .pi / 180
        let dλ = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Smallest absolute angle between two compass angles, 0...180.
    public static func angularDifference(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    /// How far `to` lies clockwise of `from` (compass degrees), wrapped into (−180, 180]: positive is to the right,
    /// exactly opposite is +180. Any finite angles; not finite → NaN.
    public static func signedOffset(from: Double, to: Double) -> Double {
        // The remainder is in (−360, 360); each correction subtracts numbers within a factor of two, so it is exact.
        var r = (to - from).truncatingRemainder(dividingBy: 360)
        if r > 180 { r -= 360 }
        if r <= -180 { r += 360 }
        return r
    }

    /// Any finite angle in compass degrees wrapped into 0..<360 (−10 → 350, 360 → 0); not finite → NaN.
    public static func normalizedDegrees(_ degrees: Double) -> Double {
        (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }
}
