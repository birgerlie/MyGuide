import Foundation

/// A position good enough to send with a photo.
public struct LocationFix: Sendable, Equatable {
    public var coordinate: Coordinate
    /// Metres; always finite and >= 0.
    public var accuracy: Double

    public init(coordinate: Coordinate, accuracy: Double) {
        self.coordinate = coordinate
        self.accuracy = accuracy
    }

    /// A fix older than this (seconds) counts as no coordinate.
    public static let maxAge: TimeInterval = 60

    /// Sanitises raw CoreLocation values: a negative or non-finite `horizontalAccuracy` marks an invalid fix,
    /// an out-of-range coordinate is invalid, and a fix older than `maxAge` counts as none.
    public static func usable(latitude: Double, longitude: Double, horizontalAccuracy: Double,
                              timestamp: Date, now: Date) -> LocationFix? {
        guard horizontalAccuracy.isFinite, horizontalAccuracy >= 0,
              latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180,
              now.timeIntervalSince(timestamp) <= maxAge else { return nil }
        return LocationFix(coordinate: Coordinate(latitude: latitude, longitude: longitude), accuracy: horizontalAccuracy)
    }
}
