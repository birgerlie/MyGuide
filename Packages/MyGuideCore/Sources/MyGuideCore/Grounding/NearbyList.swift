import Foundation

/// The places around the owner from one fetch: every merged OpenStreetMap and Wikipedia candidate (untiered ones
/// included), with the article texts of the nearest important ones. Shared by the camera and walking mode.
public struct NearbyList: Sendable, Equatable, Codable {
    /// At most this old (seconds) to count as fresh for a photo.
    public static let freshAge: TimeInterval = 600
    /// The list's centre at most this far (metres) from the photo to count as fresh.
    public static let freshDistance = 250.0
    /// A list whose OpenStreetMap part failed is stale once it is this old (seconds), wherever the owner is, so the
    /// next fix retries OpenStreetMap instead of walking on with Wikipedia only for 250 m.
    public static let osmFailedRetryAge: TimeInterval = 60

    /// Where the list was fetched.
    public var centre: Coordinate
    public var fetchedAt: Date
    public var language: StoryLanguage
    public var candidates: [Candidate]
    /// Article text by `wikipediaTitle`.
    public var articleTexts: [String: String]
    /// True when OpenStreetMap failed for this fetch (both Overpass endpoints); its OSM candidates, if any, were
    /// carried from the previous list (spec 13.6). False in a file written before the field existed.
    public var osmFailed: Bool
    /// When `osmFailed`: one short line per Overpass endpoint tried, for the walk log; empty otherwise and in a file
    /// written before the field existed.
    public var osmErrors: [String]

    public init(centre: Coordinate, fetchedAt: Date, language: StoryLanguage, candidates: [Candidate],
                articleTexts: [String: String], osmFailed: Bool = false, osmErrors: [String] = []) {
        self.centre = centre
        self.fetchedAt = fetchedAt
        self.language = language
        self.candidates = candidates
        self.articleTexts = articleTexts
        self.osmFailed = osmFailed
        self.osmErrors = osmErrors
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        centre = try c.decode(Coordinate.self, forKey: .centre)
        fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
        language = try c.decode(StoryLanguage.self, forKey: .language)
        candidates = try c.decode([Candidate].self, forKey: .candidates)
        articleTexts = try c.decode([String: String].self, forKey: .articleTexts)
        osmFailed = try c.decodeIfPresent(Bool.self, forKey: .osmFailed) ?? false
        osmErrors = try c.decodeIfPresent([String].self, forKey: .osmErrors) ?? []
    }

    /// At most `freshAge` old (less than `osmFailedRetryAge` when OpenStreetMap failed) and centred within
    /// `freshDistance` of `position`. A list dated after `now` (the clock was set back) is never fresh: its age is
    /// unknown.
    public func isFresh(for position: Coordinate, now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age >= 0 && age <= Self.freshAge && !isStaleAfterOSMFailure(age: age)
            && GeoMath.distance(centre, position) <= Self.freshDistance
    }

    /// True when OpenStreetMap failed for this list and it is at least `osmFailedRetryAge` old.
    public func isStaleAfterOSMFailure(age: TimeInterval) -> Bool {
        osmFailed && age >= Self.osmFailedRetryAge
    }

    /// Whether this list can serve a walker at `position` without a refresh: centred less than
    /// `NearbyPlaces.walkingDistance` away and at most `freshAge` old (less than `osmFailedRetryAge` when
    /// OpenStreetMap failed). A list dated after `now` (the clock was set back) never serves: its age is unknown.
    /// `NearbyPlaces` refreshes for walking exactly when this is false.
    public func serves(walkerAt position: Coordinate, now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age >= 0 && age <= Self.freshAge && !isStaleAfterOSMFailure(age: age)
            && GeoMath.distance(centre, position) < NearbyPlaces.walkingDistance
    }

    /// The candidates that can buzz while walking, in list order, with their tiers; nil tiers are dropped.
    public var walkingPlaces: [WalkingPlace] {
        candidates.compactMap { candidate in
            PlaceTiers.tier(for: candidate).map { WalkingPlace(candidate: candidate, tier: $0) }
        }
    }
}

/// What the Story timings screen shows about a nearby list (spec 13 check 3, 14.5): its age, and its centre's
/// distance from the owner when a recent position is known.
public struct NearbyListStatus: Sendable, Equatable {
    /// Whole seconds since the list was fetched, rounded down; nil when it is dated after `now` (the clock was set
    /// back), so its age is unknown.
    public var ageS: Int?
    /// Whole metres from `position` to the list's centre, rounded; nil without a position.
    public var distanceM: Int?

    public init(ageS: Int?, distanceM: Int?) {
        self.ageS = ageS
        self.distanceM = distanceM
    }

    public init(list: NearbyList, position: Coordinate?, now: Date) {
        let age = now.timeIntervalSince(list.fetchedAt)
        ageS = age >= 0 ? Int(age.rounded(.towardZero)) : nil
        distanceM = position.map { Int(GeoMath.distance(list.centre, $0).rounded()) }
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
