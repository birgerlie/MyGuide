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
    /// Most food places listed: they only ground the meal-time line (spec 7.3), so they must not crowd out the sights.
    public static let foodLimit = 2
    /// The categories (`MapKitPointsOfInterest`'s words, folded) that count as food.
    static let foodCategories: Set<String> = Set(["bakery", "restaurant", "café", "brewery", "winery", "market"].map(fold))
    public static let timeout: Duration = .seconds(8)

    /// Searches with the timeout; nil on failure or timeout (cancellation propagates).
    public static func fetch(_ search: PointsOfInterestSearching?, around: Coordinate, radius: Double,
                             timeout: Duration = ApplePlaces.timeout) async throws -> [ApplePlace]? {
        guard let search else { return nil }
        do {
            return try await Deadline.withTimeout(timeout) {
                try await search.places(around: around, radius: radius)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// The places to list, at most `limit`: every other category before food, nearest first within each group, and at
    /// most `foodLimit` food places. Names equal (case- and diacritic-insensitive, trimmed) to any of `knownNames` are
    /// dropped first. Equal distances keep input order. A name that is empty after trimming never matches.
    public static func select(_ places: [ApplePlace], from: Coordinate, knownNames: [String]) -> [ApplePlace] {
        let known = Set(knownNames.map(fold).filter { !$0.isEmpty })
        var ranked: [(index: Int, place: ApplePlace, distance: Double, isFood: Bool)] = []
        for (index, place) in places.enumerated() where !known.contains(fold(place.name)) {
            ranked.append((index, place, GeoMath.distance(from, place.coordinate), foodCategories.contains(fold(place.category))))
        }
        ranked.sort { a, b in
            if a.isFood != b.isFood { return !a.isFood }
            return a.distance != b.distance ? a.distance < b.distance : a.index < b.index
        }
        var selected: [ApplePlace] = []
        var food = 0
        for entry in ranked where selected.count < limit {
            if entry.isFood {
                guard food < foodLimit else { break }
                food += 1
            }
            selected.append(entry.place)
        }
        return selected
    }

    private static func fold(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
