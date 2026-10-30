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

    @Test func bothFailingThrowsTheOSMErrorWithItsEndpoints() async throws {
        let http = Self.stub(osm: { (500, Data()) }, wiki: { (503, Data()) })
        let error = await #expect(throws: OverpassFailure.self) {
            _ = try await source(http).places(around: here, language: .english)
        }
        let failure = try #require(error)
        #expect(failure.first as? GroundingFetchError == .http(500))
        #expect(failure.endpointErrors == ["overpass-api.de: HTTP 500", "overpass.kumi.systems: HTTP 500",
                                           "maps.mail.ru: HTTP 500"])
        // The walk log line keeps the first error's text, as before, and adds the endpoint lines.
        #expect(WalkLogEvent.fetchFailed(failure) == .fetchFailed(error: "http(500)", osmErrors: failure.endpointErrors))
    }

    @Test func overpassFailureListsEveryEndpointInTheResult() async throws {
        let http = StubHTTPClient { request in
            switch request.url?.host {
            case "overpass-api.de": throw URLError(.timedOut)
            case "overpass.kumi.systems": return (504, Data())
            case "maps.mail.ru": return (200, Data("not json".utf8))
            default: return (200, Data(Self.wikiBody.utf8))
            }
        }
        let result = try await source(http).candidates(around: here, language: .english)
        #expect(result.osmFailed)
        #expect(result.osmErrors == ["overpass-api.de: timed out", "overpass.kumi.systems: HTTP 504",
                                     "maps.mail.ru: malformed answer"])
        // OSM answering leaves no errors.
        let ok = try await source(Self.stub()).candidates(around: here, language: .english)
        #expect(!ok.osmFailed && ok.osmErrors.isEmpty)
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

    // MARK: - Wikidata facts and the OpenStreetMap grace (spec 19.2, 19.5)

    /// Il Gesù (Q1, a church), Jesuittordenen (Q2, an order at the same spot) and Via del Plebiscito (Q3, a street),
    /// all within 500 m of `here`.
    static let romeWikiBody = #"""
    {"query":{"pages":[
     {"pageid":1,"title":"Il Gesù","coordinates":[{"lat":48.2084,"lon":16.3731}],"extract":"A church.","pageprops":{"wikibase_item":"Q1"}},
     {"pageid":2,"title":"Jesuittordenen","coordinates":[{"lat":48.2084,"lon":16.3731}],"extract":"An order.","pageprops":{"wikibase_item":"Q2"}},
     {"pageid":3,"title":"Via del Plebiscito","coordinates":[{"lat":48.2085,"lon":16.3735}],"extract":"A street.","pageprops":{"wikibase_item":"Q3"}}
    ]}}
    """#
    /// A castle with its own Wikidata item (Q20) whose class says organisation, and a plain place without an id.
    static let osmWithIdBody = #"""
    {"elements":[
     {"type":"node","id":1,"lat":48.2086,"lon":16.3671,"tags":{"name":"Burg","historic":"castle","wikidata":"Q20"}},
     {"type":"node","id":2,"lat":48.2090,"lon":16.3680,"tags":{"name":"Museum","tourism":"museum"}}
    ]}
    """#
    static let romeFacts: [String: PlaceFacts] = [
        "Q1": PlaceFacts(sitelinks: 40, placeClass: .place),
        "Q2": PlaceFacts(sitelinks: 119, placeClass: .nonPlace),
        "Q3": PlaceFacts(sitelinks: 7, placeClass: .area),
        "Q20": PlaceFacts(sitelinks: 55, placeClass: .nonPlace),
    ]

    /// A lookup answering from `known` (an id without facts is still answered), recording the ids of every call.
    static func lookup(_ known: [String: PlaceFacts] = romeFacts, delay: Duration = .zero,
                       calls: LockedBox<[[String]]> = LockedBox([])) -> PlaceFactsLookup {
        PlaceFactsLookup { ids in
            calls.withValue { $0.append(ids) }
            if delay > .zero { try await Task.sleep(for: delay) }
            return WikidataClient.Answer(facts: known.filter { ids.contains($0.key) }, answered: Set(ids))
        }
    }

    func source(_ http: any HTTPClient, facts: PlaceFactsLookup?, grace: Duration = .seconds(5)) -> WalkingPlaceSource {
        WalkingPlaceSource(overpass: OverpassClient(http: http), wikipedia: WikipediaClient(http: http), facts: facts,
                           osmGrace: grace)
    }

    @Test func factsTierWikipediaOnlyPlacesAndDropNonPlaces() async throws {
        let empty = #"{"elements":[]}"#
        let http = Self.stub(osm: { (200, Data(empty.utf8)) }, wiki: { (200, Data(Self.romeWikiBody.utf8)) })
        let src = source(http, facts: Self.lookup())
        let result = try await src.candidates(around: here, language: .english)
        // Q1, Q2 and Q3 got facts: 3. Jesuittordenen is nonPlace without tags → dropped; Via del Plebiscito is an
        // area with 7 < 20 sitelinks → dropped too (spec 20.6).
        #expect(result.factsCount == 3)
        #expect(result.dropped == ["Jesuittordenen", "Via del Plebiscito"])
        #expect(result.factsFailed == 0)
        #expect(!result.osmFailed)
        // The untiered candidate stays in the list (the camera's place list uses it); only the tiers drop it.
        #expect(result.candidates.map(\.name) == ["Il Gesù", "Jesuittordenen", "Via del Plebiscito"])
        let places = try await src.places(around: here, language: .english)
        // Il Gesù: place, 40 ≥ 30 → top. Via del Plebiscito: area with 7 < 20 sitelinks → dropped.
        #expect(places.map(\.candidate.name) == ["Il Gesù"])
        #expect(places.map(\.tier) == [.top])
        #expect(places.first?.candidate.sitelinks == 40)
    }
    @Test func failingFactsLeaveTiersAsToday() async throws {
        let empty = #"{"elements":[]}"#
        let http = Self.stub(osm: { (200, Data(empty.utf8)) }, wiki: { (200, Data(Self.romeWikiBody.utf8)) })
        let failing = PlaceFactsLookup { _ in throw URLError(.timedOut) }
        let result = try await source(http, facts: failing).candidates(around: here, language: .english)
        #expect(result.factsCount == 0 && result.dropped.isEmpty)
        // The error counts as one failed batch.
        #expect(result.factsFailed == 1)
        let tiers = result.candidates.compactMap(PlaceTiers.tier(for:))
        // All three are Wikipedia-only without facts: wikiOnly, as without a lookup.
        #expect(tiers == [.wikiOnly, .wikiOnly, .wikiOnly])
        let without = try await source(http, facts: nil).candidates(around: here, language: .english)
        #expect(result.candidates == without.candidates)
        #expect(without.factsCount == 0 && without.dropped.isEmpty && without.factsFailed == 0)
    }
    @Test func cacheAndClientWiringAndWikidataDown() async throws {
        let empty = #"{"elements":[]}"#
        let wikidataUp = LockedBox(true)
        let http = StubHTTPClient { request in
            if Self.isOverpass(request) { return (200, Data(empty.utf8)) }
            if request.url?.host == "query.wikidata.org" {
                guard wikidataUp.value else { return (503, Data()) }
                return (200, WikidataClientTests.body([WikidataClientTests.row("Q1", n: 40, place: true),
                                                       WikidataClientTests.row("Q2", n: 119, nonplace: true),
                                                       WikidataClientTests.row("Q3", n: 7, area: true)]))
            }
            return (200, Data(Self.romeWikiBody.utf8))
        }
        let client = WikidataClient(http: http)
        // Down first: nothing is stored, tiers as today, one failed batch (3 ids fit one batch of 50).
        wikidataUp.set(false)
        let down = try await source(http, facts: PlaceFactsLookup(cache: PlaceFactsCache(directory: nil), client: client))
            .candidates(around: here, language: .english)
        #expect(down.factsCount == 0 && down.dropped.isEmpty && down.factsFailed == 1)
        wikidataUp.set(true)
        let up = try await source(http, facts: PlaceFactsLookup(cache: PlaceFactsCache(directory: nil), client: client))
            .candidates(around: here, language: .english)
        #expect(up.factsCount == 3 && up.dropped == ["Jesuittordenen", "Via del Plebiscito"] && up.factsFailed == 0)
    }
    @Test func osmCandidatesGetSitelinksButKeepTagTiers() async throws {
        let calls = LockedBox<[[String]]>([])
        let http = Self.stub(osm: { (200, Data(Self.osmWithIdBody.utf8)) }, wiki: { (200, Data(Self.romeWikiBody.utf8)) })
        let result = try await source(http, facts: Self.lookup(calls: calls)).candidates(around: here, language: .english)
        let burg = try #require(result.candidates.first { $0.name == "Burg" })
        // Its item is nonPlace with 55 sitelinks, but historic=castle decides: top, and it is not dropped.
        #expect(burg.sitelinks == 55 && burg.placeClass == .nonPlace)
        #expect(PlaceTiers.tier(for: burg) == .top)
        #expect(result.dropped == ["Jesuittordenen", "Via del Plebiscito"])
        // Q1, Q2, Q3 and Q20: 4 candidates got facts.
        #expect(result.factsCount == 4)
        // First the Wikipedia ids as soon as Wikipedia answered, then only the OSM id that was not asked yet.
        #expect(calls.value == [["Q1", "Q2", "Q3"], ["Q20"]])
    }
    @Test func noSecondLookupWhenTheFirstHadFailedBatches() async throws {
        let calls = LockedBox<[[String]]>([])
        let http = Self.stub(osm: { (200, Data(Self.osmWithIdBody.utf8)) }, wiki: { (200, Data(Self.romeWikiBody.utf8)) })
        let failing = PlaceFactsLookup { ids in
            calls.withValue { $0.append(ids) }
            return WikidataClient.Answer(failedBatches: 1)
        }
        let result = try await source(http, facts: failing).candidates(around: here, language: .english)
        #expect(calls.value == [["Q1", "Q2", "Q3"]])
        #expect(result.factsFailed == 1 && result.factsCount == 0)
    }
    @Test func osmIdsAreLookedUpWhenWikipediaFails() async throws {
        let calls = LockedBox<[[String]]>([])
        let http = Self.stub(osm: { (200, Data(Self.osmWithIdBody.utf8)) }, wiki: { (500, Data()) })
        let result = try await source(http, facts: Self.lookup(calls: calls)).candidates(around: here, language: .english)
        #expect(calls.value == [["Q20"]])
        #expect(result.factsCount == 1 && result.dropped.isEmpty && !result.osmFailed)
    }
    @Test func idsWithoutTagsComeFirstEachOnce() {
        let tagged = Candidate(id: "osm:node/1", name: "A", coordinate: here, kind: "x", wikidata: "Q9",
                               tags: ["historic": "castle"])
        let untagged = Candidate(id: "wiki:en/1", name: "B", coordinate: here, kind: "wikipedia", wikidata: "Q8")
        let emptyTags = Candidate(id: "osm:node/2", name: "C", coordinate: here, kind: "x", wikidata: "Q7", tags: [:])
        let none = Candidate(id: "wiki:en/2", name: "D", coordinate: here, kind: "wikipedia")
        let twin = Candidate(id: "wiki:de/1", name: "B", coordinate: here, kind: "wikipedia", wikidata: "Q8")
        #expect(PlaceFactsLookup.ids(of: [tagged, untagged, none, emptyTags, twin]) == ["Q8", "Q7", "Q9"])
    }
    @Test func noLookupCallWithoutIds() async throws {
        let calls = LockedBox<[[String]]>([])
        let http = Self.stub(wiki: { (200, Data(#"{"query":{"pages":[]}}"#.utf8)) })
        let result = try await source(http, facts: Self.lookup(calls: calls)).candidates(around: here, language: .english)
        // Neither Wikipedia (no articles) nor OSM (no wikidata tags in osmBody) has an id.
        #expect(calls.value.isEmpty && result.factsCount == 0)
    }

    @Test func slowOverpassIsCutOffAfterTheGrace() async throws {
        // Overpass would take 60 s; Wikipedia answers after 0.3 s, then OSM gets 0.3 s more: about 0.6 s in all,
        // never less (both are sleeps), and far below the 60 s.
        let http = AsyncStubHTTPClient { request in
            if Self.isOverpass(request) {
                try await Task.sleep(for: .seconds(60))
                return (200, Data(Self.osmBody.utf8))
            }
            try await Task.sleep(for: .milliseconds(300))
            return (200, Data(Self.wikiBody.utf8))
        }
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await source(http, facts: nil, grace: .milliseconds(300)).candidates(around: here, language: .english)
        let elapsed = clock.now - start
        #expect(elapsed >= .milliseconds(600))
        #expect(elapsed < .seconds(5))
        #expect(result.osmFailed)
        #expect(result.osmErrors == ["slow"])
        #expect(result.candidates.map(\.name) == ["Stephansdom"])
        // Cancelled, not failed over: only the first endpoint was asked.
        #expect(http.requests.filter(Self.isOverpass).count == 1)
    }
    @Test func graceStartsWhenTheFactsAreIn() async throws {
        // Wikipedia answers at once; the facts take 1.0 s; Overpass answers at 1.5 s; grace 1.2 s.
        // Grace from the facts: deadline 1.0 + 1.2 = 2.2 s > 1.5 s → OSM is used. (Counted from Wikipedia it would
        // have ended at 1.2 s < 1.5 s and lost the castle.)
        let http = AsyncStubHTTPClient { request in
            if Self.isOverpass(request) {
                try await Task.sleep(for: .milliseconds(1500))
                return (200, Data(Self.osmBody.utf8))
            }
            return (200, Data(Self.wikiBody.utf8))
        }
        let result = try await source(http, facts: Self.lookup(delay: .seconds(1)), grace: .milliseconds(1200))
            .candidates(around: here, language: .english)
        #expect(!result.osmFailed && result.osmErrors.isEmpty)
        #expect(result.candidates.map(\.name).contains("Burg"))
    }
    @Test func overpassAnsweringFirstNeedsNoGrace() async throws {
        // OSM at once, Wikipedia after 0.2 s, grace 60 s: the result comes when Wikipedia is in, not after the grace.
        let http = AsyncStubHTTPClient { request in
            if Self.isOverpass(request) { return (200, Data(Self.osmBody.utf8)) }
            try await Task.sleep(for: .milliseconds(200))
            return (200, Data(Self.wikiBody.utf8))
        }
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await source(http, facts: nil, grace: .seconds(60)).candidates(around: here, language: .english)
        #expect(clock.now - start < .seconds(5))
        #expect(!result.osmFailed && result.candidates.count == 4)
    }
    @Test func wikipediaFailingWaitsForOverpassFully() async throws {
        // Wikipedia fails at once; Overpass takes 0.5 s, more than the 0.05 s grace, and is still awaited.
        let http = AsyncStubHTTPClient { request in
            if Self.isOverpass(request) {
                try await Task.sleep(for: .milliseconds(500))
                return (200, Data(Self.osmBody.utf8))
            }
            return (500, Data())
        }
        let result = try await source(http, facts: nil, grace: .milliseconds(50)).candidates(around: here, language: .english)
        #expect(!result.osmFailed)
        #expect(result.candidates.map(\.name) == ["Burg", "Bank Austria", "Old Stone"])
    }
    @Test func bothFailingAfterADelayStillThrowsTheOSMError() async throws {
        let http = AsyncStubHTTPClient { request in
            if Self.isOverpass(request) {
                try await Task.sleep(for: .milliseconds(200))
                return (502, Data())
            }
            return (500, Data())
        }
        await #expect(throws: OverpassFailure.self) {
            _ = try await source(http, facts: nil, grace: .milliseconds(50)).candidates(around: here, language: .english)
        }
    }
    @Test func overpassFailingWithinTheGraceKeepsItsErrors() async throws {
        let http = AsyncStubHTTPClient { request in
            if Self.isOverpass(request) {
                try await Task.sleep(for: .milliseconds(100))
                return (502, Data())
            }
            return (200, Data(Self.wikiBody.utf8))
        }
        let result = try await source(http, facts: nil, grace: .seconds(30)).candidates(around: here, language: .english)
        #expect(result.osmFailed)
        #expect(result.osmErrors == ["overpass-api.de: HTTP 502", "overpass.kumi.systems: HTTP 502", "maps.mail.ru: HTTP 502"])
    }
    @Test func cancellationDuringTheGraceThrows() async {
        // The facts lookup flags when it returns, so the cancel lands after Wikipedia and the facts are in: the search
        // is then waiting out the 30 s grace (Overpass would take 60 s).
        let factsIn = LockedBox(false)
        let facts = PlaceFactsLookup { ids in
            defer { factsIn.set(true) }
            return WikidataClient.Answer(answered: Set(ids))
        }
        let http = AsyncStubHTTPClient { request in
            if Self.isOverpass(request) {
                try await Task.sleep(for: .seconds(60))
                return (200, Data(Self.osmBody.utf8))
            }
            return (200, Data(Self.wikiBody.utf8))
        }
        let src = source(http, facts: facts, grace: .seconds(30))
        let here = self.here
        let task = Task { try await src.candidates(around: here, language: .english) }
        let clock = ContinuousClock()
        // Bounded: should the facts never be asked for, the test fails within 5 s instead of hanging.
        let deadline = clock.now + .seconds(5)
        while !factsIn.value {
            guard clock.now < deadline else {
                Issue.record("the facts lookup was not called within 5 s")
                task.cancel()
                return
            }
            await Task.yield()
        }
        // A moment for the group to take the Wikipedia part and start the timer.
        try? await Task.sleep(for: .milliseconds(50))
        let start = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(clock.now - start < .seconds(5))
    }
    @Test func wikipediaWithNoArticlesWaitsForOverpassFully() async throws {
        // Wikipedia answers at once with nothing; Overpass takes 0.5 s, more than the 0.05 s grace, and is still used.
        let http = AsyncStubHTTPClient { request in
            if Self.isOverpass(request) {
                try await Task.sleep(for: .milliseconds(500))
                return (200, Data(Self.osmBody.utf8))
            }
            return (200, Data(#"{"query":{"pages":[]}}"#.utf8))
        }
        let result = try await source(http, facts: nil, grace: .milliseconds(50)).candidates(around: here, language: .english)
        #expect(!result.osmFailed && result.osmErrors.isEmpty)
        #expect(result.candidates.map(\.name) == ["Burg", "Bank Austria", "Old Stone"])
    }
    @Test func blankNamesAreNotListedAsDropped() {
        let blank = Candidate(id: "wiki:it/9", name: " ", coordinate: here, kind: "wikipedia", wikidata: "Q9")
        let order = Candidate(id: "wiki:it/2", name: "Jesuittordenen", coordinate: here, kind: "wikipedia", wikidata: "Q2")
        let enriched = PlaceFactsEnrichment([blank, order], facts: ["Q9": PlaceFacts(sitelinks: 1, placeClass: .nonPlace),
                                                                   "Q2": PlaceFacts(sitelinks: 119, placeClass: .nonPlace)])
        #expect(enriched.dropped == ["Jesuittordenen"])
        // Both still got facts.
        #expect(enriched.factsCount == 2)
    }
    @Test func settlementsAndSmallAreasAreListedAsDropped() {
        // Spec 20.6: Rome (settlement) and a 19-sitelink area are dropped and listed; a 20-sitelink area stays
        // (Wiki-only), and an OSM-tagged settlement is the tags' business.
        let rome = Candidate(id: "wiki:no/1", name: "Roma", coordinate: here, kind: "wikipedia", wikidata: "Q220")
        let small = Candidate(id: "wiki:no/2", name: "Small gate", coordinate: here, kind: "wikipedia", wikidata: "Q2")
        let big = Candidate(id: "wiki:no/3", name: "Via del Corso", coordinate: here, kind: "wikipedia", wikidata: "Q3")
        let tagged = Candidate(id: "osm:node/4", name: "Borgo", coordinate: here, kind: "x", wikidata: "Q4",
                               tags: ["place": "suburb"])
        let enriched = PlaceFactsEnrichment([rome, small, big, tagged], facts: [
            "Q220": PlaceFacts(sitelinks: 344, placeClass: .settlement),
            "Q2": PlaceFacts(sitelinks: 19, placeClass: .area),
            "Q3": PlaceFacts(sitelinks: 20, placeClass: .area),
            "Q4": PlaceFacts(sitelinks: 21, placeClass: .settlement),
        ])
        #expect(enriched.dropped == ["Roma", "Small gate"])
        #expect(enriched.factsCount == 4)
    }
    @Test func cancellationFromTheFactsLookupPropagates() async {
        let cancelled = PlaceFactsLookup { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            _ = try await source(Self.stub(), facts: cancelled).candidates(around: here, language: .english)
        }
        let urlCancelled = PlaceFactsLookup { _ in throw URLError(.cancelled) }
        await #expect(throws: CancellationError.self) {
            _ = try await source(Self.stub(), facts: urlCancelled).candidates(around: here, language: .english)
        }
    }
    @Test func defaultGraceIsFiveSeconds() {
        #expect(WalkingPlaceSource.osmGrace == .seconds(5))
        #expect(PlaceSearchResult.slow == "slow")
    }
}

/// Like `StubHTTPClient`, but the handler is async, so a request can take time (or never answer until cancelled).
final class AsyncStubHTTPClient: HTTPClient, @unchecked Sendable {
    private let handler: @Sendable (URLRequest) async throws -> (Int, Data)
    private let recorded = LockedBox<[URLRequest]>([])

    init(_ handler: @escaping @Sendable (URLRequest) async throws -> (Int, Data)) {
        self.handler = handler
    }

    var requests: [URLRequest] { recorded.value }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.withValue { $0.append(request) }
        let (status, data) = try await handler(request)
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://stub.invalid")!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        return (data, response)
    }

    func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let (data, response) = try await send(request)
        return (AsyncThrowingStream(lines: ServerSentEventLineSplitter.lines(in: data)), response)
    }
}
