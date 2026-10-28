import Foundation
import Testing
@testable import MyGuideCore

@Suite struct WalkingStoryFlowTests {
    typealias Places = PhotoStoryFlowTests.Places
    typealias Articles = PhotoStoryFlowTests.Articles

    static func body(_ inner: String) throws -> Data {
        let escaped = try #require(String(data: try JSONEncoder().encode(inner), encoding: .utf8))
        return Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":\#(escaped)}]}],"usage":{"input_tokens":10,"output_tokens":5},"status":"completed"}"#.utf8)
    }
    static func http(_ story: String = "S") -> StubHTTPClient {
        StubHTTPClient { _ in (200, try body(#"{"title":"T","story":"\#(story)"}"#)) }
    }
    static let fixedID = UUID()
    static let now = WalkPromptTests.now
    static func flow(_ http: StubHTTPClient, priors: @escaping PriorStoryLookup = { _, _, _ in [] },
                     recent: @escaping RecentStoryLookup = { _, _ in [] }, pointsOfInterest: PointsOfInterestSearching? = nil,
                     articles: ArticleTextSource? = nil) -> WalkingStoryFlow {
        WalkingStoryFlow(openAI: OpenAIClient(apiKey: "k", http: http), priors: priors, recent: recent,
                         pointsOfInterest: pointsOfInterest, articles: articles, timeZone: WalkPromptTests.utc,
                         now: { now }, makeID: { fixedID })
    }
    static let buzz = WalkPromptTests.buzz
    static let here = WalkPromptTests.origin
    static let context = WalkPromptTests.context
    static let facts = WalkPromptTests.facts

    /// The user message text of request `index`.
    static func inputText(_ http: StubHTTPClient, _ index: Int = 0) throws -> String {
        let request = try #require(http.requests.indices.contains(index) ? http.requests[index] : nil)
        let input = try #require(request.jsonBody["input"] as? [[String: Any]])
        let content = try #require(input.first?["content"] as? [[String: Any]])
        return try #require(content.first?["text"] as? String)
    }
    static func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

    @Test func buzzStoryBuildsAWalkStory() async throws {
        let http = Self.http()
        let places = Places(result: [WalkPromptTests.library])
        let (story, usage) = try await Self.flow(http, pointsOfInterest: places)
            .buzzStory(Self.buzz, position: Self.here, context: { Self.context }, nearby: Self.facts, language: .english)
        #expect(story.title == "T" && story.levels == ["S"] && story.kind == .buzz && story.place?.id == Self.buzz.place.candidate.id)
        #expect(story.id == Self.buzz.id && story.detail == "40 m right")
        // Buzz stories now keep the address and the walking direction of the context.
        #expect(story.address == WalkPromptTests.address && story.course == 0)
        #expect(story.position == Self.here && story.createdAt == Self.now && story.applePlaces == [WalkPromptTests.library])
        #expect(usage == [UsageEntry(date: Self.now, kind: .story, model: "gpt-5-mini",
                                     inputTokens: 10, outputTokens: 5, words: 0, images: 0)])
        let call = try #require(places.calls.value.first)
        #expect(places.calls.value.count == 1 && call.around == Self.here && call.radius == ApplePlaces.walkingRadius)
        let request = try #require(http.requests.first)
        let text = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(!text.contains("input_image") && text.contains(#""name":"walk_story""#) && text.contains(#""store":false"#))
        let input = try Self.inputText(http)
        // Library 120 m east (bearing 90), walking north (0): r = 90 → to your right.
        #expect(input.hasPrefix("Story: walking buzz, first level\nPosition: Kirkegata 15, Kvadraturen, Oslo\nTime: 13:46 Monday\n"))
        #expect(input.contains("\nAlso on Apple Maps:\n- Deichman (library), 120 m, to your right\n"))
    }
    @Test func buzzLooksUpTheContextWhileTheOtherFetchesRun() async throws {
        // The context (the address lookup, up to 8 s) must not hold up the Apple Maps search: the provider waits up to
        // 2 s for the search to start. Run one after the other, it would see no search and give up.
        let http = Self.http()
        let places = Places(result: [WalkPromptTests.library])
        let sawSearch = LockedBox(false)
        let context: @Sendable () async -> WalkContext = {
            let deadline = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline {
                if !places.calls.value.isEmpty { sawSearch.set(true); break }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return Self.context
        }
        let (story, _) = try await Self.flow(http, pointsOfInterest: places)
            .buzzStory(Self.buzz, position: Self.here, context: context, nearby: [], language: .english)
        #expect(sawSearch.value)
        // The context still reaches the request and the story.
        #expect(story.address == WalkPromptTests.address && story.course == 0)
        #expect(try Self.inputText(http).contains("\nPosition: Kirkegata 15, Kvadraturen, Oslo\n"))
    }
    @Test func emptyStoryIsMalformed() async {
        await #expect(throws: OpenAIError.malformedResponse) {
            try await Self.flow(Self.http(" ")).buzzStory(Self.buzz, position: Self.here, context: { Self.context }, nearby: [], language: .english)
        }
        await #expect(throws: OpenAIError.malformedResponse) {
            try await Self.flow(Self.http(" ")).stopStory(position: Self.here, context: Self.context, nearby: Self.facts, language: .english)
        }
    }
    @Test func undecodableResponseIsMalformed() async {
        let http = StubHTTPClient { _ in (200, try Self.body(#"{"nope":1}"#)) }
        await #expect(throws: OpenAIError.malformedResponse) {
            try await Self.flow(http).stopStory(position: Self.here, context: Self.context, nearby: Self.facts, language: .english)
        }
    }
    @Test func buzzPriorsStartWithTheBuzzedPlace() async throws {
        let seen = LockedBox<(ids: [String], near: Coordinate, session: UUID?)?>(nil)
        let flow = Self.flow(Self.http()) { ids, near, session in seen.set((ids, near, session)); return [] }
        _ = try await flow.buzzStory(Self.buzz, position: Self.here, context: { Self.context }, nearby: Self.facts, language: .english)
        let call = try #require(seen.value)
        // Buzzed place first, then the other places by tier and distance: castle, church, plaque.
        #expect(call.ids == ["osm:node/1", "osm:node/4", "osm:node/2", "osm:node/3"])
        #expect(call.near == Self.here && call.session == nil)
    }
    @Test func priorsAndRecentStoriesReachThePrompt() async throws {
        let http = Self.http()
        let seen = LockedBox<[(since: Date, excluding: UUID?)]>([])
        let flow = Self.flow(http, priors: { _, _, _ in [PriorStory(placeID: nil, level: .more, text: "Earlier tale.", toldAt: .now)] },
                             recent: { since, excluding in
                                 seen.withValue { $0.append((since, excluding)) }
                                 return [WalkPromptTests.recent]
                             })
        let (story, _) = try await flow.buzzStory(Self.buzz, position: Self.here, context: { Self.context }, nearby: [], language: .english)
        let input = try Self.inputText(http)
        #expect(input.contains("\nTold here before:\n- [nearby, unidentified] level 2: Earlier tale.\n"))
        #expect(input.contains("\nTold in the last 3 hours:\n- 13:36 Akershus Fortress level 1: \"Built in 1299.\"\n"))
        _ = try await flow.continueStory(story, nearby: [])
        // since = now − 3 h = 1 000 000 − 10 800 = 989 200 s, both times; the continuation leaves out its own story.
        #expect(seen.value.map(\.since) == [Date(timeIntervalSince1970: 989_200), Date(timeIntervalSince1970: 989_200)])
        #expect(seen.value.map(\.excluding) == [nil, story.id])
        #expect(try Self.inputText(http, 1).contains("\nTold in the last 3 hours:\n- 13:36 Akershus Fortress"))
    }
    @Test func walkingRequestsUseTheGuideVoiceAndNameTheLanguageOnce() async throws {
        for (language, name) in [(StoryLanguage.norwegian, "Norwegian Bokmål"), (.english, "English")] {
            let http = Self.http()
            let flow = Self.flow(http)
            let (story, _) = try await flow.buzzStory(Self.buzz, position: Self.here, context: { Self.context }, nearby: [], language: language)
            _ = try await flow.continueStory(story, nearby: [])
            _ = try #require(try await flow.stopStory(position: Self.here, context: Self.context, nearby: Self.facts, language: language))
            #expect(http.requests.count == 3)
            for index in 0..<3 {
                let body = http.requests[index].jsonBody
                #expect(body["instructions"] as? String == PromptBuilder.systemInstructions)
                #expect(body["prompt_cache_key"] as? String == "myguide-story-v1")
                let text = try Self.inputText(http, index)
                #expect(text.contains("\nAnswer in: \(name)\nTask: "))
                #expect(Self.count("Answer in:", in: text) == 1)
                #expect(!text.contains("Already told"))
            }
        }
    }
    @Test func stopStoryHasNoPlace() async throws {
        let seen = LockedBox<[String]>([])
        let flow = Self.flow(Self.http()) { ids, _, _ in seen.set(ids); return [] }
        let (story, usage) = try #require(try await flow.stopStory(position: Self.here, context: Self.context,
                                                                     nearby: Self.facts, language: .norwegian))
        #expect(story.kind == .stop && story.place == nil && story.id == Self.fixedID)
        #expect(story.address == WalkPromptTests.address && story.detail == nil && story.course == 0 && story.language == .norwegian)
        #expect(story.title == "T" && story.levels == ["S"] && usage.count == 1)
        // gate, church, plaque are within 150 m; the castle (200 m) is not.
        #expect(seen.value == ["osm:node/1", "osm:node/2", "osm:node/3"])
    }
    @Test func continuationAppendsUpToThreeLevels() async throws {
        let seen = LockedBox<(ids: [String], session: UUID?)?>(nil)
        // Each call answers with a distinct text: "Text 1", "Text 2", ...
        let calls = LockedBox(0)
        let http = StubHTTPClient { _ in
            let n = calls.withValue { $0 += 1; return $0 }
            return (200, try Self.body(#"{"title":"T\#(n)","story":"Text \#(n)"}"#))
        }
        let flow = Self.flow(http) { ids, _, session in seen.set((ids, session)); return [] }
        let (first, _) = try await flow.buzzStory(Self.buzz, position: Self.here, context: { Self.context }, nearby: [], language: .english)
        let (second, usage) = try await flow.continueStory(first, nearby: Self.facts)
        #expect(second.levels == ["Text 1", "Text 2"] && second.title == "T1" && usage.count == 1)
        #expect(seen.value?.ids == ["osm:node/1"] && seen.value?.session == first.id)
        #expect(try Self.inputText(http, 1).hasPrefix("Story: walking buzz, level 2\n"))
        let (third, _) = try await flow.continueStory(second, nearby: Self.facts)
        #expect(third.levels == ["Text 1", "Text 2", "Text 3"])
        #expect(try Self.inputText(http, 2).contains("\nTold so far:\nLevel 1: Text 1\nLevel 2: Text 2\n"))
        await #expect(throws: PhotoStoryError.noFurtherLevel) { try await flow.continueStory(third, nearby: Self.facts) }
    }
    @Test func buzzUsesArticleTextAndFallsBackToSummary() async throws {
        let full = Articles("FULL ARTICLE")
        let http = Self.http()
        let (story, _) = try await Self.flow(http, articles: full)
            .buzzStory(Self.buzz, position: Self.here, context: { Self.context }, nearby: [], language: .english)
        #expect(full.titles.value == ["de:Michaelertor"])
        let input = try Self.inputText(http)
        #expect(input.contains("\nFacts about Michaelertor:\n  OSM: start_date=1725\n  Wikipedia: FULL ARTICLE\n"))
        #expect(!input.contains("Gate of the palace."))
        // The continuation fetches it again for the subject (the cache makes that cheap).
        _ = try await Self.flow(http, articles: full).continueStory(story, nearby: [])
        #expect(full.titles.value == ["de:Michaelertor", "de:Michaelertor"])
        #expect(try Self.inputText(http, 1).contains("\n  Wikipedia: FULL ARTICLE\n"))

        // Fetch failed → the summary.
        let failed = Articles(nil)
        let http2 = Self.http()
        _ = try await Self.flow(http2, articles: failed)
            .buzzStory(Self.buzz, position: Self.here, context: { Self.context }, nearby: [], language: .english)
        #expect(try Self.inputText(http2).contains("\n  Wikipedia: Gate of the palace.\n"))

        // No article title → no fetch at all.
        var untitled = Self.buzz
        untitled.place.candidate.wikipediaTitle = nil
        let unused = Articles("UNUSED")
        _ = try await Self.flow(Self.http(), articles: unused)
            .buzzStory(untitled, position: Self.here, context: { Self.context }, nearby: [], language: .english)
        #expect(unused.titles.value.isEmpty)
    }
    @Test func stopFetchesArticleTextForTheBestPlace() async throws {
        let full = Articles("STOP ARTICLE")
        let http = Self.http()
        _ = try #require(try await Self.flow(http, articles: full)
            .stopStory(position: Self.here, context: Self.context, nearby: Self.facts, language: .english))
        #expect(full.titles.value == ["de:Michaelertor"])
        // Gate 50 m north: a stop story uses compass words, bearing 0 → north.
        #expect(try Self.inputText(http).contains("\nFacts about Michaelertor (historic=city_gate), 50 m, north:\n  OSM: start_date=1725\n  Wikipedia: STOP ARTICLE\n"))
    }
    @Test func stopWithPlacesWithin150mIsNormal() async throws {
        let http = Self.http()
        _ = try #require(try await Self.flow(http).stopStory(position: Self.here, context: Self.context,
                                                              nearby: Self.facts, language: .english))
        let input = try Self.inputText(http)
        #expect(input.hasPrefix("Story: stop, first level\n"))
        // Best listed tier .top: min(75, 50) = 50 words; 50 · 60 / 150 = 20 s.
        #expect(input.contains("\nLength: about 50 words (20 seconds spoken), 2–3 points\n"))
        #expect(input.hasSuffix("\nTask: Tell the user about the spot where they are standing."))
    }
    @Test func stopWithOnlyDistantPlacesPointsToDetour() async throws {
        let good = WalkPromptTests.place("osm:node/30", "Good", "historic=church", north: 300, tier: .good)
        let top = WalkPromptTests.place("osm:node/31", "Top", "historic=castle", north: -450, tier: .top)
        let tooFar = WalkPromptTests.place("osm:node/32", "TooFar", "historic=castle", east: 600, tier: .top)
        let seen = LockedBox<[String]>([])
        let http = Self.http()
        let places = Places(result: [])
        let (story, _) = try #require(try await Self.flow(http, priors: { ids, _, _ in seen.set(ids); return [] }, pointsOfInterest: places)
            .stopStory(position: Self.here, context: Self.context, nearby: [good, tooFar, top], language: .english))
        // A detour story lists no Apple Maps places, so it does not search.
        #expect(story.kind == .stop && story.applePlaces == nil && places.calls.value.isEmpty)
        let input = try Self.inputText(http)
        // Top .top 450 m (bearing 180 → south), then Good .good 300 m (bearing 0 → north); TooFar beyond 500 m.
        #expect(input.contains("\nWorth the detour:\n- Top (historic=castle), 450 m, south\n- Good (historic=church), 300 m, north\n"))
        #expect(!input.contains("TooFar"))
        // No tier: 40 words; 40 · 60 / 150 = 16 s.
        #expect(input.contains("\nLength: about 40 words (16 seconds spoken), 2–3 points\n"))
        #expect(seen.value == ["osm:node/31", "osm:node/30"])
        // Its "More" does not search either, and gives Top (the first detour place) its facts.
        _ = try await Self.flow(http, pointsOfInterest: places).continueStory(story, nearby: [good, tooFar, top])
        #expect(places.calls.value.isEmpty)
        #expect(try Self.inputText(http, 1).contains("\nFacts about Top (historic=castle), 450 m, south: none found\nWorth the detour:\n- Good (historic=church), 300 m, north\n"))
    }
    @Test func stopWithNothingWithin500mIsSilent() async throws {
        let http = Self.http()
        let places = Places(result: [WalkPromptTests.library])
        let articles = Articles("TEXT")
        let looked = LockedBox(0)
        let far = [WalkPromptTests.place("osm:node/70", "Out", "historic=castle", north: 501, tier: .top,
                                         summary: "S", title: "de:Out"),
                   WalkPromptTests.place("osm:node/71", "Away", "historic=castle", east: -900, tier: .top)]
        for nearby in [far, []] {
            let result = try await Self.flow(http, priors: { _, _, _ in looked.withValue { $0 += 1 }; return [] },
                                             recent: { _, _ in looked.withValue { $0 += 1 }; return [] },
                                             pointsOfInterest: places, articles: articles)
                .stopStory(position: Self.here, context: Self.context, nearby: nearby, language: .english)
            #expect(result == nil)
        }
        #expect(http.requests.isEmpty)
        #expect(places.calls.value.isEmpty && articles.titles.value.isEmpty && looked.value == 0)
    }
    @Test func continuationOfStopListsNearbyPlaces() async throws {
        let http = Self.http()
        let flow = Self.flow(http)
        let (story, _) = try #require(try await flow.stopStory(position: Self.here, context: Self.context,
                                                                 nearby: Self.facts, language: .english))
        let seen = LockedBox<(ids: [String], session: UUID?)?>(nil)
        let articles = Articles("GATE TEXT")
        let flow2 = Self.flow(http, priors: { ids, _, session in seen.set((ids, session)); return [] }, articles: articles)
        _ = try await flow2.continueStory(story, nearby: Self.facts)
        let input = try Self.inputText(http, 1)
        // The best place keeps its Facts about with the article text; compass side, gate bearing 0 → north.
        #expect(articles.titles.value == ["de:Michaelertor"])
        #expect(input.hasPrefix("Story: stop, level 2\nPosition: Kirkegata 15, Kvadraturen, Oslo\nTime: 13:46 Monday\n"
                                + "Standing still; walked in heading north along Kirkegata\n"
                                + "Facts about Michaelertor (historic=city_gate), 50 m, north:\n  OSM: start_date=1725\n"
                                + "  Wikipedia: GATE TEXT\nNearby:\n- Peterskirche (amenity=place_of_worship), 80 m, north\n"))
        #expect(input.contains("\nTold so far:\nLevel 1: S\n") && !input.contains("Came from"))
        #expect(seen.value?.ids == ["osm:node/1", "osm:node/2", "osm:node/3"] && seen.value?.session == story.id)
    }
    @Test func stopContinuationWithNoPlacesLeftDoesNotSearchAppleMaps() async throws {
        let http = Self.http()
        let places = Places(result: [WalkPromptTests.library])
        let flow = Self.flow(http, pointsOfInterest: places)
        let stop = WalkStory(id: UUID(), kind: .stop, place: nil, position: Self.here, course: 0, language: .english,
                             title: "T", levels: ["S"], createdAt: Self.now, address: WalkPromptTests.address)
        let (more, _) = try await flow.continueStory(stop, nearby: [])
        #expect(places.calls.value.isEmpty && more.applePlaces == nil && more.levels == ["S", "S"])
        #expect(try Self.inputText(http).contains("\nFacts: none found\n"))
        // With places around again, the search runs.
        _ = try await flow.continueStory(stop, nearby: Self.facts)
        #expect(places.calls.value.count == 1)
    }
    @Test func continuationReusesApplePlaces() async throws {
        let http = Self.http()
        let places = Places(result: [WalkPromptTests.library])
        let flow = Self.flow(http, pointsOfInterest: places)
        let (story, _) = try await flow.buzzStory(Self.buzz, position: Self.here, context: { Self.context }, nearby: [], language: .english)
        let (more, _) = try await flow.continueStory(story, nearby: [])
        #expect(places.calls.value.count == 1 && more.applePlaces == [WalkPromptTests.library])
        // Course 0 kept on the story: library bearing 90 → to your right.
        #expect(try Self.inputText(http, 1).contains("\nAlso on Apple Maps:\n- Deichman (library), 120 m, to your right\nTold so far:\n"))
    }
    @Test func continuationSearchesAgainWhenTheFirstSearchFailed() async throws {
        let http = Self.http()
        let failing = Places(result: nil)
        let (story, _) = try await Self.flow(http, pointsOfInterest: failing)
            .buzzStory(Self.buzz, position: Self.here, context: { Self.context }, nearby: [], language: .english)
        #expect(story.applePlaces == nil && failing.calls.value.count == 1)
        #expect(try !Self.inputText(http).contains("Also on Apple Maps"))
        let working = Places(result: [WalkPromptTests.library])
        let flow = Self.flow(http, pointsOfInterest: working)
        let (more, _) = try await flow.continueStory(story, nearby: [])
        let call = try #require(working.calls.value.first)
        #expect(call.around == story.position && call.radius == ApplePlaces.walkingRadius)
        #expect(more.applePlaces == [WalkPromptTests.library])
        // Stored course 0; library 120 m east: r = 90 → to your right.
        #expect(try Self.inputText(http, 1).contains("\nAlso on Apple Maps:\n- Deichman (library), 120 m, to your right\n"))
        // Level 3 reuses what level 2 found.
        _ = try await flow.continueStory(more, nearby: [])
        #expect(working.calls.value.count == 1)
    }
}
