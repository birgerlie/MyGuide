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

    public init(client: WikipediaClient, timeout: Duration = .seconds(5)) {
        self.client = client
        self.timeout = timeout
    }

    public func text(wikipediaTitle: String) async -> String? {
        if let hit = texts[wikipediaTitle] {
            touch(wikipediaTitle)
            return hit
        }
        let client = client
        guard let fetched = try? await GroundingService.withTimeout(timeout, {
            try await client.articleText(wikipediaTitle: wikipediaTitle)
        }) else { return nil }
        // The actor may have re-entered during the await: another call can have stored the same title.
        texts[wikipediaTitle] = fetched
        touch(wikipediaTitle)
        if order.count > Self.capacity {
            texts[order.removeFirst()] = nil
        }
        return fetched
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
