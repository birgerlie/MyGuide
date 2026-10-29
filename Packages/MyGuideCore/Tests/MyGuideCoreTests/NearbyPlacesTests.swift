import Foundation
import Testing
@testable import MyGuideCore

/// Counts calls; answers from `result`, or suspends until `resume` when `suspends` is set. Every suspended call
/// is kept and resumed, and calls after `resume` answer at once, so an implementation that wrongly starts a second
/// fetch fails the count instead of hanging.
private final class StubFetcher: NearbyFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var waiters: [CheckedContinuation<[Candidate], Error>] = []
    private var result: Result<[Candidate], Error>
    private let suspends: Bool
    private var released = false

    init(_ result: Result<[Candidate], Error>, suspends: Bool = false) {
        self.result = result
        self.suspends = suspends
    }

    var count: Int { lock.withLock { calls } }
    var isWaiting: Bool { lock.withLock { !waiters.isEmpty } }

    func set(_ result: Result<[Candidate], Error>) { lock.withLock { self.result = result } }

    func resume() {
        let (waiters, result) = lock.withLock { () -> ([CheckedContinuation<[Candidate], Error>], Result<[Candidate], Error>) in
            defer {
                self.waiters = []
                self.released = true
            }
            return (self.waiters, self.result)
        }
        for waiter in waiters { waiter.resume(with: result) }
    }

    func candidates(around: Coordinate, language: StoryLanguage) async throws -> [Candidate] {
        let (result, released) = lock.withLock { () -> (Result<[Candidate], Error>, Bool) in
            calls += 1
            return (self.result, self.released)
        }
        guard suspends, !released else { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiters.append(continuation) }
        }
    }
}

/// Records the titles asked for; answers "Text of <title>", or nil for `missing`.
private final class StubArticles: ArticleTextSource, @unchecked Sendable {
    private let asked = LockedBox<[String]>([])
    private let missing: Set<String>

    init(missing: Set<String> = []) { self.missing = missing }

    var titles: [String] { asked.value }

    func text(wikipediaTitle: String) async -> String? {
        asked.withValue { $0.append(wikipediaTitle) }
        return missing.contains(wikipediaTitle) ? nil : "Text of \(wikipediaTitle)"
    }
}

private struct Boom: Error {}

@Suite struct NearbyPlacesTests {
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func castle(_ name: String, north: Double, title: String? = nil) -> Candidate {
        Candidate(id: "osm:node/\(name)", name: name, coordinate: .at(north: north), kind: "historic=castle",
                  wikipediaTitle: title, tags: ["name": name, "historic": "castle"])
    }

    static func cafe(_ name: String, north: Double, title: String? = nil) -> Candidate {
        Candidate(id: "osm:node/\(name)", name: name, coordinate: .at(north: north), kind: "amenity=cafe",
                  wikipediaTitle: title, tags: ["name": name, "amenity": "cafe"])
    }

    static func list(fetchedAt: Date = t0, language: StoryLanguage = .english,
                     candidates: [Candidate] = [castle("Burg", north: 30)]) -> NearbyList {
        NearbyList(centre: .at(), fetchedAt: fetchedAt, language: language, candidates: candidates,
                   articleTexts: ["en:Burg": "A castle."])
    }

    static func places(_ fetcher: NearbyFetching, articles: ArticleTextSource? = nil, store: NearbyListStore? = nil,
                       clock: LockedBox<Date>) -> NearbyPlaces {
        NearbyPlaces(fetcher: fetcher, articles: articles, store: store, now: { clock.value })
    }

