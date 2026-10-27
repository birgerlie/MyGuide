import Testing
import Foundation
@testable import MyGuideCore

@Suite struct WikipediaClientTests {
    let vienna = Coordinate(latitude: 48.2082, longitude: 16.3738)
    static func page(_ id: Int, _ title: String, q: String?, coord: Bool = true) -> String {
        #"{"pageid":\#(id),"title":"\#(title)","extract":"\#(title) is old.""#
        + (coord ? #","coordinates":[{"lat":48.2086,"lon":16.3671}]"# : "")
        + (q.map { #","pageprops":{"wikibase_item":"\#($0)"}"# } ?? "") + "}"
    }
    static func body(_ pages: [String]) -> Data { Data(#"{"query":{"pages":[\#(pages.joined(separator: ","))]}}"#.utf8) }

    @Test func urlIsExact() {
        #expect(WikipediaClient.url(lang: "no", around: vienna, radius: 400).absoluteString ==
            "https://no.wikipedia.org/w/api.php?action=query&format=json&formatversion=2&generator=geosearch"
          + "&ggscoord=48.208200%7C16.373800&ggsradius=400&ggslimit=20&prop=coordinates%7Cextracts%7Cpageprops"
          + "&exintro=1&explaintext=1&exsentences=4&exlimit=20&ppprop=wikibase_item&colimit=20")
    }
    @Test func parsesPagesSkipsUncoordinated() async throws {
        let http = StubHTTPClient { _ in (200, Self.body([Self.page(1, "Hofburg", q: "Q2"), Self.page(2, "Nowhere", q: nil, coord: false),
                                                          Self.page(3, "Michaelerkirche", q: nil), Self.page(4, "Stephansdom", q: "Q4")])) }
        let c = try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .english)
        #expect(c.map(\.id) == ["wiki:en/1", "wiki:en/3", "wiki:en/4"])
        #expect(c[0] == Candidate(id: "wiki:en/1", name: "Hofburg", coordinate: .init(latitude: 48.2086, longitude: 16.3671),
                                  kind: "wikipedia", summary: "Hofburg is old.", wikipediaTitle: "en:Hofburg", wikidata: "Q2"))
        #expect(http.requests.count == 1)  // 3 results ≥ 3 → no English fallback needed anyway
        #expect(http.requests[0].value(forHTTPHeaderField: "User-Agent") == OverpassClient.userAgent)
    }
    @Test func norwegianFallsBackToEnglishWhenFewerThanThree() async throws {
        let http = StubHTTPClient { r in
            r.url!.host == "no.wikipedia.org"
              ? (200, Self.body([Self.page(10, "Hofburg", q: "Q2"), Self.page(11, "Stefansdomen", q: "Q4")]))
              : (200, Self.body([Self.page(1, "Hofburg", q: "Q2"), Self.page(3, "Michaelerkirche", q: "Q3")]))
        }
        let c = try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .norwegian)
        // Norwegian entries win on equal wikidata; English-only Q3 is added
        #expect(c.map(\.id) == ["wiki:no/10", "wiki:no/11", "wiki:en/3"])
        #expect(http.requests.count == 2)
    }
    @Test func norwegianWithThreeResultsIgnoresFallback() async throws {
        let http = StubHTTPClient { _ in (200, Self.body([Self.page(1, "A", q: nil), Self.page(2, "B", q: nil), Self.page(3, "C", q: nil)])) }
        let c = try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .norwegian)
        #expect(c.count == 3)
        // The English request now runs alongside the primary, so it is always issued.
        #expect(http.requests.count == 2)
    }
    @Test func englishRequestRunsConcurrentlyButIsIgnoredWhenPrimaryHasThree() async throws {
        let http = StubHTTPClient { r in
            r.url!.host == "no.wikipedia.org"
              ? (200, Self.body([Self.page(10, "A", q: "Q1"), Self.page(11, "B", q: nil), Self.page(12, "C", q: nil)]))
              : (200, Self.body([Self.page(1, "English only", q: "Q9"), Self.page(2, "Also English", q: nil)]))
        }
        let c = try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .norwegian)
        #expect(c.map(\.id) == ["wiki:no/10", "wiki:no/11", "wiki:no/12"])
        #expect(Set(http.requests.compactMap { $0.url?.host }) == ["no.wikipedia.org", "en.wikipedia.org"])
        #expect(http.requests.count == 2)
    }
    /// Holds the Norwegian response until the English request has arrived; a sequential client never sends it.
    final class EnglishFirstHTTP: HTTPClient, @unchecked Sendable {
        let englishSeen = LockedBox(false)
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url!.host == "en.wikipedia.org" {
                englishSeen.set(true)
                return (WikipediaClientTests.body([WikipediaClientTests.page(1, "E", q: nil)]), response)
            }
            let deadline = ContinuousClock.now + .seconds(2)
            while !englishSeen.value {
                guard ContinuousClock.now < deadline else { throw GroundingFetchError.http(599) }
                try await Task.sleep(for: .milliseconds(5))
            }
            return (WikipediaClientTests.body([WikipediaClientTests.page(10, "N", q: nil)]), response)
        }
    }
    @Test func englishRequestIsInFlightBeforePrimaryAnswers() async throws {
        let c = try await WikipediaClient(http: EnglishFirstHTTP()).articles(around: vienna, radius: 400, language: .norwegian)
        #expect(c.map(\.id) == ["wiki:no/10", "wiki:en/1"])
    }
    @Test func englishLanguageMakesOneRequest() async throws {
        let http = StubHTTPClient { _ in (200, Self.body([Self.page(1, "A", q: nil)])) }
        let c = try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .english)
        #expect(c.map(\.id) == ["wiki:en/1"] && http.requests.count == 1)
    }
    @Test func primaryFailureThrowsEvenWhenEnglishSucceeds() async {
        let http = StubHTTPClient { r in
            r.url!.host == "no.wikipedia.org" ? (502, Data()) : (200, Self.body([Self.page(1, "A", q: nil)]))
        }
        await #expect(throws: GroundingFetchError.http(502)) {
            try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .norwegian)
        }
    }
    @Test func englishFallbackFailureIsSwallowed() async throws {
        let http = StubHTTPClient { r in
            if r.url!.host == "no.wikipedia.org" { return (200, Self.body([Self.page(10, "Hofburg", q: "Q2")])) }
            return (503, Data())
        }
        let c = try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .norwegian)
        #expect(c.map(\.id) == ["wiki:no/10"])
        #expect(http.requests.count == 2)
    }
    @Test func primaryHttpErrorPropagates() async {
        let http = StubHTTPClient { _ in (500, Data()) }
        await #expect(throws: GroundingFetchError.http(500)) {
            try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .english)
        }
    }
    @Test func malformedBodyThrows() async {
        let http = StubHTTPClient { _ in (200, Data("not json".utf8)) }
        await #expect(throws: GroundingFetchError.malformed) {
            try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .english)
        }
    }
    @Test func bodyWithoutQueryMeansZeroResults() async throws {
        // MediaWiki omits "query" entirely when geosearch finds nothing.
        let http = StubHTTPClient { _ in (200, Data(#"{"batchcomplete":true}"#.utf8)) }
        let c = try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .english)
        #expect(c.isEmpty)
    }
    @Test func queryWithoutPagesMeansZeroResults() async throws {
        let http = StubHTTPClient { _ in (200, Data(#"{"query":{}}"#.utf8)) }
        let c = try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .english)
        #expect(c.isEmpty)
    }
    @Test func longSummaryIsTruncated() async throws {
        let long = Array(repeating: "word", count: 400).joined(separator: " ")
        let page = #"{"pageid":1,"title":"T","extract":"\#(long)","coordinates":[{"lat":1,"lon":2}]}"#
        let http = StubHTTPClient { _ in (200, Self.body([page])) }
        let c = try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .english)
        let summary = try #require(c[0].summary)
        #expect(summary.count <= WikipediaClient.summaryLimit + 1)
        #expect(summary.hasSuffix("word…"))
    }
    @Test func apiErrorBodyThrows() async {
        let http = StubHTTPClient { _ in (200, Data(#"{"error":{"code":"toobig","info":"too big"}}"#.utf8)) }
        await #expect(throws: GroundingFetchError.apiError("toobig")) {
            try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .english)
        }
    }
    @Test func apiErrorInFallbackIsSwallowed() async throws {
        let http = StubHTTPClient { r in
            r.url!.host == "no.wikipedia.org"
                ? (200, Self.body([Self.page(10, "Hofburg", q: "Q2")]))
                : (200, Data(#"{"error":{"code":"toobig","info":"x"}}"#.utf8))
        }
        let c = try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .norwegian)
        #expect(c.map(\.id) == ["wiki:no/10"])
    }
    @Test func cancellationInFallbackPropagates() async {
        let http = StubHTTPClient { r in
            if r.url!.host == "no.wikipedia.org" { return (200, Self.body([Self.page(10, "A", q: nil), Self.page(11, "B", q: nil)])) }
            throw CancellationError()
        }
        await #expect(throws: CancellationError.self) {
            try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .norwegian)
        }
    }
    @Test func truncateAtWordBoundary() {
        #expect(TextTrim.truncate("one two three", maxCharacters: 9) == "one two…")
        #expect(TextTrim.truncate("short", maxCharacters: 9) == "short")
        #expect(TextTrim.truncate("abcdefghijk", maxCharacters: 5) == "abcde…")  // no space: hard cut
        #expect(TextTrim.truncate("one two three", maxCharacters: 7) == "one two…")  // space exactly at the limit
        #expect(TextTrim.truncate("æøå æøå", maxCharacters: 5) == "æøå…")  // multibyte
        #expect(TextTrim.truncate("abc", maxCharacters: -1) == "…")  // negative clamps to 0
        #expect(TextTrim.truncate("exactly9!", maxCharacters: 9) == "exactly9!")
    }
}
