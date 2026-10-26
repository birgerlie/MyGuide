import Foundation

public enum CaptureSource: String, Sendable, Codable {
    case camera, library
}

/// Where, when and (if known) in which direction a photo was taken.
public struct CaptureContext: Sendable, Equatable, Codable {
    public var coordinate: Coordinate?
    public var horizontalAccuracy: Double?
    public var heading: Double?
    public var headingAccuracy: Double?
    public var horizontalFOV: Double
    public var takenAt: Date
    public var source: CaptureSource

    public init(coordinate: Coordinate?, horizontalAccuracy: Double?, heading: Double?, headingAccuracy: Double?,
                horizontalFOV: Double, takenAt: Date, source: CaptureSource) {
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.heading = heading
        self.headingAccuracy = headingAccuracy
        self.horizontalFOV = horizontalFOV
        self.takenAt = takenAt
        self.source = source
    }

    /// The heading if known and accurate enough to use (spec 8.1.3).
    public var usableHeading: Double? {
        FieldOfView.usableHeading(heading, accuracy: headingAccuracy)
    }

    /// A copy with a user-chosen position. The heading described the old position's view, so it is cleared.
    public func withCoordinate(_ c: Coordinate, accuracy: Double?) -> CaptureContext {
        var copy = self
        copy.coordinate = c
        copy.horizontalAccuracy = accuracy
        copy.heading = nil
        copy.headingAccuracy = nil
        return copy
    }
}
