import Foundation
import Testing
@testable import MyGuideCore

@Suite struct DayStoryPromptTests {
    typealias T = DayStoryPlanTests

    /// Clock times in Oslo (noon = 12:00): buzz 11:58 (−120 s), near 12:03 (+180 s), photo story 12:40 (+2400 s),
    /// lonely 13:10 (+4200 s), stop 14:00 (+7200 s).
    static let buzz = T.event("walk:b", .buzz, at: -120, coordinate: .at(), title: "The rock by the fjord",
                              place: "Akershus Fortress", sentence: "Built in 1299.")
    static let story = T.event("capture:s", .photoStory, at: 2400, coordinate: .at(north: 5000), title: "Oslo Cathedral",
                               place: "Cathedral", sentence: "Consecrated\nin 1697.")
    static let stop = T.event("walk:t", .stop, at: 7200, coordinate: .at(north: 9000), title: "Stortorvet")
    /// 5 min after the buzz and 50 m from it: matches it.
    static let near = T.library("near", at: 180, coordinate: .at(north: 50))
    /// 30 min after the photo story, nothing closer: no match.
    static let lonely = T.library("lonely", at: 4200)
    static let day = T.day([buzz, story, stop, near, lonely])

    static func input(_ day: DiaryDay = DayStoryPromptTests.day, language: StoryLanguage = .norwegian) -> String {
        PromptBuilder.dayStoryInput(plan: DayStoryPlan.make(day: day), day: day, language: language, timeZone: T.oslo)
    }

    @Test func inputFieldOrderAndLines() {
        #expect(Self.input() == """
            Day: Wednesday 28 October 2026, Oslo
            Events:
            - 11:58 walking buzz: Akershus Fortress — "Built in 1299."
            - 12:40 photo story: Oslo Cathedral — "Consecrated in 1697."
            - 14:00 stop: Stortorvet
            Photos (in the order the images are attached):
            - [p1] 12:03, matches 11:58 Akershus Fortress
            - [p2] 12:40, photo story: Oslo Cathedral
            - [p3] 13:10, no matching event
            Answer in: Norwegian Bokmål
            Task: Write one caption per photo id, then the day summary.
            """)
    }

    @Test func inputWithoutCityOrEvents() {
        var day = T.day([Self.lonely])
        day.city = nil
        #expect(Self.input(day, language: .english) == """
            Day: Wednesday 28 October 2026
            Events: none
            Photos (in the order the images are attached):
            - [p1] 13:10, no matching event
            Answer in: English
            Task: Write one caption per photo id, then the day summary.
            """)
    }

    @Test func inputNamesFallBack() {
        // A buzz without a place name uses its title; a blank photo story title falls back to its subject.
        let buzz = T.event("walk:x", .buzz, at: 0, title: "Old gate")
        let story = T.event("capture:y", .photoStory, at: 3600, title: " ", place: "Fountain")
        let s = Self.input(T.day([buzz, story]), language: .english)
        #expect(s.contains("\n- 12:00 walking buzz: Old gate\n"))
        #expect(s.contains("\n- 13:00 photo story: Fountain\n"))
        #expect(s.contains("\n- [p1] 13:00, photo story: Fountain\n"))
    }

    @Test func instructionsContainHonestySectionVerbatim() throws {
        let guide = PromptBuilder.systemInstructions
        let start = try #require(guide.range(of: "HONESTY"))
        let honesty = String(guide[start.lowerBound...])
        #expect(honesty.hasPrefix("HONESTY\n- Only state things you are genuinely confident"))
        let s = PromptBuilder.dayStoryInstructions
        #expect(s.contains(honesty))
        for rule in [
            "Write a caption for each photo: what is in the frame first, then the matched event's facts. At most 40 words, warm and specific, no greetings.",
            "Then write a 2–3 sentence summary of the day as a walk the user took.",
            "Never state facts that are not in the event list or clearly visible in a photo.",
            "Answer in the language the request names.",
        ] {
            #expect(s.contains(rule))
        }
        // One constant for both languages, so the prefix caches.
        for banned in ["English", "Norwegian"] { #expect(!s.contains(banned)) }
        #expect(PromptBuilder.dayPromptCacheKey == "myguide-day-v1")
    }

    @Test func schemaIsStrict() throws {
        guard case .object(let root) = PromptBuilder.dayStorySchema,
              case .object(let properties) = root["properties"],
              case .object(let captions) = properties["captions"],
              case .object(let item) = captions["items"] else {
            Issue.record("schema shape")
            return
        }
        #expect(root["additionalProperties"] == .bool(false))
        #expect(root["required"] == .array(["summary", "captions"]))
        #expect(captions["type"] == "array")
        #expect(item["additionalProperties"] == .bool(false))
        #expect(item["required"] == .array(["photoID", "caption"]))
    }

    // MARK: - Decoding

    static func json(summary: String, captions: [(String, String)]) throws -> Data {
        let body: [String: Any] = ["summary": summary,
                                   "captions": captions.map { ["photoID": $0.0, "caption": $0.1] }]
        return try JSONSerialization.data(withJSONObject: body)
    }

    static let ids = ["library:near", "capture:s", "library:lonely"]

    @Test func decodeMapsShortIDsToPhotoIDsInOrder() throws {
        let data = try Self.json(summary: " A walk from the fortress to the cathedral. ", captions: [
            ("p3", "A quiet street."), ("p1", "Fortress walls."), ("p2", "The cathedral tower."),
            ("p1", "A second caption for p1."),
        ])
        let decoded = try PromptBuilder.decodeDayStory(data, photoIDs: Self.ids)
        #expect(decoded.summary == "A walk from the fortress to the cathedral.")
        // p1 → ids[0], p2 → ids[1], p3 → ids[2]; a repeated id keeps its first caption.
        #expect(decoded.captions == ["library:near": "Fortress walls.", "capture:s": "The cathedral tower.",
                                     "library:lonely": "A quiet street."])
    }

    @Test func decodeDropsUnknownIDs() throws {
        let data = try Self.json(summary: "A day.", captions: [
            ("p1", "Fortress walls."), ("p0", "x"), ("p4", "x"), ("library:near", "x"), ("P2", "x"), ("p02", "x"),
            ("", "x"), ("p2", "  \n"),
        ])
        let decoded = try PromptBuilder.decodeDayStory(data, photoIDs: Self.ids)
        // p0 and p4 are outside p1…p3, real ids and other spellings are not short ids, a blank caption is no caption.
        #expect(decoded.captions == ["library:near": "Fortress walls."])
        let none = try PromptBuilder.decodeDayStory(Self.json(summary: "A day.", captions: []), photoIDs: Self.ids)
        #expect(none.captions.isEmpty && none.summary == "A day.")
    }

    @Test func decodeBlankSummaryThrows() throws {
        for summary in ["", " \n\t"] {
            let data = try Self.json(summary: summary, captions: [("p1", "Walls.")])
            #expect(throws: OpenAIError.malformedResponse) {
                try PromptBuilder.decodeDayStory(data, photoIDs: Self.ids)
            }
        }
        for bad in [#"{"captions":[]}"#, #"{"summary":"A day."}"#, "not json", #"{"summary":3,"captions":[]}"#] {
            #expect(throws: OpenAIError.malformedResponse) {
                try PromptBuilder.decodeDayStory(Data(bad.utf8), photoIDs: Self.ids)
            }
        }
    }
}
