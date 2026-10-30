import Testing
import Foundation
@testable import MyGuideCore

@Suite struct PlaceFactsTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let month: TimeInterval = 30 * 24 * 3600

    static func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("place-facts-\(UUID().uuidString)")
    }
    /// Answers every asked id as a place with 10 sitelinks.
    static func client() -> (WikidataClient, StubHTTPClient) {
        let http = StubHTTPClient { r in
            let ids = WikidataClientTests.askedIds(r)
            return (200, WikidataClientTests.body(ids.map { WikidataClientTests.row($0, n: 10, place: true) }))
        }
        return (WikidataClient(http: http), http)
    }
    static let place10 = PlaceFacts(sitelinks: 10, placeClass: .place)

    @Test func hitWithin30DaysMakesNoRequest() async throws {
        let (client, http) = Self.client()
        let clock = LockedBox(t0)
        let cache = PlaceFactsCache(directory: Self.tempDir()) { clock.value }
        _ = try await cache.facts(for: ["Q1"], client: client)
        // Exactly 30 days later is still a hit (age 2 592 000 s ≤ 2 592 000 s).
        clock.set(t0.addingTimeInterval(Self.month))
        let again = try await cache.facts(for: ["Q1"], client: client)
        #expect(again == ["Q1": Self.place10])
        #expect(http.requests.count == 1)
    }

    @Test func refetchesAt30DaysPlusOneSecond() async throws {
        let (client, http) = Self.client()
        let clock = LockedBox(t0)
        let cache = PlaceFactsCache(directory: Self.tempDir()) { clock.value }
        _ = try await cache.facts(for: ["Q1"], client: client)
        // 30 d + 1 s = 2 592 001 s > 2 592 000 s.
        clock.set(t0.addingTimeInterval(Self.month + 1))
        _ = try await cache.facts(for: ["Q1"], client: client)
        #expect(http.requests.count == 2)
    }

    @Test func onlyMissingIdsAreRequested() async throws {
        let (client, http) = Self.client()
        let cache = PlaceFactsCache(directory: nil) { t0 }
        _ = try await cache.facts(for: ["Q1", "Q2"], client: client)
        let f = try await cache.facts(for: ["Q2", "Q3", "Q3", "bad"], client: client)
        #expect(Set(f.keys) == ["Q2", "Q3"])
        #expect(http.requests.count == 2 && WikidataClientTests.idCount(http.requests[1]) == 1)
    }

    @Test func survivesNewInstanceOnSameDirectory() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (client, http) = Self.client()
        _ = try await PlaceFactsCache(directory: dir) { t0 }.facts(for: ["Q1"], client: client)
        let f = try await PlaceFactsCache(directory: dir) { t0.addingTimeInterval(3600) }.facts(for: ["Q1"], client: client)
        #expect(f == ["Q1": Self.place10])
        #expect(http.requests.count == 1)
    }

    @Test func memoryOnlyCacheWorks() async throws {
        let (client, http) = Self.client()
        let cache = PlaceFactsCache(directory: nil) { t0 }
        _ = try await cache.facts(for: ["Q1"], client: client)
        #expect(try await cache.facts(for: ["Q1"], client: client) == ["Q1": Self.place10])
        #expect(http.requests.count == 1)
        // A new instance starts empty.
        _ = try await PlaceFactsCache(directory: nil) { t0 }.facts(for: ["Q1"], client: client)
        #expect(http.requests.count == 2)
    }

    @Test func corruptFileIsIgnoredAndRewritten() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent(PlaceFactsCache.fileName))
        let (client, http) = Self.client()
        let f = try await PlaceFactsCache(directory: dir) { t0 }.facts(for: ["Q1"], client: client)
        #expect(f == ["Q1": Self.place10])
        let again = try await PlaceFactsCache(directory: dir) { t0 }.facts(for: ["Q1"], client: client)
        #expect(again == f && http.requests.count == 1)
    }

    @Test func answersStoredUnderTheOldClassRuleAreDiscarded() async throws {
        // A file of the first format (area beat place) holds a fresh Q1 answer as `area`. The new cache ignores it,
        // asks again, removes the old file and writes the new one.
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = dir.appendingPathComponent("place-facts.json")
        let stamp = t0.timeIntervalSince1970
        try Data(#"{"Q1":{"facts":{"sitelinks":58,"placeClass":"area"},"fetchedAt":\#(stamp)}}"#.utf8).write(to: legacy)
        #expect(PlaceFactsCache.fileName != "place-facts.json")
        #expect(PlaceFactsCache.legacyFileNames.contains("place-facts.json"))
        let (client, http) = Self.client()
        let f = try await PlaceFactsCache(directory: dir) { t0 }.facts(for: ["Q1"], client: client)
        #expect(f == ["Q1": Self.place10] && http.requests.count == 1)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(PlaceFactsCache.fileName).path))
    }

    @Test func answersStoredUnderTheSecondClassRuleAreDiscarded() async throws {
        // Spec 20.6 changed the classes (settlement, hill, island, organisations that are works of art): a fresh
        // answer in place-facts-v2.json is ignored, asked again, and the old file removed.
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let v2 = dir.appendingPathComponent("place-facts-v2.json")
        let stamp = t0.timeIntervalSince1970
        try Data(#"{"Q1":{"facts":{"sitelinks":83,"placeClass":"place"},"fetchedAt":\#(stamp)}}"#.utf8).write(to: v2)
        #expect(PlaceFactsCache.fileName == "place-facts-v5.json")
        #expect(PlaceFactsCache.legacyFileNames == ["place-facts.json", "place-facts-v2.json", "place-facts-v3.json",
                                                    "place-facts-v4.json"])
        let (client, http) = Self.client()
        let f = try await PlaceFactsCache(directory: dir) { t0 }.facts(for: ["Q1"], client: client)
        #expect(f == ["Q1": Self.place10] && http.requests.count == 1)
        #expect(!FileManager.default.fileExists(atPath: v2.path))
    }

    @Test func cappedLookupPassesTheCapToTheClient() async throws {
        // 450 missing ids with cap 16 → 16 requests of 25 (400 ids); the 50 left out are not answered and not stored.
        let (client, http) = Self.client()
        let cache = PlaceFactsCache(directory: nil) { t0 }
        let ids = WikidataClientTests.ids(450)
        let answer = try await cache.lookup(ids: ids, client: client, maxBatches: 16)
        #expect(http.requests.count == 16 && answer.answered == Set(ids.prefix(400)) && answer.facts.count == 400)
        // A second call asks only for the 50 left out (two requests of 25).
        _ = try await cache.lookup(ids: ids, client: client, maxBatches: 16)
        #expect(http.requests.count == 18 && http.requests.suffix(2).map(WikidataClientTests.idCount) == [25, 25])
    }

    @Test func failedLookupIsNotStored() async throws {
        let failing = StubHTTPClient { _ in (500, Data()) }
        let cache = PlaceFactsCache(directory: nil) { t0 }
        #expect(try await cache.facts(for: ["Q1"], client: WikidataClient(http: failing)).isEmpty)
        let (client, http) = Self.client()
        #expect(try await cache.facts(for: ["Q1"], client: client) == ["Q1": Self.place10])
        #expect(http.requests.count == 1)
    }

    @Test func cancellationPropagates() async {
        let http = StubHTTPClient { _ in throw CancellationError() }
        let cache = PlaceFactsCache(directory: nil) { t0 }
        await #expect(throws: CancellationError.self) { try await cache.facts(for: ["Q1"], client: WikidataClient(http: http)) }
    }

    @Test func expiredEntriesArePrunedOnSave() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (client, _) = Self.client()
        let clock = LockedBox(t0)
        let cache = PlaceFactsCache(directory: dir) { clock.value }
        _ = try await cache.facts(for: ["Q1"], client: client)
        clock.set(t0.addingTimeInterval(Self.month + 10))
        _ = try await cache.facts(for: ["Q2"], client: client)
        let data = try Data(contentsOf: dir.appendingPathComponent(PlaceFactsCache.fileName))
        let keys = (try JSONSerialization.jsonObject(with: data) as! [String: Any]).keys
        #expect(Set(keys) == ["Q2"])
    }

    @Test func answeredIdWithoutRowGetsSevenDayNegativeEntry() async throws {
        let http = StubHTTPClient { r in
            // Only Q1 has a row; Q2 is answered without one.
            (200, WikidataClientTests.body([WikidataClientTests.row("Q1", n: 10, place: true)]))
        }
        let client = WikidataClient(http: http)
        let clock = LockedBox(t0)
        let cache = PlaceFactsCache(directory: nil) { clock.value }
        #expect(try await cache.facts(for: ["Q1", "Q2"], client: client) == ["Q1": Self.place10])
        // 7 d = 604 800 s: still a hit, no request.
        clock.set(t0.addingTimeInterval(7 * 24 * 3600))
        let hit = try await cache.lookup(ids: ["Q2"], client: client)
        #expect(hit.facts.isEmpty && hit.answered == ["Q2"] && http.requests.count == 1)
        // 7 d + 1 s = 604 801 s: asked again.
        clock.set(t0.addingTimeInterval(7 * 24 * 3600 + 1))
        _ = try await cache.facts(for: ["Q2"], client: client)
        #expect(http.requests.count == 2)
        // Q1 (positive) is still fresh at 7 d + 1 s.
        _ = try await cache.facts(for: ["Q1"], client: client)
        #expect(http.requests.count == 2)
    }

    @Test func idInFailedBatchIsNotCachedNegatively() async throws {
        let failing = StubHTTPClient { _ in (500, Data()) }
        let cache = PlaceFactsCache(directory: nil) { t0 }
        let a = try await cache.lookup(ids: ["Q1"], client: WikidataClient(http: failing))
        #expect(a.facts.isEmpty && a.answered.isEmpty && a.failedBatches == 1)
        let (client, http) = Self.client()
        #expect(try await cache.facts(for: ["Q1"], client: client) == ["Q1": Self.place10])
        #expect(http.requests.count == 1)
    }

    @Test func negativeAgeCountsAsExpired() async throws {
        let (client, http) = Self.client()
        let clock = LockedBox(t0)
        let cache = PlaceFactsCache(directory: nil) { clock.value }
        _ = try await cache.facts(for: ["Q1"], client: client)
        // The clock is set back 1 s: age -1 s is not fresh.
        clock.set(t0.addingTimeInterval(-1))
        _ = try await cache.facts(for: ["Q1"], client: client)
        #expect(http.requests.count == 2)
    }

    @Test func expiredEntriesArePrunedOnLoad() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (client, _) = Self.client()
        _ = try await PlaceFactsCache(directory: dir) { t0 }.facts(for: ["Q1"], client: client)
        let file = dir.appendingPathComponent(PlaceFactsCache.fileName)
        let later = t0.addingTimeInterval(Self.month + 10)
        // A hit-only call on a new instance writes nothing, so check the loaded state through a second fetch:
        // Q1 expired on load (refetch), Q2 is fetched; the file then holds both, freshly stamped.
        let cache = PlaceFactsCache(directory: dir) { later }
        _ = try await cache.facts(for: ["Q2"], client: client)
        let keys = (try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]).keys
        #expect(Set(keys) == ["Q2"])
    }

    @Test func concurrentLookupsOfTheSameIdsShareOneRequest() async throws {
        let count = LockedBox(0)
        let http = SlowHTTP(count: count) { r in
            WikidataClientTests.body(WikidataClientTests.askedIds(r).map { WikidataClientTests.row($0, n: 10, place: true) })
        }
        let client = WikidataClient(http: http)
        let cache = PlaceFactsCache(directory: nil) { t0 }
        async let a = cache.facts(for: ["Q1", "Q2"], client: client)
        async let b = cache.facts(for: ["Q1", "Q2"], client: client)
        async let c = cache.facts(for: ["Q2", "Q3"], client: client)
        let (ra, rb, rc) = try await (a, b, c)
        #expect(ra == ["Q1": Self.place10, "Q2": Self.place10] && rb == ra)
        #expect(rc == ["Q2": Self.place10, "Q3": Self.place10])
        // The two identical lookups share one request; the third asks only for Q3 (Q2 is in flight): 2 requests.
        #expect(count.value == 2)
        // The slow answers were stored: a repeat makes no request.
        _ = try await cache.facts(for: ["Q1", "Q2", "Q3"], client: client)
        #expect(count.value == 2)
    }

    @Test func failedSharedRequestFailsNobodyButCountsFailures() async throws {
        let count = LockedBox(0)
        let http = SlowHTTP(count: count, status: 500) { _ in Data() }
        let cache = PlaceFactsCache(directory: nil) { t0 }
        let client = WikidataClient(http: http)
        async let a = cache.lookup(ids: ["Q1"], client: client)
        async let b = cache.lookup(ids: ["Q1"], client: client)
        let (ra, rb) = try await (a, b)
        // One shared request, retried once as a single half (one id): 2 requests (spec 20.2.7).
        #expect(ra.facts.isEmpty && rb.facts.isEmpty && count.value == 2)
        #expect(ra.failedBatches == 1 && rb.failedBatches == 1)
    }

    // MARK: Deadline (spec 20.6.3)

    @Test func aDeadlineReturnsAndStoresWhatAnswered() async throws {
        // 60 ids, the second batch (Q26…Q50) hangs: at a 300 ms deadline the cache returns the 35 answered ids with one
        // failed batch, and stores them: a repeat for the answered ids makes no request.
        let http = WikidataClientTests.hangingSecondBatch()
        let client = WikidataClient(http: http)
        let cache = PlaceFactsCache(directory: nil) { t0 }
        let answer = try await cache.lookup(ids: WikidataClientTests.ids(60), client: client,
                                            deadline: .now + .milliseconds(300))
        #expect(answer.answered.count == 35 && answer.failedBatches == 1)
        let requests = http.requests.count
        let again = try await cache.lookup(ids: WikidataClientTests.ids(25), client: client)
        #expect(again.answered == Set(WikidataClientTests.ids(25)) && http.requests.count == requests)
    }
    @Test func waitingForAnotherCallersRequestStopsAtTheDeadline() async throws {
        // A first caller without a deadline starts the request for Q1, which never answers. A second caller with a
        // 300 ms deadline waits on that request only until its deadline: nothing answered, one failed batch.
        let http = AsyncStubHTTPClient { _ in
            try await Task.sleep(for: .seconds(60))
            return (200, WikidataClientTests.body([]))
        }
        let client = WikidataClient(http: http)
        let cache = PlaceFactsCache(directory: nil) { t0 }
        let first = Task { try await cache.lookup(ids: ["Q1"], client: client) }
        defer { first.cancel() }
        while http.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let start = ContinuousClock.now
        let answer = try await cache.lookup(ids: ["Q1"], client: client, deadline: start + .milliseconds(300))
        #expect(answer.answered.isEmpty && answer.failedBatches == 1)
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(http.requests.count == 1)
    }

    // MARK: applying

    @Test func applyingSetsFactsByWikidataId() {
        let a = Candidate(id: "a", name: "A", coordinate: .init(latitude: 0, longitude: 0), kind: "wikipedia", wikidata: "Q1")
        let noId = Candidate(id: "b", name: "B", coordinate: .init(latitude: 0, longitude: 0), kind: "wikipedia")
        let noFacts = Candidate(id: "c", name: "C", coordinate: .init(latitude: 0, longitude: 0), kind: "wikipedia", wikidata: "Q2")
        let out = [a, noId, noFacts].applying(["Q1": PlaceFacts(sitelinks: 33, placeClass: .area)])
        #expect(out[0].sitelinks == 33 && out[0].placeClass == .area)
        #expect(out[0].id == "a" && out[0].name == "A")
        #expect(out[1] == noId)
        #expect(out[2] == noFacts)
        #expect(out.count == 3)
    }

    @Test func oldCandidateJSONDecodes() throws {
        let json = #"{"id":"osm:node/1","name":"X","coordinate":{"latitude":1,"longitude":2},"kind":"historic=castle"}"#
        let c = try JSONDecoder().decode(Candidate.self, from: Data(json.utf8))
        #expect(c.sitelinks == nil && c.placeClass == nil)
        let round = try JSONDecoder().decode(Candidate.self, from: JSONEncoder().encode(
            Candidate(id: "w", name: "W", coordinate: c.coordinate, kind: "wikipedia", sitelinks: 5, placeClass: .nonPlace)))
        #expect(round.sitelinks == 5 && round.placeClass == .nonPlace)
    }

    // MARK: - Spec 20.2.6: story-language titles

    /// Answers every asked id as a place with 10 sitelinks, titled "no-<id>" when the query asks for Norwegian titles.
    static func titledClient() -> (WikidataClient, StubHTTPClient) {
        let http = StubHTTPClient { r in
            let ids = WikidataClientTests.askedIds(r)
            let titled = WikidataClientTests.sparql(r).contains("no.wikipedia.org")
            return (200, WikidataClientTests.body(ids.map {
                WikidataClientTests.row($0, n: 10, title: titled ? "no-\($0)" : nil, place: true)
            }))
        }
        return (WikidataClient(http: http), http)
    }

    @Test func cacheKeepsTitlesPerLanguage() async throws {
        // Norwegian and plain (English) answers for Q1 are stored apart: each asks once, and a repeat asks nothing.
        let (client, http) = Self.titledClient()
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = PlaceFactsCache(directory: dir) { t0 }
        let no = try await cache.facts(for: ["Q1"], client: client, language: .norwegian)
        let en = try await cache.facts(for: ["Q1"], client: client, language: .english)
        #expect(no == ["Q1": PlaceFacts(sitelinks: 10, placeClass: .place, localTitle: "no-Q1")])
        #expect(en == ["Q1": Self.place10])
        #expect(http.requests.count == 2)
        _ = try await cache.facts(for: ["Q1"], client: client, language: .norwegian)
        _ = try await cache.facts(for: ["Q1"], client: client)
        #expect(http.requests.count == 2)
        // And on disk: a new cache over the same file answers both without a request.
        let reloaded = PlaceFactsCache(directory: dir) { t0 }
        #expect(try await reloaded.facts(for: ["Q1"], client: client, language: .norwegian)["Q1"]?.localTitle == "no-Q1")
        #expect(http.requests.count == 2)
    }
    @Test func lookupPassesTheLanguageThroughTheCache() async throws {
        let (client, _) = Self.titledClient()
        let lookup = PlaceFactsLookup(cache: PlaceFactsCache(directory: nil) { t0 }, client: client)
        let answer = try await lookup.answer(for: ["Q7"], language: .norwegian)
        #expect(answer.facts["Q7"]?.localTitle == "no-Q7")
    }
    @Test func applyingSetsIsArt() {
        let here = Coordinate(latitude: 41.9, longitude: 12.48)
        let fountain = Candidate(id: "wiki:it/1", name: "Barcaccia", coordinate: here, kind: "wikipedia", wikidata: "Q1")
        let church = Candidate(id: "wiki:it/2", name: "Gesù", coordinate: here, kind: "wikipedia", wikidata: "Q2")
        let applied = [fountain, church].applying(["Q1": PlaceFacts(sitelinks: 32, placeClass: .place, isArt: true),
                                                   "Q2": PlaceFacts(sitelinks: 40, placeClass: .place)])
        #expect(applied.map(\.isArt) == [true, false])
        #expect(fountain.isArt == nil)
    }
    @Test func englishCandidateTakesTheStoryLanguageTitle() {
        // Trevi: the English article (no Norwegian one has coordinates) gets the item's Norwegian title. A Norwegian
        // article keeps its own; an OSM candidate keeps its OSM name; without a language nothing is renamed.
        let here = Coordinate(latitude: 41.9, longitude: 12.48)
        let trevi = Candidate(id: "wiki:en/1", name: "Trevi Fountain", coordinate: here, kind: "wikipedia",
                              wikipediaTitle: "en:Trevi Fountain", wikidata: "Q186579")
        let norsk = Candidate(id: "wiki:no/2", name: "Pantheon (Roma)", coordinate: here, kind: "wikipedia",
                              wikidata: "Q99309")
        let osm = Candidate(id: "osm:way/3", name: "Fontana di Trevi", coordinate: here, kind: "x", wikidata: "Q186579",
                            tags: ["amenity": "fountain"])
        let untitled = Candidate(id: "wiki:en/4", name: "Abbot Luigi", coordinate: here, kind: "wikipedia", wikidata: "Q4")
        let facts = ["Q186579": PlaceFacts(sitelinks: 68, placeClass: .place, localTitle: "Fontana di Trevi (no)"),
                     "Q99309": PlaceFacts(sitelinks: 81, placeClass: .place, localTitle: "Pantheon"),
                     "Q4": PlaceFacts(sitelinks: 2, placeClass: .unknown)]
        let applied = [trevi, norsk, osm, untitled].applying(facts, language: .norwegian)
        #expect(applied.map(\.name) == ["Fontana di Trevi (no)", "Pantheon (Roma)", "Fontana di Trevi", "Abbot Luigi"])
        // The id, article title and summary language stay: only the shown name changes.
        #expect(applied[0].id == "wiki:en/1" && applied[0].wikipediaTitle == "en:Trevi Fountain")
        #expect([trevi].applying(facts).map(\.name) == ["Trevi Fountain"])
        #expect([trevi].applying(facts, language: .english).map(\.name) == ["Trevi Fountain"])
    }

}

/// Answers after 100 ms and counts the requests.
private struct SlowHTTP: HTTPClient {
    let count: LockedBox<Int>
    var status = 200
    let body: @Sendable (URLRequest) -> Data

    init(count: LockedBox<Int>, status: Int = 200, body: @escaping @Sendable (URLRequest) -> Data) {
        self.count = count
        self.status = status
        self.body = body
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count.withValue { $0 += 1 }
        try await Task.sleep(for: .milliseconds(100))
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (body(request), response)
    }
}
