import Foundation

/// A place a tour may visit, with what it is worth to the planner.
public struct TourCandidate: Sendable, Equatable {
    public var place: WalkingPlace
    public var score: Double

    public init(place: WalkingPlace, score: Double) {
        self.place = place
        self.score = score
    }
}

public enum TourCandidates {
    /// Below this many top/good places in the area, wikiOnly places become candidates too.
    public static let minimumTopOrGood = 4
    /// A place heard in the last 30 days keeps this share of its score, so it loses to new ones but is not excluded.
    public static let heardFactor = 0.5
    /// A place counts as heard for `heardFactor` when heard within this many seconds (30 days, tours spec 4). Its own
    /// constant: walking mode's rest (`MemoryStore.placeRestDays`) is a different rule that happens to match today.
    public static let heardWindow: TimeInterval = 30 * 86_400

    /// The places in the area that a tour may visit (spec 4): tier top and good, plus wikiOnly only when fewer than
    /// `minimumTopOrGood` top/good places lie in the area. Scores are top 3, good 2, wikiOnly 1, halved when the
    /// place's id is in `heardWithin30Days`. Each id counts once (the first). Highest score first, ties by id.
    public static func select(_ places: [WalkingPlace], in area: TourArea,
                              heardWithin30Days heard: Set<String>) -> [TourCandidate] {
        var seen = Set<String>()
        var inside: [WalkingPlace] = []
        for place in places where area.contains(place.candidate.coordinate) && seen.insert(place.candidate.id).inserted {
            inside.append(place)
        }
        let topOrGood = inside.filter { $0.tier != .wikiOnly }
        let chosen = topOrGood.count < minimumTopOrGood ? inside : topOrGood
        return chosen
            .map { TourCandidate(place: $0, score: baseScore($0.tier) * (heard.contains($0.candidate.id) ? heardFactor : 1)) }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.place.candidate.id < b.place.candidate.id
            }
    }

    static func baseScore(_ tier: PlaceTier) -> Double {
        switch tier {
        case .top: 3
        case .good: 2
        case .wikiOnly: 1
        }
    }
}

/// The tiered places of a tour area, and what failed or was cut while fetching them, so the app can mark the result
/// as possibly incomplete and the log can say why.
public struct TourPlaceSearch: Sendable, Equatable {
    public var places: [WalkingPlace]
    /// OpenStreetMap failed (every Overpass endpoint) while Wikipedia answered.
    public var osmFailed: Bool
    /// When `osmFailed`: one short line per Overpass endpoint tried; else empty.
    public var osmErrors: [String]
    /// Wikipedia geosearch tiles that failed, of `tileCount`; all of them when OpenStreetMap alone answered.
    public var failedTiles: Int
    public var tileCount: Int
    /// OpenStreetMap answered with as many elements as one of the tour query's caps (`OverpassClient.tourAreaCap`,
    /// `.tourNodeCap`): places may be missing.
    public var osmCapped: Bool

    public init(places: [WalkingPlace], osmFailed: Bool, osmErrors: [String], failedTiles: Int, tileCount: Int,
                osmCapped: Bool = false) {
        self.places = places
        self.osmFailed = osmFailed
        self.osmErrors = osmErrors
        self.failedTiles = failedTiles
        self.tileCount = tileCount
        self.osmCapped = osmCapped
    }

    /// True when a source, or part of one, did not answer, or OpenStreetMap's answer was cut at a cap.
    public var isPartial: Bool { osmFailed || failedTiles > 0 || osmCapped }
}

/// Fetches the tiered places of a tour area: one Overpass box query (`OverpassClient.tourQuery`) and one Wikipedia
/// geosearch per tile of the area, merged with `CandidateRanker`, given their Wikidata facts, and tiered with
/// `PlaceTiers` (spec 19.2: a Wikipedia-only `nonPlace` is never a tour candidate). Places outside the area may be
/// included (tiles and boxes overreach); `TourCandidates.select` keeps the area's own.
public struct TourPlaceSource: Sendable {
    /// Results per geosearch tile: the API maximum, since one tile may cover several square kilometres.
    public static let wikiLimit = WikipediaClient.maxGeosearchLimit

    private let overpass: OverpassClient
    private let wikipedia: WikipediaClient
    private let facts: PlaceFactsLookup?

    /// Without `facts`, places keep the tiers of tags and articles alone.
    public init(overpass: OverpassClient, wikipedia: WikipediaClient, facts: PlaceFactsLookup? = nil) {
        self.overpass = overpass
        self.wikipedia = wikipedia
        self.facts = facts
    }

    /// `search(in:language:)`'s places alone.
    public func places(in area: TourArea, language: StoryLanguage) async throws -> [WalkingPlace] {
        try await search(in: area, language: language).places
    }

