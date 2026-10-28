import Foundation

/// Why a refresh is being considered.
public enum RefreshTrigger: Sendable, Equatable {
    /// A fix while the app is in the foreground (camera open, or walking mode running).
    case foreground
    /// A fix from walking mode.
    case walking
    /// A significant-location-change wake; `speed` in m/s, nil when the fix has none.
    case background(speed: Double?)
}

/// Where the nearby list's candidates come from.
public protocol NearbyFetching: Sendable {
    func candidates(around: Coordinate, language: StoryLanguage) async throws -> [Candidate]
}

extension WalkingPlaceSource: NearbyFetching {}

/// Owns the nearby list, one per story language: decides when to refresh, merges simultaneous refreshes into one
/// fetch, and keeps the latest list in memory and on disk.
public actor NearbyPlaces {
    /// Foreground: refresh once the position is at least this far (metres) from the list's centre.
    public static let foregroundDistance = 150.0
    /// Foreground and walking: no fetch within this many seconds of the last fetch attempt.
    public static let foregroundInterval: TimeInterval = 60
    /// Walking: refresh once the position is at least this far (metres) from the list's centre.
    public static let walkingDistance = 250.0
    /// Background: never refresh above this speed (m/s); it is a drive, not a walk.
    public static let backgroundMaxSpeed = 8.0
    /// Background: no refresh within this many seconds of the last successful refresh.
    public static let backgroundInterval: TimeInterval = 600
    /// Article texts are fetched for at most this many of the nearest tier-top or tier-good candidates.
    public static let articleCount = 5

    private let fetcher: NearbyFetching
    private let articles: ArticleTextSource?
    private let store: NearbyListStore?
    private let now: @Sendable () -> Date
    /// Told when a refreshed list could not be written to the store; the refresh itself still succeeds.
    private let onStoreError: (@Sendable (Error) -> Void)?

    private var lists: [StoryLanguage: NearbyList] = [:]
    /// Languages whose stored list has been looked for; the store is read at most once per language.
    private var loadedLanguages: Set<StoryLanguage> = []
    /// When a fetch last started, per language, whether or not it succeeded.
    private var lastFetchAttempt: [StoryLanguage: Date] = [:]
    /// When a fetch last succeeded, per language. Seeded from a stored list's `fetchedAt`, so the background
    /// interval holds across relaunches.
    private var lastRefresh: [StoryLanguage: Date] = [:]
    /// The fetch under way per language; simultaneous callers await it.
    private var inFlight: [StoryLanguage: Task<NearbyList, Error>] = [:]
    /// Callers currently awaiting a fetch, per language (the starter included).
    private var waitingCallers: [StoryLanguage: Int] = [:]

    public init(fetcher: NearbyFetching, articles: ArticleTextSource?, store: NearbyListStore?,
                now: @escaping @Sendable () -> Date, onStoreError: (@Sendable (Error) -> Void)? = nil) {
        self.fetcher = fetcher
        self.articles = articles
        self.store = store
        self.now = now
        self.onStoreError = onStoreError
    }

    /// The latest list for `language`: from this run, or else from the store.
    public func current(language: StoryLanguage) -> NearbyList? {
        list(for: language)
    }

    /// Whether a fix at `position` should start a refresh:
    /// - foreground: no list, or the list is ≥ `foregroundDistance` away or older than `NearbyList.freshAge`;
    ///   never within `foregroundInterval` of the last fetch attempt;
    /// - walking: no list, or the list is ≥ `walkingDistance` away or older than `NearbyList.freshAge` (a list
    ///   loaded from disk days ago must not drive a walk); never within `foregroundInterval` of the last fetch
    ///   attempt, so a failing source is not retried on every fix;
    /// - background: never above `backgroundMaxSpeed` or within `backgroundInterval` of the last refresh;
    ///   otherwise as foreground.
    public func shouldRefresh(at position: Coordinate, trigger: RefreshTrigger, language: StoryLanguage) -> Bool {
        let now = now()
        let list = list(for: language)
        switch trigger {
        case .foreground:
            return foregroundRule(list, position: position, language: language, now: now)
        case .walking:
            if Self.isWithin(Self.foregroundInterval, of: lastFetchAttempt[language], now: now) { return false }
            guard let list else { return true }
            return GeoMath.distance(list.centre, position) >= Self.walkingDistance || Self.isOld(list, now: now)
        case .background(let speed):
            if let speed, speed > Self.backgroundMaxSpeed { return false }
            if Self.isWithin(Self.backgroundInterval, of: lastRefresh[language], now: now) { return false }
            return foregroundRule(list, position: position, language: language, now: now)
        }
    }

    /// Fetches a new list centred on `position` and keeps it, in memory and in the store.
    /// One fetch runs per language: a caller arriving while one is under way awaits that fetch (and gets a list
    /// centred where it started). A failure keeps the old list and is thrown. A cancelled caller stops waiting with
    /// CancellationError; the fetch carries on for the others and is still kept.
    @discardableResult
    public func refresh(at position: Coordinate, language: StoryLanguage) async throws -> NearbyList {
        let task: Task<NearbyList, Error>
        if let running = inFlight[language] {
            task = running
        } else {
            try Task.checkCancellation()
            lastFetchAttempt[language] = now()
            let fetcher = fetcher
            let articles = articles
            // Unstructured on purpose: one caller's cancellation must not fail the others waiting on the same fetch.
            // It runs on this actor, so it cannot start before `inFlight` is set below.
            task = Task {
                defer { inFlight[language] = nil }
                let candidates = try await fetcher.candidates(around: position, language: language)
                let texts = await Self.articleTexts(for: candidates, around: position, from: articles)
                let list = NearbyList(centre: position, fetchedAt: now(), language: language,
                                      candidates: candidates, articleTexts: texts)
                keep(list)
                return list
            }
            inFlight[language] = task
        }
        waitingCallers[language, default: 0] += 1
        defer { waitingCallers[language, default: 1] -= 1 }
        return try await GroundingService.abandoningOnCancel { try await task.value }
    }

    /// Callers currently awaiting a fetch for `language`; lets tests see a second caller join.
    func callersWaiting(language: StoryLanguage) -> Int {
        waitingCallers[language, default: 0]
    }

    // MARK: - Private

    private func list(for language: StoryLanguage) -> NearbyList? {
        if !loadedLanguages.contains(language) {
            loadedLanguages.insert(language)
            if lists[language] == nil, let stored = store?.load(language: language) {
                lists[language] = stored
                if lastRefresh[language] == nil { lastRefresh[language] = stored.fetchedAt }
            }
        }
        return lists[language]
    }

    private func keep(_ list: NearbyList) {
        lists[list.language] = list
        loadedLanguages.insert(list.language)
        lastRefresh[list.language] = list.fetchedAt
        // The stored copy is only a restart and fallback aid; failing to write it must not fail a good refresh,
        // but it is reported.
        guard let store else { return }
        do {
            try store.save(list)
        } catch {
            onStoreError?(error)
        }
    }

    private func foregroundRule(_ list: NearbyList?, position: Coordinate, language: StoryLanguage, now: Date) -> Bool {
        if Self.isWithin(Self.foregroundInterval, of: lastFetchAttempt[language], now: now) { return false }
        guard let list else { return true }
        assert(list.language == language, "lists are keyed by their own language")
        return GeoMath.distance(list.centre, position) >= Self.foregroundDistance || Self.isOld(list, now: now)
    }

    /// Older than `NearbyList.freshAge`. A list dated in the future (the clock was set back) has an unknown age and
    /// counts as old.
    private static func isOld(_ list: NearbyList, now: Date) -> Bool {
        let age = now.timeIntervalSince(list.fetchedAt)
        return age > NearbyList.freshAge || age < 0
    }

    /// True when `date` lies less than `interval` before `now`. A date after `now` (the clock was set back) does
    /// not hold anything off.
    private static func isWithin(_ interval: TimeInterval, of date: Date?, now: Date) -> Bool {
        guard let date else { return false }
        let elapsed = now.timeIntervalSince(date)
        return elapsed >= 0 && elapsed < interval
    }

    /// Texts for the `articleCount` nearest distinct titles among tier-top and tier-good candidates, fetched
    /// concurrently; titles without a text are left out.
    static func articleTexts(for candidates: [Candidate], around position: Coordinate,
                             from source: ArticleTextSource?) async -> [String: String] {
        guard let source else { return [:] }
        let titles = articleTitles(for: candidates, around: position)
        return await withTaskGroup(of: (String, String?).self) { group in
            for title in titles {
                group.addTask { (title, await source.text(wikipediaTitle: title)) }
            }
            var texts: [String: String] = [:]
            for await (title, text) in group {
                if let text { texts[title] = text }
            }
            return texts
        }
    }

    /// Nearest first (ties in list order), distinct, at most `articleCount`.
    static func articleTitles(for candidates: [Candidate], around position: Coordinate) -> [String] {
        let eligible = candidates.enumerated().compactMap { index, candidate -> (distance: Double, index: Int, title: String)? in
            guard let tier = PlaceTiers.tier(for: candidate), tier == .top || tier == .good,
                  let title = candidate.wikipediaTitle, !title.isEmpty else { return nil }
            return (GeoMath.distance(position, candidate.coordinate), index, title)
        }
        .sorted { ($0.distance, $0.index) < ($1.distance, $1.index) }

        var titles: [String] = []
        var seen: Set<String> = []
        for entry in eligible {
            if titles.count == articleCount { break }
            if seen.insert(entry.title).inserted { titles.append(entry.title) }
        }
        return titles
    }
}
