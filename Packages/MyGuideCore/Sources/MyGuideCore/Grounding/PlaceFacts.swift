import Foundation

/// What a Wikidata item is, for ranking (spec 19.1, 20.6, 20.2.6). Precedence: a metro station or treaty is
/// `nonPlace`; else a street or road is `street` (even when also a place); else a place is `place` (a work of art only
/// when it is not also an organisation, person or event); else a hill or island is `natural`; else a human settlement
/// is `settlement`; else a neighbourhood or administrative area is `area`; else `nonPlace`; else `unknown`.
public enum PlaceClass: String, Sendable, Codable {
    /// A building, monument, church, castle, square … (`WikidataClient.placeClasses`).
    case place
    /// A hill or an island: a place, but at most good, and it excludes no other place (spec 20.2.2).
    case natural
    /// A street or road: a place, but not a spot to stand at (spec 20.2.6; `area` before it).
    case street
    /// A neighbourhood or administrative area that is not a settlement; a Wikipedia-only one is dropped.
    case area
    /// An area that is a human settlement (a city, a district, a rione); a Wikipedia-only one is dropped.
    case settlement
    /// An organisation, person, event, metro station or treaty; never worth a buzz on its own.
    case nonPlace
    /// None of the known classes.
    case unknown
}

/// The Wikidata facts that rank a place: how many Wikipedia editions have an article, what kind of thing it is, and
/// the title of its article in the story language when the lookup asked for one (spec 20.2.6).
public struct PlaceFacts: Sendable, Equatable, Codable {
    public var sitelinks: Int
    public var placeClass: PlaceClass
    /// The item's article title on the story language's Wikipedia; nil when it has none or none was asked for.
    public var localTitle: String?

    public init(sitelinks: Int, placeClass: PlaceClass, localTitle: String? = nil) {
        self.sitelinks = sitelinks
        self.placeClass = placeClass
        self.localTitle = localTitle
    }
}

