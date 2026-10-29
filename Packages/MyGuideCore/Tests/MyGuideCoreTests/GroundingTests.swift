import Foundation
import Testing
@testable import MyGuideCore

@Suite struct GroundingTests {
    // Offsets at the equator: 1 m ≈ 1/111_195 degree (R·π/180 = 111_194.93 m per degree)
    static let m = 1.0 / 111_195
    static func cand(_ id: String, n: Double, e: Double, name: String? = nil, wiki: String? = nil, q: String? = nil, summary: String? = nil) -> Candidate {
        Candidate(id: id, name: name ?? id, coordinate: .init(latitude: n * m, longitude: e * m), kind: "historic=yes",
                  summary: summary, wikipediaTitle: wiki, wikidata: q)
    }
    static func capture(heading: Double?, acc: Double?) -> CaptureContext {
        CaptureContext(coordinate: .init(latitude: 0, longitude: 0), horizontalAccuracy: 5, heading: heading,
                       headingAccuracy: acc, horizontalFOV: 55, takenAt: .now, source: .camera)
    }

    @Test func mergeByWikidataThenTitleAndDedupeByName() {
        let osm = [Self.cand("osm:node/1", n: 0, e: 0, name: "Michaelertor", q: "Q1"),
                   Self.cand("osm:way/2", n: 10, e: 0, name: "Hofburg", wiki: "en:Hofburg"),
                   Self.cand("osm:node/3", n: 20, e: 0, name: "hofburg")]          // 10 m from way/2, same name → dropped
        let wiki = [Self.cand("wiki:en/9", n: 0, e: 1, name: "St Michael's Gate", q: "Q1", summary: "Gate story."),
                    Self.cand("wiki:en/8", n: 10, e: 1, name: "Hofburg", wiki: "en:Hofburg", summary: "Palace story."),
                    Self.cand("wiki:en/7", n: 90, e: 0, name: "Loos House", summary: "Plain facade.")]
        let merged = CandidateRanker.merge(osm: osm, wiki: wiki)
        #expect(merged.map(\.id) == ["osm:node/1", "osm:way/2", "wiki:en/7"])
        #expect(merged[0].summary == "Gate story." && merged[1].summary == "Palace story.")
    }
    @Test func rankInViewFirstThenByDistance() {
        // heading 0, fov 55, acc 10 → half-width 27.5 + 20 = 47.5
        let a = Self.cand("A", n: 100, e: 0)                       // bearing 0,   100 m, in view
        let b = Self.cand("B", n: 0, e: 30)                        // bearing 90,   30 m, out
        let c = Self.cand("C", n: 200 * cos(.pi / 6), e: 100)      // bearing 30,  200 m, in view
        let d = Self.cand("D", n: -10, e: 0)                       // bearing 180,  10 m, out
        let r = CandidateRanker.rank([a, b, c, d], capture: Self.capture(heading: 0, acc: 10))
        #expect(r.map(\.candidate.id) == ["A", "C", "D", "B"])
        #expect(r.map(\.inView) == [true, true, false, false])
        #expect(abs(r[1].bearing - 30) < 0.01 && abs(r[1].distance - 200) < 0.5)
    }
    @Test func rankPutsWikiBackedPlacesFirstWithinEachViewGroup() {
        // heading 0, fov 55, acc 10 → half-width 47.5; everything north (bearing 0) is in view, south (180) is out
        let plaque = Self.cand("plaque", n: 10, e: 0)                          // 10 m, in view, no wiki
        let landmark = Self.cand("landmark", n: 60, e: 0, q: "Q1")            // 60 m, in view, wikidata
        let titled = Self.cand("titled", n: 80, e: 0, wiki: "en:Titled")       // 80 m, in view, article title
        let summarised = Self.cand("summarised", n: 90, e: 0, summary: "S.")  // 90 m, in view, summary
        let emptySummary = Self.cand("empty", n: 5, e: 0, summary: "")         // 5 m, in view, empty summary counts as none
        let behindWiki = Self.cand("behindWiki", n: -20, e: 0, q: "Q2")       // 20 m, out of view, wikidata
        let behindPlain = Self.cand("behindPlain", n: -5, e: 0)               // 5 m, out of view, no wiki
        let r = CandidateRanker.rank([plaque, landmark, titled, summarised, emptySummary, behindWiki, behindPlain],
                                     capture: Self.capture(heading: 0, acc: 10))
        // in view: wiki tier by distance (60, 80, 90), then plain tier by distance (5, 10); then out of view likewise
        #expect(r.map(\.candidate.id) == ["landmark", "titled", "summarised", "empty", "plaque", "behindWiki", "behindPlain"])
        // without a usable heading there is one group: wiki tier first, then by distance
        let noHeading = CandidateRanker.rank([plaque, landmark, behindPlain, behindWiki], capture: Self.capture(heading: 0, acc: 60))
        #expect(noHeading.map(\.candidate.id) == ["behindWiki", "landmark", "behindPlain", "plaque"])
    }
    @Test func rankWithoutUsableHeadingIsByDistanceAndInViewNil() {
        let r = CandidateRanker.rank([Self.cand("A", n: 100, e: 0), Self.cand("D", n: -10, e: 0)], capture: Self.capture(heading: 0, acc: 60))
        #expect(r.map(\.candidate.id) == ["D", "A"] && r.allSatisfy { $0.inView == nil })
    }
    @Test func rankCapsAtFifteen() {
        let many = (1...40).map { Self.cand("c\($0)", n: Double($0), e: 0) }
        #expect(CandidateRanker.rank(many, capture: Self.capture(heading: nil, acc: nil)).count == 15)
    }

