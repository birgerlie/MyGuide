import Foundation
import Testing
@testable import MyGuideCore

@Suite struct JSONValueTests {
    @Test func roundTripsAllCases() throws {
        let v: JSONValue = ["s": "x", "n": 1.5, "i": 2, "b": true, "z": nil, "a": [1, "two", false], "o": ["k": "v"]]
        let data = try JSONEncoder().encode(v)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == v)
    }
    @Test func boolAndNumberStayDistinct() throws {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(#"[true,1,0,false]"#.utf8))
        #expect(v == [true, 1, 0, false])
    }
    @Test func encodesIntegerLiteralWithoutFraction() throws {
        #expect(String(decoding: try JSONEncoder().encode(JSONValue.number(3)), as: UTF8.self) == "3")
    }
}
