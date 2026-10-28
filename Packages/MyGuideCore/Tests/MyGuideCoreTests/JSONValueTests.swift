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
    @Test func serializerRoundTripsAwkwardStrings() throws {
        let strings = ["quote\"", "back\\slash", "line\nbreak", "\u{01}ctl", "é", "😀", "a/b"]
        let v: JSONValue = .ordered([
            JSONMember(key: "k\"ey\\\n\u{01}é😀/", value: .array(strings.map { JSONValue.string($0) })),
            JSONMember(key: "nested", value: .object(["z": "x", "a": [1, 0.5, nil, true]])),
        ])
        let back = try JSONDecoder().decode(JSONValue.self, from: v.jsonData())
        let expected: JSONValue = ["k\"ey\\\n\u{01}é😀/": .array(strings.map { JSONValue.string($0) }),
                                   "nested": ["z": "x", "a": [1, 0.5, nil, true]]]
        #expect(back == expected)
    }
    @Test func serializerNumberFormats() throws {
        #expect(String(decoding: try JSONValue.number(3).jsonData(), as: UTF8.self) == "3")
        #expect(String(decoding: try JSONValue.number(0.5).jsonData(), as: UTF8.self) == "0.5")
    }
    @Test func serializerRejectsNonFiniteNumbers() {
        #expect(throws: (any Error).self) { try JSONValue.number(.nan).jsonData() }
        #expect(throws: (any Error).self) { try JSONValue.number(.infinity).jsonData() }
        #expect(throws: (any Error).self) { try JSONValue.array([.number(-.infinity)]).jsonData() }
    }
}