    /// Both sources concurrently, failing like `WalkingPlaceSource`: one failing → the other's places, with the failure
    /// reported in the result; both failing → the OpenStreetMap error is thrown (an `OverpassFailure` when every
    /// endpoint answered with an error). Wikipedia counts as failed only when every tile failed; single failed tiles
    /// are counted in `failedTiles`. The merged candidates then get their Wikidata facts (Wikipedia-only ones first,
    /// since their tier depends on them; at most `WikidataClient.tourMaxBatches` batches of `WikidataClient.batchSize`, the rest are left out); a failed lookup leaves the tiers as they were. Unlike walking,
    /// OpenStreetMap is awaited fully: a tour is planned once, and its 30 s query is worth the wait. Cancellation
    /// always propagates.
    public func search(in area: TourArea, language: StoryLanguage) async throws -> TourPlaceSearch {
        let box = area.boundingBox, tiles = area.wikipediaTiles
        async let osm = WalkingPlaceSource.outcome {
            try await overpass.tourPlacesReportingEndpoints(in: box, language: language)
        }
        async let wiki = WalkingPlaceSource.outcome { try await articles(in: tiles, language: language) }
        let (osmResult, wikiResult) = try await (osm, wiki)
        // Some sources signal cancellation with their own error type; do not report that as a failure.
        try Task.checkCancellation()

        var result = TourPlaceSearch(places: [], osmFailed: false, osmErrors: [], failedTiles: 0, tileCount: tiles.count)
        var candidates: [Candidate]
        switch (osmResult, wikiResult) {
        case (.failure(let error), .failure):
            throw error
        case (.success(let osm), .failure):
            result.failedTiles = tiles.count
            result.osmCapped = osm.capped
            candidates = CandidateRanker.merge(osm: osm.candidates, wiki: [])
        case (.failure(let error), .success(let found)):
            result.osmFailed = true
            result.osmErrors = WalkingPlaceSource.endpointErrors(error)
            result.failedTiles = found.failedTiles
            candidates = CandidateRanker.merge(osm: [], wiki: found.articles)
        case (.success(let osm), .success(let found)):
            result.failedTiles = found.failedTiles
            result.osmCapped = osm.capped
            candidates = CandidateRanker.merge(osm: osm.candidates, wiki: found.articles)
        }
        if let facts {
            // A tour area holds far more articles than a walk's list: up to 8 batches (400 ids), 4 at a time.
            let answer = try await facts.answer(for: PlaceFactsLookup.ids(of: candidates),
                                                maxBatches: WikidataClient.tourMaxBatches, language: language)
            candidates = candidates.applying(answer.facts, language: language)
        }
        result.places = candidates.compactMap { candidate in
            PlaceTiers.tier(for: candidate).map { WalkingPlace(candidate: candidate, tier: $0) }
        }
        return result
    }

    /// Every tile concurrently. The articles come in tile order, each place once: a page found by two overlapping
    /// tiles, or the same Wikidata item found in two languages (each tile adds English pages), is kept from the
    /// first, except that a later story-language page replaces an earlier English one in its place (spec 20.1).
    /// Failed tiles are left out and counted; when every tile fails, the first tile's error is thrown.
    private func articles(in tiles: [GeosearchTile],
                          language: StoryLanguage) async throws -> (articles: [Candidate], failedTiles: Int) {
        let wikipedia = self.wikipedia
        let results = try await withThrowingTaskGroup(of: (Int, Result<[Candidate], Error>).self) { group in
            for (index, tile) in tiles.enumerated() {
                group.addTask {
                    let result = try await WalkingPlaceSource.outcome {
                        try await wikipedia.articles(around: tile.centre, radius: tile.radius, language: language,
                                                     limit: Self.wikiLimit)
                    }
                    return (index, result)
                }
            }
            var byTile = [Result<[Candidate], Error>?](repeating: nil, count: tiles.count)
            for try await (index, result) in group { byTile[index] = result }
            return byTile.compactMap { $0 }
        }

        let storyPrefix = "wiki:\(language.wikipediaCode)/"
        // The index in `articles` of each kept place, by Wikidata id (else page id).
        var seen: [String: Int] = [:]
        var articles: [Candidate] = []
        var firstError: Error?
        var failedTiles = 0
        for result in results {
            switch result {
            case .success(let found):
                for article in found {
                    let key = article.wikidata ?? article.id
                    if let index = seen[key] {
                        if !articles[index].id.hasPrefix(storyPrefix), article.id.hasPrefix(storyPrefix) {
                            articles[index] = article
                        }
                    } else {
                        seen[key] = articles.count
                        articles.append(article)
                    }
                }
            case .failure(let error):
                failedTiles += 1
                if firstError == nil { firstError = error }
            }
        }
        if failedTiles == results.count, let firstError { throw firstError }
        return (articles, failedTiles)
    }
}
