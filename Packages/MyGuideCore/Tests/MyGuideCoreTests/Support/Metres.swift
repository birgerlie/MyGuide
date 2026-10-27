import Foundation
@testable import MyGuideCore

/// metres per degree on the equator = 6 371 000 · π / 180 = 111 194.9266, computed from the same radius GeoMath uses,
/// so `.at(north: d)` is exactly `d` metres by haversine (up to floating point).
extension Coordinate {
    static let metresPerDegree = GeoMath.earthRadius * .pi / 180

    static func at(north: Double = 0, east: Double = 0) -> Coordinate {
        Coordinate(latitude: north / Self.metresPerDegree, longitude: east / Self.metresPerDegree)
    }
}
