import Foundation

/// One of the eight compass points, each the 45° sector around its direction: north is 337.5..<22.5, north-east
/// 22.5..<67.5, and so on round.
public enum CompassPoint: Int, Sendable, CaseIterable {
    case north, northEast, east, southEast, south, southWest, west, northWest

    /// The point whose sector holds `degrees`, any finite angle (wrapped into 0..<360 first). A sector's lower edge
    /// belongs to it: 22.5 is north-east. Not finite → north.
    public init(degrees: Double) {
        guard degrees.isFinite else { self = .north; return }
        // normalizedDegrees is in 0..<360, so (x + 22.5) / 45 is in 0.5..<8.5 and Int(…) % 8 is in 0...7: a raw value.
        let index = Int((GeoMath.normalizedDegrees(degrees) + 22.5) / 45) % 8
        self = CompassPoint(rawValue: index)!
    }

    /// The English word the prompts send to the model ("north-west"). Kept as is: the model reads it.
    public var promptWord: String {
        switch self {
        case .north: "north"
        case .northEast: "north-east"
        case .east: "east"
        case .southEast: "south-east"
        case .south: "south"
        case .southWest: "south-west"
        case .west: "west"
        case .northWest: "north-west"
        }
    }

    /// The word on screen: "nordvest" / "north-west".
    public func words(_ language: StoryLanguage) -> String {
        switch language {
        case .english: promptWord
        case .norwegian:
            switch self {
            case .north: "nord"
            case .northEast: "nordøst"
            case .east: "øst"
            case .southEast: "sørøst"
            case .south: "sør"
            case .southWest: "sørvest"
            case .west: "vest"
            case .northWest: "nordvest"
            }
        }
    }

    /// "NW": the capture screen's short form, English initials in either language.
    public var abbreviation: String {
        switch self {
        case .north: "N"
        case .northEast: "NE"
        case .east: "E"
        case .southEast: "SE"
        case .south: "S"
        case .southWest: "SW"
        case .west: "W"
        case .northWest: "NW"
        }
    }
}
