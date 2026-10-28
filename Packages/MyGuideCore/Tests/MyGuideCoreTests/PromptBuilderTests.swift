import Testing
import Foundation
@testable import MyGuideCore

@Suite struct PromptBuilderTests {
    static let gate = RankedCandidate(candidate: Candidate(id: "osm:way/1", name: "Michaelertor", coordinate: .init(latitude: 0, longitude: 0),
                                      kind: "historic=building", summary: "Gate of the palace.", wikipediaTitle: "de:Michaelertor", wikidata: nil,
                                      tags: ["historic": "building", "start_date": "1697"]),
                                      distance: 35.4, bearing: 304.6, inView: true)
    static let here = Coordinate(latitude: 48.2082, longitude: 16.3738)
    /// 0.001° east of `here`: Δλ = 0.001° = 1.745 33e-5 rad; R·cos φ·Δλ = 6 371 000 × 0.666 59 × 1.745 33e-5 = 74.1 m → 70 m;
    /// bearing ≈ 90° (a hair under, great circle).
    static let albertina = ApplePlace(name: "Albertina", category: "museum", coordinate: .init(latitude: 48.2082, longitude: 16.3748))
    static let address = Address(line: "Michaelerplatz", district: "Innere Stadt", city: "Vienna", country: "Austria")
    static let grounding = Grounding(candidates: [gate], address: address, failedSources: [], applePlaces: [albertina])
    static let utc = TimeZone(identifier: "UTC")!
    // 1 000 000 s after 1970 = 11 d 13 h 46 m 40 s → 13:46 UTC on 12 January 1970; 1 January 1970 was a Thursday,
    // + 11 days = Monday.
    static let now = Date(timeIntervalSince1970: 1_000_000)
    /// Ten minutes before `now`: 13:36 UTC.
    static let recent = RecentStory(toldAt: now - 600, placeName: "Hofburg", level: .first,
                                    text: "The palace grew for 600 years. Then it stopped.", prepared: false)
    static let prior = PriorStory(placeID: "osm:way/1", level: .first, text: "The emperor rode out here.", toldAt: .now)

    static func capture(heading: Double?, acc: Double?) -> CaptureContext {
        CaptureContext(coordinate: here, horizontalAccuracy: 8, heading: heading,
                       headingAccuracy: acc, horizontalFOV: 55, takenAt: .now, source: .camera)
    }
    static func first(heading: Double? = 135, acc: Double? = 10, grounding: Grounding = PromptBuilderTests.grounding,
                      capture: CaptureContext? = nil, recent: [RecentStory] = [PromptBuilderTests.recent],
                      priors: [PriorStory] = [PromptBuilderTests.prior], language: StoryLanguage = .english,
                      timeZone: TimeZone = PromptBuilderTests.utc) -> String {
        PromptBuilder.photoFirstInput(capture: capture ?? Self.capture(heading: heading, acc: acc), grounding: grounding,
                                      recent: recent, priors: priors, language: language, now: now, timeZone: timeZone)
    }
    static func lines(_ s: String) -> [String] { s.components(separatedBy: "\n") }
    /// Line `i` of `s`, nil when there are fewer lines (so a short prompt fails the test instead of crashing it).
    static func line(_ s: String, _ i: Int) -> String? {
        let all = lines(s)
        return all.indices.contains(i) ? all[i] : nil
    }
    /// The field names of the top-level lines (not list items, indented facts or told-so-far levels).
    static func fields(_ s: String) -> [String] {
        lines(s).filter { !$0.hasPrefix(" ") && !$0.hasPrefix("- ") && !$0.hasPrefix("Level ") }
            .map { String($0.prefix { $0 != ":" }) }
    }

    @Test func levelSuccession() {
        #expect(StoryLevel.evenMore.next == nil && StoryLevel.first.next == .more)
    }

    // MARK: - Instructions

