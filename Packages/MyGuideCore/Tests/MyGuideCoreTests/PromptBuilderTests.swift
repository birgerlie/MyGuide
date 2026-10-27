import Testing
import Foundation
@testable import MyGuideCore

@Suite struct PromptBuilderTests {
    static let gate = RankedCandidate(candidate: Candidate(id: "osm:way/1", name: "Michaelertor", coordinate: .init(latitude: 0, longitude: 0),
                                      kind: "historic=building", summary: "Gate of the palace.", wikipediaTitle: nil, wikidata: nil),
                                      distance: 35.4, bearing: 304.6, inView: true)
    static let grounding = Grounding(candidates: [gate], address: Address(line: "Michaelerplatz", city: "Vienna", country: "Austria"), failedSources: [])
    static func capture(heading: Double?, acc: Double?) -> CaptureContext {
        CaptureContext(coordinate: .init(latitude: 48.2082, longitude: 16.3738), horizontalAccuracy: 8, heading: heading,
                       headingAccuracy: acc, horizontalFOV: 55, takenAt: .now, source: .camera)
    }

    @Test func levelTargets() {
        // words = seconds·150/60:  20·150/60 = 50;  30·150/60 = 75;  120·150/60 = 300
        #expect(StoryLevel.allCases.map(\.targetWords) == [50, 75, 300])
        #expect(StoryLevel.allCases.map(\.lengthPhrase) == ["about 50 words (20 seconds spoken)",
                                                           "about 75 words (30 seconds spoken)",
                                                           "about 300 words (2 minutes spoken)"])
        #expect(StoryLevel.evenMore.next == nil && StoryLevel.first.next == .more)
    }
    @Test func instructionsCarryVoiceAndLanguage() {
        let en = PromptBuilder.systemInstructions(language: .english)
        #expect(en.contains("legend has it") && en.contains("Write in English."))
        #expect(PromptBuilder.systemInstructions(language: .norwegian).contains("Write in Norwegian Bokmål."))
    }
    @Test func firstInputWithHeading() {
        let s = PromptBuilder.firstStoryInput(capture: Self.capture(heading: 312, acc: 10), grounding: Self.grounding, priors: [])
        #expect(s.contains("Story length: about 50 words (20 seconds spoken)."))
        #expect(s.contains("Position: 48.208200, 16.373800 (accuracy ±8 m)"))
        #expect(s.contains("Facing: 312° (north-west), compass accuracy ±10°"))
        #expect(s.contains("Address: Michaelerplatz, Vienna, Austria"))
        // 35.4 m → 35 m; 304.6° → 305°
        #expect(s.contains("- [osm:way/1] Michaelertor — historic=building — 35 m, bearing 305°, in view\n  Summary: Gate of the palace."))
        #expect(s.contains("Already told: nothing yet"))
        #expect(!s.contains("Map data unavailable"))
    }
    @Test func firstInputUnknownHeadingAndFailures() {
        var g = Self.grounding; g.failedSources = [.openStreetMap, .geocoder]; g.address = nil
        let s = PromptBuilder.firstStoryInput(capture: Self.capture(heading: 312, acc: 60), grounding: g, priors: [])
        #expect(s.contains("Facing: unknown"))
        #expect(s.contains("Map data unavailable: OpenStreetMap, address lookup. Be more cautious."))
        #expect(!s.contains("Address:"))
    }
    @Test func priorsAreListedAndTrimmed() {
        let long = String(repeating: "word ", count: 100)   // 500 chars
        let s = PromptBuilder.firstStoryInput(capture: Self.capture(heading: nil, acc: nil), grounding: Self.grounding,
            priors: [PriorStory(placeID: "osm:way/1", level: .first, text: "The emperor rode out here.", toldAt: .now),
                     PriorStory(placeID: nil, level: .more, text: long, toldAt: .now)])
        #expect(s.contains("Already told:\n- [osm:way/1] level 1: The emperor rode out here."))
        let line = s.components(separatedBy: "\n").first { $0.hasPrefix("- [nearby, unidentified] level 2: ") }!
        #expect(line.hasSuffix("…") && line.count <= "- [nearby, unidentified] level 2: ".count + 241)
    }
    @Test func decodeNilsUnknownCandidate() throws {
        let ok = Data(#"{"subject":"Michaelertor","confidence":"likely","matchedCandidateID":"osm:way/1","title":"The gate","era":"around 1890","story":"S"}"#.utf8)
        #expect(try PromptBuilder.decodeFirstStory(ok, grounding: Self.grounding).matchedCandidateID == "osm:way/1")
        let bogus = Data(#"{"subject":"X","confidence":"unsure","matchedCandidateID":"osm:way/999","title":"T","era":"E","story":"S"}"#.utf8)
        #expect(try PromptBuilder.decodeFirstStory(bogus, grounding: Self.grounding).matchedCandidateID == nil)
    }
    @Test func decodeGarbageIsMalformed() {
        #expect(throws: OpenAIError.malformedResponse) { try PromptBuilder.decodeFirstStory(Data("{}".utf8), grounding: Self.grounding) }
    }
    @Test func schemaIsStrictCompatible() {
        guard case .object(let o) = PromptBuilder.firstStorySchema, case .array(let req) = o["required"]! else { Issue.record(); return }
        #expect(req.count == 6 && o["additionalProperties"] == .bool(false))
    }

    // Added beyond the brief: rounding must never print 360.
    @Test func bearingAndHeadingNearNorthWrapToZero() {
        // 359.6 rounds to 360, which wraps to 0; 359.4 rounds to 359.
        var near = Self.gate; near.bearing = 359.6
        var other = Self.gate; other.candidate.id = "osm:way/2"; other.bearing = 359.4
        let g = Grounding(candidates: [near, other], address: nil, failedSources: [])
        let s = PromptBuilder.firstStoryInput(capture: Self.capture(heading: 359.6, acc: 10), grounding: g, priors: [])
        #expect(s.contains("— 35 m, bearing 0°, in view"))
        #expect(!s.contains("360"))
        #expect(s.contains("— 35 m, bearing 359°, in view"))
        #expect(s.contains("Facing: 0° (north), compass accuracy ±10°"))
    }
    @Test func noHeadingOmitsViewFlagsAndShowsOutOfView() {
        var out = Self.gate; out.inView = false
        let g = Grounding(candidates: [Self.gate, out], address: nil, failedSources: [.wikipedia])
        let s = PromptBuilder.firstStoryInput(capture: Self.capture(heading: nil, acc: nil), grounding: g, priors: [])
        #expect(s.contains("Facing: unknown — identify the subject from position and the photo alone, and be more cautious."))
        #expect(s.contains("Map data unavailable: Wikipedia. Be more cautious."))
        #expect(s.contains("Places nearby (in view first, nearest first):"))
        let withFlags = PromptBuilder.firstStoryInput(capture: Self.capture(heading: 10, acc: 5), grounding: g, priors: [])
        #expect(withFlags.contains("bearing 305°, out of view"))
        let nilFlag = Grounding(candidates: [RankedCandidate(candidate: Self.gate.candidate, distance: 35.4, bearing: 304.6, inView: nil)],
                                address: nil, failedSources: [])
        let t = PromptBuilder.firstStoryInput(capture: Self.capture(heading: nil, acc: nil), grounding: nilFlag, priors: [])
        #expect(t.contains("— 35 m, bearing 305°\n"))
        #expect(!t.contains("in view,") && !t.contains("out of view"))
    }
    @Test func noCandidatesAndNoSummary() {
        let none = Grounding(candidates: [], address: nil, failedSources: [])
        let s = PromptBuilder.firstStoryInput(capture: Self.capture(heading: nil, acc: nil), grounding: none, priors: [])
        #expect(s.contains("Places nearby: none found"))
        #expect(s.hasSuffix("Then write the first story."))
        var bare = Self.gate; bare.candidate.summary = nil
        let t = PromptBuilder.firstStoryInput(capture: Self.capture(heading: nil, acc: nil),
                                              grounding: Grounding(candidates: [bare], address: nil, failedSources: []), priors: [])
        #expect(!t.contains("Summary:"))
    }
    @Test func continuationSchemaRequiresOnlyStory() {
        guard case .object(let o) = PromptBuilder.continuationSchema, case .array(let req) = o["required"]! else { Issue.record(); return }
        #expect(req == [.string("story")] && o["additionalProperties"] == .bool(false))
    }

    // MARK: - Task 11: continuations

    static func session(grounding: Grounding = PromptBuilderTests.grounding, matched: String? = "osm:way/1") -> StorySession {
        StorySession(id: UUID(), capture: capture(heading: 312, acc: 10), photoJPEG: Data(), thumbnailJPEG: Data(), language: .english,
            grounding: grounding,
            identified: IdentifiedStory(subject: "Michaelertor", confidence: .likely, matchedCandidateID: matched, title: "T", era: "around 1890", story: "L1"),
            levels: ["L1 text."])
    }
    @Test func continuationInput() {
        let session = Self.session()
        let s = PromptBuilder.continuationInput(session: session, level: .more,
            priors: [PriorStory(placeID: "osm:way/1", level: .first, text: "Earlier visit.", toldAt: .now)])
        #expect(s.contains("Story length: about 75 words (30 seconds spoken)."))
        #expect(s.contains("Subject: Michaelertor (confidence: likely)"))
        #expect(s.contains("Facts:\n- Michaelertor — historic=building\n  Summary: Gate of the palace."))
        #expect(s.contains("Told so far:\nLevel 1: L1 text."))
        #expect(s.contains("Already told on earlier visits:\n- [osm:way/1] level 1: Earlier visit."))
        #expect(s.contains("Continue the story from where it left off. Do not restart or repeat."))
    }
    @Test func continuationFactsWithoutMatchUseTopThreeInView() {
        func rc(_ name: String, _ d: Double, inView: Bool?) -> RankedCandidate {
            RankedCandidate(candidate: Candidate(id: "osm:node/\(name)", name: name, coordinate: .init(latitude: 0, longitude: 0),
                            kind: "historic=yes", summary: nil, wikipediaTitle: nil, wikidata: nil), distance: d, bearing: 0, inView: inView)
        }
        // ranked order is already in-view-first; the out-of-view one sits between to prove filtering, not slicing
        let g = Grounding(candidates: [rc("A", 10, inView: true), rc("B", 20, inView: true), rc("X", 5, inView: false),
                                       rc("C", 30, inView: true), rc("D", 40, inView: true)], address: nil, failedSources: [])
        let s = PromptBuilder.continuationInput(session: Self.session(grounding: g, matched: nil), level: .more, priors: [])
        #expect(s.contains("Facts:\n- A — historic=yes\n- B — historic=yes\n- C — historic=yes\n"))
        #expect(!s.contains("- X —") && !s.contains("- D —"))
        // heading unknown (inView nil everywhere) → nearest 3 in ranked order
        let g2 = Grounding(candidates: [rc("A", 10, inView: nil), rc("B", 20, inView: nil), rc("C", 30, inView: nil), rc("D", 40, inView: nil)],
                           address: nil, failedSources: [])
        let s2 = PromptBuilder.continuationInput(session: Self.session(grounding: g2, matched: nil), level: .more, priors: [])
        #expect(s2.contains("- C — historic=yes") && !s2.contains("- D —"))
        #expect(s.contains("Already told on earlier visits: nothing"))
    }
    @Test func continuationWithoutCandidatesAndAddress() {
        let none = Grounding(candidates: [], address: nil, failedSources: [])
        let s = PromptBuilder.continuationInput(session: Self.session(grounding: none, matched: nil), level: .evenMore, priors: [])
        // 120·150/60 = 300
        #expect(s.contains("Story length: about 300 words (2 minutes spoken)."))
        #expect(s.contains("Facts: none found") && !s.contains("Address:"))
    }
    @Test func decodeContinuation() throws {
        #expect(try PromptBuilder.decodeContinuation(Data(#"{"story":"Two."}"#.utf8)) == "Two.")
        #expect(throws: OpenAIError.malformedResponse) { try PromptBuilder.decodeContinuation(Data("{}".utf8)) }
        #expect(throws: OpenAIError.malformedResponse) { try PromptBuilder.decodeContinuation(Data(#"{"story":" \n "}"#.utf8)) }
    }
}
