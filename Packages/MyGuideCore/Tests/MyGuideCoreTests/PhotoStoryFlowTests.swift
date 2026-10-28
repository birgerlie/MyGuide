import Foundation
import Testing
@testable import MyGuideCore

@Suite struct PhotoStoryFlowTests {
    struct Geo: ReverseGeocoding { func address(for: Coordinate) async throws -> Address { Address(line: "Platz", city: "Wien", country: nil) } }
    static let storyJSON = #"{"subject":"Gate","confidence":"likely","matchedCandidateID":"osm:node/1","title":"T","era":"around 1890","story":"Once a coachman waited here."}"#
    static func openAIBody(_ inner: String) -> Data {
        let escaped = String(data: try! JSONEncoder().encode(inner), encoding: .utf8)!
        return Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":\#(escaped)}]}],"usage":{"input_tokens":900,"output_tokens":120}}"#.utf8)
    }
    static func http(_ openAI: Data = openAIBody(storyJSON)) -> StubHTTPClient {
        StubHTTPClient { r in
            switch r.url!.host! {
            case let h where h.contains("overpass"): (200, Data(GroundingTests.osmJSON.utf8))
            case let h where h.contains("wikipedia"): (200, Data(GroundingTests.wikiJSON.utf8))
            default: (200, openAI)
            }
        }
    }
    static func flow(_ http: StubHTTPClient, priors: @escaping PriorStoryLookup = { _, _, _ in [] },
                     recent: @escaping RecentStoryLookup = { _, _ in [] }, pointsOfInterest: PointsOfInterestSearching? = nil,
                     articles: ArticleTextSource? = nil, geocoder: ReverseGeocoding = Geo(),
                     timeZone: TimeZone = TimeZone(identifier: "UTC")!) -> PhotoStoryFlow {
        PhotoStoryFlow(grounding: GroundingService(overpass: .init(http: http), wikipedia: .init(http: http), geocoder: geocoder),
                       openAI: OpenAIClient(apiKey: "k", http: http), priors: priors, recent: recent,
                       pointsOfInterest: pointsOfInterest, articles: articles, timeZone: timeZone,
                       now: { Date(timeIntervalSince1970: 5) })
    }
    static func openAIRequest(_ http: StubHTTPClient) throws -> URLRequest {
        try #require(http.requests.first { $0.url?.host == "api.openai.com" })
    }
    /// The user message's text part.
    static func inputText(_ request: URLRequest) throws -> String {
        let input = try #require(request.jsonBody["input"] as? [[String: Any]])
        let content = try #require(input.first?["content"] as? [[String: Any]])
        return try #require(content.first?["text"] as? String)
    }
    static let capture = GroundingTests.capture(heading: 0, acc: 10)