    struct Geo: ReverseGeocoding { var fail = false
        func address(for: Coordinate) async throws -> Address {
            if fail { throw URLError(.timedOut) }
            return Address(line: "Michaelerplatz", city: "Vienna", country: "Austria")
        }
    }
    static let osmJSON = #"{"elements":[{"type":"node","id":1,"lat":0.0009,"lon":0,"tags":{"name":"Gate","historic":"yes"}}]}"#
    static let wikiJSON = #"{"query":{"pages":[{"pageid":5,"title":"Palace","extract":"Old.","coordinates":[{"lat":0.0005,"lon":0}]}]}}"#
    func service(osmStatus: Int = 200, geoFail: Bool = false) -> GroundingService {
        let http = StubHTTPClient { r in
            r.url!.host!.contains("overpass") ? (osmStatus, Data(Self.osmJSON.utf8)) : (200, Data(Self.wikiJSON.utf8))
        }
        return GroundingService(overpass: .init(http: http), wikipedia: .init(http: http), geocoder: Geo(fail: geoFail))
    }

    @Test func groundsFromAllSources() async throws {
        let g = try await service().ground(Self.capture(heading: 0, acc: 10), language: .english)
        #expect(g.candidates.map(\.candidate.name) == ["Palace", "Gate"])
        #expect(g.address?.display == "Michaelerplatz, Vienna, Austria" && g.failedSources.isEmpty)
    }
    @Test func overpassFailureStillGroundsOnWikipedia() async throws {
        let g = try await service(osmStatus: 504).ground(Self.capture(heading: 0, acc: 10), language: .english)
        #expect(g.candidates.map(\.candidate.name) == ["Palace"] && g.failedSources == [.openStreetMap])
    }
    @Test func geocoderFailureLeavesAddressNil() async throws {
        let g = try await service(geoFail: true).ground(Self.capture(heading: 0, acc: 10), language: .english)
        #expect(g.address == nil && g.failedSources == [.geocoder])
    }
    @Test func noPositionThrows() async {
        var cap = Self.capture(heading: 0, acc: 10); cap.coordinate = nil
        await #expect(throws: GroundingError.noPosition) { try await service().ground(cap, language: .english) }
    }

