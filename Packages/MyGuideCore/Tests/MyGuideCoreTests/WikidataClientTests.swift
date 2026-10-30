import Testing
import Foundation
@testable import MyGuideCore

@Suite struct WikidataClientTests {
    /// `never`: metro station Q928830 or treaty Q131569; `street`: street Q79007 or road Q34442; `settlement`: human
    /// settlement Q486972; `area`: neighbourhood Q123705 or administrative territorial entity Q56061; `natural`: hill
    /// Q54050 or island Q23442; `art`: work of art Q838948; `title`: the story-language sitelink title.
    static func row(_ q: String, n: Int, title: String? = nil, never: Bool = false, street: Bool = false,
                    settlement: Bool = false, area: Bool = false, place: Bool = false, natural: Bool = false,
                    art: Bool = false, nonplace: Bool = false) -> String {
        func b(_ v: Bool) -> String { #"{"type":"literal","datatype":"http://www.w3.org/2001/XMLSchema#boolean","value":"\#(v)"}"# }
        let titleField = title.map { #""title":{"type":"literal","xml:lang":"nb","value":"\#($0)"},"# } ?? ""
        return #"{"item":{"type":"uri","value":"http://www.wikidata.org/entity/\#(q)"},"#
            + #""n":{"type":"literal","datatype":"http://www.w3.org/2001/XMLSchema#integer","value":"\#(n)"},"#
            + titleField
            + #""never":\#(b(never)),"street":\#(b(street)),"settlement":\#(b(settlement)),"area":\#(b(area)),"#
            + #""place":\#(b(place)),"natural":\#(b(natural)),"art":\#(b(art)),"nonplace":\#(b(nonplace))}"#
    }
    static func body(_ rows: [String]) -> Data {
        Data(#"{"head":{"vars":["item","n","title","never","street","settlement","area","place","natural","art","nonplace"]},"results":{"bindings":[\#(rows.joined(separator: ","))]}}"#.utf8)
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
        for c in ["Q811979", "Q174782", "Q22698", "Q839954", "Q4989906", "Q838948", "Q483453", "Q54050", "Q23442",
                  "Q79007", "Q34442", "Q486972", "Q123705", "Q56061", "Q43229", "Q5", "Q1656682", "Q16334295",
                  "Q928830", "Q131569"] {
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
            "Q4010851": PlaceFacts(sitelinks: 7, placeClass: .street),
            "Q242839": PlaceFacts(sitelinks: 44, placeClass: .unknown),
        ])
    }

    @Test func streetWinsOverEverything() throws {
        let f = try WikidataClient.parse(Self.body([
            Self.row("Q1", n: 1, street: true, area: true, place: true, nonplace: true),
            Self.row("Q2", n: 1, street: true, place: true),
            Self.row("Q3", n: 1, street: true),
        ]))
        #expect(f["Q1"]?.placeClass == .street && f["Q2"]?.placeClass == .street && f["Q3"]?.placeClass == .street)
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
        #expect(f["Q105"] == PlaceFacts(sitelinks: 30, placeClass: .street))
    }

    @Test func queryHasSeparateStreetAndAreaFlags() {
        let q = WikidataClient.query(ids: ["Q1"])
        #expect(q.contains("SELECT ?item ?n ?never ?street ?settlement ?area ?place ?natural ?art ?nonplace WHERE"))
        let street = q.split(separator: "\n").first { $0.contains("AS ?street)") }.map(String.init) ?? ""
        let area = q.split(separator: "\n").first { $0.contains("AS ?area)") }.map(String.init) ?? ""
        #expect(street.contains("wd:Q79007") && street.contains("wd:Q34442") && !street.contains("wd:Q123705")
                && !street.contains("wd:Q56061"))
        #expect(area.contains("wd:Q123705") && area.contains("wd:Q56061") && !area.contains("wd:Q79007"))
    }

    // MARK: - Spec 20.6: hills, islands, settlements; organisations that are places only as works of art

    /// The query's line that binds `name`.
    static func flagLine(_ name: String) -> String {
        WikidataClient.query(ids: ["Q1"]).split(separator: "\n").first { $0.contains("AS ?\(name))") }.map(String.init) ?? ""
    }
    @Test func hillAndIslandHaveTheirOwnFlagAndSoDoesArt() {
        let place = Self.flagLine("place"), art = Self.flagLine("art"), settlement = Self.flagLine("settlement")
        for c in ["Q811979", "Q174782", "Q22698", "Q839954", "Q4989906", "Q483453"] {
            #expect(place.contains("wd:\(c) "), "place misses \(c)")
        }
        #expect(!place.contains("wd:Q838948") && !place.contains("wd:Q54050") && !place.contains("wd:Q23442"))
        let natural = Self.flagLine("natural")
        #expect(natural.contains("wd:Q54050 ") && natural.contains("wd:Q23442 ")
                && natural.components(separatedBy: "wd:Q").count - 1 == 2)
        let never = Self.flagLine("never")
        #expect(never.contains("wd:Q928830 ") && never.contains("wd:Q131569 ")
                && never.components(separatedBy: "wd:Q").count - 1 == 2)
        #expect(!Self.flagLine("nonplace").contains("wd:Q928830"))
        #expect(art.contains("wd:Q838948") && art.components(separatedBy: "wd:Q").count - 1 == 1)
        #expect(settlement.contains("wd:Q486972") && settlement.components(separatedBy: "wd:Q").count - 1 == 1)
        #expect(!Self.flagLine("area").contains("wd:Q486972"))
    }
    @Test func settlementIsItsOwnClassBelowStreetAndPlace() throws {
        let f = try WikidataClient.parse(Self.body([
            Self.row("Q1", n: 344, settlement: true, area: true, nonplace: true), // Rome
            Self.row("Q2", n: 17, settlement: true, area: true),                  // a rione
            Self.row("Q3", n: 5, street: true, settlement: true),
            Self.row("Q4", n: 5, settlement: true, place: true),
        ]))
        #expect(f["Q1"]?.placeClass == .settlement && f["Q2"]?.placeClass == .settlement)
        #expect(f["Q3"]?.placeClass == .street && f["Q4"]?.placeClass == .place)
    }
    @Test func workOfArtIsAPlaceUnlessAlsoAnOrganisation() throws {
        // The Sovereign Military Order of Malta reaches work of art through religious military order → order of
        // chivalry → state order → state decoration → decoration (live WDQS, 30 Oct), and organisation directly.
        let f = try WikidataClient.parse(Self.body([
            Self.row("Q1", n: 3, art: true),
            Self.row("Q2", n: 83, art: true, nonplace: true),
            Self.row("Q3", n: 40, place: true, art: true, nonplace: true),
            Self.row("Q4", n: 9, area: true, art: true, nonplace: true),
        ]))
        #expect(f["Q1"]?.placeClass == .place)
        #expect(f["Q2"]?.placeClass == .nonPlace)
        // A structure path still wins over the organisation (a church that is also a religious community).
        #expect(f["Q3"]?.placeClass == .place)
        #expect(f["Q4"]?.placeClass == .area)
    }
    @Test func rowsWithoutTheNewFlagsReadAsFalse() throws {
        let old = #"{"item":{"type":"uri","value":"http://www.wikidata.org/entity/Q5"},"n":{"type":"literal","value":"7"},"#
            + #""street":{"type":"literal","value":"false"},"area":{"type":"literal","value":"true"},"#
            + #""place":{"type":"literal","value":"false"},"nonplace":{"type":"literal","value":"false"}}"#
        #expect(try WikidataClient.parse(Self.body([old])) == ["Q5": PlaceFacts(sitelinks: 7, placeClass: .area)])
    }
    /// Flags from the live WDQS answers of 30 Oct (the query of spec 20.6 run on every id the replays met; the ids
    /// are the real items).
    @Test func recordedLiveClassesOfIteration1() throws {
        let f = try WikidataClient.parse(Self.body([
            Self.row("Q190353", n: 83, art: true, nonplace: true),            // Sovereign Military Order of Malta
            Self.row("Q719794", n: 40, place: true, nonplace: true),          // Il Gesù
            Self.row("Q34925", n: 68, natural: true),                         // Capitoline Hill (hill)
            Self.row("Q545404", n: 35, natural: true),                        // Tiber Island (island)
            Self.row("Q242839", n: 44),                                       // Campus Martius: P31 terrain only
            Self.row("Q220", n: 344, settlement: true, area: true, nonplace: true), // Rome
            Self.row("Q1329671", n: 21, settlement: true, area: true),        // Pigna (rione)
        ]))
        #expect(f["Q190353"] == PlaceFacts(sitelinks: 83, placeClass: .nonPlace))
        #expect(f["Q719794"] == PlaceFacts(sitelinks: 40, placeClass: .place))
        #expect(f["Q34925"] == PlaceFacts(sitelinks: 68, placeClass: .natural))
        #expect(f["Q545404"] == PlaceFacts(sitelinks: 35, placeClass: .natural))
        #expect(f["Q242839"] == PlaceFacts(sitelinks: 44, placeClass: .unknown))
        #expect(f["Q220"] == PlaceFacts(sitelinks: 344, placeClass: .settlement))
        #expect(f["Q1329671"] == PlaceFacts(sitelinks: 21, placeClass: .settlement))
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

    @Test func threeHundredFiftyIdsAreCappedAtSixBatches() async throws {
        let http = StubHTTPClient { _ in (200, Self.body([])) }
        _ = try await WikidataClient(http: http).facts(for: Self.ids(350))
        // 6 batches × 50 = 300 ids (spec 20.2.4: walking takes 6); the last 50 are left out.
        #expect(http.requests.map(Self.idCount) == [50, 50, 50, 50, 50, 50])
        let asked = Set(http.requests.flatMap { Self.sparql($0).components(separatedBy: "VALUES ?item {")[1]
            .components(separatedBy: "}")[0].split(separator: " ").filter { $0.hasPrefix("wd:") } })
        #expect(asked.count == 300)
        #expect(asked.contains("wd:Q300") && !asked.contains("wd:Q301"))
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

    @Test func defaultCapIsSixBatchesFourAtATime() async throws {
        let http = GaugedHTTP()
        _ = try await WikidataClient(http: http).lookup(ids: Self.ids(450))
        // 6 × 50 = 300 ids, never more than 4 requests at once.
        #expect(WikidataClient.maxBatches == 6)
        #expect(http.requests.count == 6 && http.requests.flatMap(Self.askedIds).count == 300 && http.peak == 4)
    }

    @Test func failedBatchInALaterWindowIsCounted() async throws {
        // 300 ids, cap 8 → 6 batches; the 6th (Q251...Q300) starts only after one of the first 4 is done, and fails.
        // Its retry: Q251...Q275 fails again, Q276...Q300 answers → 6 + 2 = 8 requests, 1 failed batch,
        // 250 + 25 = 275 ids answered.
        let http = GaugedHTTP { r in Self.askedIds(r).contains("Q251") ? 500 : 200 }
        let answer = try await WikidataClient(http: http).lookup(ids: Self.ids(300), maxBatches: 8)
        #expect(http.requests.count == 8 && http.peak <= 4)
        #expect(answer.failedBatches == 1)
        #expect(answer.answered == Set(Self.ids(250) + (276...300).map { "Q\($0)" }))
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
        // The failed batch Q1...Q50 is retried as Q1...Q25 (fails again: it holds Q1) and Q26...Q50 (answers):
        // 25 + 10 = 35 ids answered, one batch failed.
        #expect(answer.answered == Set(Self.ids(60).suffix(35)) && answer.failedBatches == 1)
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

    // MARK: - Spec 20.2.7: a failed batch is retried once as two halves

    @Test func halvesSplitWithTheLargerHalfFirst() {
        #expect(WikidataClient.halves(Self.ids(50)).map(\.count) == [25, 25])
        #expect(WikidataClient.halves(Self.ids(3)) == [["Q1", "Q2"], ["Q3"]])
        #expect(WikidataClient.halves(["Q1"]) == [["Q1"]])
        #expect(WikidataClient.halves([]).isEmpty)
    }
    @Test func aFailedBatchIsRetriedAsTwoHalvesThatSucceed() async throws {
        // The first request for the 50 ids times out; both halves (25 + 25) answer → nothing failed, all answered.
        let calls = LockedBox(0)
        let http = StubHTTPClient { r in
            let n = calls.withValue { $0 += 1; return $0 }
            if n == 1 { throw URLError(.timedOut) }
            return (200, Self.body(Self.askedIds(r).map { Self.row($0, n: 1, place: true) }))
        }
        let answer = try await WikidataClient(http: http).lookup(ids: Self.ids(50))
        #expect(http.requests.map(Self.idCount) == [50, 25, 25])
        #expect(answer.failedBatches == 0 && answer.answered == Set(Self.ids(50)) && answer.facts.count == 50)
        // Every retried half keeps the 8 s timeout.
        #expect(http.requests.allSatisfy { $0.timeoutInterval == 8 })
    }
    @Test func aBatchIsRetriedOnlyOnce() async throws {
        // Always failing: 1 request + 2 halves, no further splitting; one failed batch.
        let http = StubHTTPClient { _ in (500, Data()) }
        let answer = try await WikidataClient(http: http).lookup(ids: Self.ids(50))
        #expect(http.requests.count == 3 && answer.failedBatches == 1 && answer.answered.isEmpty)
    }
    @Test func retriedHalvesShareTheFourRequestWindow() async throws {
        // 4 batches all fail once: 4 first requests, then 8 halves, never more than 4 in flight.
        let http = GaugedHTTP { r in Self.askedIds(r).count == 50 ? 500 : 200 }
        let answer = try await WikidataClient(http: http).lookup(ids: Self.ids(200))
        #expect(http.requests.count == 4 + 8 && http.peak == 4)
        #expect(answer.failedBatches == 0 && answer.answered == Set(Self.ids(200)))
    }
    @Test func cancellationIsNotRetried() async {
        let http = StubHTTPClient { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) { try await WikidataClient(http: http).facts(for: ["Q1"]) }
        #expect(http.requests.count == 1)
    }
    @Test func aStrayURLCancelledWhileTheCallerRunsIsAFailureLikeAnyOther() async throws {
        // URLError.cancelled without the caller being cancelled (as before spec 20.2.7: a failed batch) → retried
        // once as one half (one id): 2 requests, 1 failed batch.
        let http = StubHTTPClient { _ in throw URLError(.cancelled) }
        let answer = try await WikidataClient(http: http).lookup(ids: ["Q1"])
        #expect(http.requests.count == 2 && answer.failedBatches == 1)
    }

    // MARK: - Spec 20.2.6: story-language titles, roads, metro stations and treaties

    @Test func titleIsAskedForInTheStoryLanguageOnly() {
        let norwegian = WikidataClient.query(ids: ["Q1"], titleCode: WikidataClient.titleCode(.norwegian))
        #expect(norwegian.contains("SELECT ?item ?n ?title ?never"))
        #expect(norwegian.contains("OPTIONAL { ?article schema:about ?item ; schema:isPartOf <https://no.wikipedia.org/> ; schema:name ?title . }"))
        // English (the English candidates carry their titles) and no language: no title, no OPTIONAL.
        #expect(WikidataClient.titleCode(.english) == nil && WikidataClient.titleCode(nil) == nil)
        let plain = WikidataClient.query(ids: ["Q1"])
        #expect(!plain.contains("?title") && !plain.contains("OPTIONAL"))
        // Anything but lowercase ASCII letters is ignored.
        for bad in ["n o", "no>", "NO", "", "nö"] {
            #expect(!WikidataClient.query(ids: ["Q1"], titleCode: bad).contains("OPTIONAL"), "accepted \(bad)")
        }
    }
    @Test func lookupInNorwegianSendsTheTitleQuery() async throws {
        let http = StubHTTPClient { _ in (200, Self.body([Self.row("Q186579", n: 68, title: "Fontana di Trevi", place: true)])) }
        let answer = try await WikidataClient(http: http).lookup(ids: ["Q186579"], language: .norwegian)
        #expect(Self.sparql(http.requests[0]) == WikidataClient.query(ids: ["Q186579"], titleCode: "no"))
        #expect(answer.facts["Q186579"] == PlaceFacts(sitelinks: 68, placeClass: .place, localTitle: "Fontana di Trevi"))
    }
    @Test func blankTitleIsNoTitle() throws {
        let f = try WikidataClient.parse(Self.body([Self.row("Q1", n: 1, title: "  ", place: true),
                                                    Self.row("Q2", n: 1, place: true)]))
        #expect(f["Q1"]?.localTitle == nil && f["Q2"]?.localTitle == nil)
    }
    @Test func metroStationAndTreatyAreNonPlacesBeforeAnything() throws {
        // Venezia (Rome Metro) is a structure; Roma-vedtektene is a treaty.
        let f = try WikidataClient.parse(Self.body([
            Self.row("Q1", n: 12, never: true, street: true, place: true),
            Self.row("Q2", n: 59, never: true),
        ]))
        #expect(f["Q1"]?.placeClass == .nonPlace && f["Q2"]?.placeClass == .nonPlace)
    }
    @Test func naturalComesAfterPlaceAndBeforeSettlement() throws {
        let f = try WikidataClient.parse(Self.body([
            Self.row("Q1", n: 68, natural: true),
            Self.row("Q2", n: 9, place: true, natural: true),          // a fort on an island
            Self.row("Q3", n: 9, settlement: true, natural: true),     // an inhabited island
            Self.row("Q4", n: 9, street: true, natural: true),
        ]))
        #expect(f["Q1"]?.placeClass == .natural && f["Q2"]?.placeClass == .place)
        #expect(f["Q3"]?.placeClass == .natural && f["Q4"]?.placeClass == .street)
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
