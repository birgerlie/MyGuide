import Foundation

/// The merged candidates of one place search, and whether its OpenStreetMap part failed (every Overpass endpoint, or
/// it ran out of time) while Wikipedia answered, so the walk log can say so (spec 13.6, 19.5), with what the Wikidata
/// facts did (spec 19.8).
public struct PlaceSearchResult: Sendable, Equatable {
    public var candidates: [Candidate]
    public var osmFailed: Bool
    /// When `osmFailed`: one short line per Overpass endpoint tried ("overpass-api.de: timed out"), or
    /// `[PlaceSearchResult.slow]` when OpenStreetMap had not answered within the grace; else empty.
    public var osmErrors: [String]
    /// Candidates that received Wikidata facts.
    public var factsCount: Int
    /// Names of the Wikipedia-only candidates whose Wikidata item is `nonPlace`, which the tiering drops.
    public var dropped: [String]
    /// Wikidata batches that failed (their candidates keep their tiers without facts).
    public var factsFailed: Int

    /// The `osmErrors` line when OpenStreetMap was cut off after the grace.
    public static let slow = "slow"

    public init(candidates: [Candidate], osmFailed: Bool, osmErrors: [String] = [], factsCount: Int = 0,
                dropped: [String] = [], factsFailed: Int = 0) {
        self.candidates = candidates
        self.osmFailed = osmFailed
        self.osmErrors = osmErrors
        self.factsCount = factsCount
        self.dropped = dropped
        self.factsFailed = factsFailed
    }
}

/// Fetches the places around a walker from OpenStreetMap and Wikipedia, ranks them with Wikidata facts, and keeps
/// those that can buzz.
public struct WalkingPlaceSource: Sendable {
    public static let radius = 500
    public static let wikiLimit = 50
    /// How long OpenStreetMap may still take once Wikipedia and the facts are in (spec 19.5).
    public static let osmGrace: Duration = .seconds(5)

    private let overpass: OverpassClient
    private let wikipedia: WikipediaClient
    private let facts: PlaceFactsLookup?
    private let osmGrace: Duration

    /// Without `facts`, candidates keep the tiers of tags and articles alone. `osmGrace` is injectable for tests.
    public init(overpass: OverpassClient, wikipedia: WikipediaClient, facts: PlaceFactsLookup? = nil,
                osmGrace: Duration = Self.osmGrace) {
        self.overpass = overpass
        self.wikipedia = wikipedia
        self.facts = facts
        self.osmGrace = osmGrace
    }

    /// `candidates(around:language:)` with tiers; places with a nil tier are dropped.
    public func places(around: Coordinate, language: StoryLanguage) async throws -> [WalkingPlace] {
        try await candidates(around: around, language: language).candidates.compactMap { candidate in
            PlaceTiers.tier(for: candidate).map { WalkingPlace(candidate: candidate, tier: $0) }
        }
    }

    /// One part of a search, as its task in the group ends.
    private enum Part: Sendable {
        case osm(Result<[Candidate], Error>)
        /// Wikipedia's articles, and the facts for them when Wikipedia answered and there is a lookup.
        case wiki(Result<[Candidate], Error>, WikidataClient.Answer?)
        case graceOver
    }

