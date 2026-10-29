import CryptoKit
import Foundation

/// A place's Wikipedia page image (thumbnail about 600 px) and its credit from the file's metadata.
public struct PlaceImageInfo: Sendable, Equatable, Codable {
    public var thumbnailURL: URL
    /// Plain text (the file page's Artist HTML reduced); nil when the file names no author.
    public var author: String?
    /// Short licence name, e.g. "CC BY-SA 4.0".
    public var licence: String?
    /// The file's description page (Commons, or the article's wiki for a local file).
    public var filePage: URL?

    public init(thumbnailURL: URL, author: String? = nil, licence: String? = nil, filePage: URL? = nil) {
        self.thumbnailURL = thumbnailURL
        self.author = author
        self.licence = licence
        self.filePage = filePage
    }
}

/// A cached picture: the thumbnail's file on disk and its credit.
public struct StoredPlaceImage: Sendable, Equatable {
    public var fileURL: URL
    public var info: PlaceImageInfo

    public init(fileURL: URL, info: PlaceImageInfo) {
        self.fileURL = fileURL
        self.info = info
    }
}

/// Disk cache of place pictures, keyed by the language-prefixed article title.
/// Each title is stored as `<SHA-256 hex of title>.jpg` plus `.json` holding the `PlaceImageInfo` and the fetch time.
/// A picture is kept for good; a "no image" answer is a `.json` without info and is trusted for 7 days.
/// Failures (network, HTTP, API, malformed replies, a picture without credit) are not stored on disk; in memory they
/// hold the title back for 5 minutes, after which the next call tries again.
public actor PlaceImages {
    public static let notificationCap: Duration = .milliseconds(1500)
    /// How long a "no image" answer is trusted: 7 × 86 400 s.
    static let noImageLifetime: TimeInterval = 7 * 86_400
    /// How long a failed title is left alone: 5 × 60 s.
    static let failureCooldown: TimeInterval = 5 * 60

    private let directory: URL
    private let client: WikipediaClient
    private let now: @Sendable () -> Date
    /// Fetches under way, so concurrent callers for one title share a single fetch.
    private var inFlight: [String: Task<StoredPlaceImage?, Never>] = [:]
    /// When each title last failed (in memory only).
    private var failedAt: [String: Date] = [:]
    /// How many callers joined a fetch already under way, and who waits for that count (lets tests see that a
    /// second caller is waiting).
    private(set) var joinedFetches = 0
    private var joinWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    public init(directory: URL, client: WikipediaClient, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.client = client
        self.now = now
    }

    public func cached(wikipediaTitle: String) -> StoredPlaceImage? {
        guard let info = record(for: wikipediaTitle)?.info else { return nil }
        let file = pictureURL(for: wikipediaTitle)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return StoredPlaceImage(fileURL: file, info: info)
    }

    /// Fetch once (in-flight requests merged per title); a "no image" answer is remembered for 7 days.
    /// nil for no image, a malformed title, any failure (and for 5 minutes after one), or when the caller is
    /// cancelled: the caller stops waiting, the fetch continues and fills the cache.
    public func image(wikipediaTitle: String) async -> StoredPlaceImage? {
        switch lookup(wikipediaTitle) {
        case .done(let image): return image
        case .running(let fetch): return await Self.waitAbandoningOnCancel(fetch)
        }
    }

    /// `image` raced against `cap`; nil past the cap (the fetch continues and fills the cache).
    public func image(wikipediaTitle: String, within cap: Duration) async -> StoredPlaceImage? {
        switch lookup(wikipediaTitle) {
        case .done(let image):
            return image
        case .running(let fetch):
            // The fetch is already started and owned by the actor; only the waiting is capped. Waiting on
            // `fetch.value` ignores cancellation, so withTimeout abandons the waiter instead of holding the race open.
            return (try? await GroundingService.withTimeout(cap) { await fetch.value }) ?? nil
        }
    }

    /// Starts the fetches for all titles not yet cached (each title once) and waits for them. A cancelled caller
    /// stops waiting at once; the fetches continue and fill the cache.
    public func prefetch(_ titles: [String]) async {
        var seen: Set<String> = []
        var fetches: [Task<StoredPlaceImage?, Never>] = []
        for title in titles where seen.insert(title).inserted {
            if case .running(let fetch) = lookup(title) { fetches.append(fetch) }
        }
        for fetch in fetches {
            _ = await Self.waitAbandoningOnCancel(fetch)
            if Task.isCancelled { return }
        }
    }

    /// Waits for `fetch` until the caller is cancelled (then nil); waiting on `fetch.value` alone ignores cancellation.
    private static func waitAbandoningOnCancel(_ fetch: Task<StoredPlaceImage?, Never>) async -> StoredPlaceImage? {
        (try? await GroundingService.abandoningOnCancel { await fetch.value }) ?? nil
    }

    /// Returns once at least `count` callers have joined a fetch under way.
    func waitForJoinedFetches(_ count: Int) async {
        guard joinedFetches < count else { return }
        await withCheckedContinuation { joinWaiters.append((count, $0)) }
    }

    /// The title to use for a candidate: its wikipediaTitle, or "code:" + name for a "wiki:code/…" id; nil otherwise.
    public static func title(for candidate: Candidate) -> String? {
        if let title = candidate.wikipediaTitle, !title.isEmpty { return title }
        guard candidate.id.hasPrefix("wiki:"), !candidate.name.isEmpty else { return nil }
        let rest = candidate.id.dropFirst("wiki:".count)
        guard let slash = rest.firstIndex(of: "/"), slash > rest.startIndex else { return nil }
        return "\(rest[..<slash]):\(candidate.name)"
    }

    // MARK: Fetching

    private enum Lookup {
        case done(StoredPlaceImage?)
        case running(Task<StoredPlaceImage?, Never>)
    }

    /// Answers from the cache when it can; otherwise joins or starts the fetch. Synchronous on the actor, so a
    /// fetch is registered before any caller suspends.
    private func lookup(_ title: String) -> Lookup {
        guard (try? WikipediaClient.split(wikipediaTitle: title)) != nil else { return .done(nil) }
        if let hit = cached(wikipediaTitle: title) { return .done(hit) }
        if let running = inFlight[title] {
            joinedFetches += 1
            let ready = joinWaiters.filter { $0.count <= joinedFetches }
            joinWaiters.removeAll { $0.count <= joinedFetches }
            ready.forEach { $0.continuation.resume() }
            return .running(running)
        }
        if remembersNoImage(for: title) || isCoolingDown(title) { return .done(nil) }
        // Unstructured on purpose: it outlives a capped or cancelled caller, so the cache is still filled.
        let fetch = Task<StoredPlaceImage?, Never> {
            let result = await self.fetch(title)
            self.inFlight[title] = nil
            return result
        }
        inFlight[title] = fetch
        return .running(fetch)
    }

    /// nil for "no image" (remembered on disk) and for a failure (held back in memory by `failureCooldown`).
    private func fetch(_ title: String) async -> StoredPlaceImage? {
        do {
            guard let info = try await client.pageImage(wikipediaTitle: title) else {
                try? FileManager.default.removeItem(at: pictureURL(for: title))
                try? save(Record(info: nil, fetchedAt: now()), for: title)
                failedAt[title] = nil
                return nil
            }
            let data = try await client.imageData(info.thumbnailURL)
            let file = pictureURL(for: title)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // The picture first: a record with info always has its picture beside it.
            try data.write(to: file, options: .atomic)
            try save(Record(info: info, fetchedAt: now()), for: title)
            failedAt[title] = nil
            return StoredPlaceImage(fileURL: file, info: info)
        } catch {
            failedAt[title] = now()
            return nil
        }
    }

    private func isCoolingDown(_ title: String) -> Bool {
        guard let failed = failedAt[title] else { return false }
        let age = now().timeIntervalSince(failed)
        // A time ahead of now (the clock moved back) is not trusted.
        return age >= 0 && age < Self.failureCooldown
    }

    private func remembersNoImage(for title: String) -> Bool {
        guard let record = record(for: title), record.info == nil else { return false }
        let age = now().timeIntervalSince(record.fetchedAt)
        // A time ahead of now (the clock moved back) is not trusted.
        return age >= 0 && age < Self.noImageLifetime
    }

    // MARK: Storage

    private struct Record: Codable {
        var info: PlaceImageInfo?
        var fetchedAt: Date
    }

    private func record(for title: String) -> Record? {
        guard let data = try? Data(contentsOf: recordURL(for: title)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func save(_ record: Record, for title: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: recordURL(for: title), options: .atomic)
    }

    private func pictureURL(for title: String) -> URL {
        directory.appendingPathComponent(Self.key(for: title)).appendingPathExtension("jpg")
    }

    private func recordURL(for title: String) -> URL {
        directory.appendingPathComponent(Self.key(for: title)).appendingPathExtension("json")
    }

    private static func key(for title: String) -> String {
        SHA256.hash(data: Data(title.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
