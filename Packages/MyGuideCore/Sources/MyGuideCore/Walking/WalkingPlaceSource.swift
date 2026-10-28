import Foundation

/// Fetches the places around a walker from OpenStreetMap and Wikipedia and keeps those that can buzz.
public struct WalkingPlaceSource: Sendable {
    public static let radius = 500
    public static let wikiLimit = 50

    private let overpass: OverpassClient
    private let wikipedia: WikipediaClient

    public init(overpass: OverpassClient, wikipedia: WikipediaClient) {
        self.overpass = overpass
        self.wikipedia = wikipedia
    }

    /// `candidates(around:language:)` with tiers; places with a nil tier are dropped.
    public func places(around: Coordinate, language: StoryLanguage) async throws -> [WalkingPlace] {
        try await candidates(around: around, language: language).compactMap { candidate in
            PlaceTiers.tier(for: candidate).map { WalkingPlace(candidate: candidate, tier: $0) }
        }
    }

    /// The merged OpenStreetMap and Wikipedia candidates, untiered ones included.
    /// Both sources concurrently. One failing → the other's candidates; both failing → the OSM error is thrown.
    /// CancellationError always propagates.
    public func candidates(around: Coordinate, language: StoryLanguage) async throws -> [Candidate] {
        async let osm = Self.outcome { try await overpass.places(around: around, radius: Self.radius, language: language) }
        async let wiki = Self.outcome {
            try await wikipedia.articles(around: around, radius: Self.radius, language: language, limit: Self.wikiLimit)
        }
        let (osmResult, wikiResult) = try await (osm, wiki)
        // Some sources signal cancellation with their own error type; do not report that as a failure.
        try Task.checkCancellation()

        switch (osmResult, wikiResult) {
        case (.failure(let error), .failure):
            throw error
        case (.success(let osmPlaces), .failure):
            return CandidateRanker.merge(osm: osmPlaces, wiki: [])
        case (.failure, .success(let articles)):
            return CandidateRanker.merge(osm: [], wiki: articles)
        case (.success(let osmPlaces), .success(let articles)):
            return CandidateRanker.merge(osm: osmPlaces, wiki: articles)
        }
    }

    /// The work's result; cancellation (including `URLError.cancelled`, as phase 1 treats it) is thrown instead.
    private static func outcome<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> Result<T, Error> {
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
