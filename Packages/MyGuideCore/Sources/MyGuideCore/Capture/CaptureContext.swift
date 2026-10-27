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
    /// True when `coordinate` is where the listener is now ("Use where I am now"), not where the photo was taken.
    public var positionIsSubstitute: Bool

    public init(coordinate: Coordinate?, horizontalAccuracy: Double?, heading: Double?, headingAccuracy: Double?,
                horizontalFOV: Double, takenAt: Date, source: CaptureSource, positionIsSubstitute: Bool = false) {
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.heading = heading
        self.headingAccuracy = headingAccuracy
        self.horizontalFOV = horizontalFOV
        self.takenAt = takenAt
        self.source = source
        self.positionIsSubstitute = positionIsSubstitute
    }

    /// Records stored before `positionIsSubstitute` existed have no such key; they decode as false.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coordinate = try c.decodeIfPresent(Coordinate.self, forKey: .coordinate)
        horizontalAccuracy = try c.decodeIfPresent(Double.self, forKey: .horizontalAccuracy)
        heading = try c.decodeIfPresent(Double.self, forKey: .heading)
        headingAccuracy = try c.decodeIfPresent(Double.self, forKey: .headingAccuracy)
        horizontalFOV = try c.decode(Double.self, forKey: .horizontalFOV)
        takenAt = try c.decode(Date.self, forKey: .takenAt)
        source = try c.decode(CaptureSource.self, forKey: .source)
        positionIsSubstitute = try c.decodeIfPresent(Bool.self, forKey: .positionIsSubstitute) ?? false
    }

    /// The heading if known and accurate enough to use (spec 8.1.3).
    public var usableHeading: Double? {
        FieldOfView.usableHeading(heading, accuracy: headingAccuracy)
    }

    /// A copy with a substitute position (where the listener is now). The heading described the old position's view,
    /// so it is cleared, and the position is flagged as a substitute.
    public func withCoordinate(_ c: Coordinate, accuracy: Double?) -> CaptureContext {
        var copy = self
        copy.coordinate = c
        copy.horizontalAccuracy = accuracy
        copy.heading = nil
        copy.headingAccuracy = nil
        copy.positionIsSubstitute = true
        return copy
    }
}
