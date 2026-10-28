import Foundation
import Testing
@testable import MyGuideCore

@Suite struct PartialStoryParserTests {
    static let document = """
    {"subject":"Pantheon","confidence":"certain","matchedCandidateID":"osm-1","title":"Kuppelen","era":"125 e.Kr.","story":"Se opp i kuppelen."}
    """

    /// Feeds the chunks one by one and returns the state after the last.
    static func feed(_ chunks: [String]) -> PartialFirstStory {
        var parser = PartialStoryParser()
        var state = PartialFirstStory()
        for chunk in chunks { state = parser.append(chunk) }
        return state
    }

    /// Splits the text into chunks of `size` characters (not bytes).
    static func chunks(_ text: String, size: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if current.count == size { result.append(current); current = "" }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    @Test func fieldsAppearWhenClosed() {
        var parser = PartialStoryParser()
        #expect(parser.append(#"{"subject":"Pan"#).subject == nil)
        #expect(parser.append(#"theon","#).subject == "Pantheon")
    }

    @Test func storyGrows() {
        var parser = PartialStoryParser()
        _ = parser.append(#"{"subject":"Pantheon","story":"Se opp"#)
        #expect(parser.append("").story == "Se opp")
        let done = parser.append(#" i kuppelen."}"#)
        #expect(done.story == "Se opp i kuppelen.")
        #expect(done.subject == "Pantheon")
    }

    @Test func otherStringsAreHeldBackUntilClosed() {
        var parser = PartialStoryParser()
        let s = parser.append(#"{"title":"Kupp"#)
        #expect(s.title == nil)
        #expect(s.story == nil)
    }

    @Test func escapeSplitAcrossChunks() {
        // æ is U+00E6 "æ".
        var p1 = PartialStoryParser()
        #expect(p1.append(#"{"story":"\u00"#).story == "")
        #expect(p1.append(#"e6r""#).story == "ær")

        var p2 = PartialStoryParser()
        #expect(p2.append(#"{"story":"a\"#).story == "a")
        #expect(p2.append(#""b""#).story == #"a"b"#)

        var p3 = PartialStoryParser()
        _ = p3.append(#"{"story":"x\"#)
        #expect(p3.append(#"ny""#).story == "x\ny")
    }

    @Test func everySimpleEscapeDecodes() {
        // \" \\ \/ \b \f \n \r \t
        let s = Self.feed([#"{"story":"\"\\\/\b\f\n\r\t"}"#])
        #expect(s.story == "\"\\/\u{08}\u{0C}\n\r\t")
    }

    @Test func surrogatePairSplitEverywhere() {
        // U+1F600 = D83D DE00.
        let text = #"{"story":"a😀b"}"#
        for size in 1...text.count {
            let s = Self.feed(Self.chunks(text, size: size))
            #expect(s.story == "a😀b", "chunk size \(size)")
        }
    }

    @Test func halfPairIsHeldBack() {
        var parser = PartialStoryParser()
        #expect(parser.append(#"{"story":"a\ud83d"#).story == "a")
        #expect(parser.append(#"\ude00"#).story == "a😀")
    }

    @Test func loneSurrogatesBecomeReplacementCharacter() {
        #expect(Self.feed([#"{"story":"\ud83dx"}"#]).story == "\u{FFFD}x")
        #expect(Self.feed([#"{"story":"\ude00x"}"#]).story == "\u{FFFD}x")
        #expect(Self.feed([#"{"story":"\ud83d\n"}"#]).story == "\u{FFFD}\n")
        #expect(Self.feed([#"{"story":"\ud83d"}"#]).story == "\u{FFFD}")
    }

    @Test func rawNonASCIIPassesThrough() {
        #expect(Self.feed(["{\"story\":\"Æ😀å\"}"]).story == "Æ😀å")
    }

    @Test func nullMatchedID() {
        let s = Self.feed([#"{"subject":"X","matchedCandidateID":null,"story":"y"}"#])
        #expect(s.matchedCandidateID == nil)
        #expect(s.subject == "X")
        #expect(s.story == "y")
        // Null split across chunks, then more keys still parse.
        let t = Self.feed([#"{"matchedCandidateID":nu"#, #"ll,"title":"T"}"#])
        #expect(t.matchedCandidateID == nil)
        #expect(t.title == "T")
    }

    @Test func wholeDocumentInOneChunk() {
        let s = Self.feed([Self.document])
        #expect(s == PartialFirstStory(
            subject: "Pantheon", confidence: "certain", matchedCandidateID: "osm-1",
            title: "Kuppelen", era: "125 e.Kr.", story: "Se opp i kuppelen."))
    }

    @Test func keyOrderIndependent() {
        let s = Self.feed([#"{"story":"S","era":"E","title":"T","matchedCandidateID":"m","confidence":"likely","subject":"X"}"#])
        #expect(s == PartialFirstStory(
            subject: "X", confidence: "likely", matchedCandidateID: "m",
            title: "T", era: "E", story: "S"))
    }

    @Test func everyChunkSizeGivesTheSameResult() {
        let whole = Self.feed([Self.document])
        for size in 1...Self.document.count {
            #expect(Self.feed(Self.chunks(Self.document, size: size)) == whole, "chunk size \(size)")
        }
    }

    @Test func whitespaceEverywhere() {
        let text = " \n{ \"subject\" \t: \"A\" ,\r\n \"matchedCandidateID\" : null , \"story\" : \"B\" } \n"
        for size in [1, 3, text.count] {
            let s = Self.feed(Self.chunks(text, size: size))
            #expect(s.subject == "A")
            #expect(s.story == "B")
            #expect(s.matchedCandidateID == nil)
        }
    }

    @Test func unknownKeysAreSkipped() {
        let text = #"{"extra":{"a":[1,2,{"b":"}\"]"}],"c":-1.5e3},"flag":true,"n":null,"x":"v","subject":"S","story":"T"}"#
        for size in [1, 2, 7, text.count] {
            let s = Self.feed(Self.chunks(text, size: size))
            #expect(s.subject == "S", "size \(size)")
            #expect(s.story == "T", "size \(size)")
            #expect(s.title == nil)
        }
    }

    @Test func unknownKeyNamedLikeFieldInsideStringDoesNotLeak() {
        let s = Self.feed([#"{"x":"\"title\":\"no\"","title":"yes"}"#])
        #expect(s.title == "yes")
    }

    @Test func keyWithEscapeStillMatches() {
        // "subject" is "subject".
        #expect(Self.feed([#"{"subject":"S"}"#]).subject == "S")
    }

    @Test func nonStringValueForStringFieldIsIgnored() {
        let s = Self.feed([#"{"subject":5,"title":"T"}"#])
        #expect(s.subject == nil)
        #expect(s.title == "T")
    }

    @Test func malformedInputStopsUpdatingAndNeverCrashes() {
        var parser = PartialStoryParser()
        _ = parser.append(#"{"subject":"A","#)
        let broken = parser.append("garbage")
        #expect(broken.subject == "A")
        // Later valid-looking input is ignored.
        #expect(parser.append(#""title":"T"}"#).title == nil)

        var bad = PartialStoryParser()
        #expect(bad.append("not json at all") == PartialFirstStory())
        var badEscape = PartialStoryParser()
        let s = badEscape.append(#"{"story":"ok\qmore"}"#)
        #expect(s.story == "ok")
        var badHex = PartialStoryParser()
        #expect(badHex.append(#"{"story":"ok\u00zz"}"#).story == "ok")
    }

    @Test func emptyAndTrailingInput() {
        var parser = PartialStoryParser()
        #expect(parser.append("") == PartialFirstStory())
        _ = parser.append(#"{"story":"a"}"#)
        #expect(parser.append("  trailing").story == "a")
    }

    @Test func emptyStoryIsReportedAsEmptyString() {
        #expect(Self.feed([#"{"story":""}"#]).story == "")
    }

    @Test func longStoryIsLinear() {
        let body = String(repeating: "abcdefghij", count: 200)   // 2 000 characters
        var parser = PartialStoryParser()
        _ = parser.append(#"{"story":""#)
        var last = PartialFirstStory()
        for ch in body { last = parser.append(String(ch)) }
        #expect(last.story == body)
    }
}
