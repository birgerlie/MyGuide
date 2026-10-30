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
        #expect(ra.facts.isEmpty && rb.facts.isEmpty && count.value == 1)
        #expect(ra.failedBatches == 1 && rb.failedBatches == 1)
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
