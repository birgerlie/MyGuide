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

/// Fetches the tiered places of a tour area: one Overpass box query (the same tags as walking mode) and one Wikipedia
/// geosearch per tile of the area, merged with `CandidateRanker` and tiered with `PlaceTiers`. Places outside the
/// area may be included (tiles and boxes overreach); `TourCandidates.select` keeps the area's own.
public struct TourPlaceSource: Sendable {
    /// Results per geosearch tile: the API maximum, since one tile may cover several square kilometres.
    public static let wikiLimit = WikipediaClient.maxGeosearchLimit

    private let overpass: OverpassClient
    private let wikipedia: WikipediaClient

    public init(overpass: OverpassClient, wikipedia: WikipediaClient) {
        self.overpass = overpass
        self.wikipedia = wikipedia
    }

    /// Both sources concurrently, failing like `WalkingPlaceSource`: one failing → the other's places; both failing →
    /// the OpenStreetMap error is thrown (an `OverpassFailure` when every endpoint answered with an error).
    /// Wikipedia counts as failed only when every tile failed. Cancellation always propagates.
    public func places(in area: TourArea, language: StoryLanguage) async throws -> [WalkingPlace] {
        let box = area.boundingBox, tiles = area.wikipediaTiles
        async let osm = WalkingPlaceSource.outcome {
            try await overpass.placesReportingEndpoints(in: box, language: language)
        }
        async let wiki = WalkingPlaceSource.outcome { try await articles(in: tiles, language: language) }
        let (osmResult, wikiResult) = try await (osm, wiki)
        // Some sources signal cancellation with their own error type; do not report that as a failure.
        try Task.checkCancellation()

        let candidates: [Candidate]
        switch (osmResult, wikiResult) {
        case (.failure(let error), .failure):
            throw error
        case (.success(let osmPlaces), .failure):
            candidates = CandidateRanker.merge(osm: osmPlaces, wiki: [])
        case (.failure, .success(let articles)):
            candidates = CandidateRanker.merge(osm: [], wiki: articles)
        case (.success(let osmPlaces), .success(let articles)):
            candidates = CandidateRanker.merge(osm: osmPlaces, wiki: articles)
        }
        return candidates.compactMap { candidate in
            PlaceTiers.tier(for: candidate).map { WalkingPlace(candidate: candidate, tier: $0) }
        }
    }

    /// Every tile concurrently. The articles come in tile order, each place once: a page found by two overlapping
    /// tiles, or the same Wikidata item found in two languages (each tile may add English pages), is kept from the
    /// first. Failed tiles are left out; when every tile fails, the first tile's error is thrown.
    private func articles(in tiles: [GeosearchTile], language: StoryLanguage) async throws -> [Candidate] {
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

        var seen = Set<String>()
        var articles: [Candidate] = []
        var firstError: Error?
        var anyAnswered = false
        for result in results {
            switch result {
            case .success(let found):
                anyAnswered = true
                articles += found.filter { seen.insert($0.wikidata ?? $0.id).inserted }
            case .failure(let error):
                if firstError == nil { firstError = error }
            }
        }
        if !anyAnswered, let firstError { throw firstError }
        return articles
    }
}
