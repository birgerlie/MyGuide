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
    private var osmFailed = false
    private var osmErrors: [String] = []
    private var facts: (count: Int, dropped: [String], failed: Int) = (0, [], 0)
    private let suspends: Bool
    private var released = false

    init(_ result: Result<[Candidate], Error>, suspends: Bool = false) {
        self.result = result
        self.suspends = suspends
    }

    var count: Int { lock.withLock { calls } }
    var isWaiting: Bool { lock.withLock { !waiters.isEmpty } }

    func set(_ result: Result<[Candidate], Error>, osmFailed: Bool = false, osmErrors: [String] = []) {
        lock.withLock {
            self.result = result
            self.osmFailed = osmFailed
            self.osmErrors = osmErrors
        }
    }

    func setFacts(count: Int, dropped: [String], failed: Int) {
        lock.withLock { facts = (count, dropped, failed) }
    }

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

    func candidates(around: Coordinate, language: StoryLanguage) async throws -> PlaceSearchResult {
        let (result, released, osmFailed, osmErrors, facts) = lock.withLock {
            () -> (Result<[Candidate], Error>, Bool, Bool, [String], (count: Int, dropped: [String], failed: Int)) in
            calls += 1
            return (self.result, self.released, self.osmFailed, self.osmErrors, self.facts)
        }
        guard suspends, !released else {
            return PlaceSearchResult(candidates: try result.get(), osmFailed: osmFailed, osmErrors: osmErrors,
                                     factsCount: facts.count, dropped: facts.dropped, factsFailed: facts.failed)
        }
        let candidates = try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiters.append(continuation) }
        }
        return PlaceSearchResult(candidates: candidates, osmFailed: osmFailed, osmErrors: osmErrors,
                                 factsCount: facts.count, dropped: facts.dropped, factsFailed: facts.failed)
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

