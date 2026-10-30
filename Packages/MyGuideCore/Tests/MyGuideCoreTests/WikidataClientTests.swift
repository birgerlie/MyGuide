import Testing
import Foundation
@testable import MyGuideCore

@Suite struct WikidataClientTests {
    /// `street`: street Q79007; `area`: neighbourhood Q123705 or administrative territorial entity Q56061.
    static func row(_ q: String, n: Int, street: Bool = false, area: Bool = false, place: Bool = false,
                    nonplace: Bool = false) -> String {
        func b(_ v: Bool) -> String { #"{"type":"literal","datatype":"http://www.w3.org/2001/XMLSchema#boolean","value":"\#(v)"}"# }
        return #"{"item":{"type":"uri","value":"http://www.wikidata.org/entity/\#(q)"},"#
            + #""n":{"type":"literal","datatype":"http://www.w3.org/2001/XMLSchema#integer","value":"\#(n)"},"#
            + #""street":\#(b(street)),"area":\#(b(area)),"place":\#(b(place)),"nonplace":\#(b(nonplace))}"#
    }
    static func body(_ rows: [String]) -> Data {
        Data(#"{"head":{"vars":["item","n","street","area","place","nonplace"]},"results":{"bindings":[\#(rows.joined(separator: ","))]}}"#.utf8)
    }
    /// The decoded SPARQL of a recorded request.
    static func sparql(_ request: URLRequest) -> String {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "query" }!.value!
    }
    /// How many ids the request asked for.
    static func idCount(_ request: URLRequest) -> Int {
        let line = sparql(request).split(separator: "\n").first { $0.contains("VALUES ?item") }!
        return line.components(separatedBy: "wd:Q").count - 1
    }
    /// The ids a request asked for, in order.
    static func askedIds(_ request: URLRequest) -> [String] {
        let line = sparql(request).split(separator: "\n").first { $0.contains("VALUES ?item") }!
        return line.split(separator: " ").filter { $0.hasPrefix("wd:Q") }.map { String($0.dropFirst(3)) }
    }
    static func ids(_ count: Int) -> [String] { (1...count).map { "Q\($0)" } }

    @Test func queryContainsEveryClassAndOnlyValidIds() {
        let q = WikidataClient.query(ids: ["Q42", "bad", "Q", "Q1x", "q5", "Q7; DROP", "Q8"])
        for c in ["Q811979", "Q174782", "Q22698", "Q839954", "Q4989906", "Q838948", "Q483453",
                  "Q79007", "Q123705", "Q56061", "Q43229", "Q5", "Q1656682", "Q16334295"] {
            #expect(q.contains("wd:\(c)"), "missing \(c)")
        }
        #expect(q.contains("VALUES ?item { wd:Q42 wd:Q8 }"))
        #expect(!q.contains("DROP") && !q.contains("bad") && !q.contains("wd:Q1x"))
        #expect(q.contains("wikibase:sitelinks ?n"))
        #expect(q.contains("wdt:P31/wdt:P279*"))
    }

    @Test func requestShape() async throws {
        let http = StubHTTPClient { _ in (200, Self.body([])) }
        _ = try await WikidataClient(http: http).facts(for: ["Q42"])
        let r = http.requests[0]
        #expect(r.httpMethod == "GET")
        #expect(r.url!.absoluteString.hasPrefix("https://query.wikidata.org/sparql?query="))
        #expect(!r.url!.absoluteString.dropFirst(40).contains(" "))
        #expect(r.timeoutInterval == 8)
        #expect(r.value(forHTTPHeaderField: "Accept") == "application/sparql-results+json")
        #expect(r.value(forHTTPHeaderField: "User-Agent") == OverpassClient.userAgent)
        #expect(Self.sparql(r) == WikidataClient.query(ids: ["Q42"]))
    }

    @Test func parsesTheRecordedAnswer() async throws {
        let http = StubHTTPClient { _ in
            (200, Self.body([Self.row("Q36380", n: 119, nonplace: true),
                             Self.row("Q719794", n: 40, place: true, nonplace: true),
                             Self.row("Q4010851", n: 7, street: true, place: true),
                             Self.row("Q242839", n: 44)]))
        }
        let f = try await WikidataClient(http: http).facts(for: ["Q36380", "Q719794", "Q4010851", "Q242839"])
        #expect(f == [
            "Q36380": PlaceFacts(sitelinks: 119, placeClass: .nonPlace),
            "Q719794": PlaceFacts(sitelinks: 40, placeClass: .place),
            "Q4010851": PlaceFacts(sitelinks: 7, placeClass: .area),
            "Q242839": PlaceFacts(sitelinks: 44, placeClass: .unknown),
        ])
    }

    @Test func streetWinsOverEverything() throws {
        let f = try WikidataClient.parse(Self.body([
            Self.row("Q1", n: 1, street: true, area: true, place: true, nonplace: true),
            Self.row("Q2", n: 1, street: true, place: true),
            Self.row("Q3", n: 1, street: true),
        ]))
        #expect(f["Q1"]?.placeClass == .area && f["Q2"]?.placeClass == .area && f["Q3"]?.placeClass == .area)
    }

    @Test func placeWinsOverNeighbourhoodAndAdministrativeArea() throws {
        // Castles, city gates and walls reach Q56061 through odd subclass chains (final review 30 Oct): a place
        // that is also an administrative territorial entity is a place.
        let f = try WikidataClient.parse(Self.body([
            Self.row("Q1", n: 58, area: true, place: true),
            Self.row("Q2", n: 1, area: true, place: true, nonplace: true),
        ]))
        #expect(f["Q1"]?.placeClass == .place && f["Q2"]?.placeClass == .place)
    }

    @Test func neighbourhoodWithoutPlaceIsAreaAndBeatsNonPlace() throws {
        let f = try WikidataClient.parse(Self.body([
            Self.row("Q1", n: 12, area: true),
            Self.row("Q2", n: 3, area: true, nonplace: true),
        ]))
        #expect(f["Q1"]?.placeClass == .area && f["Q2"]?.placeClass == .area)
    }

    /// Sitelinks and flags from the live WDQS answers of 30 Oct (final review finding 1); the ids are stand-ins.
    @Test func recordedRomeLandmarks() throws {
        let f = try WikidataClient.parse(Self.body([
            Self.row("Q101", n: 58, area: true, place: true), // Castel Sant'Angelo: castle → … → Q56061
            Self.row("Q102", n: 63, area: true, place: true), // Archbasilica of St John Lateran
            Self.row("Q103", n: 48, area: true, place: true), // Aurelian Walls
            Self.row("Q104", n: 18, area: true, place: true), // Porta del Popolo
            Self.row("Q105", n: 30, street: true, place: true), // Via del Corso: a street
        ]))
        #expect(f["Q101"] == PlaceFacts(sitelinks: 58, placeClass: .place))
        #expect(f["Q102"] == PlaceFacts(sitelinks: 63, placeClass: .place))
        #expect(f["Q103"] == PlaceFacts(sitelinks: 48, placeClass: .place))
        #expect(f["Q104"] == PlaceFacts(sitelinks: 18, placeClass: .place))
        #expect(f["Q105"] == PlaceFacts(sitelinks: 30, placeClass: .area))
    }

    @Test func queryHasSeparateStreetAndAreaFlags() {
        let q = WikidataClient.query(ids: ["Q1"])
        #expect(q.contains("SELECT ?item ?n ?street ?area ?place ?nonplace WHERE"))
        let street = q.split(separator: "\n").first { $0.contains("AS ?street)") }.map(String.init) ?? ""
        let area = q.split(separator: "\n").first { $0.contains("AS ?area)") }.map(String.init) ?? ""
        #expect(street.contains("wd:Q79007") && !street.contains("wd:Q123705") && !street.contains("wd:Q56061"))
        #expect(area.contains("wd:Q123705") && area.contains("wd:Q56061") && !area.contains("wd:Q79007"))
    }

    @Test func skipsRowsWithoutUsableIdOrCount() throws {
        let odd = #"{"item":{"type":"uri","value":"http://www.wikidata.org/entity/Q9"},"n":{"type":"literal","value":"many"}}"#
        let blank = #"{"item":{"type":"uri","value":"http://www.wikidata.org/entity/P9"},"n":{"type":"literal","value":"3"}}"#
        // A row without the flags is an item without a class.
        let noFlags = #"{"item":{"type":"uri","value":"http://www.wikidata.org/entity/Q3"},"n":{"type":"literal","value":"3"}}"#
        let f = try WikidataClient.parse(Self.body([odd, blank, noFlags, Self.row("Q3", n: 99, place: true)]))
        // The first row of Q3 wins.
        #expect(f == ["Q3": PlaceFacts(sitelinks: 3, placeClass: .unknown)])
    }

    @Test func oneHundredTwentyIdsMakeThreeRequests() async throws {
        let http = StubHTTPClient { _ in (200, Self.body([])) }
        _ = try await WikidataClient(http: http).facts(for: Self.ids(120))
        // 120 = 50 + 50 + 20; requests run concurrently so compare sorted.
        #expect(http.requests.map(Self.idCount).sorted() == [20, 50, 50])
    }

    @Test func twoHundredFiftyIdsAreCappedAtFourBatches() async throws {
        let http = StubHTTPClient { _ in (200, Self.body([])) }
        _ = try await WikidataClient(http: http).facts(for: Self.ids(250))
        // 4 batches × 50 = 200 ids; the last 50 are left out.
        #expect(http.requests.map(Self.idCount) == [50, 50, 50, 50])
        let asked = Set(http.requests.flatMap { Self.sparql($0).components(separatedBy: "VALUES ?item {")[1]
            .components(separatedBy: "}")[0].split(separator: " ").filter { $0.hasPrefix("wd:") } })
        #expect(asked.count == 200)
        #expect(asked.contains("wd:Q200") && !asked.contains("wd:Q201"))
    }

    @Test func toursTakeEightBatchesFourAtATime() async throws {
        let http = GaugedHTTP()
        let answer = try await WikidataClient(http: http).lookup(ids: Self.ids(450), maxBatches: WikidataClient.tourMaxBatches)
        // 8 batches × 50 = 400 ids: Q1...Q400 asked, Q401...Q450 left out.
        #expect(WikidataClient.tourMaxBatches == 8)
        #expect(http.requests.count == 8)
        let asked = http.requests.flatMap(Self.askedIds)
        #expect(asked.count == 400 && Set(asked) == Set(Self.ids(400)))
        #expect(answer.answered == Set(Self.ids(400)))
        // Never more than 4 requests at once, and the window is used (each answer takes 50 ms).
        #expect(http.peak == WikidataClient.maxConcurrentBatches && WikidataClient.maxConcurrentBatches == 4)
    }

    @Test func defaultCapStaysFourBatches() async throws {
        let http = StubHTTPClient { _ in (200, Self.body([])) }
        _ = try await WikidataClient(http: http).lookup(ids: Self.ids(450))
        // 4 × 50 = 200 ids.
        #expect(http.requests.count == 4 && http.requests.flatMap(Self.askedIds).count == 200)
    }

    @Test func failedBatchInALaterWindowIsCounted() async throws {
        // 300 ids, cap 8 → 6 batches; the 6th (Q251...Q300) starts only after one of the first 4 is done, and fails.
        let http = GaugedHTTP { r in Self.askedIds(r).contains("Q251") ? 500 : 200 }
        let answer = try await WikidataClient(http: http).lookup(ids: Self.ids(300), maxBatches: 8)
        #expect(http.requests.count == 6 && http.peak <= 4)
        #expect(answer.failedBatches == 1 && answer.answered == Set(Self.ids(250)))
    }

    @Test func duplicatesAndInvalidIdsDoNotCountTowardBatches() async throws {
        let http = StubHTTPClient { _ in (200, Self.body([])) }
        _ = try await WikidataClient(http: http).facts(for: ["Q1", "Q1", "nope", "Q2"])
        #expect(http.requests.count == 1 && Self.idCount(http.requests[0]) == 2)
        let none = StubHTTPClient { _ in (200, Self.body([])) }
        let f = try await WikidataClient(http: none).facts(for: ["x"])
        #expect(f.isEmpty && none.requests.isEmpty)
    }

    @Test func failedBatchIsLeftOutOthersSucceed() async throws {
        let http = StubHTTPClient { r in
            // The batch holding Q1 (the first 50 ids) fails; the batch of Q51...Q60 answers.
            Self.askedIds(r).contains("Q1")
                ? (500, Data())
                : (200, Self.body([Self.row("Q51", n: 5, place: true)]))
        }
        let f = try await WikidataClient(http: http).facts(for: Self.ids(60))
        #expect(f == ["Q51": PlaceFacts(sitelinks: 5, placeClass: .place)])
        let answer = try await WikidataClient(http: http).lookup(ids: Self.ids(60))
        // Only the 10 ids of the successful batch are answered; one batch failed.
        #expect(answer.answered == Set(Self.ids(60).suffix(10)) && answer.failedBatches == 1)
    }

    @Test func answeredIdsWithoutRowAreReported() async throws {
        let http = StubHTTPClient { _ in (200, Self.body([Self.row("Q1", n: 3, place: true)])) }
        let a = try await WikidataClient(http: http).lookup(ids: ["Q1", "Q2"])
        #expect(a.facts.keys.sorted() == ["Q1"] && a.answered == ["Q1", "Q2"] && a.failedBatches == 0)
    }

    @Test func idValidationIsAsciiOnly() {
        let bad = ["Q1\u{0301}", "Q0\u{0301}", "Q1\u{200D}", "Q\u{FF11}\u{FF12}", "Q\u{0661}\u{0662}", "Q", "q1", "", "Q-1", "Q1 ", "1"]
        for id in bad { #expect(!WikidataClient.isValid(id), "accepted \(id.unicodeScalars.map(\.value))") }
        for id in ["Q1", "Q0", "Q42", "Q4010851"] { #expect(WikidataClient.isValid(id)) }
        let q = WikidataClient.query(ids: bad + ["Q7"])
        #expect(q.contains("VALUES ?item { wd:Q7 }"))
    }

    @Test func malformedBodyIsLeftOut() async throws {
        for bad in ["not json", #"{"results":{}}"#, ""] {
            let http = StubHTTPClient { _ in (200, Data(bad.utf8)) }
            let f = try await WikidataClient(http: http).facts(for: ["Q1"])
            #expect(f.isEmpty)
        }
        #expect(throws: GroundingFetchError.malformed) { try WikidataClient.parse(Data("x".utf8)) }
    }

    @Test func networkErrorIsLeftOut() async throws {
        let http = StubHTTPClient { _ in throw OpenAIError.network("down") }
        #expect(try await WikidataClient(http: http).facts(for: ["Q1"]).isEmpty)
    }

    @Test func cancellationPropagates() async {
        let http = StubHTTPClient { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) { try await WikidataClient(http: http).facts(for: ["Q1"]) }
    }
}

/// Answers each request after 50 ms with no rows, and records the most requests in flight at once.
private final class GaugedHTTP: HTTPClient, @unchecked Sendable {
    private let state = LockedBox((current: 0, peak: 0, requests: [URLRequest]()))
    private let status: @Sendable (URLRequest) -> Int

    init(status: @escaping @Sendable (URLRequest) -> Int = { _ in 200 }) {
        self.status = status
    }

    var peak: Int { state.value.peak }
    var requests: [URLRequest] { state.value.requests }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        state.withValue {
            $0.current += 1
            $0.peak = max($0.peak, $0.current)
            $0.requests.append(request)
        }
        defer { state.withValue { $0.current -= 1 } }
        try await Task.sleep(for: .milliseconds(50))
        let response = HTTPURLResponse(url: request.url!, statusCode: status(request), httpVersion: "HTTP/1.1",
                                       headerFields: nil)!
        return (WikidataClientTests.body([]), response)
    }
}