    @Test func groundingWithoutApplePlacesDecodes() throws {
        // A grounding stored before Apple Maps places existed has no such key.
        let old = Data(#"{"candidates":[],"address":{"line":"Platz"},"failedSources":["geocoder"]}"#.utf8)
        let decoded = try JSONDecoder().decode(Grounding.self, from: old)
        #expect(decoded.applePlaces == nil && decoded.address == Address(line: "Platz") && decoded.failedSources == [.geocoder])
        // With places it round-trips.
        let back = try JSONDecoder().decode(Grounding.self, from: JSONEncoder().encode(Self.grounding))
        #expect(back == Self.grounding && back.applePlaces == [Self.albertina])
    }
    @Test func instructionsAreOneConstant() {
        let s = PromptBuilder.systemInstructions
        #expect(s.hasPrefix("You are a brilliant private guide walking beside the user."))
        #expect(s.contains("Never recommend a particular restaurant, café or shop."))
        #expect(s.contains(#"Never repeat anything listed under "Told in the last 3 hours" or "Told here before"; find a new point."#))
        #expect(s.hasSuffix("and say plainly that you know no recorded history of it."))
        for banned in ["{{", "◆", "English", "Norwegian"] { #expect(!s.contains(banned)) }
        // No trailing spaces left where a ◆ mark was removed.
        #expect(!s.contains(" \n") && !s.contains("  "))
        #expect(PromptBuilder.promptCacheKey == "myguide-story-v1")
    }

    // MARK: - Photo first level

    @Test func photoFirstInputFieldOrder() {
        let s = Self.first()
        #expect(Self.fields(s) == ["Story", "Position", "Coordinates", "Time", "Facing", "Nearby", "Also on Apple Maps",
                                   "Told in the last 3 hours", "Told here before", "Length", "Answer in", "Task"])
        let l = Self.lines(s)
        #expect(Self.line(s, 0) == "Story: photo, first level")
        #expect(Self.line(s, 1) == "Position: Michaelerplatz, Innere Stadt, Vienna, Austria")
        #expect(Self.line(s, 2) == "Coordinates: 48.208200, 16.373800 (accuracy ±8 m)")
        #expect(Self.line(s, 3) == "Time: 13:46 Monday")
        #expect(Self.line(s, 4) == "Facing: south-east (135°), compass ±10°")
        // 35.4 m → 40 m; r = 304.6 − 135 = 169.6 → |r| > 150 → "behind".
        #expect(s.contains("Nearby:\n- [osm:way/1] Michaelertor (historic=building), 40 m, behind, in view\n  Summary: Gate of the palace.\n  OSM: start_date=1697\n"))
        // 74.1 m → 70 m; r = 90 − 135 = −45 → 30 < 45 ≤ 60, left → "ahead-left".
        #expect(s.contains("Also on Apple Maps:\n- Albertina (museum), 70 m, ahead-left\n"))
        #expect(s.contains("Told in the last 3 hours:\n- 13:36 Hofburg level 1: \"The palace grew for 600 years.\"\n"))
        #expect(s.contains("Told here before:\n- [osm:way/1] level 1: The emperor rode out here.\n"))
        // 200 words · 60 / 150 = 80 s.
        #expect(s.contains("\nLength: about 200 words (80 seconds spoken), 3–4 points\nAnswer in: English\n"))
        #expect(l.last == "Task: Identify what the photo shows, preferring places in view. Set matchedCandidateID only if the subject is one of the listed places (use its id in brackets). Then tell the user about it. If nothing listed matches what you see, talk about what can actually be seen in the frame and say plainly that you know no recorded history of it.")
        #expect(!s.contains("Map data unavailable"))
    }
    @Test func photoFirstInputSidesFollowTheHeading() {
        // Facing 312: gate r = 304.6 − 312 = −7.4 → |r| ≤ 30 → "ahead";
        // Albertina r = 90 − 312 = −222 → +360 = 138 → 120 < 138 ≤ 150, right → "behind-right".
        let s = Self.first(heading: 312)
        #expect(s.contains("Facing: north-west (312°), compass ±10°"))
        #expect(s.contains("- [osm:way/1] Michaelertor (historic=building), 40 m, ahead, in view\n"))
        #expect(s.contains("- Albertina (museum), 70 m, behind-right\n"))
    }
    @Test func photoFirstInputInNorwegianAndAnotherTimeZone() {
        // 13:46 UTC; Oslo on 12 January 1970 is UTC+1 → 14:46, still Monday. The request stays English.
        let s = Self.first(language: .norwegian, timeZone: TimeZone(identifier: "Europe/Oslo")!)
        #expect(s.contains("\nTime: 14:46 Monday\n"))
        #expect(s.contains("\nAnswer in: Norwegian Bokmål\n"))
        #expect(s.contains("- 14:36 Hofburg level 1:"))
    }
    @Test func photoNothingFound() throws {
        let none = Grounding(candidates: [], address: Self.address, failedSources: [], applePlaces: nil)
        let s = Self.first(grounding: none, recent: [], priors: [])
        #expect(s.contains("\nNearby: none found\n"))
        #expect(!s.contains("Also on Apple Maps"))
        #expect(s.contains("\nTold in the last 3 hours: nothing\nTold here before: nothing\n"))
        let task = try #require(Self.lines(s).last)
        #expect(task.hasPrefix("Task: ") && task.contains("no recorded history"))
    }
    @Test func appleMapsFieldIsOmittedWhenEmptyOrAllKnown() {
        var g = Self.grounding
        g.applePlaces = []
        #expect(!Self.first(grounding: g).contains("Also on Apple Maps"))
        // The only Apple place repeats a listed candidate (case- and diacritic-insensitive): nothing is left to list.
        g.applePlaces = [ApplePlace(name: " MICHAELERTÓR ", category: "landmark", coordinate: Self.albertina.coordinate)]
        #expect(!Self.first(grounding: g).contains("Also on Apple Maps"))
    }
    @Test func appleMapsPlacesAreNearestFirstAndCappedAtEight() {
        // Ten places 0.001°·k east (k = 1…10), given farthest first; 74.1·k m. The eight nearest are k = 1…8 (70 … 590 m).
        let places = (1...10).reversed().map { k in
            ApplePlace(name: "P\(k)", category: "park", coordinate: .init(latitude: 48.2082, longitude: 16.3738 + 0.001 * Double(k)))
        }
        var g = Self.grounding
        g.applePlaces = places
        let listed = Self.lines(Self.first(grounding: g)).filter { $0.hasPrefix("- P") }
        #expect(listed.map { $0.split(separator: " ")[1] } == ["P1", "P2", "P3", "P4", "P5", "P6", "P7", "P8"])
        // P1: 74.1 m → 70 m; P8: 8 × 74.1 = 593 m → 590 m. All due east (bearing ≈ 90) against facing 135:
        // r = −45 → ahead-left.
        #expect(listed.first == "- P1 (park), 70 m, ahead-left" && listed.last == "- P8 (park), 590 m, ahead-left")
    }
    @Test func addressFailedSaysSo() {
        var g = Self.grounding
        g.address = nil
        g.failedSources = [.openStreetMap, .geocoder]
        let s = Self.first(grounding: g)
        #expect(Self.line(s, 1) == "Position: address lookup failed")
        #expect(Self.line(s, 2) == "Coordinates: 48.208200, 16.373800 (accuracy ±8 m)")
        // The failure line sits between Facing and Nearby.
        #expect(s.contains("\nFacing: south-east (135°), compass ±10°\nMap data unavailable: OpenStreetMap, address lookup. Be more cautious.\nNearby:\n"))
        // An address with no parts is no address either.
        g.address = Address()
        #expect(Self.line(Self.first(grounding: g), 1) == "Position: address lookup failed")
    }
    @Test func substitutePositionIsFlaggedRightAfterTheCoordinates() {
        let line = "Position is where the listener is now, not necessarily where the photo was taken; trust the photo over the places list."
        let moved = Self.capture(heading: nil, acc: nil).withCoordinate(Self.here, accuracy: 8)
        #expect(Self.first(capture: moved).contains("Coordinates: 48.208200, 16.373800 (accuracy ±8 m)\n" + line + "\nTime:"))
        #expect(!Self.first().contains("Position is where the listener is now"))
    }
    @Test func coordinatesWithoutAccuracyOrPositionAtAll() {
        var c = Self.capture(heading: 135, acc: 10)
        c.horizontalAccuracy = nil
        #expect(Self.line(Self.first(capture: c), 2) == "Coordinates: 48.208200, 16.373800")
        // No coordinate: no coordinate line and no Apple Maps distances to give.
        c.coordinate = nil
        let s = Self.first(capture: c)
        #expect(!s.contains("Coordinates:") && !s.contains("Also on Apple Maps"))
        #expect(Self.line(s, 2)?.hasPrefix("Time: ") == true)
    }
    @Test func unknownHeadingUsesCompassWordsAndNoViewFlags() {
        // Accuracy 60 > 45 is unusable. Gate bearing 304.6 → (304.6 + 22.5) / 45 = 7.27 → point 7 = north-west;
        // Albertina bearing ≈ 90 → (90 + 22.5) / 45 = 2.5 → point 2 = east.
        let s = Self.first(heading: 312, acc: 60)
        #expect(s.contains("\nFacing: unknown — identify the subject from position and the photo alone, and be more cautious.\n"))
        #expect(s.contains("- [osm:way/1] Michaelertor (historic=building), 40 m, north-west\n"))
        #expect(s.contains("- Albertina (museum), 70 m, east\n"))
        #expect(!s.contains(", in view") && !s.contains(", out of view"))
    }
    @Test func outOfViewAndUnknownViewFlags() {
        var out = Self.gate
        out.candidate.id = "osm:way/2"
        out.inView = false
        var unknown = Self.gate
        unknown.candidate.id = "osm:way/3"
        unknown.inView = nil
        let g = Grounding(candidates: [Self.gate, out, unknown], address: nil, failedSources: [.wikipedia])
        let s = Self.first(grounding: g)
        #expect(s.contains("- [osm:way/2] Michaelertor (historic=building), 40 m, behind, out of view\n"))
        #expect(s.contains("- [osm:way/3] Michaelertor (historic=building), 40 m, behind\n"))
        #expect(s.contains("Map data unavailable: Wikipedia. Be more cautious."))
    }
    @Test func headingNearNorthWrapsToZero() {
        // 359.6 rounds to 360, which wraps to 0; never prints 360.
        let s = Self.first(heading: 359.6)
        #expect(s.contains("Facing: north (0°), compass ±10°"))
        #expect(!s.contains("360"))
    }
    @Test func candidateSummaryIsCollapsedToOneLine() {
        var gate = Self.gate
        gate.candidate.summary = "Gate of\n the  palace.\n"
        let s = Self.first(grounding: Grounding(candidates: [gate], address: Self.address, failedSources: []))
        #expect(s.contains("\n  Summary: Gate of the palace.\n"))
    }
    @Test func candidateWithoutSummaryOrFactsHasNoIndentedLines() {
        var bare = Self.gate
        bare.candidate.summary = ""
        bare.candidate.tags = ["historic": "building"]
        let s = Self.first(grounding: Grounding(candidates: [bare], address: nil, failedSources: []))
        #expect(!s.contains("Summary:") && !s.contains("OSM:"))
        #expect(s.contains("in view\nTold in the last 3 hours:"))
    }
    @Test func priorsAreListedAndTrimmed() {
        let long = String(repeating: "word ", count: 100)   // 500 chars
        let s = Self.first(recent: [], priors: [Self.prior, PriorStory(placeID: nil, level: .more, text: long, toldAt: .now)])
        #expect(s.contains("Told here before:\n- [osm:way/1] level 1: The emperor rode out here.\n"))
        let line = Self.lines(s).first { $0.hasPrefix("- [nearby, unidentified] level 2: ") }
        // Cut to priorTextLimit 240, plus "…".
        #expect(line?.hasSuffix("…") == true)
        #expect((line?.count ?? .max) <= "- [nearby, unidentified] level 2: ".count + 241)
    }
    @Test func recentPriorsAreNotRepeatedInToldHereBefore() {
        // The prior with the recent story's level and text is listed once, under the last 3 hours.
        let same = PriorStory(placeID: "osm:way/9", level: .first, text: Self.recent.text, toldAt: .now)
        let s = Self.first(priors: [same, Self.prior])
        #expect(s.contains("Told here before:\n- [osm:way/1] level 1: The emperor rode out here.\nLength:"))
        #expect(!s.contains("osm:way/9"))
        #expect(Self.first(priors: [same]).contains("\nTold here before: nothing\n"))
    }
    @Test func recentStoriesAreCappedAtTen() {
        // Twelve stories given newest first; only the first ten (r0 … r9) are listed.
        let twelve = (0..<12).map { RecentStory(toldAt: Self.now - Double($0) * 60, placeName: "r\($0)", level: .first,
                                                text: "Story \($0).", prepared: false) }
        let listed = Self.lines(Self.first(recent: twelve)).filter { $0.contains(" level 1: \"Story ") }
        #expect(listed.count == 10)
        #expect(listed.first?.contains(" r0 ") == true && listed.last?.contains(" r9 ") == true)
        // A prior repeating r11 (not listed) stays under "Told here before", so it is not lost.
        let p = PriorStory(placeID: "osm:way/5", level: .first, text: "Story 11.", toldAt: .now)
        #expect(Self.first(recent: twelve, priors: [p]).contains("Told here before:\n- [osm:way/5] level 1: Story 11.\n"))
    }

