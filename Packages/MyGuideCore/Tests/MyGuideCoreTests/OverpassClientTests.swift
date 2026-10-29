import Foundation
import Testing
@testable import MyGuideCore

@Suite struct OverpassClientTests {
    let vienna = Coordinate(latitude: 48.2082, longitude: 16.3738)

    @Test func queryIsExactAndLocaleIndependent() {
        let a = "around:250,48.208200,16.373800"
        #expect(OverpassClient.query(around: vienna, radius: 250) == """
        [out:json][timeout:10];
        (
          nwr(\(a))["historic"]["name"];
          nwr(\(a))["tourism"~"^(attraction|museum|artwork|viewpoint|gallery)$"]["name"];
          nwr(\(a))["amenity"="place_of_worship"]["name"];
          nwr(\(a))["building"]["name"]["wikidata"];
          nwr(\(a))["wikipedia"]["name"];
        );
        out center tags 500;
        """)
    }
    @Test func requestShape() async throws {
        let http = StubHTTPClient { _ in (200, Data(#"{"elements":[]}"#.utf8)) }
        _ = try await OverpassClient(http: http).places(around: vienna, radius: 250, language: .english)
        let r = http.requests[0]
        #expect(r.url == OverpassClient.endpoints[0] && r.httpMethod == "POST")
        #expect(http.requests.count == 1)
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(r.value(forHTTPHeaderField: "User-Agent") == OverpassClient.userAgent)
        #expect(r.timeoutInterval == 12)
        #expect(String(decoding: r.httpBody!, as: UTF8.self).hasPrefix("data=%5Bout%3Ajson%5D"))
    }
    @Test func parsesFiltersAndPrefersLocalName() async throws {
        let body = #"""
        {"elements":[
         {"type":"node","id":1,"lat":48.2086,"lon":16.3671,"tags":{"name":"Michaelertor","historic":"building","wikidata":"Q1","wikipedia":"de:Michaelertor"}},
         {"type":"way","id":2,"center":{"lat":48.2087,"lon":16.3675},"tags":{"name":"Hofburg","name:nb":"Hofburg slott","tourism":"attraction"}},
         {"type":"node","id":3,"lat":48.2,"lon":16.3,"tags":{"name":"Café Central","amenity":"cafe","historic":"yes"}},
         {"type":"node","id":4,"lat":48.2,"lon":16.3,"tags":{"name":"Souvenirs","shop":"gift","tourism":"attraction"}},
         {"type":"node","id":5,"lat":48.2,"lon":16.3,"tags":{"historic":"memorial"}},
         {"type":"relation","id":6,"tags":{"name":"No centre","historic":"yes"}}
        ]}
        """#
        let http = StubHTTPClient { _ in (200, Data(body.utf8)) }
        let en = try await OverpassClient(http: http).places(around: vienna, radius: 250, language: .english)
        #expect(en.map(\.id) == ["osm:node/1", "osm:way/2"])
        #expect(en[0] == Candidate(id: "osm:node/1", name: "Michaelertor", coordinate: .init(latitude: 48.2086, longitude: 16.3671),
                                   kind: "historic=building", summary: nil, wikipediaTitle: "de:Michaelertor", wikidata: "Q1",
                                   tags: ["historic": "building", "wikidata": "Q1"]))
        #expect(en[1].kind == "tourism=attraction" && en[1].name == "Hofburg")
        let nb = try await OverpassClient(http: http).places(around: vienna, radius: 250, language: .norwegian)
        #expect(nb[1].name == "Hofburg slott")
    }
    @Test func keepsGuideFactTagsAndDropsUnrelatedOnes() async throws {
        let body = #"""
        {"elements":[{"type":"node","id":1,"lat":1,"lon":2,"tags":{"name":"Kirke","historic":"church",
         "start_date":"1697","architect":"Linstow","inscription":"Soli Deo","description":"A church","artist_name":"Vigeland",
         "name:etymology":"King","wikidata":"Q9","heritage:operator":"Riksantikvaren","memorial:type":"statue",
         "material":"stone","building:architecture":"baroque","opening_hours":"Mo-Su 10:00-16:00"}}]}
        """#
        let http = StubHTTPClient { _ in (200, Data(body.utf8)) }
        let r = try await OverpassClient(http: http).places(around: vienna, radius: 250, language: .english)
        #expect(r[0].tags == ["historic": "church", "start_date": "1697", "architect": "Linstow", "inscription": "Soli Deo",
                              "description": "A church", "artist_name": "Vigeland", "name:etymology": "King", "wikidata": "Q9",
                              "heritage:operator": "Riksantikvaren", "memorial:type": "statue", "material": "stone",
                              "building:architecture": "baroque"])
        #expect(r[0].tags?["opening_hours"] == nil)
    }
    @Test func httpErrorThrows() async {
        await #expect(throws: GroundingFetchError.http(504)) {
            try await OverpassClient(http: StubHTTPClient { _ in (504, Data()) }).places(around: vienna, radius: 250, language: .english)
        }
    }

    // Additions beyond the brief: edge cases.
    @Test func malformedBodyThrows() async {
        for body in ["not json", #"{"version":0.6}"#] {
            await #expect(throws: GroundingFetchError.malformed) {
                try await OverpassClient(http: StubHTTPClient { _ in (200, Data(body.utf8)) }).places(around: vienna, radius: 250, language: .english)
            }
        }
    }
    @Test func norwegianFallsBackToNameNoThenName() async throws {
        let body = #"""
        {"elements":[
         {"type":"node","id":1,"lat":1,"lon":2,"tags":{"name":"A","name:no":"A no","historic":"yes"}},
         {"type":"node","id":2,"lat":1,"lon":2,"tags":{"name":"B","name:nb":"B nb","name:no":"B no","historic":"yes"}},
         {"type":"node","id":3,"lat":1,"lon":2,"tags":{"name":"C","name:en":"C en","historic":"yes"}}
        ]}
        """#
        let c = OverpassClient(http: StubHTTPClient { _ in (200, Data(body.utf8)) })
        let nb = try await c.places(around: vienna, radius: 250, language: .norwegian)
        #expect(nb.map(\.name) == ["A no", "B nb", "C"])
        let en = try await c.places(around: vienna, radius: 250, language: .english)
        #expect(en.map(\.name) == ["A", "B", "C en"])
    }
    @Test func kindPrecedenceAndExcludedAmenities() async throws {
        let body = #"""
        {"elements":[
         {"type":"node","id":1,"lat":1,"lon":2,"tags":{"name":"A","tourism":"museum","building":"yes"}},
         {"type":"node","id":2,"lat":1,"lon":2,"tags":{"name":"B","amenity":"place_of_worship","building":"church"}},
         {"type":"node","id":3,"lat":1,"lon":2,"tags":{"name":"C","building":"yes","wikidata":"Q3"}},
         {"type":"node","id":4,"lat":1,"lon":2,"tags":{"name":"Pub","amenity":"pub","historic":"yes"}},
         {"type":"node","id":5,"lat":1,"lon":2,"tags":{"name":"Shop","shop":"","historic":"yes"}},
         {"type":"node","id":6,"lat":1,"lon":2,"tags":{"name":"","historic":"yes"}}
        ]}
        """#
        let c = OverpassClient(http: StubHTTPClient { _ in (200, Data(body.utf8)) })
        let r = try await c.places(around: vienna, radius: 250, language: .english)
        #expect(r.map(\.kind) == ["tourism=museum", "amenity=place_of_worship", "building=yes"])
        #expect(r[2].wikidata == "Q3")
    }

    @Test func runtimeRemarkThrowsEvenWithElements() async {
        let remark = "runtime error: Query timed out in \"query\" at line 3 after 10 seconds."
        let escaped = remark.replacingOccurrences(of: "\"", with: "\\\"")
        let empty = #"{"elements":[],"remark":"\#(escaped)"}"#
        let partial = #"{"elements":[{"type":"node","id":1,"lat":1,"lon":2,"tags":{"name":"A","historic":"yes"}}],"remark":"\#(escaped)"}"#
        for body in [empty, partial] {
            await #expect(throws: GroundingFetchError.overpassRuntime(remark)) {
                try await OverpassClient(http: StubHTTPClient { _ in (200, Data(body.utf8)) }).places(around: vienna, radius: 250, language: .english)
            }
        }
    }
    @Test func otherRemarkIsIgnored() async throws {
        let body = #"{"elements":[{"type":"node","id":1,"lat":1,"lon":2,"tags":{"name":"A","historic":"yes"}}],"remark":"note: something"}"#
        let r = try await OverpassClient(http: StubHTTPClient { _ in (200, Data(body.utf8)) }).places(around: vienna, radius: 250, language: .english)
        #expect(r.map(\.id) == ["osm:node/1"])
    }
    @Test func wikipediaOnlyElementHasWikipediaKind() async throws {
        let body = #"{"elements":[{"type":"node","id":1,"lat":1,"lon":2,"tags":{"name":"A","wikipedia":"en:A"}}]}"#
        let r = try await OverpassClient(http: StubHTTPClient { _ in (200, Data(body.utf8)) }).places(around: vienna, radius: 250, language: .english)
        #expect(r.map(\.kind) == ["wikipedia"])
    }
    @Test func keepsOnlyWhitelistedTags() async throws {
        let body = #"{"elements":[{"type":"node","id":1,"lat":1,"lon":2,"tags":{"name":"Plaque","historic":"memorial","memorial":"plaque","addr:street":"X","wikipedia":"de:Y"}}]}"#
        let r = try await OverpassClient(http: StubHTTPClient { _ in (200, Data(body.utf8)) }).places(around: vienna, radius: 250, language: .english)
        #expect(r[0].tags == ["historic": "memorial", "memorial": "plaque"])
        #expect(r[0].wikipediaTitle == "de:Y")
    }
    @Test func heritageBuildingKeepsBothTagsAndTiersGood() async throws {
        let body = #"{"elements":[{"type":"node","id":1,"lat":1,"lon":2,"tags":{"name":"Old House","historic":"building","heritage":"2"}}]}"#
        let r = try await OverpassClient(http: StubHTTPClient { _ in (200, Data(body.utf8)) }).places(around: vienna, radius: 250, language: .english)
        #expect(r[0].tags == ["historic": "building", "heritage": "2"])
        #expect(PlaceTiers.tier(for: r[0]) == .good)
    }

    // MARK: - The second endpoint (spec 13.6)

    static let oneElement = #"{"elements":[{"type":"node","id":1,"lat":1,"lon":2,"tags":{"name":"A","historic":"yes"}}]}"#

    @Test func endpointsAreTheMainOneThenKumi() {
        #expect(OverpassClient.endpoints.map(\.absoluteString) == [
            "https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter",
        ])
    }
    @Test func overpassFallsBackToSecondEndpointOnce() async throws {
        let http = StubHTTPClient { request in
            request.url?.host == "overpass-api.de" ? (502, Data()) : (200, Data(Self.oneElement.utf8))
        }
        let r = try await OverpassClient(http: http).places(around: vienna, radius: 250, language: .english)
        #expect(r.map(\.id) == ["osm:node/1"])
        #expect(http.requests.map(\.url) == OverpassClient.endpoints)
        // The same request goes to the second endpoint.
        #expect(http.requests[1].httpBody == http.requests[0].httpBody && http.requests[1].httpMethod == "POST")
        #expect(http.requests[1].value(forHTTPHeaderField: "User-Agent") == OverpassClient.userAgent)
        #expect(http.requests[1].timeoutInterval == 12)
    }
    @Test func bothEndpointsFailingThrowsTheFirstErrorAfterTwoRequests() async {
        let http = StubHTTPClient { request in
            request.url?.host == "overpass-api.de" ? (502, Data()) : (504, Data())
        }
        await #expect(throws: GroundingFetchError.http(502)) {
            try await OverpassClient(http: http).places(around: vienna, radius: 250, language: .english)
        }
        #expect(http.requests.count == 2)
    }
    @Test func malformedRuntimeAndTransportFailuresAlsoFallBack() async throws {
        let remark = #"{"elements":[],"remark":"runtime error: Query timed out"}"#
        let failures: [@Sendable () throws -> (Int, Data)] = [
            { (200, Data("not json".utf8)) },
            { (200, Data(remark.utf8)) },
            { throw URLError(.timedOut) },
        ]
        for failure in failures {
            let http = StubHTTPClient { request in
                request.url?.host == "overpass-api.de" ? try failure() : (200, Data(Self.oneElement.utf8))
            }
            let r = try await OverpassClient(http: http).places(around: vienna, radius: 250, language: .english)
            #expect(r.map(\.id) == ["osm:node/1"])
            #expect(http.requests.count == 2)
        }
    }
    @Test func cancellationIsNeverRetried() async {
        let cancelledURL = StubHTTPClient { _ in throw URLError(.cancelled) }
        await #expect(throws: URLError(.cancelled)) {
            try await OverpassClient(http: cancelledURL).places(around: vienna, radius: 250, language: .english)
        }
        #expect(cancelledURL.requests.count == 1)

        let cancelled = StubHTTPClient { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) {
            try await OverpassClient(http: cancelled).places(around: vienna, radius: 250, language: .english)
        }
        #expect(cancelled.requests.count == 1)
    }
    @Test func aCancelledTaskIsNotRetriedAfterAnOrdinaryFailure() async {
        let http = StubHTTPClient { _ in (502, Data()) }
        let vienna = self.vienna
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await OverpassClient(http: http).places(around: vienna, radius: 250, language: .english)
        }
        task.cancel()
        _ = await task.result
        #expect(http.requests.count == 1)
    }
}
