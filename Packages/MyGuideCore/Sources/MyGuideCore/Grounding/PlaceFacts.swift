import Foundation

/// What a Wikidata item is, for ranking: the class precedence is area > place > nonPlace > unknown (spec 19.1).
public enum PlaceClass: String, Sendable, Codable {
    /// A building, monument, church, castle … (`WikidataClient.placeClasses`).
    case place
    /// A street, square or district: a place, but not a spot to stand at.
    case area
    /// An organisation, person or event; never worth a buzz on its own.
    case nonPlace
    /// None of the known classes.
    case unknown
}

/// The Wikidata facts that rank a place: how many Wikipedia editions have an article, and what kind of thing it is.
public struct PlaceFacts: Sendable, Equatable, Codable {
    public var sitelinks: Int
    public var placeClass: PlaceClass

    public init(sitelinks: Int, placeClass: PlaceClass) {
        self.sitelinks = sitelinks
        self.placeClass = placeClass
    }
}

/// Disk cache of `PlaceFacts` by Wikidata id, valid for 30 days. An id Wikidata answered without a row (deleted or
/// merged items) is remembered for 7 days as "no facts"; an id in a failed batch is not stored, so a failure is
/// retried on the next call. Concurrent lookups of one id share a single request. A missing, unreadable or corrupt
/// file is an empty cache.
public actor PlaceFactsCache {
    /// How long a stored answer is used (spec 19).
    public static let lifetime: TimeInterval = 30 * 24 * 3600
    /// How long "Wikidata has no such item" is remembered.
    public static let negativeLifetime: TimeInterval = 7 * 24 * 3600
    static let fileName = "place-facts.json"

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
    public func facts(for ids: [String], client: WikidataClient) async throws -> [String: PlaceFacts] {
        try await lookup(ids: ids, client: client).facts
    }

    /// Like `facts(for:client:)`; `failedBatches` counts the failed batches of the requests this call waited for.
    public func lookup(ids: [String], client: WikidataClient) async throws -> WikidataClient.Answer {
        loadIfNeeded()
        var answer = WikidataClient.Answer()
        var missing: [String] = []
        var seen = Set<String>()
        let current = now().timeIntervalSince1970
        for id in ids where WikidataClient.isValid(id) && seen.insert(id).inserted {
            if let entry = entries[id], entry.isFresh(at: current) {
                answer.answered.insert(id)
                if let facts = entry.facts { answer.facts[id] = facts }
            } else {
                missing.append(id)
            }
        }
        guard !missing.isEmpty else { return answer }

        let fresh = missing.filter { inFlight[$0] == nil }
        if !fresh.isEmpty {
            let key = nextKey
            nextKey += 1
            // Unstructured on purpose: one caller's cancellation must not fail the others waiting on the same ids.
            let task = Task<WikidataClient.Answer, Error> {
                do {
                    let fetched = try await client.lookup(ids: fresh)
                    complete(fresh, with: fetched)
                    return fetched
                } catch {
                    for id in fresh { inFlight[id] = nil }
                    throw error
                }
            }
            for id in fresh { inFlight[id] = Flight(key: key, task: task) }
        }
        var waited = Set<Int>()
        var waitedFailures = 0
        for id in missing {
            guard let flight = inFlight[id], waited.insert(flight.key).inserted else { continue }
            waitedFailures += try await flight.task.value.failedBatches
        }
        try Task.checkCancellation()
        answer.failedBatches = waitedFailures
        let after = now().timeIntervalSince1970
        for id in missing {
            guard let entry = entries[id], entry.isFresh(at: after) else { continue }
            answer.answered.insert(id)
            if let facts = entry.facts { answer.facts[id] = facts }
        }
        return answer
    }

    /// Stores what a request answered and lets later callers start new requests for its ids.
    private func complete(_ ids: [String], with fetched: WikidataClient.Answer) {
        let stamp = now().timeIntervalSince1970
        for id in ids {
            inFlight[id] = nil
            if let facts = fetched.facts[id] {
                entries[id] = Entry(facts: facts, fetchedAt: stamp)
            } else if fetched.answered.contains(id) {
                entries[id] = Entry(facts: nil, fetchedAt: stamp)
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
    public func applying(_ facts: [String: PlaceFacts]) -> [Candidate] {
        map { candidate in
            guard let id = candidate.wikidata, let found = facts[id] else { return candidate }
            var copy = candidate
            copy.sitelinks = found.sitelinks
            copy.placeClass = found.placeClass
            return copy
        }
    }
}