    struct CancellingGeo: ReverseGeocoding {
        func address(for: Coordinate) async throws -> Address { throw CancellationError() }
    }
    @Test func sourceCancellationPropagatesFromHTTP() async {
        let http = StubHTTPClient { r in
            if r.url!.host!.contains("overpass") { throw CancellationError() }
            return (200, Data(Self.wikiJSON.utf8))
        }
        let s = GroundingService(overpass: .init(http: http), wikipedia: .init(http: http), geocoder: Geo())
        await #expect(throws: CancellationError.self) { try await s.ground(Self.capture(heading: 0, acc: 10), language: .english) }
    }
    @Test func geocoderCancellationPropagates() async {
        let http = StubHTTPClient { _ in (200, Data(Self.wikiJSON.utf8)) }
        let s = GroundingService(overpass: .init(http: http), wikipedia: .init(http: http), geocoder: CancellingGeo())
        await #expect(throws: CancellationError.self) { try await s.ground(Self.capture(heading: 0, acc: 10), language: .english) }
    }
    @Test func allSourcesFailingYieldsEmptyGroundingWithAllFailed() async throws {
        let http = StubHTTPClient { _ in (500, Data()) }
        let s = GroundingService(overpass: .init(http: http), wikipedia: .init(http: http), geocoder: Geo(fail: true))
        let g = try await s.ground(Self.capture(heading: 0, acc: 10), language: .english)
        #expect(g.candidates.isEmpty && g.address == nil && g.failedSources == [.openStreetMap, .wikipedia, .geocoder])
    }

