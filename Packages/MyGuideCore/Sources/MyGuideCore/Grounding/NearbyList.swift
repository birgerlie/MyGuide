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
    /// At the start of a walk, a stored list at most this old (seconds, 7 days) and centred at most
    /// `staleStartDistance` (metres) from the first fix stands in until the fresh one arrives (spec 19.6).
    public static let staleStartAge: TimeInterval = 7 * 86_400
    public static let staleStartDistance = 250.0

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
    /// When `osmFailed`: one short line per Overpass endpoint tried, or `PlaceSearchResult.slow` when OpenStreetMap
    /// ran out of time, for the walk log; empty otherwise and in a file written before the field existed.
    public var osmErrors: [String]
    /// For the walk log (spec 19.8), as in `PlaceSearchResult`: candidates that received Wikidata facts, the names
    /// dropped for their Wikidata class, and the Wikidata batches that failed. 0 / empty / 0 in a file written before they existed.
    public var factsCount: Int
    public var dropped: [String]
    public var factsFailed: Int

    public init(centre: Coordinate, fetchedAt: Date, language: StoryLanguage, candidates: [Candidate],
                articleTexts: [String: String], osmFailed: Bool = false, osmErrors: [String] = [],
                factsCount: Int = 0, dropped: [String] = [], factsFailed: Int = 0) {
        self.centre = centre
        self.fetchedAt = fetchedAt
        self.language = language
        self.candidates = candidates
        self.articleTexts = articleTexts
        self.osmFailed = osmFailed
        self.osmErrors = osmErrors
        self.factsCount = factsCount
        self.dropped = dropped
        self.factsFailed = factsFailed
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
        factsCount = try c.decodeIfPresent(Int.self, forKey: .factsCount) ?? 0
        dropped = try c.decodeIfPresent([String].self, forKey: .dropped) ?? []
        factsFailed = try c.decodeIfPresent(Int.self, forKey: .factsFailed) ?? 0
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

    /// `stored` when it can stand in at the start of a walk at `position` (spec 19.6): in `language`, at most
    /// `staleStartAge` old (both inclusive) and centred at most `staleStartDistance` away. Nil otherwise, and for a
    /// list dated after `now` (the clock was set back), whose age is unknown. It says nothing about freshness: the
    /// caller asks only when the walk needs a fetch, and `serves` alone decides whether one is needed.
    public static func staleCandidate(stored: NearbyList?, position: Coordinate, language: StoryLanguage,
                                      now: Date) -> NearbyList? {
        guard let stored, stored.language == language else { return nil }
        let age = now.timeIntervalSince(stored.fetchedAt)
        guard age >= 0, age <= staleStartAge,
              GeoMath.distance(stored.centre, position) <= staleStartDistance else { return nil }
        return stored
    }

    /// This list with its candidates' Wikidata facts looked up again through `facts` and applied, so a stale list
    /// stands in tiered as a fresh one would be (spec 19.6, 19.2): a list stored before facts existed loses its
    /// `nonPlace` articles. Cache hits answer at once. `factsCount`, `dropped` and `factsFailed` follow the new
    /// answer. When the answer holds no facts (the lookup failed, ran past `timeout`, the caller was cancelled, or no
    /// candidate has a Wikidata id) the list is returned as it is.
    public func withFacts(from facts: PlaceFactsLookup, within timeout: Duration) async -> NearbyList {
        let ids = PlaceFactsLookup.ids(of: candidates)
        guard !ids.isEmpty,
              let answer = await Deadline.value(within: timeout, { try? await facts.answer(for: ids) }),
              !answer.facts.isEmpty else { return self }
        let enriched = PlaceFactsEnrichment(candidates, facts: answer.facts)
        var copy = self
        copy.candidates = enriched.candidates
        copy.factsCount = enriched.factsCount
        copy.dropped = enriched.dropped
        copy.factsFailed = answer.failedBatches
        return copy
    }

    /// True when the list has no facts (`factsCount` 0: stored before facts existed, or every lookup failed) while it
    /// holds a Wikipedia-only candidate with a Wikidata id, whose tier depends on facts. A walk re-tiers such a list
    /// with `withFacts(from:within:)` before using it, also when it still `serves` (spec 19.6).
    public var needsFacts: Bool {
        factsCount == 0 && candidates.contains {
            !PlaceTiers.hasOSMTags($0) && $0.wikidata.map(WikidataClient.isValid) == true
        }
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
