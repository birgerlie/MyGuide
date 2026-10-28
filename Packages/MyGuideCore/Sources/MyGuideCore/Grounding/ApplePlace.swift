import Foundation

/// A point of interest from Apple Maps near the user.
public struct ApplePlace: Sendable, Equatable, Codable {
    public var name: String
    /// Lowercase words, e.g. "museum", "café".
    public var category: String
    public var coordinate: Coordinate

    public init(name: String, category: String, coordinate: Coordinate) {
        self.name = name
        self.category = category
        self.coordinate = coordinate
    }
}

/// Implemented by the app over MapKit.
public protocol PointsOfInterestSearching: Sendable {
    func places(around: Coordinate, radius: Double) async throws -> [ApplePlace]
}

public enum ApplePlaces {
    public static let walkingRadius = 150.0
    public static let photoRadius = 250.0
    public static let limit = 8
    public static let timeout: Duration = .seconds(8)

    /// Searches with the timeout; nil on failure or timeout (cancellation propagates).
    public static func fetch(_ search: PointsOfInterestSearching?, around: Coordinate, radius: Double,
                             timeout: Duration = ApplePlaces.timeout) async throws -> [ApplePlace]? {
        guard let search else { return nil }
        do {
            return try await GroundingService.withTimeout(timeout) {
                try await search.places(around: around, radius: radius)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// Nearest first, at most `limit`, dropping names equal (case- and diacritic-insensitive, trimmed) to any of `knownNames`.
    /// Equal distances keep input order. A name that is empty after trimming never matches.
    public static func select(_ places: [ApplePlace], from: Coordinate, knownNames: [String]) -> [ApplePlace] {
        let known = Set(knownNames.map(fold).filter { !$0.isEmpty })
        var ranked: [(index: Int, place: ApplePlace, distance: Double)] = []
        for (index, place) in places.enumerated() where !known.contains(fold(place.name)) {
            ranked.append((index, place, GeoMath.distance(from, place.coordinate)))
        }
        ranked.sort { $0.distance != $1.distance ? $0.distance < $1.distance : $0.index < $1.index }
        return ranked.prefix(limit).map(\.place)
    }

    private static func fold(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