/// Answers "Text of <title>" only once `release()` is called; every call before that waits. Calls after the release
/// answer at once.
private final class GatedArticles: ArticleTextSource, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var asked: [String] = []

    var titles: [String] { lock.withLock { asked } }
    var waiting: Int { lock.withLock { waiters.count } }

    func release() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { self.waiters = [] }
            return self.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func text(wikipediaTitle: String) async -> String? {
        let open = lock.withLock { () -> Bool in
            asked.append(wikipediaTitle)
            return released
        }
        if !open {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    if released { return true }
                    waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return "Text of \(wikipediaTitle)"
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

    @Test func listStatusForTheTimingsScreen() {
        let list = Self.list()   // centre (0, 0), fetched at t0
        // t0 + 125.9 s: 125.9 rounded down → 125 s. Position 85.4 m north: `.at(north:)` is that many metres up to
        // floating point, rounded → 85 m.
        #expect(NearbyListStatus(list: list, position: .at(north: 85.4), now: Self.t0.addingTimeInterval(125.9))
                == NearbyListStatus(ageS: 125, distanceM: 85))
        // No position → no distance; age 0 at t0. 1 200.6 m rounds to 1 201 m.
        #expect(NearbyListStatus(list: list, position: nil, now: Self.t0) == NearbyListStatus(ageS: 0, distanceM: nil))
        #expect(NearbyListStatus(list: list, position: .at(north: 1200.6), now: Self.t0).distanceM == 1201)
        // Dated after now (t0 − 1 s): age −1 is unknown → nil.
        #expect(NearbyListStatus(list: list, position: nil, now: Self.t0.addingTimeInterval(-1)).ageS == nil)
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

    @Test func backgroundNeedsDistanceNotAgeAlone() async throws {
        let clock = LockedBox(Self.t0)
        let places = Self.places(StubFetcher(.success([Self.castle("Burg", north: 30)])), clock: clock)
        try await places.refresh(at: .at(), language: .english)   // list centred at (0, 0), refreshed at t0
        // t0+601: 601 ≥ 600 since the refresh and 601 ≥ 60 since the attempt, and the list is old (601 > 600 s).
        clock.set(Self.t0.addingTimeInterval(601))
        // At the centre (0 m < 150) → false: age alone does not refresh in the background.
        #expect(await !places.shouldRefresh(at: .at(), trigger: .background(speed: 1), language: .english))
        // 149 m < 150 → false; 151 m ≥ 150 → true.
        #expect(await !places.shouldRefresh(at: .at(north: 149), trigger: .background(speed: 1), language: .english))
        #expect(await places.shouldRefresh(at: .at(north: 151), trigger: .background(speed: 1), language: .english))
        // Days later (t0 + 86 400 s), still at the centre → false.
        clock.set(Self.t0.addingTimeInterval(86_400))
        #expect(await !places.shouldRefresh(at: .at(), trigger: .background(speed: 1), language: .english))
        // The foreground rule still refreshes an old list at the centre (86 400 > 600 s).
        #expect(await places.shouldRefresh(at: .at(), trigger: .foreground, language: .english))
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
        // The article texts follow the list.
        await places.articleTextsSettled(language: .norwegian)
        var withTexts = list
        withTexts.articleTexts = ["en:Burg": "Text of en:Burg"]
        #expect(await places.current(language: .norwegian) == withTexts)
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

        try await places.refresh(at: .at(), language: .english)
        await places.articleTextsSettled(language: .english)
        let list = try #require(await places.current(language: .english))
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
        try await places.refresh(at: .at(), language: .english)
        await places.articleTextsSettled(language: .english)
        let list = try #require(await places.current(language: .english))
        // 3 asked, 1 missing → 2 texts, and the missing one does not take a sixth candidate's place.
        #expect(articles.titles.count == 3)
        #expect(list.articleTexts.keys.sorted() == ["en:P10", "en:P30"])
    }

    @Test func noArticleSourceGivesNoTexts() async throws {
        let clock = LockedBox(Self.t0)
        let places = Self.places(StubFetcher(.success([Self.castle("Burg", north: 30, title: "en:Burg")])), clock: clock)
        let list = try await places.refresh(at: .at(), language: .english)
        #expect(list.articleTexts.isEmpty)
        await places.articleTextsSettled(language: .english)
        #expect(await places.current(language: .english)?.articleTexts.isEmpty == true)
    }

    @Test func refreshReturnsBeforeTheArticleTexts() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NearbyListStore(directory: directory)
        let clock = LockedBox(Self.t0)
        let articles = GatedArticles()
        let places = Self.places(StubFetcher(.success([Self.castle("Burg", north: 30, title: "en:Burg")])),
                                 articles: articles, store: store, clock: clock)
        // The article source has not answered (and will not until released), yet the refresh returns with the list,
        // which is already current and stored, without texts.
        let list = try await places.refresh(at: .at(), language: .english)
        #expect(list.candidates.map(\.name) == ["Burg"])
        #expect(list.articleTexts.isEmpty)
        #expect(await places.current(language: .english) == list)
        #expect(store.load(language: .english) == list)
        await Self.waitUntil { articles.waiting == 1 }
        #expect(articles.titles == ["en:Burg"])

        articles.release()
        await places.articleTextsSettled(language: .english)
        var withTexts = list
        withTexts.articleTexts = ["en:Burg": "Text of en:Burg"]
        #expect(await places.current(language: .english) == withTexts)
        // Saved again with the texts.
        #expect(store.load(language: .english) == withTexts)
    }

    @Test func articleTextsForAnOlderListAreDropped() async throws {
        let clock = LockedBox(Self.t0)
        let articles = GatedArticles()
        let fetcher = StubFetcher(.success([Self.castle("Old", north: 30, title: "en:Old")]))
        let places = Self.places(fetcher, articles: articles, clock: clock)
        try await places.refresh(at: .at(), language: .english)   // its article step waits for "en:Old"
        await Self.waitUntil { articles.waiting == 1 }

        // t0+61: 61 ≥ 60 since the first attempt, so a second fetch runs, with another place.
        clock.set(Self.t0.addingTimeInterval(61))
        fetcher.set(.success([Self.castle("New", north: 30, title: "en:New")]))
        let newer = try await places.refresh(at: .at(north: 200), language: .english)
        await Self.waitUntil { articles.waiting == 2 }

        articles.release()
        await places.articleTextsSettled(language: .english)
        // Both steps answered; only the newer list's text is kept, and the list stays the newer one.
        let current = try #require(await places.current(language: .english))
        #expect(current.candidates == newer.candidates)
        #expect(current.centre == .at(north: 200))
        #expect(current.articleTexts == ["en:New": "Text of en:New"])
    }

    @Test func aRefreshNearbyKeepsTheTextsItStillNeeds() async throws {
        let clock = LockedBox(Self.t0)
        let burg = Self.castle("Burg", north: 30, title: "en:Burg")
        let fort = Self.castle("Fort", north: 40, title: "en:Fort")
        let fetcher = StubFetcher(.success([burg, fort]))
        let first = StubArticles()
        let places = Self.places(fetcher, articles: first, clock: clock)
        try await places.refresh(at: .at(), language: .english)
        await places.articleTextsSettled(language: .english)
        #expect(await places.current(language: .english)?.articleTexts.count == 2)

        // t0+61 (61 ≥ 60): the next fetch has Burg and a new tower but no longer Fort. Burg's text comes with the list
        // at once; Fort's is dropped; only the tower's is fetched.
        clock.set(Self.t0.addingTimeInterval(61))
        let tower = Self.castle("Tower", north: 50, title: "en:Tower")
        fetcher.set(.success([burg, tower]))
        let list = try await places.refresh(at: .at(), language: .english)
        #expect(list.articleTexts == ["en:Burg": "Text of en:Burg"])
        await places.articleTextsSettled(language: .english)
        #expect(await places.current(language: .english)?.articleTexts
                == ["en:Burg": "Text of en:Burg", "en:Tower": "Text of en:Tower"])
        // First refresh asked Burg and Fort; the second only Tower: 2 + 1 = 3 asks.
        #expect(first.titles.sorted() == ["en:Burg", "en:Fort", "en:Tower"])
    }

    @Test func articleTextsSettledReturnsWhenTheCallerIsCancelled() async throws {
        let clock = LockedBox(Self.t0)
        let articles = GatedArticles()
        let places = Self.places(StubFetcher(.success([Self.castle("Burg", north: 30, title: "en:Burg")])),
                                 articles: articles, clock: clock)
        try await places.refresh(at: .at(), language: .english)
        await Self.waitUntil { articles.waiting == 1 }
        let waiting = Task { await places.articleTextsSettled(language: .english) }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        // Returns although the source never answered; the step itself is left running.
        await waiting.value
        #expect(await places.current(language: .english)?.articleTexts.isEmpty == true)
        articles.release()
        await places.articleTextsSettled(language: .english)
        #expect(await places.current(language: .english)?.articleTexts == ["en:Burg": "Text of en:Burg"])
    }

    // MARK: - Refresh spacing

    @Test func refreshWithinSixtySecondsOfAFinishedFetchReusesIt() async throws {
        let clock = LockedBox(Self.t0)
        let fetcher = StubFetcher(.success([Self.castle("Burg", north: 30)]))
        let places = Self.places(fetcher, clock: clock)
        // Two callers that both decided to refresh, one after the other: the first fetches at t0.
        let first = try await places.refresh(at: .at(), language: .english)
        #expect(fetcher.count == 1)
        // The second asks at t0+59 (59 < 60 since the attempt): no new fetch; it gets the current list, centred
        // where the first fetch was.
        clock.set(Self.t0.addingTimeInterval(59))
        let second = try await places.refresh(at: .at(north: 300), language: .english)
        #expect(fetcher.count == 1)
        #expect(second == first)
        #expect(second.centre == .at())
        // t0+60: 60 is not < 60 → a new fetch, centred where asked.
        clock.set(Self.t0.addingTimeInterval(60))
        let third = try await places.refresh(at: .at(north: 300), language: .english)
        #expect(fetcher.count == 2)
        #expect(third.centre == .at(north: 300))
    }

    @Test func refreshWithinSixtySecondsOfAFailedFetchRethrowsIt() async throws {
        let clock = LockedBox(Self.t0)
        let fetcher = StubFetcher(.failure(Boom()))
        let places = Self.places(fetcher, clock: clock)
        await #expect(throws: Boom.self) { try await places.refresh(at: .at(), language: .english) }
        #expect(fetcher.count == 1)
        // t0+30: 30 < 60 since the failed attempt → the same failure, no fetch, even though the source works now.
        fetcher.set(.success([Self.castle("Burg", north: 30)]))
        clock.set(Self.t0.addingTimeInterval(30))
        await #expect(throws: Boom.self) { try await places.refresh(at: .at(), language: .english) }
        #expect(fetcher.count == 1)
        #expect(await places.current(language: .english) == nil)
        // t0+60: 60 ≥ 60 → fetched.
        clock.set(Self.t0.addingTimeInterval(60))
        let list = try await places.refresh(at: .at(), language: .english)
        #expect(fetcher.count == 2)
        #expect(list.candidates.map(\.name) == ["Burg"])
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

    // MARK: - Carrying OpenStreetMap places forward (spec 13.6)

    static func article(_ name: String, north: Double) -> Candidate {
        Candidate(id: "wiki:en/\(name)", name: name, coordinate: .at(north: north), kind: "wikipedia",
                  summary: "An article.", wikipediaTitle: "en:\(name)")
    }

    /// A first list at `.at()` with two OSM castles and an article at t0, then a refresh at `north` metres, `age`
    /// seconds later, whose OSM part failed (only an article came back).
    static func refreshAfterOSMFailure(north: Double, age: TimeInterval,
                                       language: StoryLanguage = .english) async throws -> NearbyList {
        let fetcher = StubFetcher(.success([castle("Burg", north: 30), castle("Far", north: -200),
                                            article("Old article", north: 10)]))
        let clock = LockedBox(t0)
        let nearby = places(fetcher, clock: clock)
        let first = try await nearby.refresh(at: .at(), language: language)
        #expect(!first.osmFailed)
        clock.set(t0 + age)
        fetcher.set(.success([article("New article", north: north + 5)]), osmFailed: true)
        return try await nearby.refresh(at: .at(north: north), language: language)
    }

    @Test func previousOSMPlacesCarriedForward() async throws {
        // 6 days = 6 × 86 400 = 518 400 s ≤ 7 days (604 800 s); centre 400 m ≤ 500 m away.
        let list = try await Self.refreshAfterOSMFailure(north: 400, age: 518_400)
        #expect(list.osmFailed)
        // "Burg" (north 30) is 400 − 30 = 370 m from the new centre: carried. "Far" (north −200) is 400 + 200 = 600 m
        // away, beyond the 500 m search radius: left behind. The old article is not OSM: not carried.
        #expect(list.candidates.map(\Candidate.id) == ["osm:node/Burg", "wiki:en/New article"])
        #expect(list.fetchedAt == Self.t0 + 518_400 && list.centre == .at(north: 400))
    }
    @Test func previousOSMPlacesNotCarriedWhenTooFarOrTooOld() async throws {
        // 600 m > 500 m.
        let far = try await Self.refreshAfterOSMFailure(north: 600, age: 518_400)
        #expect(far.osmFailed && far.candidates.map(\Candidate.id) == ["wiki:en/New article"])
        // 8 days = 691 200 s > 604 800 s.
        let old = try await Self.refreshAfterOSMFailure(north: 400, age: 691_200)
        #expect(old.osmFailed && old.candidates.map(\Candidate.id) == ["wiki:en/New article"])
        // Exactly 7 days (604 800 s) still carries; one second more does not.
        let sevenDays = try await Self.refreshAfterOSMFailure(north: 400, age: 604_800)
        #expect(sevenDays.candidates.map(\Candidate.id) == ["osm:node/Burg", "wiki:en/New article"])
        let justOver = try await Self.refreshAfterOSMFailure(north: 400, age: 604_801)
        #expect(justOver.candidates.map(\Candidate.id) == ["wiki:en/New article"])
    }
    @Test func previousListFromTheFutureIsNotCarried() async throws {
        // A clock set back: the old list's age is unknown, so nothing is carried.
        let list = try await Self.refreshAfterOSMFailure(north: 0, age: -120)
        #expect(list.candidates.map(\Candidate.id) == ["wiki:en/New article"])
    }
    @Test func carriedPlacesMergeWithTheNewArticles() async throws {
        // The carried castle and a new article about it (same title) become one candidate, the OSM one.
        let fetcher = StubFetcher(.success([Self.castle("Burg", north: 30, title: "en:Burg")]))
        let clock = LockedBox(Self.t0)
        let nearby = Self.places(fetcher, clock: clock)
        try await nearby.refresh(at: .at(), language: .english)
        clock.set(Self.t0 + 3_600)
        let same = Candidate(id: "wiki:en/Burg", name: "Burg Castle", coordinate: .at(north: 31), kind: "wikipedia",
                             summary: "The castle.", wikipediaTitle: "en:Burg")
        fetcher.set(.success([same]), osmFailed: true)
        let list = try await nearby.refresh(at: .at(north: 100), language: .english)
        #expect(list.candidates.map(\Candidate.id) == ["osm:node/Burg"])
        #expect(list.candidates.first?.summary == "The castle.")
    }
    @Test func listKeepsTheOverpassEndpointErrors() async throws {
        let fetcher = StubFetcher(.success([Self.article("A", north: 0)]))
        fetcher.set(.success([Self.article("A", north: 0)]), osmFailed: true,
                    osmErrors: ["overpass-api.de: timed out", "overpass.kumi.systems: HTTP 504"])
        let nearby = Self.places(fetcher, clock: LockedBox(Self.t0))
        let list = try await nearby.refresh(at: .at(), language: .english)
        #expect(list.osmFailed && list.osmErrors == ["overpass-api.de: timed out", "overpass.kumi.systems: HTTP 504"])
        // A stored list written before the field existed reads with no errors; a new one round-trips them.
        let back = try JSONDecoder().decode(NearbyList.self, from: JSONEncoder().encode(list))
        #expect(back == list)
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(list)) as? [String: Any])
        old["osmErrors"] = nil
        let decodedOld = try JSONDecoder().decode(NearbyList.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decodedOld.osmErrors.isEmpty && decodedOld.osmFailed)
    }
    @Test func listKeepsTheFactsCountsAndOldFilesDecodeWithout() async throws {
        let fetcher = StubFetcher(.success([Self.article("A", north: 0)]))
        fetcher.setFacts(count: 4, dropped: ["Jesuittordenen"], failed: 1)
        let nearby = Self.places(fetcher, clock: LockedBox(Self.t0))
        let list = try await nearby.refresh(at: .at(), language: .english)
        #expect(list.factsCount == 4 && list.dropped == ["Jesuittordenen"] && list.factsFailed == 1)
        let back = try JSONDecoder().decode(NearbyList.self, from: JSONEncoder().encode(list))
        #expect(back == list)
        // A stored list written before the fields existed reads with 0 / [] / 0.
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(list)) as? [String: Any])
        old["factsCount"] = nil
        old["dropped"] = nil
        old["factsFailed"] = nil
        let decodedOld = try JSONDecoder().decode(NearbyList.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decodedOld.factsCount == 0 && decodedOld.dropped.isEmpty && decodedOld.factsFailed == 0)
        #expect(decodedOld.candidates == list.candidates)
    }
    @Test func walkingPlacesUseTheCandidatesFacts() {
        // A Wikipedia-only nonPlace candidate stays in the stored list but never walks; a place with 30 sitelinks is top.
        var gesu = Self.article("Il Gesù", north: 0)
        gesu.sitelinks = 30
        gesu.placeClass = .place
        var order = Self.article("Jesuittordenen", north: 0)
        order.sitelinks = 119
        order.placeClass = .nonPlace
        let list = NearbyList(centre: .at(), fetchedAt: Self.t0, language: .english, candidates: [gesu, order],
                              articleTexts: [:])
        #expect(list.walkingPlaces.map(\.candidate.name) == ["Il Gesù"])
        #expect(list.walkingPlaces.map(\.tier) == [.top])
    }
    @Test func nothingCarriedWhenOSMAnswers() async throws {
        let fetcher = StubFetcher(.success([Self.castle("Burg", north: 30)]))
        let clock = LockedBox(Self.t0)
        let nearby = Self.places(fetcher, clock: clock)
        try await nearby.refresh(at: .at(), language: .english)
        clock.set(Self.t0 + 3_600)
        fetcher.set(.success([Self.castle("Tower", north: 120)]))
        let list = try await nearby.refresh(at: .at(north: 100), language: .english)
        #expect(!list.osmFailed && list.candidates.map(\Candidate.id) == ["osm:node/Tower"])
    }
    @Test func storedListIsCarriedAfterARelaunch() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NearbyListStore(directory: directory)
        try store.save(Self.list(language: .norwegian))
        let fetcher = StubFetcher(.success([]))
        fetcher.set(.success([]), osmFailed: true)
        let clock = LockedBox(Self.t0 + 86_400)
        let nearby = Self.places(fetcher, store: store, clock: clock)
        let list = try await nearby.refresh(at: .at(north: 50), language: .norwegian)
        #expect(list.osmFailed && list.candidates.map(\Candidate.id) == ["osm:node/Burg"])
        // The other language's list is never used.
        let english = try await nearby.refresh(at: .at(north: 50), language: .english)
        #expect(english.candidates.isEmpty)
    }
    @Test func osmFailedDecodesAsFalseFromAnOldFile() throws {
        let list = Self.list()
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(list)) as? [String: Any])
        #expect(json["osmFailed"] as? Bool == false)
        json["osmFailed"] = nil
        let old = try JSONDecoder().decode(NearbyList.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old == list && !old.osmFailed)
        var failed = list
        failed.osmFailed = true
        #expect(try JSONDecoder().decode(NearbyList.self, from: JSONEncoder().encode(failed)) == failed)
    }

    // MARK: - A list whose OpenStreetMap part failed is retried after 60 s (fix round 1)

    static func failedList(fetchedAt: Date = t0) -> NearbyList {
        var list = list(fetchedAt: fetchedAt)
        list.osmFailed = true
        return list
    }

    @Test func osmFailedListIsNotFreshForAPhotoFromSixtySeconds() {
        #expect(NearbyList.osmFailedRetryAge == 60)
        let failed = Self.failedList(), ok = Self.list()
        // Age 59 s < 60 → fresh at the centre; age 60 s ≥ 60 → stale, though well inside 600 s and 250 m.
        #expect(failed.isFresh(for: .at(), now: Self.t0.addingTimeInterval(59)))
        #expect(!failed.isFresh(for: .at(), now: Self.t0.addingTimeInterval(60)))
        // A list without the failure stays fresh at 60 s (and to 600 s).
        #expect(ok.isFresh(for: .at(), now: Self.t0.addingTimeInterval(60)))
        #expect(failed.isStaleAfterOSMFailure(age: 60) && !failed.isStaleAfterOSMFailure(age: 59.9))
        #expect(!ok.isStaleAfterOSMFailure(age: 600))
    }
    @Test func osmFailedListStopsServingAWalkerFromSixtySeconds() {
        let failed = Self.failedList(), ok = Self.list()
        // At the centre, regardless of distance: 59 s serves, 60 s does not.
        #expect(failed.serves(walkerAt: .at(), now: Self.t0.addingTimeInterval(59)))
        #expect(!failed.serves(walkerAt: .at(), now: Self.t0.addingTimeInterval(60)))
        #expect(ok.serves(walkerAt: .at(), now: Self.t0.addingTimeInterval(60)))
    }
    @Test func osmFailedStoredListRefreshesAfterSixtySecondsForForegroundAndWalking() async throws {
        // A stored list: no fetch attempt this run, so only the list's own age decides (no 60 s attempt spacing).
        for trigger in [RefreshTrigger.foreground, .walking] {
            for (age, expected) in [(59.0, false), (60.0, true)] {
                let directory = Self.tempDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let store = NearbyListStore(directory: directory)
                try store.save(Self.failedList())
                let clock = LockedBox(Self.t0.addingTimeInterval(age))
                let places = Self.places(StubFetcher(.success([])), store: store, clock: clock)
                #expect(await places.shouldRefresh(at: .at(), trigger: trigger, language: .english) == expected,
                        "\(trigger) at \(age) s")
            }
        }
        // Without the failure, the same stored list at 60 s does not refresh at its centre.
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NearbyListStore(directory: directory)
        try store.save(Self.list())
        let places = Self.places(StubFetcher(.success([])), store: store, clock: LockedBox(Self.t0.addingTimeInterval(60)))
        #expect(await !places.shouldRefresh(at: .at(), trigger: .foreground, language: .english))
        #expect(await !places.shouldRefresh(at: .at(), trigger: .walking, language: .english))
    }
    @Test func osmFailedFetchIsRetriedOnTheNextFixAfterSixtySeconds() async throws {
        // In a run: the failed fetch at t0 sets both the attempt spacing and the list age; at t0 + 60 both allow it.
        let fetcher = StubFetcher(.success([]))
        fetcher.set(.success([]), osmFailed: true)
        let clock = LockedBox(Self.t0)
        let places = Self.places(fetcher, clock: clock)
        try await places.refresh(at: .at(), language: .english)
        clock.set(Self.t0.addingTimeInterval(59))
        #expect(await !places.shouldRefresh(at: .at(), trigger: .walking, language: .english))
        clock.set(Self.t0.addingTimeInterval(60))
        #expect(await places.shouldRefresh(at: .at(), trigger: .walking, language: .english))
        #expect(await places.shouldRefresh(at: .at(), trigger: .foreground, language: .english))
    }
}