/// Disk cache of `PlaceFacts` by Wikidata id and title language (`WikidataClient.titleCode`: none, or the story
/// language other than English), valid for 30 days. An id Wikidata answered without a row (deleted or
/// merged items) is remembered for 7 days as "no facts"; an id in a failed batch is not stored, so a failure is
/// retried on the next call. Concurrent lookups of one id share a single request. A missing, unreadable or corrupt
/// file is an empty cache. The file name carries the format: when the class rule changes, a new name discards the
/// answers stored under the old rule (`legacyFileNames` are removed on load).
public actor PlaceFactsCache {
    /// How long a stored answer is used (spec 19).
    public static let lifetime: TimeInterval = 30 * 24 * 3600
    /// How long "Wikidata has no such item" is remembered.
    public static let negativeLifetime: TimeInterval = 7 * 24 * 3600
    /// Version 2: a place that is also an administrative area is `place` (final review 30 Oct). Version 3: hills,
    /// islands and settlements, and an organisation that is a place only as a work of art is `nonPlace` (spec 20.6).
    /// Version 4: streets and roads, natural places, metro stations and treaties, story-language titles, keys by
    /// title language (spec 20.2.6).
    static let fileName = "place-facts-v4.json"
    /// Files of earlier formats, deleted when the cache first loads.
    static let legacyFileNames = ["place-facts.json", "place-facts-v2.json", "place-facts-v3.json"]

    private struct Entry: Codable {
        /// Nil: Wikidata answered but has no row for the id.
        var facts: PlaceFacts?
        /// Seconds since 1970 when the answer was fetched.
        var fetchedAt: TimeInterval

        /// A negative age (the clock was set back) counts as expired.
        func isFresh(at time: TimeInterval) -> Bool {
            (0...(facts == nil ? PlaceFactsCache.negativeLifetime : PlaceFactsCache.lifetime)).contains(time - fetchedAt)
        }
    }

    private struct Flight {
        var key: Int
        var task: Task<WikidataClient.Answer, Error>
    }

    private let file: URL?
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var inFlight: [String: Flight] = [:]
    private var nextKey = 0

    /// A nil `directory` keeps the cache in memory only.
    public init(directory: URL?, now: @escaping @Sendable () -> Date = Date.init) {
        self.file = directory?.appendingPathComponent(Self.fileName)
        self.now = now
    }

    /// Cached facts younger than 30 days; looks up the missing ids through `client` and stores them. Never throws
    /// except `CancellationError` (the client leaves failed batches out).
    public func facts(for ids: [String], client: WikidataClient,
                      language: StoryLanguage? = nil) async throws -> [String: PlaceFacts] {
        try await lookup(ids: ids, client: client, language: language).facts
    }

    /// Like `facts(for:client:)`; `failedBatches` counts the failed batches of the requests this call waited for.
    /// `maxBatches` caps the ids this call sends to the client (`WikidataClient.lookup(ids:maxBatches:)`); ids it
    /// leaves out, or ids in flight for another caller's capped request that left them out, are not answered.
    /// `language` selects the title language (and so the cache keys); the answer is keyed by plain Wikidata id.
    public func lookup(ids: [String], client: WikidataClient, maxBatches: Int = WikidataClient.maxBatches,
                       language: StoryLanguage? = nil) async throws -> WikidataClient.Answer {
        loadIfNeeded()
        let code = WikidataClient.titleCode(language)
        func key(_ id: String) -> String { code.map { "\($0):\(id)" } ?? id }
        var answer = WikidataClient.Answer()
        var missing: [String] = []
        var seen = Set<String>()
        let current = now().timeIntervalSince1970
        for id in ids where WikidataClient.isValid(id) && seen.insert(id).inserted {
            if let entry = entries[key(id)], entry.isFresh(at: current) {
                answer.answered.insert(id)
                if let facts = entry.facts { answer.facts[id] = facts }
            } else {
                missing.append(id)
            }
        }
        guard !missing.isEmpty else { return answer }

        let fresh = missing.filter { inFlight[key($0)] == nil }
        if !fresh.isEmpty {
            let flightKey = nextKey
            nextKey += 1
            let keys = fresh.map(key)
            // Unstructured on purpose: one caller's cancellation must not fail the others waiting on the same ids.
            let task = Task<WikidataClient.Answer, Error> {
                do {
                    let fetched = try await client.lookup(ids: fresh, maxBatches: maxBatches, language: language)
                    complete(fresh, keys: keys, with: fetched)
                    return fetched
                } catch {
                    for key in keys { inFlight[key] = nil }
                    throw error
                }
            }
            for key in keys { inFlight[key] = Flight(key: flightKey, task: task) }
        }
        var waited = Set<Int>()
        var waitedFailures = 0
        for id in missing {
            guard let flight = inFlight[key(id)], waited.insert(flight.key).inserted else { continue }
            waitedFailures += try await flight.task.value.failedBatches
        }
        try Task.checkCancellation()
        answer.failedBatches = waitedFailures
        let after = now().timeIntervalSince1970
        for id in missing {
            guard let entry = entries[key(id)], entry.isFresh(at: after) else { continue }
            answer.answered.insert(id)
            if let facts = entry.facts { answer.facts[id] = facts }
        }
        return answer
    }

    /// Stores what a request answered (`ids` with their cache `keys`, in the same order) and lets later callers
    /// start new requests for its ids.
    private func complete(_ ids: [String], keys: [String], with fetched: WikidataClient.Answer) {
        let stamp = now().timeIntervalSince1970
        for (id, key) in zip(ids, keys) {
            inFlight[key] = nil
            if let facts = fetched.facts[id] {
                entries[key] = Entry(facts: facts, fetchedAt: stamp)
            } else if fetched.answered.contains(id) {
                entries[key] = Entry(facts: nil, fetchedAt: stamp)
            }
        }
        prune(at: stamp)
        save()
    }

    private func prune(at time: TimeInterval) {
        entries = entries.filter { $0.value.isFresh(at: time) }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let directory = file?.deletingLastPathComponent() {
            for name in Self.legacyFileNames {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        guard let file, let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = stored
        prune(at: now().timeIntervalSince1970)
    }

    /// Best effort: a failed write only costs a refetch.
    private func save() {
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: file, options: .atomic)
        } catch {}
    }
}