    @Test func tellsFirstStory() async throws {
        let http = Self.http()
        let (s, usage) = try await Self.flow(http).tellFirstStory(photoJPEG: TestImages.jpeg(width: 4032, height: 3024, orientation: 6),
                                                                capture: Self.capture, language: .english)
        #expect(s.levels == ["Once a coachman waited here."] && s.nextLevel == .more)
        #expect(s.matchedCandidate?.candidate.name == "Gate")
        // Compare components: tuples with labels do not compare directly.
        // 400/4032·3024 = 300, portrait
        let thumb = ImageProcessing.pixelSize(of: s.thumbnailJPEG)!
        #expect(thumb.width == 300 && thumb.height == 400)
        // 1536/4032·3024 = 1152, portrait
        let photo = ImageProcessing.pixelSize(of: s.photoJPEG)!
        #expect(photo.width == 1152 && photo.height == 1536)
        #expect(usage == [UsageEntry(date: Date(timeIntervalSince1970: 5), kind: .story, model: "gpt-5-mini",
                                     inputTokens: 900, outputTokens: 120, words: 0, images: 0)])
        let openAIRequest = http.requests.first { $0.url!.host == "api.openai.com" }!
        let content = ((openAIRequest.jsonBody["input"] as! [[String: Any]])[0]["content"] as! [[String: Any]])
        let b64 = (content[1]["image_url"] as! String).replacingOccurrences(of: "data:image/jpeg;base64,", with: "")
        let sent = ImageProcessing.pixelSize(of: Data(base64Encoded: b64)!)!
        #expect(sent.width == 1152 && sent.height == 1536)
    }
    @Test func noPositionThrowsBeforeAnyRequest() async {
        let http = Self.http(); var cap = Self.capture; cap.coordinate = nil
        await #expect(throws: PhotoStoryError.noPosition) {
            try await Self.flow(http).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: cap, language: .english)
        }
        #expect(http.requests.isEmpty)
    }
    @Test func priorsAreLookedUpByCandidateIDsAndSent() async throws {
        let http = Self.http()
        let seen = LockedBox<(ids: [String], near: Coordinate, session: UUID?)?>(nil)
        let flow = Self.flow(http) { ids, near, session in
            seen.set((ids, near, session))
            return [PriorStory(placeID: "osm:node/1", level: .first, text: "Told before: the coachman.", toldAt: .now)]
        }
        // Non-zero coordinate so a hard-coded (0, 0) would be caught.
        var cap = Self.capture
        cap.coordinate = Coordinate(latitude: 0.0001, longitude: 0.0002)
        _ = try await flow.tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: cap, language: .english)
        let call = try #require(seen.value)
        #expect(Set(call.ids) == ["osm:node/1", "wiki:en/5"])
        #expect(call.near == cap.coordinate)
        #expect(call.session == nil)
        let body = String(decoding: http.requests.first { $0.url!.host == "api.openai.com" }!.httpBody!, as: UTF8.self)
        #expect(body.contains("Told before: the coachman."))
    }
    @Test func refusalPropagates() async {
        let refusal = Data(#"{"output":[{"type":"message","content":[{"type":"refusal","refusal":"no"}]}],"usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)
        await #expect(throws: OpenAIError.refused("no")) {
            try await Self.flow(Self.http(refusal)).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english)
        }
    }
    @Test(arguments: ["", "   \n\t "])
    func emptyStoryIsMalformed(story: String) async {
        let json = #"{"subject":"Gate","confidence":"likely","matchedCandidateID":null,"title":"T","era":"e","story":"\#(story.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t"))"}"#
        await #expect(throws: OpenAIError.malformedResponse) {
            try await Self.flow(Self.http(Self.openAIBody(json))).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english)
        }
    }
    @Test func unreadablePhotoThrowsBeforeAnyRequest() async {
        let http = Self.http()
        await #expect(throws: ImageProcessingError.unreadableImage) {
            try await Self.flow(http).tellFirstStory(photoJPEG: Data("not a jpeg".utf8), capture: Self.capture, language: .english)
        }
        #expect(http.requests.isEmpty)
    }
    @Test func nextLevelRunsOutAfterThreeLevels() async throws {
        var (s, _) = try await Self.flow(Self.http()).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english)
        s.levels += ["two", "three"]
        #expect(s.nextLevel == nil)
    }

    @Test func continueAddsLevelWithoutImage() async throws {
        let http = Self.http(Self.openAIBody(#"{"story":"Level two."}"#))
        let flow = Self.flow(http)
        var s = try await Self.flow(Self.http()).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english).0
        let (next, usage) = try await flow.continueStory(s)
        #expect(next.levels == ["Once a coachman waited here.", "Level two."] && next.nextLevel == .evenMore)
        #expect(usage.count == 1 && usage[0].kind == .story)
        let r = http.requests.first { $0.url!.host == "api.openai.com" }!
        let content = ((r.jsonBody["input"] as! [[String: Any]])[0]["content"] as! [[String: Any]])
        #expect(content.count == 1)                        // text only, no image
        #expect(String(decoding: r.httpBody!, as: UTF8.self).contains("about 200 words"))
        let body = String(decoding: r.httpBody!, as: UTF8.self)
        #expect(body.contains("Once a coachman waited here.") && body.contains(#""name":"continuation""#))
        s.levels = ["a", "b", "c"]
        let before = http.requests.count
        await #expect(throws: PhotoStoryError.noFurtherLevel) { try await flow.continueStory(s) }
        #expect(http.requests.count == before)
    }
    @Test func continuePassesSessionIDToPriorsForExclusion() async throws {
        // Non-zero coordinate so a hard-coded (0, 0) would be caught.
        var cap = Self.capture
        cap.coordinate = Coordinate(latitude: 0.0001, longitude: 0.0002)
        let s = try await Self.flow(Self.http()).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: cap, language: .english).0
        let excluded = LockedBox<UUID?>(nil)
        let ids = LockedBox<[String]>([])
        let near = LockedBox<Coordinate?>(nil)
        let flow = Self.flow(Self.http(Self.openAIBody(#"{"story":"Two."}"#))) { placeIDs, coordinate, exclude in
            excluded.set(exclude); ids.set(placeIDs); near.set(coordinate); return []
        }
        _ = try await flow.continueStory(s)
        #expect(near.value == cap.coordinate)
        #expect(excluded.value == s.id)
        #expect(ids.value == ["osm:node/1"])   // matched candidate only
    }
    @Test(arguments: ["", "   \n\t "])
    func emptyContinuationIsMalformed(story: String) async throws {
        let s = try await Self.flow(Self.http()).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english).0
        let inner = #"{"story":"\#(story.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t"))"}"#
        await #expect(throws: OpenAIError.malformedResponse) {
            try await Self.flow(Self.http(Self.openAIBody(inner))).continueStory(s)
        }
    }
    @Test func continueWithoutCoordinateSkipsPriorsAndDoesNotThrow() async throws {
        var s = try await Self.flow(Self.http()).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english).0
        s.capture.coordinate = nil
        let called = LockedBox<Bool>(false)
        let flow = Self.flow(Self.http(Self.openAIBody(#"{"story":"Two."}"#))) { _, _, _ in called.set(true); return [] }
        let (next, _) = try await flow.continueStory(s)
        #expect(next.levels.last == "Two." && called.value == false)
    }
    @Test func continueWithNothingInViewPassesNearestThreeIDsToPriors() async throws {
        var s = try await Self.flow(Self.http()).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english).0
        func rc(_ n: String) -> RankedCandidate {
            RankedCandidate(candidate: Candidate(id: "osm:node/\(n)", name: n, coordinate: .init(latitude: 0, longitude: 0),
                            kind: "historic=yes", summary: nil, wikipediaTitle: nil, wikidata: nil), distance: 10, bearing: 0, inView: false)
        }
        s.grounding = Grounding(candidates: [rc("A"), rc("B"), rc("C"), rc("D")], address: nil, failedSources: [])
        s.identified.matchedCandidateID = nil
        let ids = LockedBox<[String]>([])
        let flow = Self.flow(Self.http(Self.openAIBody(#"{"story":"Two."}"#))) { placeIDs, _, _ in ids.set(placeIDs); return [] }
        _ = try await flow.continueStory(s)
        #expect(ids.value == ["osm:node/A", "osm:node/B", "osm:node/C"])
    }

    // MARK: - Guide voice

    struct Places: PointsOfInterestSearching {
        var result: [ApplePlace]?
        let calls = LockedBox<[(around: Coordinate, radius: Double)]>([])
        func places(around: Coordinate, radius: Double) async throws -> [ApplePlace] {
            calls.withValue { $0.append((around, radius)) }
            guard let result else { throw URLError(.notConnectedToInternet) }
            return result
        }
    }
    final class Articles: ArticleTextSource, @unchecked Sendable {
        let result: String?
        let titles = LockedBox<[String]>([])
        init(_ result: String?) { self.result = result }
        func text(wikipediaTitle: String) async -> String? {
            titles.withValue { $0.append(wikipediaTitle) }
            return result
        }
    }
    /// 0.0005° east of the capture point (0, 0): 0.0005 · π/180 · 6 371 000 = 55.6 m → 60 m, bearing 90.
    static let museum = ApplePlace(name: "Museum", category: "museum", coordinate: .init(latitude: 0, longitude: 0.0005))

    @Test func instructionsAreOneConstantAcrossLanguagesAndLevels() async throws {
        var sent: [URLRequest] = []
        for language in [StoryLanguage.norwegian, .english] {
            let http = Self.http()
            let session = try await Self.flow(http).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10),
                                                                   capture: Self.capture, language: language).0
            sent.append(try Self.openAIRequest(http))
            let more = Self.http(Self.openAIBody(#"{"story":"Two."}"#))
            _ = try await Self.flow(more).continueStory(session)
            sent.append(try Self.openAIRequest(more))
        }
        let instructions = sent.map { $0.jsonBody["instructions"] as? String }
        #expect(instructions.allSatisfy { $0 == PromptBuilder.systemInstructions })
        // Byte-identical in the encoded bodies too.
        let encoded = try sent.map { try JSONSerialization.data(withJSONObject: try #require($0.jsonBody["instructions"] as? String),
                                                                options: .fragmentsAllowed) }
        #expect(Set(encoded).count == 1)
        for request in sent {
            let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
            #expect(body.contains(#""prompt_cache_key":"myguide-story-v1""#))
        }
        #expect(try Self.inputText(sent[0]).contains("\nAnswer in: Norwegian Bokmål\n"))
        #expect(try Self.inputText(sent[1]).contains("\nAnswer in: Norwegian Bokmål\n"))
        #expect(try Self.inputText(sent[2]).contains("\nAnswer in: English\n"))
    }
    @Test func firstStoryFetchesApplePlacesStoresAndListsThem() async throws {
        let http = Self.http()
        let places = Places(result: [Self.museum])
        let s = try await Self.flow(http, pointsOfInterest: places)
            .tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english).0
        #expect(s.grounding.applePlaces == [Self.museum])
        let call = try #require(places.calls.value.first)
        #expect(places.calls.value.count == 1 && call.around == Self.capture.coordinate && call.radius == ApplePlaces.photoRadius)
        // Facing 0 (accuracy 10): r = 90 − 0 = 90 → 60 < 90 ≤ 120, right → "to your right".
        #expect(try Self.inputText(Self.openAIRequest(http)).contains("\nAlso on Apple Maps:\n- Museum (museum), 60 m, to your right\n"))
        // The continuation reuses the stored places without a new search.
        let more = Self.http(Self.openAIBody(#"{"story":"Two."}"#))
        _ = try await Self.flow(more, pointsOfInterest: places).continueStory(s)
        #expect(places.calls.value.count == 1)
        #expect(try Self.inputText(Self.openAIRequest(more)).contains("\nAlso on Apple Maps:\n- Museum (museum), 60 m, to your right\n"))
    }
    @Test func failedApplePlacesSearchNeverBlocksTheStory() async throws {
        let http = Self.http()
        let s = try await Self.flow(http, pointsOfInterest: Places(result: nil))
            .tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english).0
        #expect(s.grounding.applePlaces == nil && s.levels == ["Once a coachman waited here."])
        #expect(try !Self.inputText(Self.openAIRequest(http)).contains("Also on Apple Maps"))
        // No searcher at all: same outcome.
        let none = try await Self.flow(Self.http())
            .tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english).0
        #expect(none.grounding.applePlaces == nil)
    }

    /// Each side waits (up to 2 s) for the other to have started: run one after the other, the second never starts in
    /// time and its result is missing.
    final class Rendezvous: @unchecked Sendable {
        let geocoderStarted = LockedBox(false), searchStarted = LockedBox(false)
        func await(_ flag: LockedBox<Bool>) async throws {
            for _ in 0..<200 {
                if flag.value { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw URLError(.timedOut)
        }
    }
    struct RendezvousGeo: ReverseGeocoding {
        let r: Rendezvous
        func address(for: Coordinate) async throws -> Address {
            r.geocoderStarted.set(true)
            try await r.await(r.searchStarted)
            return Address(line: "Platz")
        }
    }
    struct RendezvousPlaces: PointsOfInterestSearching {
        let r: Rendezvous
        func places(around: Coordinate, radius: Double) async throws -> [ApplePlace] {
            r.searchStarted.set(true)
            try await r.await(r.geocoderStarted)
            return [PhotoStoryFlowTests.museum]
        }
    }
    @Test func groundingAndApplePlacesRunConcurrently() async throws {
        let r = Rendezvous()
        let s = try await Self.flow(Self.http(), pointsOfInterest: RendezvousPlaces(r: r), geocoder: RendezvousGeo(r: r))
            .tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english).0
        #expect(s.grounding.address == Address(line: "Platz"))
        #expect(s.grounding.applePlaces == [Self.museum])
    }

    @Test func recentStoriesAreLookedUpForTheLastThreeHoursAndSent() async throws {
        let http = Self.http()
        let seen = LockedBox<[(since: Date, excluding: UUID?)]>([])
        let recent: RecentStoryLookup = { since, excluding in
            seen.withValue { $0.append((since, excluding)) }
            // now = 5 s → 00:00:05 UTC; 00:00 is printed.
            return [RecentStory(toldAt: Date(timeIntervalSince1970: 5), placeName: "Tower", level: .first, text: "Tall. Very.", prepared: false)]
        }
        let s = try await Self.flow(http, recent: recent)
            .tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english).0
        // since = now − window = 5 − 3 · 3600 = −10 795 s.
        let first = try #require(seen.value.first)
        #expect(first.since == Date(timeIntervalSince1970: -10_795) && first.excluding == nil)
        #expect(try Self.inputText(Self.openAIRequest(http)).contains("Told in the last 3 hours:\n- 00:00 Tower level 1: \"Tall.\"\n"))
        // The continuation leaves out its own session.
        _ = try await Self.flow(Self.http(Self.openAIBody(#"{"story":"Two."}"#)), recent: recent).continueStory(s)
        #expect(seen.value.count == 2)
        #expect(seen.value.last?.since == Date(timeIntervalSince1970: -10_795) && seen.value.last?.excluding == s.id)
    }
    @Test func timeIsNowInTheInjectedTimeZone() async throws {
        // now = 5 s after 1970-01-01 00:00 UTC (a Thursday); Oslo is UTC+1 → 01:00 Thursday.
        let http = Self.http()
        _ = try await Self.flow(http, timeZone: TimeZone(identifier: "Europe/Oslo")!)
            .tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10), capture: Self.capture, language: .english)
        #expect(try Self.inputText(Self.openAIRequest(http)).contains("\nTime: 01:00 Thursday\n"))
    }

    static func matchedSession(title: String?) async throws -> StorySession {
        var s = try await Self.flow(Self.http()).tellFirstStory(photoJPEG: TestImages.jpeg(width: 10, height: 10),
                                                                capture: Self.capture, language: .english).0
        let index = try #require(s.grounding.candidates.firstIndex { $0.candidate.id == "osm:node/1" })
        s.grounding.candidates[index].candidate.wikipediaTitle = title
        s.grounding.candidates[index].candidate.summary = "Short summary."
        return s
    }
    @Test func continuationUsesArticleTextForMatched() async throws {
        let s = try await Self.matchedSession(title: "de:Tor")
        let articles = Articles("FULL TEXT")
        let http = Self.http(Self.openAIBody(#"{"story":"Two."}"#))
        _ = try await Self.flow(http, articles: articles).continueStory(s)
        #expect(articles.titles.value == ["de:Tor"])
        #expect(try Self.inputText(Self.openAIRequest(http)).contains("\nFacts about Gate:\n  Wikipedia: FULL TEXT\n"))
        // The fetch fails: the summary stands in.
        let failed = Self.http(Self.openAIBody(#"{"story":"Two."}"#))
        _ = try await Self.flow(failed, articles: Articles(nil)).continueStory(s)
        #expect(try Self.inputText(Self.openAIRequest(failed)).contains("\nFacts about Gate:\n  Wikipedia: Short summary.\n"))
    }
    @Test func noArticleFetchWithoutTitleOrMatch() async throws {
        let articles = Articles("FULL TEXT")
        let untitled = try await Self.matchedSession(title: nil)
        _ = try await Self.flow(Self.http(Self.openAIBody(#"{"story":"Two."}"#)), articles: articles).continueStory(untitled)
        var unmatched = try await Self.matchedSession(title: "de:Tor")
        unmatched.identified.matchedCandidateID = nil
        let http = Self.http(Self.openAIBody(#"{"story":"Two."}"#))
        _ = try await Self.flow(http, articles: articles).continueStory(unmatched)
        #expect(articles.titles.value.isEmpty)
        #expect(try Self.inputText(Self.openAIRequest(http)).contains("\nNearby:\n"))
    }
}
