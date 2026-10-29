import Foundation
import Testing
@testable import MyGuideCore

@Suite struct WalkingPlaceSourceTests {
    let here = Coordinate(latitude: 48.2082, longitude: 16.3738)

    static let osmBody = #"""
    {"elements":[
     {"type":"node","id":1,"lat":48.2086,"lon":16.3671,"tags":{"name":"Burg","historic":"castle"}},
     {"type":"node","id":2,"lat":48.2087,"lon":16.3675,"tags":{"name":"Bank Austria","amenity":"bank","wikipedia":"de:Bank_Austria"}},
     {"type":"node","id":3,"lat":48.2090,"lon":16.3680,"tags":{"name":"Old Stone","historic":"yes"}}
    ]}
    """#
    static let wikiBody = #"""
    {"query":{"pages":[
     {"pageid":10,"title":"Stephansdom","coordinates":[{"lat":48.2084,"lon":16.3731}],"extract":"A cathedral.","pageprops":{"wikibase_item":"Q10"}}
    ]}}
    """#

    /// Routes by host: any Overpass endpoint vs Wikipedia.
    static func stub(osm: @escaping @Sendable () throws -> (Int, Data) = { (200, Data(osmBody.utf8)) },
                     wiki: @escaping @Sendable () throws -> (Int, Data) = { (200, Data(wikiBody.utf8)) }) -> StubHTTPClient {
        StubHTTPClient { request in
            isOverpass(request) ? try osm() : try wiki()
        }
    }
    static func isOverpass(_ request: URLRequest) -> Bool {
        OverpassClient.endpoints.contains { $0.host == request.url?.host }
    }

    func source(_ http: StubHTTPClient) -> WalkingPlaceSource {
        WalkingPlaceSource(overpass: OverpassClient(http: http), wikipedia: WikipediaClient(http: http))
    }

    @Test func happyPathKeepsTieredPlacesOnly() async throws {
        let empty = #"{"query":{"pages":[]}}"#
        let places = try await source(Self.stub(wiki: { (200, Data(empty.utf8)) })).places(around: here, language: .english)
        // castle -> top; bank (never) and plain historic=yes without article (nil tier) are dropped.
        #expect(places.map(\.candidate.name) == ["Burg"])
        #expect(places.map(\.tier) == [.top])
    }

    @Test func candidatesKeepUntieredPlaces() async throws {
        // OverpassClient drops cafés before merging, so the untiered place is a plain historic=yes without an article.
        let stone = #"{"elements":[{"type":"node","id":7,"lat":48.2086,"lon":16.3671,"tags":{"name":"Old Stone","historic":"yes"}}]}"#
        let empty = #"{"query":{"pages":[]}}"#
        let src = source(Self.stub(osm: { (200, Data(stone.utf8)) }, wiki: { (200, Data(empty.utf8)) }))
        let candidates = try await src.candidates(around: here, language: .english).candidates
        let places = try await src.places(around: here, language: .english)
        #expect(candidates.map(\.name) == ["Old Stone"])
        #expect(candidates.first?.tags?["historic"] == "yes")
        #expect(places.isEmpty)
    }

    @Test func wikipediaArticlesAreWikiOnlyAndMergedWithOSM() async throws {
        let places = try await source(Self.stub()).places(around: here, language: .english)
        #expect(places.map(\.candidate.name) == ["Burg", "Stephansdom"])
        #expect(places.map(\.tier) == [.top, .wikiOnly])
    }

    @Test func overpassFailureStillReturnsWikipediaPlaces() async throws {
        let places = try await source(Self.stub(osm: { (500, Data()) })).places(around: here, language: .english)
        #expect(places.map(\.candidate.name) == ["Stephansdom"])
        #expect(places.map(\.tier) == [.wikiOnly])
    }

    @Test func wikipediaFailureStillReturnsOSMPlaces() async throws {
        let places = try await source(Self.stub(wiki: { (500, Data()) })).places(around: here, language: .english)
        #expect(places.map(\.candidate.name) == ["Burg"])
    }

    @Test func bothFailingThrowsTheOSMError() async {
        let http = Self.stub(osm: { (500, Data()) }, wiki: { (503, Data()) })
        await #expect(throws: GroundingFetchError.http(500)) {
            _ = try await source(http).places(around: here, language: .english)
        }
    }

    @Test func requestParameters() async throws {
        let http = Self.stub()
        _ = try await source(http).places(around: here, language: .english)
        let overpass = http.requests.first { $0.url?.host == "overpass-api.de" }
        let wiki = http.requests.first { $0.url?.host?.hasSuffix("wikipedia.org") == true }
        let body = String(decoding: overpass?.httpBody ?? Data(), as: UTF8.self).removingPercentEncoding ?? ""
        #expect(body.contains("around:500,"))
        let url = wiki?.url?.absoluteString ?? ""
        #expect(url.contains("ggsradius=500") && url.contains("ggslimit=50"))
    }

    @Test func cancelledURLErrorFromEitherSourceBecomesCancellation() async {
        let cancelled: @Sendable () throws -> (Int, Data) = { throw URLError(.cancelled) }
        await #expect(throws: CancellationError.self) {
            _ = try await source(Self.stub(osm: cancelled)).places(around: here, language: .english)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await source(Self.stub(wiki: cancelled)).places(around: here, language: .english)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await source(Self.stub(osm: cancelled, wiki: cancelled)).places(around: here, language: .english)
        }
    }

    @Test func cancelledTaskThrowsEvenWhenSourcesFailWithOtherErrors() async {
        let http = Self.stub(osm: { (500, Data()) }, wiki: { (500, Data()) })
        let src = source(http)
        let here = self.here
        let task = Task {
            // Wait until cancelled, so the sources run on an already-cancelled task.
            while !Task.isCancelled { await Task.yield() }
            return try await src.places(around: here, language: .english)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    // MARK: - Reporting an OpenStreetMap failure (spec 13.6)

    @Test func osmFailureReportedWhenWikipediaAnswers() async throws {
        let http = Self.stub(osm: { (502, Data()) })
        let result = try await source(http).candidates(around: here, language: .english)
        #expect(result.osmFailed)
        #expect(result.candidates.map(\.name) == ["Stephansdom"])
        // All three Overpass endpoints were tried, then given up.
        #expect(http.requests.filter(Self.isOverpass).count == 3)
    }
    @Test func secondEndpointAnsweringIsNoFailure() async throws {
        let http = StubHTTPClient { request in
            switch request.url?.host {
            case "overpass-api.de": (502, Data())
            case "overpass.kumi.systems": (200, Data(Self.osmBody.utf8))
            default: (200, Data(Self.wikiBody.utf8))
            }
        }
        let result = try await source(http).candidates(around: here, language: .english)
        #expect(!result.osmFailed)
        #expect(result.candidates.map(\.name).contains("Burg"))
    }
    @Test func noOSMFailureWhenOSMAnswers() async throws {
        let ok = try await source(Self.stub()).candidates(around: here, language: .english)
        #expect(!ok.osmFailed && ok.candidates.count == 4)
        // Only Wikipedia failing is not an OpenStreetMap failure.
        let wikiDown = try await source(Self.stub(wiki: { (500, Data()) })).candidates(around: here, language: .english)
        #expect(!wikiDown.osmFailed && wikiDown.candidates.map(\.name) == ["Burg", "Bank Austria", "Old Stone"])
    }
}