extension Array where Element == Candidate {
    /// Sets `sitelinks` and `placeClass` from `facts` (by `wikidata` id); candidates without facts are unchanged.
    /// With a `language`, a Wikipedia-only candidate whose article is in another language (an English article in a
    /// Norwegian walk) takes the item's `localTitle` as its name when there is one (spec 20.2.6).
    public func applying(_ facts: [String: PlaceFacts], language: StoryLanguage? = nil) -> [Candidate] {
        map { candidate in
            guard let id = candidate.wikidata, let found = facts[id] else { return candidate }
            var copy = candidate
            copy.sitelinks = found.sitelinks
            copy.placeClass = found.placeClass
            if let language, let title = found.localTitle, !title.isEmpty, candidate.id.hasPrefix("wiki:"),
               !candidate.id.hasPrefix("wiki:\(language.wikipediaCode)/") {
                copy.name = title
            }
            return copy
        }
    }
}

/// How a place source gets Wikidata facts: through a `PlaceFactsCache` and a `WikidataClient` in the app, or any
/// closure in tests. Without one, a source tiers by tags and articles alone, as before facts existed.
public struct PlaceFactsLookup: Sendable {
    /// The ids, the most batches of 50 the client may send for them (`WikidataClient.lookup(ids:maxBatches:)`), and
    /// the story language whose titles to read.
    private let lookup: @Sendable ([String], Int, StoryLanguage?) async throws -> WikidataClient.Answer

    /// A lookup that ignores the batch cap and the language.
    public init(_ lookup: @escaping @Sendable ([String]) async throws -> WikidataClient.Answer) {
        self.lookup = { ids, _, _ in try await lookup(ids) }
    }

    /// A lookup that is told the batch cap with the ids, and ignores the language.
    public init(capped lookup: @escaping @Sendable (_ ids: [String], _ maxBatches: Int) async throws -> WikidataClient.Answer) {
        self.lookup = { ids, maxBatches, _ in try await lookup(ids, maxBatches) }
    }

    /// A lookup that is told the batch cap and the story language with the ids.
    public init(full lookup: @escaping @Sendable (_ ids: [String], _ maxBatches: Int,
                                                  _ language: StoryLanguage?) async throws -> WikidataClient.Answer) {
        self.lookup = lookup
    }

    public init(cache: PlaceFactsCache, client: WikidataClient) {
        self.init(full: { ids, maxBatches, language in
            try await cache.lookup(ids: ids, client: client, maxBatches: maxBatches, language: language)
        })
    }

    /// The facts for `ids`, at most `maxBatches` batches of 50 of them (walking keeps the default 6; tours ask for
    /// `WikidataClient.tourMaxBatches`); an empty answer for no ids, without a call. Never throws except
    /// CancellationError (also for `URLError.cancelled`): any other error is an answer without facts that counts as one
    /// failed batch, so a failing lookup leaves every tier as it was.
    func answer(for ids: [String], maxBatches: Int = WikidataClient.maxBatches,
                language: StoryLanguage? = nil) async throws -> WikidataClient.Answer {
        guard !ids.isEmpty else { return WikidataClient.Answer() }
        do {
            return try await lookup(ids, maxBatches, language)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            return WikidataClient.Answer(failedBatches: 1)
        }
    }

    /// The Wikidata ids of `candidates`, each once, those without OSM tags first: their tier depends on the facts,
    /// while an OSM candidate only gains sitelinks for the buzz order, so they go first when the client has to leave
    /// ids out (more than `WikidataClient.batchSize` times the call's batch cap).
    static func ids(of candidates: [Candidate]) -> [String] {
        var seen = Set<String>()
        let untagged = candidates.filter { !PlaceTiers.hasOSMTags($0) }
        let tagged = candidates.filter { PlaceTiers.hasOSMTags($0) }
        return (untagged + tagged).compactMap(\.wikidata).filter { seen.insert($0).inserted }
    }
}

/// Candidates with their Wikidata facts applied, and what the walk log says about them (spec 19.8).
struct PlaceFactsEnrichment: Sendable, Equatable {
    var candidates: [Candidate]
    /// Candidates that received facts.
    var factsCount: Int
    /// Names of the candidates the tiering drops for their Wikidata class (`PlaceTiers.isDroppedByClass`: a
    /// non-place, a settlement or a small area), in list order. A blank name is left out: the name rule drops that
    /// candidate, not its class.
    var dropped: [String]

    init(_ candidates: [Candidate], facts: [String: PlaceFacts], language: StoryLanguage? = nil) {
        self.candidates = candidates.applying(facts, language: language)
        factsCount = candidates.filter { $0.wikidata.map { facts[$0] != nil } ?? false }.count
        dropped = self.candidates.filter(PlaceTiers.isDroppedByClass).map(\.name)
    }
}
