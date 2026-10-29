import Foundation
import Testing
@testable import MyGuideCore

@Suite struct TourCandidatesTests {
    /// 30 min loop on the equator: radius 1.3 × 1800 / 2.5 = 936 m.
    let area = TourArea.loop(from: .at(), minutes: 30)

    static func place(_ id: String, _ tier: PlaceTier, north: Double = 100, east: Double = 0) -> WalkingPlace {
        WalkingPlace(candidate: Candidate(id: id, name: id, coordinate: .at(north: north, east: east), kind: "historic=yes"),
                     tier: tier)
    }

    // MARK: - select

    @Test func fewerThanFourTopOrGoodAddsWikiOnly() {
        let places = [Self.place("a", .top), Self.place("b", .good), Self.place("c", .good), Self.place("w", .wikiOnly)]
        let selected = TourCandidates.select(places, in: area, heardWithin30Days: [])
        // 3 top/good < 4 → wikiOnly joins. Scores: top 3, good 2, wikiOnly 1; highest first, ties by id.
        #expect(selected.map(\.place.candidate.id) == ["a", "b", "c", "w"])
        #expect(selected.map(\.score) == [3, 2, 2, 1])
    }

    @Test func fourTopOrGoodLeaveWikiOnlyOut() {
        let places = [Self.place("w", .wikiOnly), Self.place("d", .good), Self.place("c", .top), Self.place("b", .good),
                      Self.place("a", .top), Self.place("x", .wikiOnly)]
        let selected = TourCandidates.select(places, in: area, heardWithin30Days: [])
        // Exactly 4 top/good (the boundary) → no wikiOnly. Scores 3, 3, 2, 2; ties by id.
        #expect(selected.map(\.place.candidate.id) == ["a", "c", "b", "d"])
        #expect(selected.map(\.score) == [3, 3, 2, 2])
    }

    @Test func heardPlacesScoreHalf() {
        let places = [Self.place("t", .top), Self.place("g", .good), Self.place("w", .wikiOnly), Self.place("t2", .top)]
        let selected = TourCandidates.select(places, in: area, heardWithin30Days: ["t", "g", "w"])
        // Heard: top 3 × 0.5 = 1.5, good 2 × 0.5 = 1, wikiOnly 1 × 0.5 = 0.5; unheard top t2 stays 3.
        // Order by score: t2 3, t 1.5, g 1, w 0.5.
        #expect(selected.map(\.place.candidate.id) == ["t2", "t", "g", "w"])
        #expect(selected.map(\.score) == [3, 1.5, 1, 0.5])
    }

    @Test func heardPlacesStillCountTowardsTheFour() {
        // Halving changes the score, not the tier: 4 heard top/good still keep wikiOnly out.
        let places = [Self.place("a", .top), Self.place("b", .top), Self.place("c", .good), Self.place("d", .good),
                      Self.place("w", .wikiOnly)]
        let selected = TourCandidates.select(places, in: area, heardWithin30Days: ["a", "b", "c", "d"])
        // 3 × 0.5 = 1.5 twice, 2 × 0.5 = 1 twice.
        #expect(selected.map(\.score) == [1.5, 1.5, 1, 1])
        #expect(!selected.contains { $0.place.tier == .wikiOnly })
    }

    @Test func placesOutsideTheAreaAreDroppedAndDoNotCount() {
        // Four top places, but one is 1000 m north, outside the 936 m loop: 3 remain, so wikiOnly joins.
        let places = [Self.place("a", .top), Self.place("b", .top), Self.place("c", .top),
                      Self.place("far", .top, north: 1000), Self.place("w", .wikiOnly, north: -900),
                      Self.place("wfar", .wikiOnly, east: 940)]
        let selected = TourCandidates.select(places, in: area, heardWithin30Days: [])
        // w at 900 m is inside (≤ 936), wfar at 940 m is outside.
        #expect(selected.map(\.place.candidate.id) == ["a", "b", "c", "w"])
    }

    @Test func emptyInputGivesNoCandidates() {
        #expect(TourCandidates.select([], in: area, heardWithin30Days: ["a"]).isEmpty)
        // Only wikiOnly places: 0 top/good < 4, so they are the candidates, at score 1.
        let onlyWiki = TourCandidates.select([Self.place("w", .wikiOnly)], in: area, heardWithin30Days: [])
        #expect(onlyWiki == [TourCandidate(place: Self.place("w", .wikiOnly), score: 1)])
    }