    @Test func mergeKeepsOSMTags() {
        var o = Self.cand("osm:node/1", n: 0, e: 0, name: "Gate", q: "Q1")
        o.tags = ["historic": "city_gate"]
        let wiki = [Self.cand("wiki:en/9", n: 0, e: 1, name: "The Gate", q: "Q1", summary: "Gate story.")]
        let merged = CandidateRanker.merge(osm: [o], wiki: wiki)
        #expect(merged.count == 1)
        #expect(merged[0].tags == ["historic": "city_gate"] && merged[0].summary == "Gate story.")
    }
    @Test func candidateDecodesWithoutTags() throws {
        let json = #"{"id":"osm:node/1","name":"A","coordinate":{"latitude":1,"longitude":2},"kind":"historic=yes"}"#
        let c = try JSONDecoder().decode(Candidate.self, from: Data(json.utf8))
        #expect(c.tags == nil && c.name == "A")
        let round = try JSONDecoder().decode(Candidate.self, from: JSONEncoder().encode(c))
        #expect(round == c)
    }
    @Test func droppedDuplicateDonatesSummaryAndWikiTagsToKeptTwin() {
        let osm = [Self.cand("osm:way/1", n: 0, e: 0, name: "Hofburg"),
                   Self.cand("osm:way/2", n: 20, e: 0, name: "Hofburg", q: "Q9")]
        let wiki = [Self.cand("wiki:en/1", n: 5, e: 0, name: "Hofburg Palace", q: "Q9", summary: "Palace story.")]
        let merged = CandidateRanker.merge(osm: osm, wiki: wiki)
        #expect(merged.map(\.id) == ["osm:way/1"])
        #expect(merged[0].summary == "Palace story." && merged[0].wikidata == "Q9")
    }
    @Test func oneArticleEnrichesEveryMatchingOSMCandidateAndIsNotAppended() {
        let osm = [Self.cand("osm:way/1", n: 0, e: 0, name: "Wing A", q: "Q9"),
                   Self.cand("osm:way/2", n: 200, e: 0, name: "Wing B", q: "Q9")]
        let wiki = [Self.cand("wiki:en/1", n: 100, e: 0, name: "Palace", q: "Q9", summary: "Palace story.")]
        let merged = CandidateRanker.merge(osm: osm, wiki: wiki)
        #expect(merged.map(\.id) == ["osm:way/1", "osm:way/2"])
        #expect(merged.allSatisfy { $0.summary == "Palace story." })
    }
    @Test func cancelledTaskThrowsEvenWhenSourceFailsWithOtherError() async {
        let s = service(geoFail: true)
        let capture = Self.capture(heading: 0, acc: 10)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await s.ground(capture, language: .english)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    /// Sleeps 60 s but honours cancellation.
    struct SlowGeo: ReverseGeocoding {
        func address(for: Coordinate) async throws -> Address {
            try await Task.sleep(for: .seconds(60))
            return Address(line: "late", city: nil, country: nil)
        }
    }
    /// Never returns and ignores cancellation, like a MapKit request that does not answer.
    struct HangingGeo: ReverseGeocoding {
        func address(for: Coordinate) async throws -> Address {
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
            return Address(line: "never", city: nil, country: nil)
        }
    }
    func elapsed(_ work: () async throws -> Void) async rethrows -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        try await work()
        return clock.now - start
    }
    @Test(arguments: [false, true]) func geocoderTimeoutIsAFailureAndKeepsCandidates(ignoresCancellation: Bool) async throws {
        let http = StubHTTPClient { r in
            r.url!.host!.contains("overpass") ? (200, Data(Self.osmJSON.utf8)) : (200, Data(Self.wikiJSON.utf8))
        }
        let geo: ReverseGeocoding = ignoresCancellation ? HangingGeo() : SlowGeo()
        let s = GroundingService(overpass: .init(http: http), wikipedia: .init(http: http), geocoder: geo,
                                 geocoderTimeout: .milliseconds(50))
        var g: Grounding?
        let took = try await elapsed { g = try await s.ground(Self.capture(heading: 0, acc: 10), language: .english) }
        #expect(took < .seconds(1))
        #expect(g?.address == nil && g?.failedSources == [.geocoder])
        #expect(g?.candidates.map(\.candidate.name) == ["Palace", "Gate"])
    }
    /// Overpass hosts answer only after 60 s (cancellable, or ignoring cancellation); Wikipedia answers at once.
    struct SlowOverpassHTTP: HTTPClient {
        var ignoresCancellation: Bool
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url!.host!.contains("overpass") {
                if ignoresCancellation {
                    await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
                } else {
                    try await Task.sleep(for: .seconds(60))
                }
                return (Data(GroundingTests.osmJSON.utf8), response)
            }
            return (Data(GroundingTests.wikiJSON.utf8), response)
        }
    }
    @Test(arguments: [false, true]) func osmTimeoutIsAFailureAndThePhotoGoesOn(ignoresCancellation: Bool) async throws {
        let http = SlowOverpassHTTP(ignoresCancellation: ignoresCancellation)
        let s = GroundingService(overpass: .init(http: http), wikipedia: .init(http: http), geocoder: Geo(),
                                 osmTimeout: .milliseconds(50))
        var g: Grounding?
        let took = try await elapsed { g = try await s.ground(Self.capture(heading: 0, acc: 10), language: .english) }
        #expect(took < .seconds(1))
        #expect(g?.failedSources == [.openStreetMap])
        #expect(g?.candidates.map(\.candidate.name) == ["Palace"])
        #expect(g?.address?.line == "Michaelerplatz")
    }
    @Test func defaultOSMTimeoutIsFifteenSeconds() {
        // Two Overpass endpoints at 12 s each could take 24 s; the photo waits at most 15 s.
        #expect(GroundingService.defaultOSMTimeout == .seconds(15))
    }
    @Test func defaultGeocoderTimeoutIsEightSeconds() {
        #expect(GroundingService.defaultGeocoderTimeout == .seconds(8))
    }
    @Test func outerCancellationPropagatesWhileGeocoderHangs() async {
        let http = StubHTTPClient { r in
            r.url!.host!.contains("overpass") ? (200, Data(Self.osmJSON.utf8)) : (200, Data(Self.wikiJSON.utf8))
        }
        // A 60 s timeout proves the return comes from cancellation, not from the timeout.
        let s = GroundingService(overpass: .init(http: http), wikipedia: .init(http: http), geocoder: HangingGeo(),
                                 geocoderTimeout: .seconds(60))
        let capture = Self.capture(heading: 0, acc: 10)
        let task = Task { try await s.ground(capture, language: .english) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let took = await elapsed {
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        #expect(took < .seconds(1))
    }
    @Test func limitIsAppliedAfterSorting() {
        let near = (1...20).map { Self.cand("out\($0)", n: -Double($0), e: 0) }          // behind, out of view
        let far = (1...3).map { Self.cand("in\($0)", n: 100 + Double($0), e: 0) }         // ahead, in view
        let r = CandidateRanker.rank(near + far, capture: Self.capture(heading: 0, acc: 10))
        #expect(r.count == 15)
        #expect(r.prefix(3).map(\.candidate.id) == ["in1", "in2", "in3"])
    }
}

