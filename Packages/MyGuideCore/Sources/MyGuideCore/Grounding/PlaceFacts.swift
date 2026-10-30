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

/// Disk cache of `PlaceFacts` by Wikidata id, valid for 30 days. Only found facts are stored, so a failed or empty
/// lookup is retried on the next call. A missing, unreadable or corrupt file is an empty cache.
public actor PlaceFactsCache {
    /// How long a stored answer is used (spec 19).
    public static let lifetime: TimeInterval = 30 * 24 * 3600
    static let fileName = "place-facts.json"

    private struct Entry: Codable {
        var facts: PlaceFacts
        /// Seconds since 1970 when the answer was fetched.
        var fetchedAt: TimeInterval
    }

    private let file: URL?
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    private var loaded = false

    /// A nil `directory` keeps the cache in memory only.
    public init(directory: URL?, now: @escaping @Sendable () -> Date = Date.init) {
        self.file = directory?.appendingPathComponent(Self.fileName)
        self.now = now
    }

    /// Cached facts younger than 30 days; looks up the missing ids through `client` and stores them. Never throws
    /// except `CancellationError` (the client leaves failed batches out).
    public func facts(for ids: [String], client: WikidataClient) async throws -> [String: PlaceFacts] {
        loadIfNeeded()
        let current = now().timeIntervalSince1970
        var result: [String: PlaceFacts] = [:]
        var missing: [String] = []
        var seen = Set<String>()
        for id in ids where WikidataClient.isValid(id) && seen.insert(id).inserted {
            if let entry = entries[id], current - entry.fetchedAt <= Self.lifetime {
                result[id] = entry.facts
            } else {
                missing.append(id)
            }
        }
        guard !missing.isEmpty else { return result }
        let fetched = try await client.facts(for: missing)
        guard !fetched.isEmpty else { return result }
        let stamp = now().timeIntervalSince1970
        for (id, facts) in fetched {
            entries[id] = Entry(facts: facts, fetchedAt: stamp)
            result[id] = facts
        }
        entries = entries.filter { stamp - $0.value.fetchedAt <= Self.lifetime }
        save()
        return result
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let file, let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = stored
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
