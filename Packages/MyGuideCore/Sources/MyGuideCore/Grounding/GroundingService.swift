import Foundation

public enum GroundingError: Error, Equatable {
    case noPosition
}

/// Gathers nearby places (OpenStreetMap, Wikipedia) and a street address for a capture.
/// A failing source is recorded in `failedSources`; only cancellation propagates.
public struct GroundingService: Sendable {
    static let osmRadius = 250
    static let wikiRadius = 400

    private let overpass: OverpassClient
    private let wikipedia: WikipediaClient
    private let geocoder: ReverseGeocoding

    public init(overpass: OverpassClient, wikipedia: WikipediaClient, geocoder: ReverseGeocoding) {
        self.overpass = overpass
        self.wikipedia = wikipedia
        self.geocoder = geocoder
    }

    public func ground(_ capture: CaptureContext, language: StoryLanguage) async throws -> Grounding {
        guard let here = capture.coordinate else { throw GroundingError.noPosition }

        async let osm = Self.attempt { try await overpass.places(around: here, radius: Self.osmRadius, language: language) }
        async let wiki = Self.attempt { try await wikipedia.articles(around: here, radius: Self.wikiRadius, language: language) }
        async let geo = Self.attempt { try await geocoder.address(for: here) }
        let (osmResult, wikiResult, geoResult) = try await (osm, wiki, geo)
        // Some sources signal cancellation with their own error type (CLError, MKError); do not report that as a failure.
        try Task.checkCancellation()

        var failed: [GroundingSource] = []
        if osmResult == nil { failed.append(.openStreetMap) }
        if wikiResult == nil { failed.append(.wikipedia) }
        if geoResult == nil { failed.append(.geocoder) }

        let merged = CandidateRanker.merge(osm: osmResult ?? [], wiki: wikiResult ?? [])
        return Grounding(candidates: CandidateRanker.rank(merged, capture: capture),
                         address: geoResult, failedSources: failed)
    }

    /// nil on any failure except cancellation, which propagates.
    private static func attempt<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T? {
        do {
            return try await work()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }
}