    @Test func duplicateIdsAreKeptOnce() {
        let places = [Self.place("a", .top), Self.place("a", .top), Self.place("b", .good)]
        #expect(TourCandidates.select(places, in: area, heardWithin30Days: []).map(\.place.candidate.id) == ["a", "b"])
    }

    // MARK: - TourPlaceSource

    static let osmBody = #"""
    {"elements":[
     {"type":"node","id":1,"lat":0.0009,"lon":0.0,"tags":{"name":"Burg","historic":"castle"}},
     {"type":"node","id":2,"lat":0.0010,"lon":0.0,"tags":{"name":"Bank","amenity":"bank","wikipedia":"en:Bank"}},
     {"type":"node","id":3,"lat":0.0011,"lon":0.0,"tags":{"name":"Old Stone","historic":"yes"}}
    ]}
    """#
    static let wikiBody = #"""
    {"query":{"pages":[
     {"pageid":10,"title":"Dom","coordinates":[{"lat":0.002,"lon":0.002}],"extract":"A cathedral.","pageprops":{"wikibase_item":"Q10"}}
    ]}}
    """#

    static func stub(osm: @escaping @Sendable () throws -> (Int, Data) = { (200, Data(osmBody.utf8)) },
                     wiki: @escaping @Sendable (URLRequest) throws -> (Int, Data) = { _ in (200, Data(wikiBody.utf8)) })
        -> StubHTTPClient {
        StubHTTPClient { request in
            OverpassClient.endpoints.contains { $0.host == request.url?.host } ? try osm() : try wiki(request)
        }
    }

    static func source(_ http: StubHTTPClient) -> TourPlaceSource {
        TourPlaceSource(overpass: OverpassClient(http: http), wikipedia: WikipediaClient(http: http))
    }

    static func wikiRequests(_ http: StubHTTPClient) -> [URLRequest] {
        http.requests.filter { $0.url?.host?.hasSuffix("wikipedia.org") == true }
    }

    @Test func loopFetchesTheBoxFromOverpassAndOneTileFromWikipedia() async throws {
        let http = Self.stub()
        let places = try await Self.source(http).places(in: area, language: .english)
        // castle → top; bank (never) and historic=yes without article (no tier) dropped; Dom → wikiOnly.
        #expect(places.map(\.candidate.name) == ["Burg", "Dom"])
        #expect(places.map(\.tier) == [.top, .wikiOnly])

        let overpass = try #require(http.requests.first { $0.url?.host == "overpass-api.de" })
        let body = String(decoding: overpass.httpBody ?? Data(), as: UTF8.self).removingPercentEncoding ?? ""
        // Box ±936 m: 936 / 111 194.93 = 0.008418°.
        #expect(body.contains("nwr(-0.008418,-0.008418,0.008418,0.008418)[\"historic\"][\"name\"]"))
        let wiki = Self.wikiRequests(http)
        #expect(wiki.count == 1)
        let url = wiki.first?.url?.absoluteString ?? ""
        #expect(url.contains("ggscoord=0.000000%7C0.000000&ggsradius=936&ggslimit=500"))
    }

    @Test func corridorAsksWikipediaOncePerTile() async throws {
        let http = Self.stub()
        let corridor = TourArea.corridor(from: .at(), to: .at(east: 15_000))
        _ = try await Self.source(http).places(in: corridor, language: .english)
        // 2 tiles (see TourAreaTests.mediumCorridorSplitsAlongItsLongSide), 1500 m and 13 500 m east:
        // 1500 / 111 194.93 = 0.013490°, 13 500 / 111 194.93 = 0.121408°.
        let coords = Self.wikiRequests(http).compactMap { request -> String? in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ggscoord" }?.value
        }
        #expect(Set(coords) == ["0.000000|0.013490", "0.000000|0.121408"])
        #expect(http.requests.filter { $0.url?.host == "overpass-api.de" }.count == 1)
    }

    @Test func articlesFoundByTwoTilesAreKeptOnce() async throws {
        let corridor = TourArea.corridor(from: .at(), to: .at(east: 15_000))
        let places = try await Self.source(Self.stub()).places(in: corridor, language: .english)
        // Both tiles answer with the same Dom page; it appears once.
        #expect(places.filter { $0.candidate.name == "Dom" }.count == 1)
    }

    @Test func oneWikidataItemFromTwoTilesIsKeptOnce() async throws {
        let corridor = TourArea.corridor(from: .at(), to: .at(east: 15_000))
        let http = Self.stub(osm: { (200, Data(#"{"elements":[]}"#.utf8)) }, wiki: { request in
            let first = request.url!.absoluteString.contains("ggscoord=0.000000%7C0.013490")
            // Different pages (and names) of the same item Q10, as when one tile's English fallback adds it.
            let page = first
                ? #"{"pageid":10,"title":"Dom","coordinates":[{"lat":0.0,"lon":0.06}],"pageprops":{"wikibase_item":"Q10"}}"#
                : #"{"pageid":77,"title":"Cathedral","coordinates":[{"lat":0.0,"lon":0.07}],"pageprops":{"wikibase_item":"Q10"}}"#
            return (200, Data(#"{"query":{"pages":[\#(page)]}}"#.utf8))
        })
        let places = try await Self.source(http).places(in: corridor, language: .english)
        // The first tile's page wins.
        #expect(places.map(\.candidate.name) == ["Dom"])
    }

    @Test func oneFailingTileKeepsTheOtherTilesArticles() async throws {
        let corridor = TourArea.corridor(from: .at(), to: .at(east: 15_000))
        let http = Self.stub(osm: { (500, Data()) }, wiki: { request in
            request.url!.absoluteString.contains("ggscoord=0.000000%7C0.013490") ? (503, Data()) : (200, Data(Self.wikiBody.utf8))
        })
        let places = try await Self.source(http).places(in: corridor, language: .english)
        #expect(places.map(\.candidate.name) == ["Dom"])
    }

    @Test func overpassFailingGivesWikipediaPlaces() async throws {
        let places = try await Self.source(Self.stub(osm: { (500, Data()) })).places(in: area, language: .english)
        #expect(places.map(\.candidate.name) == ["Dom"])
    }

    @Test func wikipediaFailingGivesOverpassPlaces() async throws {
        let places = try await Self.source(Self.stub(wiki: { _ in (500, Data()) })).places(in: area, language: .english)
        #expect(places.map(\.candidate.name) == ["Burg"])
    }

    @Test func bothFailingThrowsTheOverpassError() async throws {
        let http = Self.stub(osm: { (500, Data()) }, wiki: { _ in (503, Data()) })
        let error = await #expect(throws: OverpassFailure.self) {
            _ = try await Self.source(http).places(in: area, language: .english)
        }
        #expect(try #require(error).first as? GroundingFetchError == .http(500))
    }

    @Test func cancellationFromEitherSourcePropagates() async {
        let cancelled: @Sendable () throws -> (Int, Data) = { throw URLError(.cancelled) }
        await #expect(throws: CancellationError.self) {
            _ = try await Self.source(Self.stub(osm: cancelled)).places(in: area, language: .english)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await Self.source(Self.stub(wiki: { _ in throw URLError(.cancelled) })).places(in: area, language: .english)
        }
    }

    // MARK: - Reporting failures

    @Test func searchReportsNothingFailedWhenAllAnswer() async throws {
        let result = try await Self.source(Self.stub()).search(in: area, language: .english)
        #expect(result.places.map(\.candidate.name) == ["Burg", "Dom"])
        #expect(!result.osmFailed && result.osmErrors.isEmpty && result.failedTiles == 0 && result.tileCount == 1)
        #expect(!result.osmCapped)
        #expect(!result.isPartial)
    }

    @Test func searchMarksACappedOverpassAnswerPartial() async throws {
        // 1200 nodes = the node cap: OpenStreetMap answered, but may have cut places.
        let capped = TourAreaTests.overpassBody(areas: 0, nodes: OverpassClient.tourNodeCap)
        let result = try await Self.source(Self.stub(osm: { (200, capped) })).search(in: area, language: .english)
        #expect(result.osmCapped && result.isPartial)
        #expect(!result.osmFailed && result.failedTiles == 0)
        // Also when Wikipedia failed (OSM alone answered, capped).
        let alone = try await Self.source(Self.stub(osm: { (200, capped) }, wiki: { _ in (500, Data()) }))
            .search(in: area, language: .english)
        #expect(alone.osmCapped && alone.failedTiles == 1)
        // A failed OSM is never capped.
        let failed = try await Self.source(Self.stub(osm: { (502, Data()) })).search(in: area, language: .english)
        #expect(!failed.osmCapped)
        // The default and each flag alone.
        #expect(!TourPlaceSearch(places: [], osmFailed: false, osmErrors: [], failedTiles: 0, tileCount: 1).isPartial)
        #expect(TourPlaceSearch(places: [], osmFailed: false, osmErrors: [], failedTiles: 0, tileCount: 1,
                                osmCapped: true).isPartial)
    }

    @Test func searchReportsOverpassFailureWithItsEndpoints() async throws {
        let result = try await Self.source(Self.stub(osm: { (502, Data()) })).search(in: area, language: .english)
        #expect(result.osmFailed && result.isPartial)
        #expect(result.osmErrors == ["overpass-api.de: HTTP 502", "overpass.kumi.systems: HTTP 502", "maps.mail.ru: HTTP 502"])
        #expect(result.failedTiles == 0)
        #expect(result.places.map(\.candidate.name) == ["Dom"])
    }

    @Test func searchCountsFailedTiles() async throws {
        let corridor = TourArea.corridor(from: .at(), to: .at(east: 15_000))
        let oneTile = Self.stub(wiki: { request in
            request.url!.absoluteString.contains("ggscoord=0.000000%7C0.013490") ? (503, Data()) : (200, Data(Self.wikiBody.utf8))
        })
        let partial = try await Self.source(oneTile).search(in: corridor, language: .english)
        // 1 of the 2 tiles failed; OSM answered.
        #expect(partial.failedTiles == 1 && partial.tileCount == 2 && !partial.osmFailed && partial.isPartial)

        let allTiles = try await Self.source(Self.stub(wiki: { _ in (500, Data()) })).search(in: corridor, language: .english)
        // Every tile failed: Wikipedia failed, OSM's places remain and all 2 tiles count as failed.
        #expect(allTiles.failedTiles == 2 && allTiles.tileCount == 2 && !allTiles.osmFailed)
        #expect(allTiles.places.map(\.candidate.name) == ["Burg"])
    }

    // MARK: - CandidateRanker.merge at tour scale

    @Test func mergeOfTwoThousandPlacesPerSourceIsFast() {
        // 2000 OSM places on a 50 × 40 grid 50 m apart; 2000 articles, every 4th the same Wikidata item as an OSM place
        // (folded in), the rest new names, 25 m east of a grid point. Expected: 2000 OSM + 1500 unmatched articles.
        let osm = (0..<2000).map { Self.gridCandidate($0, wiki: false) }
        let wiki = (0..<2000).map { Self.gridCandidate($0, wiki: true) }
        let clock = ContinuousClock()
        var merged: [Candidate] = []
        let elapsed = clock.measure { merged = CandidateRanker.merge(osm: osm, wiki: wiki) }
        #expect(merged.count == 3500)
        #expect(merged[0].summary == "Text 0.")   // Q0 folded its summary into the OSM place
        // Measured on the M-series dev Mac in a debug build: 1.65 s pairwise, 0.005 s bucketed.
        #expect(elapsed < .seconds(2))
    }

    /// Point `i` of a 50-wide grid, 50 m apart; an article sits 25 m east of its point and shares the OSM place's
    /// name and Wikidata item only when `i` is a multiple of 4.
    static func gridCandidate(_ i: Int, wiki: Bool) -> Candidate {
        let north = Double(i / 50) * 50
        let east = Double(i % 50) * 50 + (wiki ? 25 : 0)
        let shared = !wiki || i % 4 == 0
        let name = shared ? "Place \(i)" : "Article \(i)"
        let wikidata = shared ? "Q\(i)" : "W\(i)"
        let id = wiki ? "wiki:en/\(i)" : "osm:node/\(i)"
        let summary: String? = wiki ? "Text \(i)." : nil
        return Candidate(id: id, name: name, coordinate: .at(north: north, east: east), kind: wiki ? "wikipedia" : "historic=yes",
                         summary: summary, wikidata: wikidata)
    }

    @Test func norwegianTilesFallBackToEnglishLikeEveryGeosearch() async throws {
        let http = Self.stub(wiki: { _ in (200, Data(#"{"query":{"pages":[]}}"#.utf8)) })
        _ = try await Self.source(http).places(in: area, language: .norwegian)
        // One tile: the Norwegian request plus its concurrent English fallback.
        #expect(Set(Self.wikiRequests(http).compactMap { $0.url?.host }) == ["no.wikipedia.org", "en.wikipedia.org"])
    }
}
