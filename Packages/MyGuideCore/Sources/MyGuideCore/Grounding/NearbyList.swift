import Foundation

/// The places around the owner from one fetch: every merged OpenStreetMap and Wikipedia candidate (untiered ones
/// included), with the article texts of the nearest important ones. Shared by the camera and walking mode.
public struct NearbyList: Sendable, Equatable, Codable {
    /// At most this old (seconds) to count as fresh for a photo.
    public static let freshAge: TimeInterval = 600
    /// The list's centre at most this far (metres) from the photo to count as fresh.
    public static let freshDistance = 250.0

    /// Where the list was fetched.
    public var centre: Coordinate
    public var fetchedAt: Date
    public var language: StoryLanguage
    public var candidates: [Candidate]
    /// Article text by `wikipediaTitle`.
    public var articleTexts: [String: String]

    public init(centre: Coordinate, fetchedAt: Date, language: StoryLanguage, candidates: [Candidate],
                articleTexts: [String: String]) {
        self.centre = centre
        self.fetchedAt = fetchedAt
        self.language = language
        self.candidates = candidates
        self.articleTexts = articleTexts
    }

    /// At most `freshAge` old and centred within `freshDistance` of `position`. A list dated after `now` (the clock
    /// was set back) is never fresh: its age is unknown.
    public func isFresh(for position: Coordinate, now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age >= 0 && age <= Self.freshAge && GeoMath.distance(centre, position) <= Self.freshDistance
    }

    /// Whether this list can serve a walker at `position` without a refresh: centred less than
    /// `NearbyPlaces.walkingDistance` away and at most `freshAge` old. A list dated after `now` (the clock was set
    /// back) never serves: its age is unknown. `NearbyPlaces` refreshes for walking exactly when this is false.
    public func serves(walkerAt position: Coordinate, now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age >= 0 && age <= Self.freshAge && GeoMath.distance(centre, position) < NearbyPlaces.walkingDistance
    }

    /// The candidates that can buzz while walking, in list order, with their tiers; nil tiers are dropped.
    public var walkingPlaces: [WalkingPlace] {
        candidates.compactMap { candidate in
            PlaceTiers.tier(for: candidate).map { WalkingPlace(candidate: candidate, tier: $0) }
        }
    }
}

/// Keeps one JSON file per story language in a directory, written atomically (temporary file, then rename).
public struct NearbyListStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The stored list, or nil when there is none, it cannot be read, or it belongs to another language.
    public func load(language: StoryLanguage) -> NearbyList? {
        guard let data = try? Data(contentsOf: file(for: language)),
              let list = try? JSONDecoder().decode(NearbyList.self, from: data),
              list.language == language else { return nil }
        return list
    }

    /// Replaces the list's language file, creating the directory when missing.
    public func save(_ list: NearbyList) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(list)
        // `.atomic` writes a temporary file and renames it over the old one, so a reader never sees half a file.
        try data.write(to: file(for: list.language), options: .atomic)
    }

    func file(for language: StoryLanguage) -> URL {
        directory.appendingPathComponent("nearby-\(language.rawValue).json")
    }
}
