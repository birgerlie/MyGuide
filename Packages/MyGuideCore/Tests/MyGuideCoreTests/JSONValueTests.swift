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

    @Test func orderedKeepsOrder() throws {
        let v: JSONValue = .ordered([JSONMember(key: "b", value: 1), JSONMember(key: "a", value: "x"), JSONMember(key: "c", value: [true])])
        #expect(String(decoding: try v.jsonData(), as: UTF8.self) == #"{"b":1,"a":"x","c":[true]}"#)
    }
    @Test func orderedKeepsOrderWhenNested() throws {
        let inner: JSONValue = .ordered([JSONMember(key: "z", value: 1), JSONMember(key: "y", value: 2)])
        let v: JSONValue = .object(["k": [inner]])
        #expect(String(decoding: try v.jsonData(), as: UTF8.self) == #"{"k":[{"z":1,"y":2}]}"#)
    }
    @Test func objectEncodesSorted() throws {
        let v: JSONValue = ["b": 1, "a": 2]
        for _ in 0..<20 {
            #expect(String(decoding: try v.jsonData(), as: UTF8.self) == #"{"a":2,"b":1}"#)
        }
    }
    @Test func orderedDecodesBackAsObject() throws {
        let v: JSONValue = .ordered([JSONMember(key: "b", value: 1), JSONMember(key: "a", value: 2)])
        let back = try JSONDecoder().decode(JSONValue.self, from: v.jsonData())
        #expect(back == ["a": 2, "b": 1])
    }
    @Test func emptyOrderedEncodesEmptyObject() throws {
        #expect(String(decoding: try JSONValue.ordered([]).jsonData(), as: UTF8.self) == "{}")
    }
}