    // MARK: - Decoding and schemas

    @Test func decodeNilsUnknownCandidate() throws {
        let ok = Data(#"{"subject":"Michaelertor","confidence":"likely","matchedCandidateID":"osm:way/1","title":"The gate","era":"around 1890","story":"S"}"#.utf8)
        #expect(try PromptBuilder.decodeFirstStory(ok, grounding: Self.grounding).matchedCandidateID == "osm:way/1")
        let bogus = Data(#"{"subject":"X","confidence":"unsure","matchedCandidateID":"osm:way/999","title":"T","era":"E","story":"S"}"#.utf8)
        #expect(try PromptBuilder.decodeFirstStory(bogus, grounding: Self.grounding).matchedCandidateID == nil)
    }
    @Test func decodeUnknownCandidateDowngradesCertain() throws {
        let certainBogus = Data(#"{"subject":"X","confidence":"certain","matchedCandidateID":"osm:way/999","title":"T","era":"E","story":"S"}"#.utf8)
        let decoded = try PromptBuilder.decodeFirstStory(certainBogus, grounding: Self.grounding)
        #expect(decoded.matchedCandidateID == nil && decoded.confidence == .likely)
        // likely and unsure stay as they are when the id is dropped
        let likelyBogus = Data(#"{"subject":"X","confidence":"likely","matchedCandidateID":"osm:way/999","title":"T","era":"E","story":"S"}"#.utf8)
        #expect(try PromptBuilder.decodeFirstStory(likelyBogus, grounding: Self.grounding).confidence == .likely)
        let unsureBogus = Data(#"{"subject":"X","confidence":"unsure","matchedCandidateID":"osm:way/999","title":"T","era":"E","story":"S"}"#.utf8)
        #expect(try PromptBuilder.decodeFirstStory(unsureBogus, grounding: Self.grounding).confidence == .unsure)
        // a known id keeps "certain"; a null id with "certain" is untouched
        let certainKnown = Data(#"{"subject":"X","confidence":"certain","matchedCandidateID":"osm:way/1","title":"T","era":"E","story":"S"}"#.utf8)
        #expect(try PromptBuilder.decodeFirstStory(certainKnown, grounding: Self.grounding).confidence == .certain)
        let certainNull = Data(#"{"subject":"X","confidence":"certain","matchedCandidateID":null,"title":"T","era":"E","story":"S"}"#.utf8)
        #expect(try PromptBuilder.decodeFirstStory(certainNull, grounding: Self.grounding).confidence == .certain)
    }
    @Test func decodeGarbageIsMalformed() {
        #expect(throws: OpenAIError.malformedResponse) { try PromptBuilder.decodeFirstStory(Data("{}".utf8), grounding: Self.grounding) }
    }
    @Test func schemaIsStrictCompatible() throws {
        guard case .object(let o) = PromptBuilder.firstStorySchema, case .array(let req) = try #require(o["required"]) else { Issue.record(); return }
        #expect(req.count == 6 && o["additionalProperties"] == .bool(false))
    }
    @Test func eraDescribesWhenTheSubjectIsBestKnownFrom() throws {
        guard case .object(let o) = PromptBuilder.firstStorySchema, case .ordered(let props) = try #require(o["properties"]),
              case .object(let era) = try #require(props.first { $0.key == "era" }?.value) else { Issue.record(); return }
        #expect(era["description"] == .string("The era the subject is best known from, e.g. 'built 1697' or 'around 1780'"))
    }
    @Test func firstStorySchemaPutsStoryLast() throws {
        let json = String(decoding: try PromptBuilder.firstStorySchema.jsonData(), as: UTF8.self)
        let props = try #require(json.range(of: #""properties":"#)).upperBound
        let eraAt = try #require(json[props...].range(of: #""era":"#)).lowerBound
        let storyAt = try #require(json[props...].range(of: #""story":"#)).lowerBound
        #expect(storyAt > eraAt)
        #expect(json.contains(#""required":["subject","confidence","matchedCandidateID","title","era","story"]"#))
        // Byte-identical on every encoding, so the prompt cache is not broken.
        for _ in 0..<20 { #expect(String(decoding: try PromptBuilder.firstStorySchema.jsonData(), as: UTF8.self) == json) }
    }
    @Test func continuationSchemaRequiresOnlyStory() throws {
        guard case .object(let o) = PromptBuilder.continuationSchema, case .array(let req) = try #require(o["required"]) else { Issue.record(); return }
        #expect(req == [.string("story")] && o["additionalProperties"] == .bool(false))
    }
    @Test func decodeContinuation() throws {
        #expect(try PromptBuilder.decodeContinuation(Data(#"{"story":"Two."}"#.utf8)) == "Two.")
        #expect(throws: OpenAIError.malformedResponse) { try PromptBuilder.decodeContinuation(Data("{}".utf8)) }
        #expect(throws: OpenAIError.malformedResponse) { try PromptBuilder.decodeContinuation(Data(#"{"story":" \n "}"#.utf8)) }
    }

    // MARK: - Photo continuation

    static func session(grounding: Grounding = PromptBuilderTests.grounding, matched: String? = "osm:way/1",
                        language: StoryLanguage = .english) -> StorySession {
        StorySession(id: UUID(), capture: capture(heading: 135, acc: 10), photoJPEG: Data(), thumbnailJPEG: Data(), language: language,
            grounding: grounding,
            identified: IdentifiedStory(subject: "Michaelertor", confidence: .likely, matchedCandidateID: matched, title: "T", era: "around 1890", story: "L1"),
            levels: ["L1 text."])
    }
    static func continuation(_ session: StorySession = PromptBuilderTests.session(), level: StoryLevel = .more,
                             articleText: String? = nil, recent: [RecentStory] = [PromptBuilderTests.recent],
                             priors: [PriorStory] = [PromptBuilderTests.prior]) -> String {
        PromptBuilder.photoContinuationInput(session: session, level: level, articleText: articleText,
                                             recent: recent, priors: priors, now: now, timeZone: utc)
    }

    @Test func continuationFieldOrder() {
        let s = Self.continuation(articleText: "FULL TEXT")
        #expect(Self.fields(s) == ["Story", "Position", "Coordinates", "Time", "Facing", "Subject", "Facts about Michaelertor",
                                   "Also on Apple Maps", "Told so far", "Told in the last 3 hours", "Told here before",
                                   "Length", "Answer in", "Task"])
        let l = Self.lines(s)
        #expect(Self.line(s, 0) == "Story: photo, level 2")
        #expect(Self.line(s, 1) == "Position: Michaelerplatz, Innere Stadt, Vienna, Austria")
        #expect(Self.line(s, 3) == "Time: 13:46 Monday" && Self.line(s, 4) == "Facing: south-east (135°), compass ±10°")
        // Matched gate 35.4 m → 40 m; r = 304.6 − 135 = 169.6 > 150 → behind.
        #expect(Self.line(s, 5) == "Subject: Michaelertor (confidence: likely), 40 m, behind")
        // Albertina 74.1 m → 70 m, bearing ≈ 90 against facing 135: r = −45 → 30 < 45 ≤ 60, negative → ahead-left.
        // The only candidate (the gate) is listed and named otherwise, so nothing is dropped.
        #expect(s.contains("Also on Apple Maps:\n- Albertina (museum), 70 m, ahead-left\nTold so far:\nLevel 1: L1 text.\n"))
        #expect(s.contains("Told in the last 3 hours:\n- 13:36 Hofburg level 1:"))
        #expect(s.contains("Told here before:\n- [osm:way/1] level 1: The emperor rode out here.\n"))
        // 200 words · 60 / 150 = 80 s.
        #expect(s.contains("\nLength: about 200 words (80 seconds spoken), 3–4 points\nAnswer in: English\n"))
        #expect(l.last == "Task: Continue from where the story left off; new points, from another domain where the facts allow; do not repeat.")
    }
    @Test func continuationUsesArticleTextForMatched() {
        let full = Self.continuation(articleText: "FULL TEXT")
        #expect(full.contains("\nFacts about Michaelertor:\n  OSM: start_date=1697\n  Wikipedia: FULL TEXT\n"))
        #expect(!full.contains("Gate of the palace.") && !full.contains("Nearby:"))
        // Without article text (fetch failed or no article), or with an empty one, the summary stands in.
        for missing in [nil, "", " \n "] as [String?] {
            #expect(Self.continuation(articleText: missing).contains("\nFacts about Michaelertor:\n  OSM: start_date=1697\n  Wikipedia: Gate of the palace.\n"))
        }
    }
    @Test func continuationMatchedWithoutAnyFactsSaysSo() {
        var bare = Self.gate
        bare.candidate.summary = nil
        bare.candidate.tags = nil
        let g = Grounding(candidates: [bare], address: Self.address, failedSources: [])
        let s = Self.continuation(Self.session(grounding: g), articleText: nil)
        #expect(s.contains("\nFacts about Michaelertor: none found\n"))
        #expect(s.contains("  Wikipedia: ") == false)
    }
    @Test func continuationUnmatchedListsUpToThreePlacesInView() {
        func rc(_ name: String, _ d: Double, inView: Bool?) -> RankedCandidate {
            RankedCandidate(candidate: Candidate(id: "osm:node/\(name)", name: name, coordinate: .init(latitude: 0, longitude: 0),
                            kind: "historic=yes", summary: "About \(name).", tags: ["architect": "Arch \(name)"]),
                            distance: d, bearing: 135, inView: inView)
        }
        // Ranked order is already in-view-first; the out-of-view one sits between to prove filtering, not slicing.
        // Distances 10, 20, 30 round to themselves; bearing 135 against facing 135: r = 0 → "ahead".
        let g = Grounding(candidates: [rc("A", 10, inView: true), rc("B", 20, inView: true), rc("X", 5, inView: false),
                                       rc("C", 30, inView: true), rc("D", 40, inView: true)], address: nil, failedSources: [])
        let s = Self.continuation(Self.session(grounding: g, matched: nil), recent: [], priors: [])
        #expect(s.contains("\nNearby:\n- [osm:node/A] A (historic=yes), 10 m, ahead, in view\n  Summary: About A.\n  OSM: architect=Arch A\n"
                           + "- [osm:node/B] B (historic=yes), 20 m, ahead, in view\n  Summary: About B.\n  OSM: architect=Arch B\n"
                           + "- [osm:node/C] C (historic=yes), 30 m, ahead, in view\n  Summary: About C.\n  OSM: architect=Arch C\nTold so far:"))
        #expect(!s.contains("[osm:node/X]") && !s.contains("[osm:node/D]") && !s.contains("Facts about"))
        #expect(s.contains("\nTold in the last 3 hours: nothing\nTold here before: nothing\n"))
        // Heading unknown (inView nil everywhere) → the nearest three in ranked order.
        let g2 = Grounding(candidates: [rc("A", 10, inView: nil), rc("B", 20, inView: nil), rc("C", 30, inView: nil), rc("D", 40, inView: nil)],
                           address: nil, failedSources: [])
        let s2 = Self.continuation(Self.session(grounding: g2, matched: nil))
        #expect(s2.contains("[osm:node/C]") && !s2.contains("[osm:node/D]"))
    }
    @Test func continuationWithNothingInViewFallsBackToNearestThree() {
        func rc(_ name: String) -> RankedCandidate {
            RankedCandidate(candidate: Candidate(id: "osm:node/\(name)", name: name, coordinate: .init(latitude: 0, longitude: 0),
                            kind: "historic=yes"), distance: 10, bearing: 0, inView: false)
        }
        let g = Grounding(candidates: [rc("A"), rc("B"), rc("C"), rc("D")], address: nil, failedSources: [])
        let s = Self.continuation(Self.session(grounding: g, matched: nil))
        #expect(s.contains("[osm:node/A]") && s.contains("[osm:node/B]") && s.contains("[osm:node/C]"))
        #expect(!s.contains("[osm:node/D]") && !s.contains("Facts: none found"))
    }
    @Test func continuationWithoutCandidatesOrAddress() {
        let none = Grounding(candidates: [], address: nil, failedSources: [])
        let s = Self.continuation(Self.session(grounding: none, matched: nil), level: .evenMore)
        #expect(Self.line(s, 0) == "Story: photo, level 3")
        #expect(Self.line(s, 1) == "Position: address lookup failed")
        // 300 words · 60 / 150 = 120 s = 2 minutes.
        #expect(s.contains("Length: about 300 words (2 minutes spoken), as many as the facts carry"))
        #expect(s.contains("\nFacts: none found\n") && !s.contains("Also on Apple Maps"))
    }
    @Test func continuationSubjectDistanceFollowsTheMatchedCandidate() {
        // Heading unknown: compass word for bearing 304.6 → (304.6 + 22.5) / 45 = 7.27 → index 7 → north-west.
        var session = Self.session()
        session.capture = Self.capture(heading: nil, acc: nil)
        #expect(Self.continuation(session).contains("\nSubject: Michaelertor (confidence: likely), 40 m, north-west\n"))
        // Unmatched: no candidate to measure, so no distance.
        let unmatched = Self.continuation(Self.session(matched: nil))
        #expect(unmatched.contains("\nSubject: Michaelertor (confidence: likely)\n"))
    }
    @Test func continuationSaysWhichMapDataFailed() {
        let g = Grounding(candidates: [Self.gate], address: Self.address, failedSources: [.openStreetMap, .geocoder],
                          applePlaces: [Self.albertina])
        let s = Self.continuation(Self.session(grounding: g))
        #expect(s.contains("\nFacing: south-east (135°), compass ±10°\nMap data unavailable: OpenStreetMap, address lookup. Be more cautious.\nSubject: "))
        #expect(!Self.continuation().contains("Map data unavailable"))
    }
    @Test func continuationAppleMapsDedupeUsesOnlyTheListedPlaces() {
        // A candidate that shares the Apple place's name but is not listed in this request must not hide it.
        let namesake = RankedCandidate(candidate: Candidate(id: "osm:way/2", name: "Albertina", coordinate: Self.here, kind: "tourism=museum"),
                                       distance: 70, bearing: 90, inView: false)
        let g = Grounding(candidates: [Self.gate, namesake], address: Self.address, failedSources: [], applePlaces: [Self.albertina])
        // Albertina 74.1 m → 70 m at bearing ≈ 90 (see `albertina`); facing 135: r = 90 − 135 = −45 → 30 < 45 ≤ 60, negative
        // → ahead-left. Matched gate: only the gate is listed.
        #expect(Self.continuation(Self.session(grounding: g)).contains("\nAlso on Apple Maps:\n- Albertina (museum), 70 m, ahead-left\n"))
        // Unmatched with the namesake listed among the fact candidates (nothing in view besides the gate → gate only;
        // the namesake is out of view, so the in-view filter leaves it out) → still shown.
        #expect(Self.continuation(Self.session(grounding: g, matched: nil)).contains("\n- Albertina (museum), 70 m, ahead-left\n"))
        // Unmatched, all out of view → nearest three include the namesake → dropped.
        var outOfView = Self.gate
        outOfView.inView = false
        let g2 = Grounding(candidates: [outOfView, namesake], address: Self.address, failedSources: [], applePlaces: [Self.albertina])
        #expect(!Self.continuation(Self.session(grounding: g2, matched: nil)).contains("Also on Apple Maps"))
    }
    @Test func continuationToldSoFarListsEveryLevelInOrder() {
        var session = Self.session()
        session.levels = ["First.", "Second."]
        #expect(Self.continuation(session, level: .evenMore).contains("Told so far:\nLevel 1: First.\nLevel 2: Second.\n"))
    }
    @Test func continuationAnswersInTheSessionLanguageAndDropsRepeatedPriors() {
        let same = PriorStory(placeID: "osm:way/9", level: .first, text: Self.recent.text, toldAt: .now)
        let s = Self.continuation(Self.session(language: .norwegian), priors: [same])
        #expect(s.contains("\nAnswer in: Norwegian Bokmål\n"))
        #expect(s.contains("\nTold here before: nothing\n"))
    }
}
