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
    func candidates(around: Coordinate, language: StoryLanguage) async throws -> PlaceSearchResult
}

extension WalkingPlaceSource: NearbyFetching {}

/// Owns the nearby list, one per story language: decides when to refresh, merges simultaneous refreshes into one
/// fetch, and keeps the latest list in memory and on disk. A refreshed list is kept as soon as its candidates arrive;
/// the article texts follow in a separate step that updates (and saves) the list again.
public actor NearbyPlaces {
    /// Foreground: refresh once the position is at least this far (metres) from the list's centre.
    public static let foregroundDistance = 150.0
    /// Foreground and walking: no fetch within this many seconds of the last fetch attempt.
    public static let foregroundInterval: TimeInterval = 60
    /// Walking: refresh once the position is at least this far (metres) from the list's centre.
    public static let walkingDistance = 250.0
    /// Background: never refresh above this speed (m/s); it is a drive, not a walk.
    public static let backgroundMaxSpeed = 8.0
    /// Background: no refresh within this many seconds of the last successful refresh, and never while the position
    /// is less than `foregroundDistance` from the list's centre, however old the list is.
    public static let backgroundInterval: TimeInterval = 600
    /// Article texts are fetched for at most this many of the nearest tier-top or tier-good candidates.
    public static let articleCount = 5
    /// When OpenStreetMap fails, the previous list's OSM places are carried forward if that list is at most this old
    /// (seconds, 7 days) and centred at most `carryDistance` (metres) from the new position (spec 13.6).
    public static let carryAge: TimeInterval = 7 * 86_400
    public static let carryDistance = 500.0

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
    /// How the last fetch per language ended; a refresh asked for within `foregroundInterval` of that fetch's start
    /// gets this instead of a new fetch.
    private var lastOutcome: [StoryLanguage: Result<NearbyList, Error>] = [:]
    /// Counts the fetched lists per language, so an article step finishing after a newer list arrived is dropped.
    private var generation: [StoryLanguage: Int] = [:]
    /// The article step of the newest list per language, while it runs.
    private var articleSteps: [StoryLanguage: Task<Void, Never>] = [:]
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

    /// Whether a fix at `position` should start a refresh (a list whose OpenStreetMap part failed counts as old from
    /// `NearbyList.osmFailedRetryAge` on, for foreground and walking):
    /// - foreground: no list, or the list is ≥ `foregroundDistance` away or older than `NearbyList.freshAge`;
    ///   never within `foregroundInterval` of the last fetch attempt;
    /// - walking: no list, or the list is ≥ `walkingDistance` away or older than `NearbyList.freshAge` (a list
    ///   loaded from disk days ago must not drive a walk); never within `foregroundInterval` of the last fetch
    ///   attempt, so a failing source is not retried on every fix. After a failed fetch, `failureRetry` (at most
    ///   `foregroundInterval`) replaces that interval: walking mode passes its feed's `failureRetryInterval`
    ///   (15, 30, then 60 s while its walk has no places, spec 19.6);
    /// - background: never above `backgroundMaxSpeed`, within `backgroundInterval` of the last refresh, or within
    ///   `foregroundInterval` of the last fetch attempt; then no list, or the list is ≥ `foregroundDistance` away.
    ///   Age alone never refreshes in the background: a phone lying at home must not fetch every 10 minutes.
    public func shouldRefresh(at position: Coordinate, trigger: RefreshTrigger, language: StoryLanguage,
                              failureRetry: TimeInterval? = nil) -> Bool {
        let now = now()
        let list = list(for: language)
        switch trigger {
        case .foreground:
            return foregroundRule(list, position: position, language: language, now: now)
        case .walking:
            let interval = attemptInterval(language: language, failureRetry: failureRetry)
            if Self.isWithin(interval, of: lastFetchAttempt[language], now: now) { return false }
            guard let list else { return true }
            return !list.serves(walkerAt: position, now: now)
        case .background(let speed):
            guard backgroundGates(speed: speed, language: language, now: now) else { return false }
            guard let list else { return true }
            return GeoMath.distance(list.centre, position) >= Self.foregroundDistance
        }
    }

    /// The background rule's gates that need no accurate position: false above `backgroundMaxSpeed` (when `speed` is
    /// known), within `backgroundInterval` of the last refresh, or within `foregroundInterval` of the last fetch
    /// attempt. A significant-change wake checks this before powering GPS for an accurate fix; `shouldRefresh`
    /// applies the same gates (and the distance rule) to that fix.
    public func backgroundMayRefresh(speed: Double?, language: StoryLanguage) -> Bool {
        backgroundGates(speed: speed, language: language, now: now())
    }

    /// Fetches a new list centred on `position` and keeps it, in memory and in the store, as soon as the candidates
    /// arrive; the article texts follow (see `articleTextsSettled`) without holding the caller.
    /// One fetch runs per language: a caller arriving while one is under way awaits that fetch (and gets a list
    /// centred where it started). A caller arriving within `foregroundInterval` of the start of a fetch that has
    /// already ended gets that fetch's result (the current list, or its error) instead of a new fetch, so two
    /// callers that both decided to refresh never fetch twice in a row. A failure keeps the old list and is thrown.
    /// A cancelled caller stops waiting with CancellationError; the fetch carries on for the others and is still kept.
    /// `failureRetry` shortens that interval after a failed fetch, as in `shouldRefresh`.
    @discardableResult
    public func refresh(at position: Coordinate, language: StoryLanguage,
                        failureRetry: TimeInterval? = nil) async throws -> NearbyList {
        let task: Task<NearbyList, Error>
        if let running = inFlight[language] {
            task = running
        } else {
            try Task.checkCancellation()
            let now = now()
            // Checked and recorded with no suspension in between, so the spacing holds for every caller.
            if Self.isWithin(attemptInterval(language: language, failureRetry: failureRetry),
                             of: lastFetchAttempt[language], now: now),
               let last = lastOutcome[language] {
                switch last {
                case .success(let fetched): return lists[language] ?? fetched
                case .failure(let error): throw error
                }
            }
            lastFetchAttempt[language] = now
            let fetcher = fetcher
            // Unstructured on purpose: one caller's cancellation must not fail the others waiting on the same fetch.
            // It runs on this actor, so it cannot start before `inFlight` is set below.
            task = Task {
                defer { inFlight[language] = nil }
                do {
                    let found = try await fetcher.candidates(around: position, language: language)
                    let fetchedAt = self.now()
                    let candidates = found.osmFailed
                        ? withCarriedOSMPlaces(found.candidates, around: position, language: language, now: fetchedAt)
                        : found.candidates
                    let list = NearbyList(centre: position, fetchedAt: fetchedAt, language: language,
                                          candidates: candidates,
                                          articleTexts: carriedArticleTexts(for: candidates, around: position,
                                                                            language: language),
                                          osmFailed: found.osmFailed, osmErrors: found.osmErrors,
                                          factsCount: found.factsCount, dropped: found.dropped,
                                          factsFailed: found.factsFailed)
                    generation[language, default: 0] += 1
                    keep(list)
                    lastOutcome[language] = .success(list)
                    startArticleStep(for: list)
                    return list
                } catch {
                    lastOutcome[language] = .failure(error)
                    throw error
                }
            }
            inFlight[language] = task
        }
        waitingCallers[language, default: 0] += 1
        defer { waitingCallers[language, default: 1] -= 1 }
        return try await Deadline.abandoningOnCancel { try await task.value }
    }

    /// Returns once the newest list's article step for `language` has ended (at once when none runs), or when the
    /// caller is cancelled: a background wake waits for it within its time cap. The texts are in `current(language:)`
    /// and the store by then, unless a newer list replaced the one they were for.
    public func articleTextsSettled(language: StoryLanguage) async {
        guard let step = articleSteps[language] else { return }
        _ = try? await Deadline.abandoningOnCancel { await step.value }
    }

    /// Callers currently awaiting a fetch for `language`; lets tests see a second caller join.
    func callersWaiting(language: StoryLanguage) -> Int {
        waitingCallers[language, default: 0]
    }

    // MARK: - Private

    /// How soon after the last fetch attempt a new one may start: `foregroundInterval`, or `failureRetry` (capped at
    /// `foregroundInterval`) when given and the last fetch that ended failed.
    private func attemptInterval(language: StoryLanguage, failureRetry: TimeInterval?) -> TimeInterval {
        guard let failureRetry, case .failure? = lastOutcome[language] else { return Self.foregroundInterval }
        return min(failureRetry, Self.foregroundInterval)
    }

    private func backgroundGates(speed: Double?, language: StoryLanguage, now: Date) -> Bool {
        // Read through `list(for:)` first, so a stored list seeds `lastRefresh` before the interval is judged.
        _ = list(for: language)
        if let speed, speed > Self.backgroundMaxSpeed { return false }
        if Self.isWithin(Self.backgroundInterval, of: lastRefresh[language], now: now) { return false }
        return !Self.isWithin(Self.foregroundInterval, of: lastFetchAttempt[language], now: now)
    }

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

    /// `candidates` (from a fetch whose OpenStreetMap part failed) with the previous list's OSM places merged in
    /// first, when that list is at most `carryAge` old (and not dated after `now`) and centred within `carryDistance`
    /// of `position`. Only places within `WalkingPlaceSource.radius` of `position` are carried, as a real fetch there
    /// would return, so carrying over several failed fetches never drags places along from far behind.
    private func withCarriedOSMPlaces(_ candidates: [Candidate], around position: Coordinate, language: StoryLanguage,
                                      now: Date) -> [Candidate] {
        guard let previous = list(for: language) else { return candidates }
        let age = now.timeIntervalSince(previous.fetchedAt)
        guard age >= 0, age <= Self.carryAge,
              GeoMath.distance(previous.centre, position) <= Self.carryDistance else { return candidates }
        let carried = previous.candidates.filter {
            $0.id.hasPrefix("osm:")
                && GeoMath.distance(position, $0.coordinate) <= Double(WalkingPlaceSource.radius)
        }
        guard !carried.isEmpty else { return candidates }
        return CandidateRanker.merge(osm: carried, wiki: candidates)
    }

    /// The previous list's texts for the titles the new candidates need, so a refresh nearby does not lose them while
    /// its article step runs.
    private func carriedArticleTexts(for candidates: [Candidate], around position: Coordinate,
                                     language: StoryLanguage) -> [String: String] {
        guard let previous = list(for: language)?.articleTexts, !previous.isEmpty else { return [:] }
        let titles = Set(Self.articleTitles(for: candidates, around: position))
        return previous.filter { titles.contains($0.key) }
    }

    /// Fetches the texts `list` still lacks and adds them to it, unless a newer list has arrived meanwhile.
    private func startArticleStep(for list: NearbyList) {
        let language = list.language
        let titles = Self.articleTitles(for: list.candidates, around: list.centre).filter { list.articleTexts[$0] == nil }
        guard let articles, !titles.isEmpty else {
            articleSteps[language] = nil
            return
        }
        let fetched = generation[language, default: 0]
        // Unstructured, like the fetch: no caller waits for it unless it asks (`articleTextsSettled`).
        articleSteps[language] = Task {
            let texts = await Self.articleTexts(for: titles, from: articles)
            guard generation[language, default: 0] == fetched else { return }
            articleSteps[language] = nil
            guard !texts.isEmpty, var current = lists[language] else { return }
            current.articleTexts.merge(texts) { _, new in new }
            keep(current)
        }
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

    /// Older than `NearbyList.freshAge`, or at least `NearbyList.osmFailedRetryAge` old when its OpenStreetMap part
    /// failed. A list dated in the future (the clock was set back) has an unknown age and counts as old.
    private static func isOld(_ list: NearbyList, now: Date) -> Bool {
        let age = now.timeIntervalSince(list.fetchedAt)
        return age > NearbyList.freshAge || age < 0 || list.isStaleAfterOSMFailure(age: age)
    }

    /// True when `date` lies less than `interval` before `now`. A date after `now` (the clock was set back) does
    /// not hold anything off.
    private static func isWithin(_ interval: TimeInterval, of date: Date?, now: Date) -> Bool {
        guard let date else { return false }
        let elapsed = now.timeIntervalSince(date)
        return elapsed >= 0 && elapsed < interval
    }

    /// Texts for `titles`, fetched concurrently; titles without a text are left out.
    static func articleTexts(for titles: [String], from source: ArticleTextSource) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self) { group in
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
    public static func articleTitles(for candidates: [Candidate], around position: Coordinate) -> [String] {
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
