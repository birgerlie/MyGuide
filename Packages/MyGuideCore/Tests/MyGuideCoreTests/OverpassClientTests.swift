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
        out center tags 200;
        """)
    }
    @Test func requestShape() async throws {
        let http = StubHTTPClient { _ in (200, Data(#"{"elements":[]}"#.utf8)) }
        _ = try await OverpassClient(http: http).places(around: vienna, radius: 250, language: .english)
        let r = http.requests[0]
        #expect(r.url == OverpassClient.endpoint && r.httpMethod == "POST")
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
                                   kind: "historic=building", summary: nil, wikipediaTitle: "de:Michaelertor", wikidata: "Q1"))
        #expect(en[1].kind == "tourism=attraction" && en[1].name == "Hofburg")
        let nb = try await OverpassClient(http: http).places(around: vienna, radius: 250, language: .norwegian)
        #expect(nb[1].name == "Hofburg slott")
    }
    @Test func httpErrorThrows() async {
        await #expect(throws: GroundingFetchError.http(504)) {
            try await OverpassClient(http: StubHTTPClient { _ in (504, Data()) }).places(around: vienna, radius: 250, language: .english)
        }
    }

    // Additions beyond the brief: edge cases.
    @Test func malformedBodyThrows() async {
        for body in ["not json", #"{"remark":"x"}"#] {
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
}
