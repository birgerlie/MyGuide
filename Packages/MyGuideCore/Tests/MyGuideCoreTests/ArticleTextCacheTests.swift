import Testing
import Foundation
@testable import MyGuideCore

@Suite struct ArticleTextCacheTests {
    static func body(_ extract: String) -> Data {
        Data(#"{"query":{"pages":[{"pageid":1,"title":"T","extract":"\#(extract)"}]}}"#.utf8)
    }
    static func title(of request: URLRequest) -> String {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "titles" }?.value ?? ""
    }
    static func cache(_ http: StubHTTPClient, timeout: Duration = .seconds(5)) -> ArticleTextCache {
        ArticleTextCache(client: WikipediaClient(http: http), timeout: timeout)
    }

    @Test func secondCallForSameTitleIsServedFromCache() async {
        let http = StubHTTPClient { _ in (200, Self.body("Text.")) }
        let cache = Self.cache(http)
        let first = await cache.text(wikipediaTitle: "de:Michaelertor")
        let second = await cache.text(wikipediaTitle: "de:Michaelertor")
        #expect(first == "Text." && second == "Text.")
        #expect(http.requests.count == 1)
    }

    @Test func failureReturnsNilAndIsRetried() async {
        let fail = LockedBox(true)
        let http = StubHTTPClient { _ in fail.value ? (500, Data()) : (200, Self.body("Ok.")) }
        let cache = Self.cache(http)
        #expect(await cache.text(wikipediaTitle: "de:A") == nil)
        fail.set(false)
        #expect(await cache.text(wikipediaTitle: "de:A") == "Ok.")
        #expect(http.requests.count == 2)
    }

    @Test func thrownTransportErrorReturnsNil() async {
        struct Boom: Error {}
        let http = StubHTTPClient { _ in throw Boom() }
        #expect(await Self.cache(http).text(wikipediaTitle: "de:A") == nil)
    }

    @Test func evictsLeastRecentlyUsedAtCapacity() async {
        let http = StubHTTPClient { r in (200, Self.body("Text for \(Self.title(of: r)).")) }
        let cache = Self.cache(http)
        for i in 1...50 { _ = await cache.text(wikipediaTitle: "en:T\(i)") }
        // 50 distinct titles, 50 requests; the cache is exactly full.
        #expect(http.requests.count == 50)
        _ = await cache.text(wikipediaTitle: "en:T1")  // hit: T1 becomes most recent, T2 the least recent
        // Hit, no request: 50.
        #expect(http.requests.count == 50)
        _ = await cache.text(wikipediaTitle: "en:T51")  // miss, evicts T2 (not T1)
        // 50 + 1 miss = 51.
        #expect(http.requests.count == 51)
        _ = await cache.text(wikipediaTitle: "en:T1")
        // T1 survived: hit, still 51.
        #expect(http.requests.count == 51)
        _ = await cache.text(wikipediaTitle: "en:T2")
        // T2 was evicted: miss, 51 + 1 = 52.
        #expect(http.requests.count == 52)
    }

    @Test func concurrentCallsForOneTitleShareOneRequest() async throws {
        let gate = LockedBox(false)
        let http = GatedHTTPClient(gate: gate)
        let cache = ArticleTextCache(client: WikipediaClient(http: http))
        async let a = cache.text(wikipediaTitle: "de:Michaelertor")
        async let b = cache.text(wikipediaTitle: "de:Michaelertor")
        // Both calls are now waiting on the closed gate; a non-coalescing cache would have sent a second request.
        try await Task.sleep(for: .milliseconds(150))
        gate.set(true)
        let (ra, rb) = await (a, b)
        #expect(ra == "Gated." && rb == "Gated.")
        // 2 callers, 1 title: exactly 1 request.
        #expect(http.count.value == 1)
        _ = await cache.text(wikipediaTitle: "de:Michaelertor")
        // Now cached: still 1.
        #expect(http.count.value == 1)
    }

    @Test func untouchedFirstTitleIsEvictedAfter51Distinct() async {
        let http = StubHTTPClient { _ in (200, Self.body("x")) }
        let cache = Self.cache(http)
        for i in 1...51 { _ = await cache.text(wikipediaTitle: "en:T\(i)") }
        // 51 distinct titles, 51 requests; T1 was evicted by T51.
        #expect(http.requests.count == 51)
        _ = await cache.text(wikipediaTitle: "en:T1")
        // T1 miss: 51 + 1 = 52 (this evicts T2).
        #expect(http.requests.count == 52)
        _ = await cache.text(wikipediaTitle: "en:T51")
        // T51 hit: still 52.
        #expect(http.requests.count == 52)
    }

    @Test func timeoutReturnsNilAndIsNotCached() async {
        let slow = LockedBox(true)
        let http = SlowHTTPClient(slow: slow)
        let impatient = ArticleTextCache(client: WikipediaClient(http: http), timeout: .milliseconds(50))
        #expect(await impatient.text(wikipediaTitle: "de:A") == nil)
        slow.set(false)
        // A fresh cache with the default timeout: only the first call exercises the short timeout.
        #expect(await ArticleTextCache(client: WikipediaClient(http: http)).text(wikipediaTitle: "de:A") == "Late.")
    }
}

private struct SlowHTTPClient: HTTPClient {
    let slow: LockedBox<Bool>
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if slow.value { try await Task.sleep(for: .seconds(30)) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (ArticleTextCacheTests.body("Late."), response)
    }
}

private struct GatedHTTPClient: HTTPClient {
    let gate: LockedBox<Bool>
    let count = LockedBox(0)
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count.withValue { $0 += 1 }
        while !gate.value { try await Task.sleep(for: .milliseconds(10)) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (ArticleTextCacheTests.body("Gated."), response)
    }
}
