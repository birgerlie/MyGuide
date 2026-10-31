import Foundation
import Testing
@testable import MyGuideCore

@Suite struct ServerAllowanceTests {
    @Test func parsesBothHeaders() throws {
        let allowance = try #require(ServerAllowance(headers: ["X-MyGuide-Free-Left": "story=12,speech=40,image=4",
                                                               "X-MyGuide-Credits": "37"]))
        #expect(allowance.freeLeft == ["story": 12, "speech": 40, "image": 4])
        #expect(allowance.credits == 37)
    }

    @Test func lowercaseHeaderNamesParse() throws {
        let allowance = try #require(ServerAllowance(headers: ["x-myguide-free-left": "story=1", "x-myguide-credits": "2"]))
        #expect(allowance == ServerAllowance(freeLeft: ["story": 1], credits: 2))
        let mixed = try #require(ServerAllowance(headers: ["X-MYGUIDE-CREDITS": "3"]))
        #expect(mixed.credits == 3)
    }

    @Test func malformedPairsAreSkipped() throws {
        let allowance = try #require(ServerAllowance(headers: ["X-MyGuide-Free-Left": "story=12,bad,image=x"]))
        #expect(allowance.freeLeft == ["story": 12])
        #expect(allowance.credits == nil)
        let odd = try #require(ServerAllowance(headers: ["X-MyGuide-Free-Left": "=3,story=1=2,speech=-1, image = 4 ,,"]))
        #expect(odd.freeLeft == ["image": 4])
    }

    @Test func onlyCreditsGivesEmptyFreeLeft() throws {
        let allowance = try #require(ServerAllowance(headers: ["X-MyGuide-Credits": "5"]))
        #expect(allowance.freeLeft == [:])
        #expect(allowance.credits == 5)
    }

    @Test func absentOrEmptyHeadersGiveNil() {
        #expect(ServerAllowance(headers: [:]) == nil)
        #expect(ServerAllowance(headers: ["Content-Type": "application/json"]) == nil)
        #expect(ServerAllowance(headers: ["X-MyGuide-Free-Left": "", "X-MyGuide-Credits": ""]) == nil)
        #expect(ServerAllowance(headers: ["X-MyGuide-Free-Left": "bad", "X-MyGuide-Credits": "many"]) == nil)
    }

    @Test func badCreditsWithGoodFreeLeftKeepsFreeLeft() throws {
        let allowance = try #require(ServerAllowance(headers: ["X-MyGuide-Free-Left": "story=2", "X-MyGuide-Credits": "-4"]))
        #expect(allowance == ServerAllowance(freeLeft: ["story": 2], credits: nil))
    }

    @Test func readsHeadersOfARealResponse() throws {
        let response = try #require(HTTPURLResponse(url: URL(string: "https://guide.test")!, statusCode: 200, httpVersion: nil,
                                                    headerFields: ["x-myguide-free-left": "speech=40", "X-MyGuide-Credits": " 37 "]))
        let allowance = try #require(ServerAllowance(headers: response.allHeaderFields))
        #expect(allowance == ServerAllowance(freeLeft: ["speech": 40], credits: 37))
    }

    @Test func roundTripsThroughCodable() throws {
        let allowance = ServerAllowance(freeLeft: ["story": 12], credits: 37)
        let decoded = try JSONDecoder().decode(ServerAllowance.self, from: JSONEncoder().encode(allowance))
        #expect(decoded == allowance)
    }
}