    /// The merged OpenStreetMap and Wikipedia candidates, untiered ones included, with Wikidata facts applied.
    /// Both sources start together. Once Wikipedia has answered, the facts for its articles are looked up; once both
    /// are done, OpenStreetMap gets at most `osmGrace` more and is then cancelled, and the result is Wikipedia's with
    /// `osmFailed` and `osmErrors == [PlaceSearchResult.slow]`. When Wikipedia fails, OpenStreetMap is awaited fully.
    /// One failing → the other's candidates, with `osmFailed` set when OpenStreetMap was the one (and its per-endpoint
    /// errors in `osmErrors`); both failing → the OSM error is thrown, an `OverpassFailure` when every endpoint
    /// answered with an error. When OpenStreetMap answered, the ids of its candidates that the first lookup did not
    /// answer are looked up too (for their sitelinks), unless that lookup had failed batches: Wikidata is then down or
    /// slow, and is not waited for twice. CancellationError always propagates.
    public func candidates(around: Coordinate, language: StoryLanguage) async throws -> PlaceSearchResult {
        let overpass = overpass, wikipedia = wikipedia, facts = facts, grace = osmGrace
        let (osmResult, wikiResult, wikiAnswer) = try await withThrowingTaskGroup(of: Part.self) { group in
            group.addTask {
                .osm(try await Self.outcome {
                    try await overpass.placesReportingEndpoints(around: around, radius: Self.radius, language: language)
                })
            }
            group.addTask {
                let wiki = try await Self.outcome {
                    try await wikipedia.articles(around: around, radius: Self.radius, language: language,
                                                 limit: Self.wikiLimit)
                }
                guard case .success(let articles) = wiki, let facts else { return .wiki(wiki, nil) }
                return .wiki(wiki, try await facts.answer(for: PlaceFactsLookup.ids(of: articles)))
            }
            // Nil OSM result after the loop: the grace ran out.
            var osm: Result<[Candidate], Error>?
            var wiki: (Result<[Candidate], Error>, WikidataClient.Answer?)?
            loop: while osm == nil || wiki == nil {
                // The children always end with a part or an error, so next() never runs dry before both are in.
                guard let part = try await group.next() else { break }
                switch part {
                case .osm(let result):
                    osm = result
                case .wiki(let result, let answer):
                    wiki = (result, answer)
                    if osm == nil, case .success = result {
                        group.addTask {
                            try await Task.sleep(for: grace)
                            return .graceOver
                        }
                    }
                case .graceOver:
                    break loop
                }
            }
            // Ends the grace timer, or OpenStreetMap when the grace ran out; their errors are discarded.
            group.cancelAll()
            guard let wiki else { throw CancellationError() }
            return (osm, wiki.0, wiki.1)
        }
        // Some sources signal cancellation with their own error type; do not report that as a failure.
        try Task.checkCancellation()

        let merged: [Candidate]
        var result = PlaceSearchResult(candidates: [], osmFailed: false)
        switch (osmResult, wikiResult) {
        case (nil, .success(let articles)):
            merged = CandidateRanker.merge(osm: [], wiki: articles)
            result.osmFailed = true
            result.osmErrors = [PlaceSearchResult.slow]
        case (nil, .failure(let error)):
            // Unreachable: the grace starts only after Wikipedia answered.
            throw error
        case (.failure(let error)?, .failure):
            throw error
        case (.success(let osmPlaces)?, .failure):
            merged = CandidateRanker.merge(osm: osmPlaces, wiki: [])
        case (.failure(let error)?, .success(let articles)):
            merged = CandidateRanker.merge(osm: [], wiki: articles)
            result.osmFailed = true
            result.osmErrors = Self.endpointErrors(error)
        case (.success(let osmPlaces)?, .success(let articles)):
            merged = CandidateRanker.merge(osm: osmPlaces, wiki: articles)
        }

        var answer = wikiAnswer ?? WikidataClient.Answer()
        if let facts, answer.failedBatches == 0 {
            let missing = PlaceFactsLookup.ids(of: merged).filter { !answer.answered.contains($0) }
            let more = try await facts.answer(for: missing)
            answer.facts.merge(more.facts) { first, _ in first }
            answer.answered.formUnion(more.answered)
            answer.failedBatches += more.failedBatches
        }
        let enriched = PlaceFactsEnrichment(merged, facts: answer.facts)
        result.candidates = enriched.candidates
        result.factsCount = enriched.factsCount
        result.dropped = enriched.dropped
        result.factsFailed = answer.failedBatches
        return result
    }

    /// The per-endpoint lines of an `OverpassFailure`; one short line for any other error.
    static func endpointErrors(_ error: any Error) -> [String] {
        (error as? OverpassFailure)?.endpointErrors ?? [OverpassFailure.shortText(error)]
    }

    /// The work's result; cancellation (including `URLError.cancelled`, as phase 1 treats it) is thrown instead.
    /// `TourPlaceSource` shares it, so tours fail the same way.
    static func outcome<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> Result<T, Error> {
        do {
            return .success(try await work())
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            return .failure(error)
        }
    }
}
