import Testing
import Foundation
@testable import MyGuideCore

@Suite struct WikidataClientTests {
    static func row(_ q: String, n: Int, area: Bool = false, place: Bool = false, nonplace: Bool = false) -> String {
        func b(_ v: Bool) -> String { #"{"type":"literal","datatype":"http://www.w3.org/2001/XMLSchema#boolean","value":"\#(v)"}"# }
        return #"{"item":{"type":"uri","value":"http://www.wikidata.org/entity/\#(q)"},"#
            + #""n":{"type":"literal","datatype":"http://www.w3.org/2001/XMLSchema#integer","value":"\#(n)"},"#
            + #""area":\#(b(area)),"place":\#(b(place)),"nonplace":\#(b(nonplace))}"#
    }
    static func body(_ rows: [String]) -> Data {
        Data(#"{"head":{"vars":["item","n","area","place","nonplace"]},"results":{"bindings":[\#(rows.joined(separator: ","))]}}"#.utf8)
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
                             Self.row("Q4010851", n: 7, area: true, place: true),
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

    @Test func areaWinsOverEverything() throws {
        let f = try WikidataClient.parse(Self.body([Self.row("Q1", n: 1, area: true, place: true, nonplace: true)]))
        #expect(f["Q1"]?.placeClass == .area)
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
            Self.sparql(r).contains("wd:Q1 ")
                ? (500, Data())
                : (200, Self.body([Self.row("Q51", n: 5, place: true)]))
        }
        let f = try await WikidataClient(http: http).facts(for: Self.ids(60))
        #expect(f == ["Q51": PlaceFacts(sitelinks: 5, placeClass: .place)])
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
