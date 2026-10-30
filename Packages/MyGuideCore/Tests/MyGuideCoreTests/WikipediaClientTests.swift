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
    @Test func urlUsesLimit() {
        let url = WikipediaClient.url(lang: "en", around: .init(latitude: 0, longitude: 0), radius: 500, limit: 50).absoluteString
        #expect(url.contains("ggslimit=50") && url.contains("colimit=50") && url.contains("exlimit=20"))
        let def = WikipediaClient.url(lang: "en", around: .init(latitude: 0, longitude: 0), radius: 500).absoluteString
        #expect(def.contains("ggslimit=20") && def.contains("colimit=20"))
    }
    @Test func articlesPassesLimitToRequest() async throws {
        let http = StubHTTPClient { _ in (200, Self.body([])) }
        _ = try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .english, limit: 50)
        #expect(http.requests[0].url!.absoluteString.contains("ggslimit=50"))
    }
    @Test func parsesPagesSkipsUncoordinated() async throws {
        let http = StubHTTPClient { _ in (200, Self.body([Self.page(1, "Hofburg", q: "Q2"), Self.page(2, "Nowhere", q: nil, coord: false),
                                                          Self.page(3, "Michaelerkirche", q: nil), Self.page(4, "Stephansdom", q: "Q4")])) }
        let c = try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .english)
        #expect(c.map(\.id) == ["wiki:en/1", "wiki:en/3", "wiki:en/4"])
        #expect(c[0] == Candidate(id: "wiki:en/1", name: "Hofburg", coordinate: .init(latitude: 48.2086, longitude: 16.3671),
                                  kind: "wikipedia", summary: "Hofburg is old.", wikipediaTitle: "en:Hofburg", wikidata: "Q2",
                                  summaryLanguage: "en"))
        #expect(http.requests.count == 1)  // English: no second geosearch
        #expect(http.requests[0].value(forHTTPHeaderField: "User-Agent") == OverpassClient.userAgent)
    }
    @Test func norwegianMergesEnglishWhenFewerThanThree() async throws {
        let http = StubHTTPClient { r in
            r.url!.host == "no.wikipedia.org"
              ? (200, Self.body([Self.page(10, "Hofburg", q: "Q2"), Self.page(11, "Stefansdomen", q: "Q4")]))
              : (200, Self.body([Self.page(1, "Hofburg", q: "Q2"), Self.page(3, "Michaelerkirche", q: "Q3")]))
        }
        let c = try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .norwegian)
        // Norwegian entries win on equal wikidata; English-only Q3 is added
        #expect(c.map(\.id) == ["wiki:no/10", "wiki:no/11", "wiki:en/3"])
        #expect(c.map(\.summaryLanguage) == ["no", "no", "en"])
        #expect(http.requests.count == 2)
    }
    @Test func norwegianWithThreeResultsStillMergesEnglish() async throws {
        // Spec 20.1: Norwegian articles often lack coordinates (Trevi, Campo de' Fiori), so the English geosearch is
        // merged however many Norwegian results there are. Q1 is in both: the Norwegian page wins (name, summary,
        // language); English Q9 and the English page without an id are added after the Norwegian ones.
        let http = StubHTTPClient { r in
            r.url!.host == "no.wikipedia.org"
              ? (200, Self.body([Self.page(10, "A", q: "Q1"), Self.page(11, "B", q: nil), Self.page(12, "C", q: nil)]))
              : (200, Self.body([Self.page(1, "A in English", q: "Q1"), Self.page(2, "Trevi Fountain", q: "Q9"),
                                 Self.page(3, "Also English", q: nil)]))
        }
        let c = try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .norwegian)
        #expect(c.map(\.id) == ["wiki:no/10", "wiki:no/11", "wiki:no/12", "wiki:en/2", "wiki:en/3"])
        #expect(c[0].name == "A" && c[0].summary == "A is old." && c[0].summaryLanguage == "no")
        #expect(c[3].name == "Trevi Fountain" && c[3].summaryLanguage == "en" && c[3].wikipediaTitle == "en:Trevi Fountain")
        #expect(Set(http.requests.compactMap { $0.url?.host }) == ["no.wikipedia.org", "en.wikipedia.org"])
        // One extra geosearch per call, as before.
        #expect(http.requests.count == 2)
    }
    /// A page at `north` metres north of (0, 0), so distances are exact along the meridian.
    static func page(_ id: Int, _ title: String, q: String?, north: Double) -> String {
        let c = Coordinate.at(north: north)
        return #"{"pageid":\#(id),"title":"\#(title)","coordinates":[{"lat":\#(c.latitude),"lon":\#(c.longitude)}]"#
            + (q.map { #","pageprops":{"wikibase_item":"\#($0)"}"# } ?? "") + "}"
    }
    @Test func englishArticleWithoutAnIdIsATwinOfTheSameTitleWithinOneHundredMetres() async throws {
        // Spec 20.6.7. The Norwegian «Fontana di Trevi» stands at the origin. English pages without an id:
        // - «fontana  di TREVÍ » at 100 m: the same title once case, accents and spaces are folded; 100 ≤ 100 → a twin,
        //   left out;
        // - «Fontana di Trevi» at 100.1 m: 100.1 > 100 → kept;
        // - «Trevi Fountain» at 0 m: another title → kept.
        // An English page with an id is matched by id only: «Fontana di Trevi» with Q9 at 0 m is kept (no Norwegian
        // page has Q9).
        #expect(GeoMath.distance(.at(), .at(north: 100)) == 100)
        #expect(WikipediaClient.twinRadius == 100)
        let http = StubHTTPClient { r in
            r.url!.host == "no.wikipedia.org"
              ? (200, Self.body([Self.page(10, "Fontana di Trevi", q: nil, north: 0)]))
              : (200, Self.body([Self.page(1, "fontana  di TREVÍ ", q: nil, north: 100),
                                 Self.page(2, "Fontana di Trevi", q: nil, north: 100.1),
                                 Self.page(3, "Trevi Fountain", q: nil, north: 0),
                                 Self.page(4, "Fontana di Trevi", q: "Q9", north: 0)]))
        }
        let c = try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .norwegian)
        #expect(c.map(\.id) == ["wiki:no/10", "wiki:en/2", "wiki:en/3", "wiki:en/4"])
        // A Norwegian page with an id is a twin by title too.
        let withID = StubHTTPClient { r in
            r.url!.host == "no.wikipedia.org"
              ? (200, Self.body([Self.page(10, "Fontana di Trevi", q: "Q5", north: 0)]))
              : (200, Self.body([Self.page(1, "Fontana di Trevi", q: nil, north: 50)]))
        }
        let d = try await WikipediaClient(http: withID).articles(around: vienna, radius: 400, language: .norwegian)
        #expect(d.map(\.id) == ["wiki:no/10"])
    }
    @Test func manyNorwegianResultsKeepEveryEnglishOnlyItem() async throws {
        // 20 Norwegian pages (Q1…Q20) and 20 English ones (Q11…Q30): the 10 shared items keep their Norwegian page,
        // the 10 English-only ones (Q21…Q30) are added: 20 + 10 = 30.
        let http = StubHTTPClient { r in
            r.url!.host == "no.wikipedia.org"
              ? (200, Self.body((1...20).map { Self.page($0, "N\($0)", q: "Q\($0)") }))
              : (200, Self.body((11...30).map { Self.page(100 + $0, "E\($0)", q: "Q\($0)") }))
        }
        let c = try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .norwegian)
        #expect(c.count == 30)
        #expect(c.prefix(20).allSatisfy { $0.id.hasPrefix("wiki:no/") })
        #expect(c.dropFirst(20).map(\.wikidata) == (21...30).map { "Q\($0)" })
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
    @Test func blankExtractHasNoSummaryLanguage() async throws {
        let page = #"{"pageid":1,"title":"T","extract":"   ","coordinates":[{"lat":1,"lon":2}]}"#
        let http = StubHTTPClient { _ in (200, Self.body([page])) }
        let c = try await WikipediaClient(http: http).articles(around: vienna, radius: 400, language: .english)
        #expect(c.count == 1 && c[0].summary == nil && c[0].summaryLanguage == nil)
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

    // MARK: articleText

    static func articleBody(_ extract: String) -> Data {
        Data(#"{"query":{"pages":[{"pageid":7,"title":"Michaelertor","extract":"\#(extract)"}]}}"#.utf8)
    }

    @Test func articleTextRequestIsWholeArticleInTheTitleLanguage() async throws {
        let http = StubHTTPClient { _ in (200, Self.articleBody("Das Tor.")) }
        let text = try await WikipediaClient(http: http).articleText(wikipediaTitle: "de:Michaelertor")
        #expect(text == "Das Tor.")
        let request = try #require(http.requests.first)
        let url = try #require(request.url).absoluteString
        #expect(url.contains("de.wikipedia.org"))
        #expect(url.contains("titles=Michaelertor"))
        #expect(url.contains("explaintext=1") && url.contains("redirects=1") && url.contains("exsectionformat=plain"))
        #expect(!url.contains("exintro"))
        #expect(request.value(forHTTPHeaderField: "User-Agent") == OverpassClient.userAgent)
        #expect(request.timeoutInterval == 10)
    }

    @Test func articleTextIsCutToTheLimit() async throws {
        // 5,000 "word " repeats of 5 characters: cut at the last space at or before 4,000 -> 3,999 chars + "…" = 4,000.
        // A single 5,000-character word hard-cuts to 4,000 + "…" = 4,001 (the upper bound).
        let words = String(repeating: "word ", count: 1_000)
        let http = StubHTTPClient { _ in (200, Self.articleBody(words)) }
        let cut = try await WikipediaClient(http: http).articleText(wikipediaTitle: "en:X")
        #expect(cut.count == 3_999 + 1 && cut.hasSuffix("word…"))

        let blob = StubHTTPClient { _ in (200, Self.articleBody(String(repeating: "a", count: 5_000))) }
        let hard = try await WikipediaClient(http: blob).articleText(wikipediaTitle: "en:X")
        #expect(hard.count == 4_001 && hard.hasSuffix("…"))
    }

    @Test func articleTextAtTheLimitIsUntouched() async throws {
        let exact = String(repeating: "a", count: WikipediaClient.articleTextLimit)
        let http = StubHTTPClient { _ in (200, Self.articleBody(exact)) }
        #expect(try await WikipediaClient(http: http).articleText(wikipediaTitle: "en:X") == exact)
    }

    @Test func articleTextPercentEncodesSpacesAndNonASCII() async throws {
        let http = StubHTTPClient { _ in (200, Self.articleBody("Tekst.")) }
        let client = WikipediaClient(http: http)
        _ = try await client.articleText(wikipediaTitle: "no:Oslo domkirke")
        _ = try await client.articleText(wikipediaTitle: "no:Ålesund")
        _ = try await client.articleText(wikipediaTitle: "en:AT&T: A+B")  // only the first colon splits code from title
        let urls = http.requests.compactMap { $0.url?.absoluteString }
        #expect(urls[0].hasSuffix("titles=Oslo%20domkirke"))
        #expect(urls[1].hasSuffix("titles=%C3%85lesund"))
        #expect(urls[2].hasSuffix("titles=AT%26T%3A%20A%2BB"))
        let decoded = URLComponents(string: urls[0])?.queryItems?.first { $0.name == "titles" }?.value
        #expect(decoded == "Oslo domkirke")
    }

    @Test func articleTextThrowsForMissingPage() async {
        let http = StubHTTPClient { _ in (200, Data(#"{"query":{"pages":[{"title":"Nope","missing":true}]}}"#.utf8)) }
        await #expect(throws: GroundingFetchError.malformed) {
            _ = try await WikipediaClient(http: http).articleText(wikipediaTitle: "en:Nope")
        }
    }

    @Test func articleTextThrowsForEmptyExtractAndNoPages() async {
        for body in [#"{"query":{"pages":[{"pageid":1,"title":"T","extract":"  "}]}}"#, #"{"query":{"pages":[]}}"#, #"{}"#] {
            let http = StubHTTPClient { _ in (200, Data(body.utf8)) }
            await #expect(throws: GroundingFetchError.malformed) {
                _ = try await WikipediaClient(http: http).articleText(wikipediaTitle: "en:T")
            }
        }
    }

    @Test func articleTextThrowsOnHttpApiAndGarbage() async {
        let http500 = StubHTTPClient { _ in (500, Data()) }
        await #expect(throws: GroundingFetchError.http(500)) {
            _ = try await WikipediaClient(http: http500).articleText(wikipediaTitle: "en:T")
        }
        let api = StubHTTPClient { _ in (200, Data(#"{"error":{"code":"badvalue"}}"#.utf8)) }
        await #expect(throws: GroundingFetchError.apiError("badvalue")) {
            _ = try await WikipediaClient(http: api).articleText(wikipediaTitle: "en:T")
        }
        let junk = StubHTTPClient { _ in (200, Data("<html>".utf8)) }
        await #expect(throws: GroundingFetchError.malformed) {
            _ = try await WikipediaClient(http: junk).articleText(wikipediaTitle: "en:T")
        }
    }

    @Test func articleTextThrowsMalformedForBadTitleWithoutRequest() async {
        for bad in ["Michaelertor", ":Michaelertor", "de:", "d/e:X", "de.evil.com/x:Y"] {
            let http = StubHTTPClient { _ in (200, Self.articleBody("x")) }
            await #expect(throws: GroundingFetchError.malformed) {
                _ = try await WikipediaClient(http: http).articleText(wikipediaTitle: bad)
            }
            #expect(http.requests.isEmpty)
        }
    }
}