    static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("NearbyPlacesTests-\(UUID().uuidString)")
    }

    /// Polls (yielding) until `condition` holds or `limit` yields have passed.
    static func waitUntil(limit: Int = 100_000, _ condition: () -> Bool) async {
        var n = 0
        while !condition() && n < limit {
            await Task.yield()
            n += 1
        }
    }

    /// Polls (yielding) until `count` callers await an English fetch, or `limit` yields have passed.
    static func waitForCallers(_ count: Int, on places: NearbyPlaces, limit: Int = 100_000) async {
        var n = 0
        while await places.callersWaiting(language: .english) < count && n < limit {
            await Task.yield()
            n += 1
        }
    }

    // MARK: - NearbyList

    @Test func constants() {
        #expect(NearbyList.freshAge == 600)
        #expect(NearbyList.freshDistance == 250)
        #expect(NearbyPlaces.foregroundDistance == 150)
        #expect(NearbyPlaces.foregroundInterval == 60)
        #expect(NearbyPlaces.walkingDistance == 250)
        #expect(NearbyPlaces.backgroundMaxSpeed == 8)
        #expect(NearbyPlaces.backgroundInterval == 600)
        #expect(NearbyPlaces.articleCount == 5)
    }

    @Test func freshnessBoundaries() {
        let list = Self.list()
        let t0 = Self.t0
        // Age: t0+600 − t0 = 600 ≤ 600 → fresh; t0+601 − t0 = 601 > 600 → not fresh.
        #expect(list.isFresh(for: .at(), now: t0.addingTimeInterval(600)))
        #expect(!list.isFresh(for: .at(), now: t0.addingTimeInterval(601)))
        // Distance from the centre (0, 0): `.at(north: d)` is d metres up to floating point (250 may come out as
        // 250.00000000000003), so the boundary is probed just inside and outside: 249.9 ≤ 250 fresh, 250.1 > 250 not.
        #expect(list.isFresh(for: .at(north: 249.9), now: t0))
        #expect(!list.isFresh(for: .at(north: 250.1), now: t0))
        // 251 > 250 → not fresh, even at age 0.
        #expect(!list.isFresh(for: .at(north: 251), now: t0))
        // Both limits at once: 249.9 m and 600 s → fresh.
        #expect(list.isFresh(for: .at(north: 249.9), now: t0.addingTimeInterval(600)))
        // A list from the future (clock set back): age t0−1 − t0 = −1 is not trusted as fresh.
        #expect(!list.isFresh(for: .at(), now: t0.addingTimeInterval(-1)))
    }

    @Test func servesWalkerBoundaries() {
        let list = Self.list()   // centre (0, 0), fetched at t0
        let t0 = Self.t0
        // Distance: `.at(north: d)` is d metres up to floating point, so probe either side of 250:
        // 249.9 < 250 → serves; 250.1 ≥ 250 → does not.
        #expect(list.serves(walkerAt: .at(north: 249.9), now: t0))
        #expect(!list.serves(walkerAt: .at(north: 250.1), now: t0))
        // Age: t0+600 − t0 = 600 ≤ 600 → serves; t0+601 − t0 = 601 > 600 → does not.
        #expect(list.serves(walkerAt: .at(), now: t0.addingTimeInterval(600)))
        #expect(!list.serves(walkerAt: .at(), now: t0.addingTimeInterval(601)))
        // Both limits at once: 249.9 m and 600 s → serves; 249.9 m and 601 s → does not.
        #expect(list.serves(walkerAt: .at(north: 249.9), now: t0.addingTimeInterval(600)))
        #expect(!list.serves(walkerAt: .at(north: 249.9), now: t0.addingTimeInterval(601)))
        // A list from the future (clock set back): age t0−1 − t0 = −1 → does not serve.
        #expect(!list.serves(walkerAt: .at(), now: t0.addingTimeInterval(-1)))
    }

    @Test func walkingRefreshesExactlyWhenTheListDoesNotServe() async throws {
        let clock = LockedBox(Self.t0)
        let places = Self.places(StubFetcher(.success([Self.castle("Burg", north: 30)])), clock: clock)
        let list = try await places.refresh(at: .at(), language: .english)   // list and attempt at t0, centre (0, 0)
        // t0+61: past the 60 s attempt interval (61 ≥ 60), so only the list decides.
        let now = Self.t0.addingTimeInterval(61)
        clock.set(now)
        for north in [0.0, 249.9, 250.1, 400] {
            let position = Coordinate.at(north: north)
            #expect(await places.shouldRefresh(at: position, trigger: .walking, language: .english)
                    == !list.serves(walkerAt: position, now: now))
        }
    }

    @Test func backgroundMayRefreshGates() async throws {
        let clock = LockedBox(Self.t0)
        let fetcher = StubFetcher(.success([Self.castle("Burg", north: 30)]))
        let places = Self.places(fetcher, clock: clock)
        // Nothing fetched yet: slow or unknown speed → true; 8.1 > 8 → false; 8.0 is not above 8 → true.
        #expect(await places.backgroundMayRefresh(speed: 1, language: .english))
        #expect(await places.backgroundMayRefresh(speed: nil, language: .english))
        #expect(await !places.backgroundMayRefresh(speed: 8.1, language: .english))
        #expect(await places.backgroundMayRefresh(speed: 8.0, language: .english))

        try await places.refresh(at: .at(), language: .english)   // refresh and attempt at t0
        // t0+599: 599 < 600 since the last refresh → false.
        clock.set(Self.t0.addingTimeInterval(599))
        #expect(await !places.backgroundMayRefresh(speed: 1, language: .english))
        // t0+600: 600 is not < 600 → true (and 600 ≥ 60 since the attempt).
        clock.set(Self.t0.addingTimeInterval(600))
        #expect(await places.backgroundMayRefresh(speed: 1, language: .english))

        // A failed attempt at t0+600 holds the gate for 60 s: t0+659 → 59 < 60 → false; t0+660 → 60 → true.
        fetcher.set(.failure(URLError(.notConnectedToInternet)))
        _ = try? await places.refresh(at: .at(), language: .english)
        clock.set(Self.t0.addingTimeInterval(659))
        #expect(await !places.backgroundMayRefresh(speed: 1, language: .english))
        clock.set(Self.t0.addingTimeInterval(660))
        #expect(await places.backgroundMayRefresh(speed: 1, language: .english))
    }

    @Test func backgroundMayRefreshUsesTheStoredRefreshTime() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NearbyListStore(directory: directory)
        try store.save(Self.list(fetchedAt: Self.t0))
        // A new process at t0+300: 300 < 600 since the stored list's refresh → false, before anything else is asked.
        let clock = LockedBox(Self.t0.addingTimeInterval(300))
        let places = Self.places(StubFetcher(.success([])), store: store, clock: clock)
        #expect(await !places.backgroundMayRefresh(speed: 1, language: .english))
    }

    @Test func walkingPlacesUseTiers() {
        let church = Candidate(id: "osm:node/c", name: "Kirke", coordinate: .at(north: 10), kind: "amenity=place_of_worship",
                               tags: ["name": "Kirke", "amenity": "place_of_worship"])
        let wikiOnly = Candidate(id: "wiki:en/1", name: "Old Square", coordinate: .at(north: 20), kind: "wikipedia",
                                 wikipediaTitle: "en:Old_Square")
        let unnamed = Candidate(id: "osm:node/u", name: "  ", coordinate: .at(north: 40), kind: "historic=castle",
                                tags: ["historic": "castle"])
        let list = Self.list(candidates: [church, Self.castle("Burg", north: 30), Self.cafe("Kaffe", north: 5), wikiOnly, unnamed])
        // Church → good; castle → top; café → nil (dropped); Wikipedia-only → wikiOnly; blank name → nil (dropped).
        #expect(list.walkingPlaces.map(\.candidate.name) == ["Kirke", "Burg", "Old Square"])
        #expect(list.walkingPlaces.map(\.tier) == [.good, .top, .wikiOnly])
    }

    // MARK: - Refresh rules

    @Test func foregroundRules() async throws {
        let clock = LockedBox(Self.t0)
        let places = Self.places(StubFetcher(.success([Self.castle("Burg", north: 30)])), clock: clock)
        // No list yet → true.
        #expect(await places.shouldRefresh(at: .at(), trigger: .foreground, language: .english))

        try await places.refresh(at: .at(), language: .english)   // attempt and list at t0, centre (0, 0)

        // t0+59: 59 < 60 s since the attempt → false even 151 m away (151 ≥ 150).
        clock.set(Self.t0.addingTimeInterval(59))
        #expect(await !places.shouldRefresh(at: .at(north: 151), trigger: .foreground, language: .english))

        // t0+61: 61 ≥ 60, age 61 ≤ 600. 149 m < 150 → false; 151 m ≥ 150 → true.
        clock.set(Self.t0.addingTimeInterval(61))
        #expect(await !places.shouldRefresh(at: .at(north: 149), trigger: .foreground, language: .english))
        #expect(await places.shouldRefresh(at: .at(north: 151), trigger: .foreground, language: .english))

        // t0+600: age 600, not older than 600 → false at the centre; t0+601: 601 > 600 → true at the centre.
        clock.set(Self.t0.addingTimeInterval(600))
        #expect(await !places.shouldRefresh(at: .at(), trigger: .foreground, language: .english))
        clock.set(Self.t0.addingTimeInterval(601))
        #expect(await places.shouldRefresh(at: .at(), trigger: .foreground, language: .english))
    }

    @Test func foregroundOtherLanguageHasNoList() async throws {
        let clock = LockedBox(Self.t0)
        let places = Self.places(StubFetcher(.success([Self.castle("Burg", north: 30)])), clock: clock)
        try await places.refresh(at: .at(), language: .english)
        // The Norwegian list does not exist and no Norwegian fetch was attempted → true at once (t0).
        #expect(await places.current(language: .norwegian) == nil)
        #expect(await places.shouldRefresh(at: .at(), trigger: .foreground, language: .norwegian))
        #expect(await !places.shouldRefresh(at: .at(), trigger: .foreground, language: .english))
    }

    @Test func walkingRules() async throws {
        let clock = LockedBox(Self.t0)
        let places = Self.places(StubFetcher(.success([Self.castle("Burg", north: 30)])), clock: clock)
        #expect(await places.shouldRefresh(at: .at(), trigger: .walking, language: .english))
        try await places.refresh(at: .at(), language: .english)
        // t0+61, past the 60 s retry spacing: 249 m < 250 → false; 251 m ≥ 250 → true; 151 m (a foreground
        // distance) → false.
        clock.set(Self.t0.addingTimeInterval(61))
        #expect(await !places.shouldRefresh(at: .at(north: 249), trigger: .walking, language: .english))
        #expect(await places.shouldRefresh(at: .at(north: 251), trigger: .walking, language: .english))
        #expect(await !places.shouldRefresh(at: .at(north: 151), trigger: .walking, language: .english))
        // Age at the centre (attempt spacing satisfied, 600 ≥ 60): t0+600 − t0 = 600, not older than 600 → false;
        // t0+601 − t0 = 601 > 600 → true, so a days-old list from disk cannot drive a walk.
        clock.set(Self.t0.addingTimeInterval(600))
        #expect(await !places.shouldRefresh(at: .at(), trigger: .walking, language: .english))
        clock.set(Self.t0.addingTimeInterval(601))
        #expect(await places.shouldRefresh(at: .at(), trigger: .walking, language: .english))
    }

    @Test func walkingRetriesAFailureNoSoonerThanSixtySeconds() async {
        let clock = LockedBox(Self.t0)
        let places = Self.places(StubFetcher(.failure(Boom())), clock: clock)
        await #expect(throws: Boom.self) { try await places.refresh(at: .at(), language: .english) }
        // Failed attempt at t0, no list. t0+59: 59 < 60 → false; t0+60: 60 ≥ 60 → true.
        clock.set(Self.t0.addingTimeInterval(59))
        #expect(await !places.shouldRefresh(at: .at(), trigger: .walking, language: .english))
        clock.set(Self.t0.addingTimeInterval(60))
        #expect(await places.shouldRefresh(at: .at(), trigger: .walking, language: .english))
    }

    @Test func backgroundSpeedAndInterval() async throws {
        let clock = LockedBox(Self.t0)
        let places = Self.places(StubFetcher(.success([Self.castle("Burg", north: 30)])), clock: clock)
        // No list, no refresh yet, slow → true.
        #expect(await places.shouldRefresh(at: .at(), trigger: .background(speed: 1), language: .english))
        try await places.refresh(at: .at(), language: .english)   // last refresh at t0

        // t0+601: 601 ≥ 600 since the last refresh; 200 m ≥ 150 → foreground rule true.
        clock.set(Self.t0.addingTimeInterval(601))
        // 8.1 > 8 → false whatever the rest.
        #expect(await !places.shouldRefresh(at: .at(north: 200), trigger: .background(speed: 8.1), language: .english))
        // 8.0 is not above 8 → true.
        #expect(await places.shouldRefresh(at: .at(north: 200), trigger: .background(speed: 8.0), language: .english))
        // Unknown speed is not a reason to skip → true.
        #expect(await places.shouldRefresh(at: .at(north: 200), trigger: .background(speed: nil), language: .english))

        // t0+599: 599 < 600 since the last refresh → false, though 200 m ≥ 150 and 599 ≥ 60.
        clock.set(Self.t0.addingTimeInterval(599))
        #expect(await !places.shouldRefresh(at: .at(north: 200), trigger: .background(speed: 8.0), language: .english))
    }

    @Test func backgroundIntervalSurvivesARestart() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NearbyListStore(directory: directory)
        try store.save(Self.list(fetchedAt: Self.t0))
        // A new process at t0+300 with the stored list: 300 < 600 since that refresh → false at 200 m.
        let clock = LockedBox(Self.t0.addingTimeInterval(300))
        let places = Self.places(StubFetcher(.success([])), store: store, clock: clock)
        #expect(await !places.shouldRefresh(at: .at(north: 200), trigger: .background(speed: 1), language: .english))
        // t0+601: 601 ≥ 600, and age 601 > 600 → true.
        clock.set(Self.t0.addingTimeInterval(601))
        #expect(await places.shouldRefresh(at: .at(north: 200), trigger: .background(speed: 1), language: .english))
    }

    // MARK: - Refresh

    @Test func refreshBuildsTheList() async throws {
        let clock = LockedBox(Self.t0)
        let burg = Self.castle("Burg", north: 30, title: "en:Burg")
        let places = Self.places(StubFetcher(.success([burg, Self.cafe("Kaffe", north: 5)])), articles: StubArticles(),
                                 clock: clock)
        let list = try await places.refresh(at: .at(north: 7), language: .norwegian)
        #expect(list.centre == .at(north: 7))
        #expect(list.fetchedAt == Self.t0)
        #expect(list.language == .norwegian)
        // Every candidate is kept, the untiered café included.
        #expect(list.candidates.map(\.name) == ["Burg", "Kaffe"])
        #expect(list.articleTexts == ["en:Burg": "Text of en:Burg"])
        #expect(await places.current(language: .norwegian) == list)
        #expect(await places.current(language: .english) == nil)
    }

    @Test func concurrentRefreshesShareOneFetch() async throws {
        let clock = LockedBox(Self.t0)
        let fetcher = StubFetcher(.success([Self.castle("Burg", north: 30)]), suspends: true)
        let places = Self.places(fetcher, clock: clock)

        let first = Task { try await places.refresh(at: .at(), language: .english) }
        await Self.waitUntil { fetcher.isWaiting }
        let second = Task { try await places.refresh(at: .at(north: 10), language: .english) }
        // Both callers are awaiting; a second fetch would show up here as count 2.
        await Self.waitForCallers(2, on: places)
        #expect(await places.callersWaiting(language: .english) == 2)
        #expect(fetcher.count == 1)

        fetcher.resume()
        let a = try await first.value
        let b = try await second.value
        #expect(fetcher.count == 1)
        #expect(a == b)
        #expect(a.centre == .at())
    }

    @Test func cancelledCallerLeavesTheSharedFetchRunning() async throws {
        let clock = LockedBox(Self.t0)
        let fetcher = StubFetcher(.success([Self.castle("Burg", north: 30)]), suspends: true)
        let places = Self.places(fetcher, clock: clock)

        let first = Task { try await places.refresh(at: .at(), language: .english) }
        await Self.waitUntil { fetcher.isWaiting }
        let second = Task { try await places.refresh(at: .at(), language: .english) }
        await Self.waitForCallers(2, on: places)
        #expect(await places.callersWaiting(language: .english) == 2)
        first.cancel()
        await #expect(throws: CancellationError.self) { _ = try await first.value }

        fetcher.resume()
        let list = try await second.value
        #expect(fetcher.count == 1)
        #expect(list.candidates.map(\.name) == ["Burg"])
        #expect(await places.current(language: .english) == list)
    }

    @Test func articleTextsForFiveNearestTopOrGood() async throws {
        let clock = LockedBox(Self.t0)
        // Seven castles (top) with titles at 70, 10, 50, 30, 20, 60, 40 m from the refresh point (0, 0); the five
        // nearest are 10, 20, 30, 40, 50 → P10, P20, P30, P40, P50.
        let castles = [70.0, 10, 50, 30, 20, 60, 40].map { d in
            Self.castle("P\(Int(d))", north: d, title: "en:P\(Int(d))")
        }
        // Nearer than all of them but not fetched: a café (tier nil) with a title, a Wikipedia-only place (tier
        // wikiOnly) and a castle without a title.
        let wikiOnly = Candidate(id: "wiki:en/9", name: "Square", coordinate: .at(north: 2), kind: "wikipedia",
                                 wikipediaTitle: "en:Square")
        let extras = [Self.cafe("Kaffe", north: 1, title: "en:Kaffe"), wikiOnly, Self.castle("Untitled", north: 3)]
        let articles = StubArticles()
        let places = Self.places(StubFetcher(.success(castles + extras)), articles: articles, clock: clock)

        let list = try await places.refresh(at: .at(), language: .english)
        let expected = ["en:P10", "en:P20", "en:P30", "en:P40", "en:P50"]
        #expect(list.articleTexts.count == 5)
        #expect(list.articleTexts.keys.sorted() == expected)
        #expect(list.articleTexts["en:P10"] == "Text of en:P10")
        #expect(articles.titles.sorted() == expected)
    }

    @Test func missingArticleTextsAreSkipped() async throws {
        let clock = LockedBox(Self.t0)
        let castles = [10.0, 20, 30].map { Self.castle("P\(Int($0))", north: $0, title: "en:P\(Int($0))") }
        let articles = StubArticles(missing: ["en:P20"])
        let places = Self.places(StubFetcher(.success(castles)), articles: articles, clock: clock)
        let list = try await places.refresh(at: .at(), language: .english)
        // 3 asked, 1 missing → 2 texts, and the missing one does not take a sixth candidate's place.
        #expect(articles.titles.count == 3)
        #expect(list.articleTexts.keys.sorted() == ["en:P10", "en:P30"])
    }

    @Test func noArticleSourceGivesNoTexts() async throws {
        let clock = LockedBox(Self.t0)
        let places = Self.places(StubFetcher(.success([Self.castle("Burg", north: 30, title: "en:Burg")])), clock: clock)
        let list = try await places.refresh(at: .at(), language: .english)
        #expect(list.articleTexts.isEmpty)
    }

    @Test func failedFetchKeepsOldList() async throws {
        let clock = LockedBox(Self.t0)
        let fetcher = StubFetcher(.success([Self.castle("Burg", north: 30)]))
        let places = Self.places(fetcher, clock: clock)
        let old = try await places.refresh(at: .at(), language: .english)

        fetcher.set(.failure(Boom()))
        clock.set(Self.t0.addingTimeInterval(700))
        await #expect(throws: Boom.self) { try await places.refresh(at: .at(north: 300), language: .english) }
        #expect(await places.current(language: .english) == old)
        // The failure counts as an attempt: at t0+700+59, 59 < 60 → no foreground refresh, though the list is
        // 759 s old (> 600) and 300 m away (≥ 150).
        clock.set(Self.t0.addingTimeInterval(759))
        #expect(await !places.shouldRefresh(at: .at(north: 300), trigger: .foreground, language: .english))
        // It is not a refresh: at t0+760, 760 ≥ 600 since the last successful refresh and 60 ≥ 60 since the
        // attempt → background true.
        clock.set(Self.t0.addingTimeInterval(760))
        #expect(await places.shouldRefresh(at: .at(north: 300), trigger: .background(speed: 1), language: .english))
    }

    @Test func storeFailureIsReportedAndTheRefreshStillSucceeds() async throws {
        // The store's "directory" is an existing regular file, so creating the directory fails.
        let blocker = Self.tempDirectory()
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let errors = LockedBox(0)
        let clock = LockedBox(Self.t0)
        let places = NearbyPlaces(fetcher: StubFetcher(.success([Self.castle("Burg", north: 30)])), articles: nil,
                                  store: NearbyListStore(directory: blocker), now: { clock.value },
                                  onStoreError: { _ in errors.withValue { $0 += 1 } })
        let list = try await places.refresh(at: .at(), language: .english)
        #expect(list.candidates.map(\.name) == ["Burg"])
        #expect(await places.current(language: .english) == list)
        #expect(errors.value == 1)
    }

    // MARK: - Store

    @Test func storeRoundTrip() throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NearbyListStore(directory: directory)
        #expect(store.load(language: .english) == nil)

        let english = Self.list(candidates: [Self.castle("Burg", north: 30, title: "en:Burg"), Self.cafe("Kaffe", north: 5)])
        let norwegian = Self.list(fetchedAt: Self.t0.addingTimeInterval(1.5), language: .norwegian)
        try store.save(english)
        try store.save(norwegian)
        #expect(store.load(language: .english) == english)
        #expect(store.load(language: .norwegian) == norwegian)

        // One file per language; no temporary files left behind.
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(files.count == 2)

        // Saving again replaces the file.
        let newer = Self.list(fetchedAt: Self.t0.addingTimeInterval(60))
        try store.save(newer)
        #expect(store.load(language: .english) == newer)
    }

    @Test func unreadableStoreFileLoadsAsNil() throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NearbyListStore(directory: directory)
        try store.save(Self.list())
        let file = try #require(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("{\"centre\":".utf8).write(to: file)
        #expect(store.load(language: .english) == nil)
    }

    @Test func refreshSavesAndARestartLoads() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NearbyListStore(directory: directory)
        let clock = LockedBox(Self.t0)
        let saved = try await Self.places(StubFetcher(.success([Self.castle("Burg", north: 30)])), store: store, clock: clock)
            .refresh(at: .at(), language: .english)
        #expect(store.load(language: .english) == saved)

        let restarted = Self.places(StubFetcher(.failure(Boom())), store: store, clock: clock)
        #expect(await restarted.current(language: .english) == saved)
        // A failed fetch after the restart keeps the stored list as the fallback.
        await #expect(throws: Boom.self) { try await restarted.refresh(at: .at(), language: .english) }
        #expect(await restarted.current(language: .english) == saved)
    }
}
