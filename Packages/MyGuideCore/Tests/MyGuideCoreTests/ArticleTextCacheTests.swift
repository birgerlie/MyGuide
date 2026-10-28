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
        // Titles 1...50 fill the cache exactly; 51 evicts the oldest, which is title 1.
        for i in 1...50 { _ = await cache.text(wikipediaTitle: "en:T\(i)") }
        #expect(http.requests.count == 50)
        _ = await cache.text(wikipediaTitle: "en:T1")  // touch: now T2 is the least recent
        #expect(http.requests.count == 50)
        _ = await cache.text(wikipediaTitle: "en:T51")  // evicts T2, not T1
        #expect(http.requests.count == 51)
        _ = await cache.text(wikipediaTitle: "en:T1")
        #expect(http.requests.count == 51)
        _ = await cache.text(wikipediaTitle: "en:T2")
        #expect(http.requests.count == 52)
    }

    @Test func untouchedFirstTitleIsEvictedAfter51Distinct() async {
        let http = StubHTTPClient { _ in (200, Self.body("x")) }
        let cache = Self.cache(http)
        for i in 1...51 { _ = await cache.text(wikipediaTitle: "en:T\(i)") }
        #expect(http.requests.count == 51)
        _ = await cache.text(wikipediaTitle: "en:T1")
        #expect(http.requests.count == 52)
        _ = await cache.text(wikipediaTitle: "en:T51")
        #expect(http.requests.count == 52)
    }

    @Test func timeoutReturnsNilAndIsNotCached() async {
        let slow = LockedBox(true)
        let http = SlowHTTPClient(slow: slow)
        let cache = ArticleTextCache(client: WikipediaClient(http: http), timeout: .milliseconds(50))
        #expect(await cache.text(wikipediaTitle: "de:A") == nil)
        slow.set(false)
        #expect(await cache.text(wikipediaTitle: "de:A") == "Late.")
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
