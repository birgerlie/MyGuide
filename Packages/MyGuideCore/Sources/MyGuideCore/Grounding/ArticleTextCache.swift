import Foundation

public protocol ArticleTextSource: Sendable {
    /// The article text, or nil on any failure or after the timeout. Never throws.
    func text(wikipediaTitle: String) async -> String?
}

/// Process-wide LRU cache of article texts. Only successes are stored, so a failure is retried on the next call.
public actor ArticleTextCache: ArticleTextSource {
    public static let capacity = 50

    private let client: WikipediaClient
    private let timeout: Duration
    private var texts: [String: String] = [:]
    /// Least recently used first.
    private var order: [String] = []
    /// Fetches under way, so concurrent callers for one title share a single request.
    private var inFlight: [String: Task<String?, Never>] = [:]

    public init(client: WikipediaClient, timeout: Duration = .seconds(5)) {
        self.client = client
        self.timeout = timeout
    }

    public func text(wikipediaTitle: String) async -> String? {
        if let hit = texts[wikipediaTitle] {
            touch(wikipediaTitle)
            return hit
        }
        if let running = inFlight[wikipediaTitle] { return await running.value }
        let client = client
        let timeout = timeout
        // Unstructured on purpose: one caller's cancellation must not fail the others waiting on the same fetch.
        let task = Task<String?, Never> {
            let fetched = try? await Deadline.withTimeout(timeout) {
                try await client.articleText(wikipediaTitle: wikipediaTitle)
            }
            if let fetched { store(fetched, for: wikipediaTitle) }
            inFlight[wikipediaTitle] = nil
            return fetched
        }
        inFlight[wikipediaTitle] = task
        return await task.value
    }

    private func store(_ text: String, for key: String) {
        texts[key] = text
        touch(key)
        if order.count > Self.capacity {
            texts[order.removeFirst()] = nil
        }
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
